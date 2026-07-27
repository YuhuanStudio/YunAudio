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
    ///   - taps: Process taps to fold in as members. Their channels appear
    ///     after the sub-devices' own, on the input side only.
    /// - Throws: `AggregateError` when the member list is empty, the named clock
    ///   master is not among them, or CoreAudio refuses to build the device.
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

    /// An aggregate whose only members are process taps.
    ///
    /// A tap is not readable on its own — it has to be a member of some
    /// aggregate before an IOProc can see it — but it does not need a physical
    /// device for company. That matters when the point is to read an
    /// application's output *without* touching any hardware: adding a speaker
    /// here to satisfy an invariant would put two owners on that speaker, which
    /// is precisely the fight this project exists to avoid.
    ///
    /// The clock comes from the tapped process's own timeline, so there is no
    /// main sub-device to name.
    ///
    /// - Throws: `AggregateError.noSubDevices` when no taps are given, or
    ///   `.creationFailed` when CoreAudio refuses.
    public convenience init(name: String, tapsOnly taps: [ProcessTap]) throws {
        guard !taps.isEmpty else { throw AggregateError.noSubDevices }
        try self.init(name: name, taps: taps, subDevices: [], clockMasterUID: nil)
    }

    private init(
        name: String, taps: [ProcessTap], subDevices: [SubDevice], clockMasterUID: String?
    ) throws {
        let generatedUID = "com.yuhuanstudio.yunaudio.aggregate.\(UUID().uuidString)"
        uid = generatedUID
        self.subDevices = subDevices
        self.clockMasterUID = clockMasterUID ?? ""
        self.taps = taps

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: generatedUID,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        description[kAudioAggregateDeviceTapListKey] = taps.map { tap in
            [kAudioSubTapUIDKey: tap.uid, kAudioSubTapDriftCompensationKey: 0]
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

    /// Aligns every member to one rate before the aggregate starts, returning
    /// what each device was set to beforehand.
    ///
    /// Mixing rates inside an aggregate forces the HAL to convert on more paths
    /// than necessary, so the caller picks a rate all members share and applies
    /// it here. The change persists on the hardware after this process exits, so
    /// the previous values come back with the return value and the caller is
    /// expected to restore them — leaving someone's microphone at a rate they
    /// did not choose is a side effect, not a feature.
    @discardableResult
    public static func alignSampleRate(
        _ rate: Double, across devices: [AudioDevice]
    ) throws -> [String: Double] {
        var previous: [String: Double] = [:]
        for device in devices {
            guard let current = device.currentSampleRate, current != rate else { continue }
            previous[device.uid] = current
            try device.setNominalSampleRate(rate)
        }
        return previous
    }

    /// Puts sample rates back the way `alignSampleRate` found them.
    ///
    /// Best effort: a device that has been unplugged in the meantime is skipped
    /// rather than treated as a failure, because there is nothing to restore.
    public static func restoreSampleRates(_ rates: [String: Double]) {
        for (uid, rate) in rates {
            guard let device = try? AudioDevices.device(uid: uid) else { continue }
            try? device.setNominalSampleRate(rate)
        }
    }

    /// Highest sample rate every device in the list can present.
    public static func highestCommonSampleRate(among devices: [AudioDevice]) -> Double? {
        guard let first = devices.first else { return nil }
        let shared = devices.dropFirst().reduce(Set(first.availableSampleRates)) {
            common, device in
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
