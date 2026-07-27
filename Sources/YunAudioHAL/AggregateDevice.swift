import CoreAudio
import Foundation

/// A private aggregate device assembled at runtime.
///
/// This is the whole reason the router works. `AVAudioEngine` drives a single
/// AUHAL, so its input and output are always the same device — verified by
/// object identity, not folklore. Binding several physical devices into one
/// aggregate gives a single IO cycle that reads the microphone and writes the
/// virtual device in the same callback: no ring buffer, no jitter headroom, no
/// user-space sample rate converter.
///
/// The aggregate is created *private*, so it never appears in Audio MIDI Setup
/// or in other applications' device lists, and the HAL tears it down when this
/// process exits — a crash cannot leave debris behind.
public final class AggregateDevice {
    public struct SubDevice: Sendable {
        public let uid: String
        /// When true the HAL resamples this device to track the clock master.
        /// Exactly one sub-device — the master — must have this off.
        public let driftCompensation: Bool

        public init(uid: String, driftCompensation: Bool) {
            self.uid = uid
            self.driftCompensation = driftCompensation
        }
    }

    public let id: AudioObjectID
    public let uid: String
    public let subDevices: [SubDevice]
    /// UID of the sub-device whose clock everything else follows.
    public let clockMasterUID: String
    /// Taps folded in as sub-devices. Retained so they outlive the aggregate
    /// that references them.
    public let taps: [ProcessTap]

    private var isDestroyed = false

    /// Builds the aggregate.
    ///
    /// - Parameters:
    ///   - name: Shown nowhere (the device is private) but useful in traces.
    ///   - subDevices: Members, in the order their channels should appear.
    ///   - clockMasterUID: Must name one of `subDevices`. Prefer the physical
    ///     device: virtual endpoints follow the host clock and adapt cheaply,
    ///     whereas resampling the microphone would touch the signal we are
    ///     trying to keep intact.
    public init(
        name: String,
        subDevices: [SubDevice],
        clockMasterUID: String,
        taps: [ProcessTap] = []
    ) throws {
        guard !subDevices.isEmpty else { throw AggregateError.noSubDevices }
        guard subDevices.contains(where: { $0.uid == clockMasterUID }) else {
            throw AggregateError.clockMasterNotAMember(clockMasterUID)
        }

        let generatedUID = "com.yuhuanstudio.yunaudio.aggregate.\(UUID().uuidString)"
        self.uid = generatedUID
        self.subDevices = subDevices
        self.clockMasterUID = clockMasterUID
        self.taps = taps

        let subDeviceDicts: [[String: Any]] = subDevices.map { subDevice in
            var entry: [String: Any] = [kAudioSubDeviceUIDKey: subDevice.uid]
            if subDevice.driftCompensation {
                entry[kAudioSubDeviceDriftCompensationKey] = 1
                // Drift correction is the only resampling on the path, so it
                // runs at the highest quality the HAL offers rather than the
                // default.
                entry[kAudioSubDeviceDriftCompensationQualityKey] =
                    kAudioAggregateDriftCompensationMaxQuality
            } else {
                entry[kAudioSubDeviceDriftCompensationKey] = 0
            }
            return entry
        }

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: generatedUID,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceDicts,
            kAudioAggregateDeviceMainSubDeviceKey: clockMasterUID,
            // Invisible to every other process, and reaped with this one.
            kAudioAggregateDeviceIsPrivateKey: 1,
            // Not stacked: channels stay addressable per sub-device instead of
            // being summed together.
            kAudioAggregateDeviceIsStackedKey: 0,
        ]

        // Process taps join the aggregate as sub-devices, which is what lets a
        // single IOProc read a microphone and an application's output in the
        // same cycle. Auto-start so the tap begins producing as soon as the
        // device runs, rather than on first read.
        if !taps.isEmpty {
            description[kAudioAggregateDeviceTapListKey] = taps.map { tap in
                [kAudioSubTapUIDKey: tap.uid, kAudioSubTapDriftCompensationKey: 1]
            }
            description[kAudioAggregateDeviceTapAutoStartKey] = 1
        }

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AggregateError.creationFailed(status)
        }
        id = deviceID
    }

    deinit { destroy() }

    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        AudioHardwareDestroyAggregateDevice(id)
    }

    // MARK: Configuration

    public var device: AudioDevice? { try? AudioDevice(id: id) }

    /// Aligns every member to one rate before the aggregate starts.
    ///
    /// Mixing rates inside an aggregate forces the HAL to convert on more paths
    /// than necessary, so the caller picks the highest rate all members share
    /// and applies it here.
    public static func alignSampleRate(_ rate: Double, across devices: [AudioDevice]) throws {
        for device in devices where device.currentSampleRate != rate {
            try device.setNominalSampleRate(rate)
        }
    }

    /// Highest sample rate every device in the list can present.
    public static func highestCommonSampleRate(among devices: [AudioDevice]) -> Double? {
        guard let first = devices.first else { return nil }
        let shared = devices.dropFirst().reduce(Set(first.availableSampleRates)) { common, device in
            common.intersection(device.availableSampleRates)
        }
        return shared.max()
    }

    public func setBufferFrameSize(_ frames: UInt32) throws {
        try id.setValue(frames, for: .bufferFrameSize)
    }

    /// The sub-devices that are being resampled to follow the clock master.
    ///
    /// This — not `kAudioDevicePropertyClockDomain`, which consumer hardware
    /// almost never publishes — is the authoritative answer to "is this path
    /// bit-exact?". We built the aggregate, so we know exactly who is drifting.
    public var driftCorrectedUIDs: [String] {
        subDevices.filter(\.driftCompensation).map(\.uid)
    }
}

public enum AggregateError: Error, CustomStringConvertible {
    case noSubDevices
    case clockMasterNotAMember(String)
    case creationFailed(OSStatus)

    public var description: String {
        switch self {
        case .noSubDevices:
            "an aggregate device needs at least one sub-device"
        case let .clockMasterNotAMember(uid):
            "clock master \(uid) is not among the sub-devices"
        case let .creationFailed(status):
            "AudioHardwareCreateAggregateDevice failed with \(fourCharDescription(status))"
        }
    }
}
