import AudioToolbox
import AVFoundation
import Foundation
import YunAudioHAL

/// What `AUVoiceProcessingIO` costs, and whether it can be used the way this
/// engine needs.
///
/// Unlike `AUSoundIsolation`, this is an *output* unit rather than an effect: it
/// expects to own a device and drive its own IO. That is a real architectural
/// question, not a detail — an IO unit that opens the microphone itself cannot
/// simply be dropped into an existing IOProc.
///
/// Measured on this machine before anything was built on it:
///
/// - Bound to a duplex device (Razer V2 X, V3 Pro, BlackHole): initialises.
/// - Bound to an input-only device (an iPhone microphone, or the built-in
///   microphone, which has zero output channels): fails with `'bfmt'`,
///   `kAudioUnitErr_FormatNotSupported`. One IO unit means one device, so the
///   microphone it cancels for and the speaker it cancels against have to be
///   the same CoreAudio object.
/// - Left on the system defaults: initialises, because the HAL is willing to
///   pair a separate default input and output for it.
///
/// That last point is what makes the built-in microphone case reachable at all,
/// and the general answer is to hand it a private aggregate built from the
/// chosen microphone and the chosen speaker — which is machinery this project
/// already has.
public struct EchoCancellationReport: Sendable {
    public let isAvailable: Bool
    /// Whether a device was requested, and whether the unit took it. Reported as
    /// three states rather than a bool: an earlier version printed "REFUSED"
    /// when no device had been asked for at all, which is a different fact.
    public enum DeviceBinding: Sendable {
        case notRequested
        case accepted
        case refused
    }
    public let deviceBinding: DeviceBinding
    public let inputLatencySeconds: Double
    public let outputLatencySeconds: Double
    public let supportsAGC: Bool
    public let supportsDucking: Bool
    public let failureReason: String?

    private var bindingDescription: String {
        switch deviceBinding {
        case .notRequested: "not requested — running on the system defaults"
        case .accepted: "accepted"
        case .refused: "refused — the unit kept the system default"
        }
    }

    public var summary: String {
        guard isAvailable else {
            return "AUVoiceProcessingIO unavailable: \(failureReason ?? "unknown")"
        }
        return String(
            format: """
                AUVoiceProcessingIO
                  device selection  %@
                  input latency     %.2f ms
                  output latency    %.2f ms
                  AGC               %@
                  other-audio duck  %@
                """,
            bindingDescription,
            inputLatencySeconds * 1000, outputLatencySeconds * 1000,
            supportsAGC ? "available" : "not available",
            supportsDucking ? "available" : "not available")
    }
}

public enum EchoCancellation {
    public static let componentSubType: OSType = 0x7670_696F  // 'vpio'

    /// Instantiates the unit against a specific input device and reports what it
    /// will and will not do.
    /// - Parameter deviceUID: The device the unit should bind to. It has to
    ///   carry both input and output channels: `AUVoiceProcessingIO` is a single
    ///   IO unit, so the microphone it cancels for and the speaker it cancels
    ///   against must be the same CoreAudio device. Passing nil leaves it on the
    ///   system defaults, which the HAL is willing to treat as a pair.
    public static func probe(inputDeviceUID: String?) -> EchoCancellationReport {
        func failure(_ reason: String) -> EchoCancellationReport {
            .init(
                isAvailable: false, deviceBinding: .notRequested,
                inputLatencySeconds: 0, outputLatencySeconds: 0,
                supportsAGC: false, supportsDucking: false, failureReason: reason)
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: componentSubType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            return failure("component not found")
        }

        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance
        else { return failure("could not instantiate") }
        defer { AudioComponentInstanceDispose(unit) }

        // Element 1 is the microphone side, element 0 the speaker side. Both
        // have to be enabled for the unit to do echo cancellation at all: it
        // cancels by knowing what was played, so an output-less configuration
        // has nothing to cancel against.
        var enable: UInt32 = 1
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enable, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &enable, UInt32(MemoryLayout<UInt32>.size))

        var binding = EchoCancellationReport.DeviceBinding.notRequested
        if let uid = inputDeviceUID, let device = try? AudioDevices.device(uid: uid) {
            var deviceID = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioObjectID>.size))
            binding = status == noErr ? .accepted : .refused
        }

        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else {
            return failure(
                "initialise failed with \(fourCharDescription(initStatus))"
                    + " — a single IO unit cannot open output on an input-only device")
        }
        defer { AudioUnitUninitialize(unit) }

        func latency(scope: AudioUnitScope, element: AudioUnitElement) -> Double {
            var value: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_Latency, scope, element, &value, &size)
            return value
        }

        func supports(_ property: AudioUnitPropertyID) -> Bool {
            var size: UInt32 = 0
            var writable: DarwinBoolean = false
            return AudioUnitGetPropertyInfo(
                unit, property, kAudioUnitScope_Global, 0, &size, &writable) == noErr
        }

        return .init(
            isAvailable: true,
            deviceBinding: binding,
            inputLatencySeconds: latency(scope: kAudioUnitScope_Input, element: 1),
            outputLatencySeconds: latency(scope: kAudioUnitScope_Output, element: 0),
            supportsAGC: supports(AudioUnitPropertyID(kAUVoiceIOProperty_VoiceProcessingEnableAGC)),
            // 2102 is kAUVoiceIOProperty_DuckNonVoiceAudio. Referenced by value
            // because the constant is declared behind an iOS-only guard even
            // though the property id itself is what the unit answers to.
            supportsDucking: supports(AudioUnitPropertyID(2102)),
            failureReason: nil)
    }
}
