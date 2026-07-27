import AVFoundation
import AudioToolbox
import Foundation

/// A third-party Audio Unit that can be put in the chain.
///
/// This is what a plugin means in audio, and it is the one place where loading
/// somebody else's code is the right answer rather than an elaborate way to
/// avoid a JSON file: the format already exists, the system already vets and
/// sandboxes it, thousands of them are already installed, and none of them have
/// to be written here.
///
/// The built-in stages remain Apple's own units because their limiter is better
/// than one written in an afternoon. This is for everything else somebody
/// already owns.
public struct AudioUnitPlugin: Sendable, Hashable, Codable, Identifiable {
    public let type: OSType
    public let subType: OSType
    public let manufacturer: OSType
    public let name: String
    public let manufacturerName: String
    /// True when the unit can be loaded into this process.
    ///
    /// A version 3 unit may insist on running in its own process, and the audio
    /// then makes a round trip across an XPC boundary on every render. That is
    /// fine for a mixing session and not fine inside an IO callback with a
    /// 2.7 ms deadline, so it is reported rather than discovered.
    public let loadsInProcess: Bool

    public var id: String {
        "\(type)-\(subType)-\(manufacturer)"
    }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: type, componentSubType: subType,
            componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }

    public init(
        type: OSType, subType: OSType, manufacturer: OSType, name: String,
        manufacturerName: String, loadsInProcess: Bool
    ) {
        self.type = type
        self.subType = subType
        self.manufacturer = manufacturer
        self.name = name
        self.manufacturerName = manufacturerName
        self.loadsInProcess = loadsInProcess
    }
}

public enum AudioUnitPlugins {

    /// Every effect installed on this machine, minus the ones this application
    /// already offers as built-in stages.
    ///
    /// Apple's own units are filtered out rather than listed twice: somebody
    /// scrolling a list of two hundred plugins does not need to find
    /// `AUPeakLimiter` there as well as in the panel above it, configured
    /// differently and named nothing like it.
    public static func installed() -> [AudioUnitPlugin] {
        let manager = AVAudioUnitComponentManager.shared()
        let wanted: [OSType] = [
            kAudioUnitType_Effect,
            // Music effects take MIDI as well and are otherwise identical; a
            // great many pitch and filter plugins are registered as one.
            kAudioUnitType_MusicEffect,
        ]

        var found: [AudioUnitPlugin] = []
        for type in wanted {
            let description = AudioComponentDescription(
                componentType: type, componentSubType: 0, componentManufacturer: 0,
                componentFlags: 0, componentFlagsMask: 0)
            for component in manager.components(matching: description) {
                let manufacturer = component.audioComponentDescription.componentManufacturer
                guard manufacturer != kAudioUnitManufacturer_Apple else { continue }
                found.append(
                    AudioUnitPlugin(
                        type: component.audioComponentDescription.componentType,
                        subType: component.audioComponentDescription.componentSubType,
                        manufacturer: manufacturer,
                        name: component.name,
                        manufacturerName: component.manufacturerName,
                        loadsInProcess: Self.loadsInProcess(component)))
            }
        }
        // Stable order, so the list does not shuffle between launches.
        return found.sorted {
            ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name)
        }
    }

    /// Whether a component can render inside this process.
    ///
    /// Version 2 units always can. A version 3 unit only if it says so, and
    /// otherwise every render is an XPC round trip — which is fine in a mixing
    /// application and not fine inside an IO callback with a 2.7 ms deadline.
    /// Somebody should be told that before they put it in the path, not after
    /// their call starts breaking up.
    static func loadsInProcess(_ component: AVAudioUnitComponent) -> Bool {
        let flags = component.audioComponentDescription.componentFlags
        guard flags & AudioComponentFlags.isV3AudioUnit.rawValue != 0 else { return true }
        return flags & AudioComponentFlags.canLoadInProcess.rawValue != 0
    }

    /// The parameters a unit publishes, read off the unit itself.
    ///
    /// There is no other way: a third-party unit's controls are whatever its
    /// author decided, and the only description of them is the one it hands
    /// out at runtime. Anything hard-coded here would be a guess about
    /// somebody else's plugin.
    public static func parameters(of unit: AudioComponentInstance) -> [EffectParameter] {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard
            AudioUnitGetPropertyInfo(
                unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0,
                &size, &writable) == noErr, size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioUnitParameterID>.size
        var identifiers = [AudioUnitParameterID](repeating: 0, count: count)
        guard
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0,
                &identifiers, &size) == noErr
        else { return [] }

        return identifiers.compactMap { identifier -> EffectParameter? in
            // Parameter info comes through the property interface rather than
            // a call of its own; the element is the parameter id.
            var info = AudioUnitParameterInfo()
            var infoSize = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            guard
                AudioUnitGetProperty(
                    unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global,
                    identifier, &info, &infoSize) == noErr
            else { return nil }
            // Parameters the unit says are not for a person to touch are not
            // shown. Some units publish dozens of internal ones.
            guard info.flags.contains(.flag_IsReadable),
                info.flags.contains(.flag_IsWritable)
            else { return nil }

            let title: String
            if let name = info.cfNameString?.takeUnretainedValue() as String?, !name.isEmpty {
                title = name
            } else {
                title = withUnsafeBytes(of: info.name) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
            }
            guard !title.isEmpty, info.maxValue > info.minValue else { return nil }

            return EffectParameter(
                id: "p\(identifier)",
                title: title,
                minimum: info.minValue,
                maximum: info.maxValue,
                unit: Self.unitLabel(info.unit),
                defaultValue: info.defaultValue,
                // A parameter the unit itself says is logarithmic gets the
                // curve; guessing from the range would put a decibel control
                // on a log scale, which is wrong twice over.
                isLogarithmic: info.flags.contains(.flag_DisplayLogarithmic)
                    && info.minValue > 0)
        }
    }

    /// The parameter identifier behind one of the ids handed out above.
    public static func parameterID(from id: String) -> AudioUnitParameterID? {
        guard id.hasPrefix("p"), let value = AudioUnitParameterID(id.dropFirst()) else {
            return nil
        }
        return value
    }

    static func unitLabel(_ unit: AudioUnitParameterUnit) -> String {
        switch unit {
        case .decibels: "dB"
        case .hertz: "Hz"
        case .percent, .equalPowerCrossfade: "%"
        case .seconds: "s"
        case .milliseconds: "ms"
        case .ratio: ":1"
        case .cents, .absoluteCents: "cents"
        case .degrees: "°"
        case .beats: "beats"
        case .sampleFrames: "frames"
        default: ""
        }
    }
}
