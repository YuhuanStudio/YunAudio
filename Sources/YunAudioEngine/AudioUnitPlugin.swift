import AVFoundation
import AudioToolbox
import Foundation

/// A third-party Audio Unit that can be put in the chain.
///
/// This is what a plugin means in audio, and it is the one place where loading
/// somebody else's code is the right answer rather than an elaborate way to
/// avoid a JSON file: the format already exists and thousands of units are
/// installed. An in-process AU is still untrusted code in this process; format,
/// capacity and latency admission reduce its realtime risk but do not sandbox
/// it or contain a crash.
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
    /// True when `AudioComponentInstanceNew` is forbidden for this component.
    ///
    /// Some AUv3 components can load in process and still require Apple's
    /// asynchronous instantiation API. The realtime host currently refuses
    /// them: blocking a route lock on their callback is unsafe, while an
    /// out-of-process render cannot meet this engine's unbuffered IO deadline.
    public let requiresAsyncInstantiation: Bool

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
        manufacturerName: String, loadsInProcess: Bool,
        requiresAsyncInstantiation: Bool = false
    ) {
        self.type = type
        self.subType = subType
        self.manufacturer = manufacturer
        self.name = name
        self.manufacturerName = manufacturerName
        self.loadsInProcess = loadsInProcess
        self.requiresAsyncInstantiation = requiresAsyncInstantiation
    }

    private enum CodingKeys: String, CodingKey {
        case type, subType, manufacturer, name, manufacturerName, loadsInProcess
        case requiresAsyncInstantiation
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(OSType.self, forKey: .type)
        subType = try values.decode(OSType.self, forKey: .subType)
        manufacturer = try values.decode(OSType.self, forKey: .manufacturer)
        name = try values.decode(String.self, forKey: .name)
        manufacturerName = try values.decode(String.self, forKey: .manufacturerName)
        loadsInProcess = try values.decode(Bool.self, forKey: .loadsInProcess)
        requiresAsyncInstantiation =
            try values.decodeIfPresent(Bool.self, forKey: .requiresAsyncInstantiation) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(subType, forKey: .subType)
        try values.encode(manufacturer, forKey: .manufacturer)
        try values.encode(name, forKey: .name)
        try values.encode(manufacturerName, forKey: .manufacturerName)
        try values.encode(loadsInProcess, forKey: .loadsInProcess)
        try values.encode(requiresAsyncInstantiation, forKey: .requiresAsyncInstantiation)
    }
}

/// Why a plugin somebody asked for is not in the chain.
///
/// A name on its own is not enough to act on. "Stereo Widener could not be
/// loaded" leaves somebody switching it on and off; "it will not accept the
/// chain's mono format, -10868" tells them it is a stereo-only unit and no
/// amount of retrying will change that.
///
/// The `OSStatus` is carried rather than swallowed because it is the only part
/// of this a plugin's author can do anything with.
public struct AudioUnitLoadFailure: Sendable, Hashable, Identifiable {

    /// The step that refused, in the order the chain attempts them.
    public enum Reason: String, Sendable, Hashable, Codable {
        /// Nothing on this machine answers to the description any more.
        case notInstalled
        /// The component is there and would not produce an instance.
        case couldNotInstantiate
        /// It would not take mono 32-bit float at the route's rate — which is
        /// the ordinary answer from a unit that only works in stereo.
        case formatRejected
        /// Both formats accepted and it still would not start.
        case wouldNotInitialise
    }

    public let name: String
    public let reason: Reason
    /// The status behind the refusal, or `noErr` where the step returned no
    /// status of its own — a component that simply is not there.
    public let status: OSStatus

    public var id: String { "\(name)-\(reason.rawValue)" }

    public init(name: String, reason: Reason, status: OSStatus) {
        self.name = name
        self.reason = reason
        self.status = status
    }
}

/// The narrow property surface needed to enumerate one unit's parameters.
///
/// Keeping it behind a value-free interface makes malformed size reports
/// testable without loading untrusted plugin code into the test process.
protocol AudioUnitParameterPropertyReading {
    func parameterListSize() -> (status: OSStatus, byteCount: UInt32)
    func readParameterList(
        into destination: UnsafeMutableRawPointer, byteCapacity: UInt32
    ) -> (status: OSStatus, returnedByteCount: UInt32)
    func readParameterInfo(
        _ identifier: AudioUnitParameterID,
        into destination: UnsafeMutablePointer<AudioUnitParameterInfo>, byteCapacity: UInt32
    ) -> (status: OSStatus, returnedByteCount: UInt32)
}

private struct SystemAudioUnitParameterPropertyReader: AudioUnitParameterPropertyReading {
    let unit: AudioComponentInstance

    func parameterListSize() -> (status: OSStatus, byteCount: UInt32) {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        let status = AudioUnitGetPropertyInfo(
            unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0,
            &size, &writable)
        return (status, size)
    }

    func readParameterList(
        into destination: UnsafeMutableRawPointer, byteCapacity: UInt32
    ) -> (status: OSStatus, returnedByteCount: UInt32) {
        var size = byteCapacity
        let status = AudioUnitGetProperty(
            unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0,
            destination, &size)
        return (status, size)
    }

    func readParameterInfo(
        _ identifier: AudioUnitParameterID,
        into destination: UnsafeMutablePointer<AudioUnitParameterInfo>, byteCapacity: UInt32
    ) -> (status: OSStatus, returnedByteCount: UInt32) {
        var size = byteCapacity
        let status = AudioUnitGetProperty(
            unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global,
            identifier, destination, &size)
        return (status, size)
    }
}

public enum AudioUnitPlugins {

    /// More controls than this cannot be presented usefully and, more
    /// importantly, must not turn a plugin-owned UInt32 into an unbounded host
    /// allocation. The byte cap is checked independently of the element cap.
    static let maximumParameterCount = 4096
    static let maximumParameterListBytes = UInt32(
        maximumParameterCount * MemoryLayout<AudioUnitParameterID>.stride)

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
                        loadsInProcess: Self.loadsInProcess(component),
                        requiresAsyncInstantiation: Self.requiresAsyncInstantiation(
                            component)))
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

    static func requiresAsyncInstantiation(_ component: AVAudioUnitComponent) -> Bool {
        component.audioComponentDescription.componentFlags
            & AudioComponentFlags.requiresAsyncInstantiation.rawValue != 0
    }

    /// Rechecks the installed component instead of trusting a saved catalogue row.
    static func requiresAsyncInstantiation(_ component: AudioComponent) -> Bool {
        var description = AudioComponentDescription()
        guard AudioComponentGetDescription(component, &description) == noErr else {
            // An unreadable description is not permission to use the sync API.
            return true
        }
        return description.componentFlags
            & AudioComponentFlags.requiresAsyncInstantiation.rawValue != 0
    }

    /// The parameters a unit publishes, read off the unit itself.
    ///
    /// There is no other way: a third-party unit's controls are whatever its
    /// author decided, and the only description of them is the one it hands
    /// out at runtime. Anything hard-coded here would be a guess about
    /// somebody else's plugin.
    public static func parameters(of unit: AudioComponentInstance) -> [EffectParameter] {
        parameters(using: SystemAudioUnitParameterPropertyReader(unit: unit))
    }

    static func parameters(
        using reader: AudioUnitParameterPropertyReading
    ) -> [EffectParameter] {
        let advertised = reader.parameterListSize()
        let stride = MemoryLayout<AudioUnitParameterID>.stride
        guard advertised.status == noErr, advertised.byteCount > 0,
            advertised.byteCount <= maximumParameterListBytes,
            advertised.byteCount % UInt32(stride) == 0,
            let byteCapacity = Int(exactly: advertised.byteCount)
        else { return [] }

        let count = byteCapacity / stride
        let (allocationBytes, overflowed) = count.multipliedReportingOverflow(by: stride)
        guard !overflowed, count <= maximumParameterCount,
            allocationBytes == byteCapacity
        else { return [] }

        var identifiers = [AudioUnitParameterID](repeating: 0, count: count)
        let result = identifiers.withUnsafeMutableBytes { storage in
            reader.readParameterList(
                into: storage.baseAddress!, byteCapacity: advertised.byteCount)
        }
        guard result.status == noErr,
            result.returnedByteCount <= advertised.byteCount,
            result.returnedByteCount % UInt32(stride) == 0
        else { return [] }
        let returnedCount = Int(result.returnedByteCount) / stride

        return identifiers.prefix(returnedCount).compactMap { identifier -> EffectParameter? in
            // Parameter info comes through the property interface rather than
            // a call of its own; the element is the parameter id.
            var info = AudioUnitParameterInfo()
            let infoCapacity = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            let infoResult = withUnsafeMutablePointer(to: &info) {
                reader.readParameterInfo(
                    identifier, into: $0, byteCapacity: infoCapacity)
            }
            guard infoResult.status == noErr,
                infoResult.returnedByteCount == infoCapacity
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
                    boundedUTF8Name(raw)
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

    /// Decodes a fixed C tuple without searching beyond the tuple for a NUL.
    static func boundedUTF8Name(_ bytes: UnsafeRawBufferPointer) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end], as: UTF8.self)
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
