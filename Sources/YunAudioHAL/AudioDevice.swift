import CoreAudio
import Foundation

// MARK: - Property catalogue

extension AudioProperty {
    // System object
    public static var devices: AudioProperty<AudioObjectID> {
        .init(kAudioHardwarePropertyDevices)
    }
    public static var defaultInputDevice: AudioProperty<AudioObjectID> {
        .init(kAudioHardwarePropertyDefaultInputDevice)
    }
    public static var defaultOutputDevice: AudioProperty<AudioObjectID> {
        .init(kAudioHardwarePropertyDefaultOutputDevice)
    }

    // Identity
    public static var deviceUID: AudioProperty<CFString> {
        .init(kAudioDevicePropertyDeviceUID)
    }
    public static var deviceName: AudioProperty<CFString> {
        .init(kAudioObjectPropertyName)
    }
    public static var manufacturer: AudioProperty<CFString> {
        .init(kAudioObjectPropertyManufacturer)
    }
    public static var modelUID: AudioProperty<CFString> { .init(kAudioDevicePropertyModelUID) }
    public static var transportType: AudioProperty<UInt32> {
        .init(kAudioDevicePropertyTransportType)
    }
    public static var canBeDefaultDevice: AudioProperty<UInt32> {
        .init(kAudioDevicePropertyDeviceCanBeDefaultDevice)
    }

    // Clocking and timing
    public static var nominalSampleRate: AudioProperty<Float64> {
        .init(kAudioDevicePropertyNominalSampleRate)
    }
    public static var availableNominalSampleRates: AudioProperty<AudioValueRange> {
        .init(kAudioDevicePropertyAvailableNominalSampleRates)
    }
    public static var clockDomain: AudioProperty<UInt32> {
        .init(kAudioDevicePropertyClockDomain)
    }
    public static var bufferFrameSize: AudioProperty<UInt32> {
        .init(kAudioDevicePropertyBufferFrameSize)
    }
    public static var bufferFrameSizeRange: AudioProperty<AudioValueRange> {
        .init(kAudioDevicePropertyBufferFrameSizeRange)
    }
    public static var latency: AudioProperty<UInt32> { .init(kAudioDevicePropertyLatency) }
    public static var safetyOffset: AudioProperty<UInt32> {
        .init(kAudioDevicePropertySafetyOffset)
    }

    // Streams and formats
    public static var streams: AudioProperty<AudioObjectID> {
        .init(kAudioDevicePropertyStreams)
    }
    public static var streamConfiguration: AudioProperty<AudioBufferList> {
        .init(kAudioDevicePropertyStreamConfiguration)
    }
    public static var isAlive: AudioProperty<UInt32> {
        .init(kAudioDevicePropertyDeviceIsAlive)
    }
    public static var isRunningSomewhere: AudioProperty<UInt32> {
        .init(kAudioDevicePropertyDeviceIsRunningSomewhere)
    }
    public static var volumeScalar: AudioProperty<Float32> {
        .init(kAudioDevicePropertyVolumeScalar)
    }
    public static var mute: AudioProperty<UInt32> { .init(kAudioDevicePropertyMute) }
    public static var volumeDecibels: AudioProperty<Float32> {
        .init(kAudioDevicePropertyVolumeDecibels)
    }
    public static var volumeDecibelRange: AudioProperty<AudioValueRange> {
        .init(kAudioDevicePropertyVolumeRangeDecibels)
    }
}

// MARK: - Transport

public enum AudioTransport: Sendable, Hashable {
    case builtIn, usb, thunderbolt, hdmi, displayPort, bluetooth, airPlay, virtual, aggregate
    case pci, fireWire, avb, other(UInt32), unknown
    /// An iPhone or iPad offered to the Mac through Continuity Capture.
    case continuityCapture
    /// Bluetooth LE Audio, kept apart from classic Bluetooth on purpose.
    ///
    /// It is the one case where the answer to "why does my headset sound like a
    /// telephone the moment anything opens its microphone" is different.
    /// Classic Bluetooth has to leave A2DP for HFP to carry a microphone at
    /// all, and HFP is 8 or 16 kHz mono in both directions — so opening the
    /// microphone drags the *output* down with it. LE Audio's LC3 carries both
    /// directions at a usable rate without switching profile. Folding the two
    /// into one case would mean telling somebody with LE Audio hardware that
    /// they have a problem they do not have.
    case bluetoothLE

    init(rawValue: UInt32?) {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        case kAudioDeviceTransportTypeAVB: self = .avb
        case kAudioDeviceTransportTypeContinuityCaptureWired,
            kAudioDeviceTransportTypeContinuityCaptureWireless,
            0x6363_6170:  // 'ccap', used by macOS 13 before wired and wireless split.
            self = .continuityCapture
        case .some(let raw): self = .other(raw)
        case nil: self = .unknown
        }
    }

    /// Virtual endpoints (BlackHole, aggregates, loopbacks) derive their clock
    /// from the host rather than a crystal, which matters when deciding whether
    /// a routing path needs drift correction.
    public var isVirtual: Bool {
        switch self {
        case .virtual, .aggregate: true
        default: false
        }
    }

    /// Either flavour of Bluetooth, for the places that only care that it is
    /// wireless and shared with a phone.
    public var isBluetooth: Bool {
        switch self {
        case .bluetooth, .bluetoothLE: true
        default: false
        }
    }

    /// True when carrying a microphone costs this transport its output quality.
    ///
    /// Classic Bluetooth only. The radio does one profile at a time: A2DP is
    /// output-only and good, HFP carries both directions and is 8 or 16 kHz
    /// mono, so the moment anything opens the microphone the music becomes a
    /// telephone call. It is not a macOS bug and there is nothing to set —
    /// searched the macOS 27 SDK: CoreAudio publishes no profile or codec
    /// property, and `AVAudioSessionCategoryOptionBluetoothHighQualityRecording`
    /// is marked `API_AVAILABLE(ios(26.0))` and `API_UNAVAILABLE(macos)`.
    ///
    /// What can be done is not to open the microphone. That is what this
    /// application is for.
    public var losesOutputQualityToItsMicrophone: Bool { self == .bluetooth }

    /// Whether opening an input should require a person's explicit choice.
    ///
    /// Continuity Capture turns a nearby iPhone or iPad into a CoreAudio input,
    /// but merely opening it wakes the device and presents a capture request.
    /// It remains available in the picker; defaults, failure recovery and
    /// automated checks must not turn somebody's phone into a microphone.
    public var requiresExplicitInputSelection: Bool { self == .continuityCapture }
}

// MARK: - Device

/// Which side of a route may offer a device before its exact stream topology is
/// loaded.
///
/// CoreAudio publishes this as fixed metadata through
/// `kAudioDevicePropertyDeviceCanBeDefaultDevice`. Keeping it apart from the
/// channel counts matters for Bluetooth: asking an unused headset for its
/// stream configuration can make the plug-in negotiate with the endpoint.
public struct AudioDevicePickerRole: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let input = Self(rawValue: 1 << 0)
    public static let output = Self(rawValue: 1 << 1)
}

public struct AudioDevice: Sendable, Identifiable, Hashable {
    public let id: AudioObjectID
    /// Stable across replug and reboot, unlike `id`. Everything persisted must
    /// key on this.
    public let uid: String
    public let name: String
    public let manufacturer: String?
    public let transport: AudioTransport
    public let inputChannels: Int
    public let outputChannels: Int
    /// Direction metadata used by pickers. For a fully loaded device it agrees
    /// with the exact channel counts; an unused Bluetooth endpoint remains on
    /// both sides until an explicit selection resolves its real topology.
    public let pickerRole: AudioDevicePickerRole
    /// False for a metadata-only Bluetooth endpoint. Selecting it verifies the
    /// live topology before it can enter a route.
    public let pickerRoleIsCertain: Bool
    /// Whether `inputChannels` and `outputChannels` are exact rather than the
    /// deliberately empty values of a metadata-only Bluetooth snapshot.
    public let hasCompleteTopology: Bool
    public let nominalSampleRate: Double
    public let availableSampleRates: [Double]
    /// Stable across units of the same product, unlike `uid`. What device-
    /// specific knowledge keys on.
    public let modelUID: String?
    /// Devices sharing a non-zero clock domain are driven by one clock, so a
    /// path between them needs no rate conversion. Zero means "not published",
    /// which is not the same as "shared" — see `ClockRelationship`.
    public let clockDomain: UInt32?

    public var hasInput: Bool { pickerRole.contains(.input) }
    public var hasOutput: Bool { pickerRole.contains(.output) }

    public init(id: AudioObjectID) throws {
        try self.init(
            id: id, loadingBluetoothCapabilitiesFor: nil,
            operationAdmission: { true })
    }

    /// Package construction path which stops a multi-property snapshot after
    /// the route's absolute deadline. A property call already in flight cannot
    /// be cancelled; every later one asks this closure again.
    package init(
        id: AudioObjectID,
        operationAdmission: @escaping @Sendable () -> Bool
    ) throws {
        try self.init(
            id: id, loadingBluetoothCapabilitiesFor: nil,
            operationAdmission: operationAdmission)
    }

    /// Builds an enumeration snapshot without waking an unrelated Bluetooth
    /// plug-in for live topology or timing capabilities.
    ///
    /// A Bluetooth plug-in can perform real endpoint work while answering even
    /// a scoped direction property. In particular, asking the input scope is
    /// still an input-profile question even when the value is only a Boolean.
    /// Merely opening YunAudio therefore reads identity only and leaves the
    /// endpoint unresolved on both picker sides. An explicit selection performs
    /// the direct UID lookup and removes it from the wrong side if necessary.
    ///
    /// A nil set means an explicit `AudioDevice(id:)` lookup and preserves that
    /// public initialiser's complete snapshot. A non-nil set comes only from
    /// whole-system enumeration and names the Bluetooth endpoints whose timing
    /// the caller genuinely needs.
    init(
        id: AudioObjectID,
        loadingBluetoothCapabilitiesFor selectedUIDs: Set<String>?,
        operationAdmission: @escaping @Sendable () -> Bool = { true }
    ) throws {
        self.id = id
        guard operationAdmission() else { throw CancellationError() }
        uid = try id.string(of: .deviceUID)
        guard operationAdmission() else { throw CancellationError() }
        name = id.optionalString(of: .deviceName) ?? uid
        guard operationAdmission() else { throw CancellationError() }
        manufacturer = id.optionalString(of: .manufacturer)
        guard operationAdmission() else { throw CancellationError() }
        modelUID = id.optionalString(of: .modelUID)
        guard operationAdmission() else { throw CancellationError() }
        transport = AudioTransport(rawValue: id.optionalValue(of: .transportType))
        guard operationAdmission() else { throw CancellationError() }
        let loadsDetails: Bool
        if let selectedUIDs {
            loadsDetails = AudioDevices.shouldLoadDetailedCapabilities(
                transport: transport, uid: uid, selectedUIDs: selectedUIDs)
        } else {
            loadsDetails = true
        }
        let topology = Self.topologySnapshot(
            loadsDetails: loadsDetails,
            readsChannelCount: { scope in
                Self.channelCount(
                    of: id, scope: scope,
                    operationAdmission: operationAdmission)
            })
        guard operationAdmission() else { throw CancellationError() }
        inputChannels = topology.inputChannels
        outputChannels = topology.outputChannels
        pickerRole = topology.pickerRole
        pickerRoleIsCertain = topology.pickerRoleIsCertain
        hasCompleteTopology = topology.isComplete
        if loadsDetails {
            guard operationAdmission() else { throw CancellationError() }
            nominalSampleRate = id.optionalValue(of: .nominalSampleRate) ?? 0
            guard operationAdmission() else { throw CancellationError() }
            let ranges =
                (try? id.array(
                    of: .availableNominalSampleRates,
                    maximumCount: HALSemanticArrayPolicy.maximumFormatsPerObject)) ?? []
            guard operationAdmission() else { throw CancellationError() }
            availableSampleRates = Self.expand(ranges)

            // A published domain of 0 means the device did not join a domain, so it
            // is preserved as nil rather than being compared as a real value.
            let domain = id.optionalValue(of: .clockDomain)
            guard operationAdmission() else { throw CancellationError() }
            clockDomain = (domain == 0) ? nil : domain
        } else {
            nominalSampleRate = 0
            availableSampleRates = []
            clockDomain = nil
        }
    }

    struct TopologySnapshot: Sendable, Equatable {
        let inputChannels: Int
        let outputChannels: Int
        let pickerRole: AudioDevicePickerRole
        let pickerRoleIsCertain: Bool
        let isComplete: Bool
    }

    /// Chooses between unresolved picker metadata and exact stream topology.
    ///
    /// The closures make the HAL boundary countable in a unit test. In
    /// particular, a metadata-only answer must make zero calls to
    /// `readsChannelCount`; that number is the Bluetooth no-wake contract. No
    /// other scoped property closure exists here on purpose.
    static func topologySnapshot(
        loadsDetails: Bool,
        readsChannelCount: (AudioObjectPropertyScope) -> Int
    ) -> TopologySnapshot {
        if loadsDetails {
            let input = readsChannelCount(kAudioObjectPropertyScopeInput)
            let output = readsChannelCount(kAudioObjectPropertyScopeOutput)
            var role: AudioDevicePickerRole = []
            if input > 0 { role.insert(.input) }
            if output > 0 { role.insert(.output) }
            return TopologySnapshot(
                inputChannels: input, outputChannels: output,
                pickerRole: role, pickerRoleIsCertain: true, isComplete: true)
        }

        // Direction itself is a scoped device question. Keep the endpoint
        // available on both sides instead of asking the input profile at idle;
        // the selection boundary already resolves topology before committing.
        return TopologySnapshot(
            inputChannels: 0, outputChannels: 0,
            pickerRole: [.input, .output], pickerRoleIsCertain: false, isComplete: false)
    }

    /// Sums the channels across every buffer in the stream configuration for a
    /// scope. Multi-stream devices (the Seiren V3 Pro exposes several) report
    /// one buffer per stream, so reading only the first undercounts.
    ///
    /// Sixty-four is also the routing topology ceiling. A corrupt or hostile
    /// HAL object which reports billions of channels must be rejected here,
    /// before the application builds dictionaries and scratch storage from a
    /// value which was only ever metadata.
    static let maximumSupportedChannelsPerScope = 64

    static func admittedChannelTotal(_ reported: [UInt32]) -> Int? {
        var total = 0
        for count in reported {
            guard count <= UInt32(maximumSupportedChannelsPerScope) else { return nil }
            let (next, overflowed) = total.addingReportingOverflow(Int(count))
            guard !overflowed, next <= maximumSupportedChannelsPerScope else { return nil }
            total = next
        }
        return total
    }

    static func channelCount(of id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        channelCount(of: id, scope: scope, operationAdmission: { true })
    }

    private static func channelCount(
        of id: AudioObjectID, scope: AudioObjectPropertyScope,
        operationAdmission: () -> Bool
    ) -> Int {
        let property = AudioProperty<AudioBufferList>.streamConfiguration.scoped(to: scope)
        for attempt in 0..<HALArrayReadPolicy.maximumAttempts {
            guard operationAdmission() else { return 0 }
            guard let byteCount = try? id.dataSize(of: property), byteCount > 0,
                (try? HALArrayReadPolicy.elementCount(
                    byteCount: byteCount, for: UInt8.self, selector: property.selector)) != nil
            else { return 0 }

            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }

            var address = property.address
            var size = UInt32(byteCount)
            guard operationAdmission() else { return 0 }
            let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw)
            guard operationAdmission() else { return 0 }
            if status == kAudioHardwareBadPropertySizeError,
                attempt + 1 < HALArrayReadPolicy.maximumAttempts
            {
                continue
            }
            guard status == noErr, Int(size) <= byteCount,
                Int(size) >= MemoryLayout<UInt32>.size
            else { return 0 }

            let declaredCount = raw.load(as: UInt32.self)
            guard
                let count = try? HALAudioBufferListPolicy.bufferCount(
                    byteCount: Int(size), declaredCount: declaredCount,
                    selector: property.selector)
            else { return 0 }
            let buffers = raw.advanced(by: HALAudioBufferListPolicy.headerBytes)
                .assumingMemoryBound(to: AudioBuffer.self)
            var channels = 0
            for index in 0..<count {
                let reported = buffers[index].mNumberChannels
                guard reported <= UInt32(maximumSupportedChannelsPerScope) else { return 0 }
                let (next, overflowed) = channels.addingReportingOverflow(Int(reported))
                guard !overflowed, next <= maximumSupportedChannelsPerScope else { return 0 }
                channels = next
            }
            return channels
        }
        return 0
    }

    /// Flattens `AudioValueRange`s into concrete rates. Continuous ranges (some
    /// virtual drivers advertise 8k–192k as one span) are sampled at the
    /// standard rates that fall inside them, because a UI cannot offer an
    /// infinite set.
    static func expand(_ ranges: [AudioValueRange]) -> [Double] {
        let standard: [Double] = [
            8000, 11025, 16000, 22050, 32000, 44100, 48000,
            64000, 88200, 96000, 176_400, 192_000, 352_800, 384_000,
        ]
        var rates: Set<Double> = []
        for range in ranges {
            guard range.mMinimum.isFinite, range.mMaximum.isFinite,
                range.mMinimum <= range.mMaximum
            else { continue }
            if range.mMinimum == range.mMaximum,
                AudioHardwareValuePolicy.supports(sampleRate: range.mMinimum)
            {
                rates.insert(range.mMinimum)
            } else {
                rates.formUnion(
                    standard.filter { $0 >= range.mMinimum && $0 <= range.mMaximum })
            }
        }
        return rates.sorted()
    }

    // MARK: Live values

    /// Re-read rather than cached: the rate changes underneath us whenever
    /// another process reconfigures the device.
    public var currentSampleRate: Double? { id.optionalValue(of: .nominalSampleRate) }
    public var currentBufferFrameSize: UInt32? { id.optionalValue(of: .bufferFrameSize) }
    public var isAlive: Bool { (id.optionalValue(of: .isAlive) ?? 0) != 0 }
    public var isRunningSomewhere: Bool {
        (id.optionalValue(of: .isRunningSomewhere) ?? 0) != 0
    }

    /// True when this output is a Bluetooth headset that has already dropped to
    /// call quality.
    ///
    /// The signal is the rate. A classic Bluetooth headset sits at 44.1 or
    /// 48 kHz on A2DP, and the moment anything opens its microphone the radio
    /// leaves A2DP for HFP and *both* directions become 8 or 16 kHz mono. The
    /// output device's own nominal rate follows, so a Bluetooth output running
    /// at or below 24 kHz is a headset in a phone call, whether or not the
    /// person wearing it knows they are in one.
    ///
    /// Worth surfacing because the cause is never where the effect is. Music
    /// suddenly sounds like a telephone, and the reason is that some other
    /// application quietly opened the microphone — which is a sentence nobody
    /// on this platform is ever shown.
    ///
    /// LE Audio is excluded rather than merely untested: LC3 carries both
    /// directions without changing profile, so a low rate there means something
    /// else and saying "your headset is in call quality" would be wrong.
    public var hasFallenToCallQuality: Bool {
        guard transport.losesOutputQualityToItsMicrophone, outputChannels > 0 else {
            return false
        }
        guard let rate = currentSampleRate else { return false }
        return rate <= 24000
    }

    /// The name with the manufacturer's own prefix taken off.
    ///
    /// For the places that are narrow enough to truncate. A middle truncation
    /// of "Razer Seiren V2 X" produces "Razer…en V2 X", which keeps the word
    /// every Razer device shares and eats the one that says which device it is.
    /// Dropping the prefix gives "Seiren V2 X", which fits and is the part
    /// anybody was reading.
    ///
    /// Driven by what the device publishes rather than by a list of brands: the
    /// manufacturer is a property, and a name that begins with it is repeating
    /// something the interface either shows elsewhere or does not need. A name
    /// that would be left too short to recognise keeps its prefix — "Razer" on
    /// its own is a better label than nothing.
    public var shortName: String { Self.shortName(of: name, manufacturer: manufacturer) }

    /// The rule on its own, so it can be asserted without a device.
    public static func shortName(of name: String, manufacturer: String?) -> String {
        guard let manufacturer, !manufacturer.isEmpty else { return name }
        // The first word only. Manufacturers publish "Razer Inc" and
        // "Apple Inc." and name their devices after the bare brand.
        guard let brand = manufacturer.split(separator: " ").first, brand.count >= 3,
            name.hasPrefix(brand + " ")
        else { return name }
        let remainder = name.dropFirst(brand.count + 1).trimmingCharacters(in: .whitespaces)
        return remainder.count >= 3 ? remainder : name
    }

    public func latencyFrames(scope: AudioObjectPropertyScope) -> Int {
        let latency = id.optionalValue(of: AudioProperty<UInt32>.latency.scoped(to: scope)) ?? 0
        let safety =
            id.optionalValue(of: AudioProperty<UInt32>.safetyOffset.scoped(to: scope)) ?? 0
        return Int(latency) + Int(safety)
    }

    /// The device's own level control on a scope, when it publishes one.
    ///
    /// Read rather than assumed, because it is somebody else's to move: the
    /// volume keys, System Settings, or any application. A path that claims to
    /// be bit-exact while a control on the device is attenuating it would be
    /// claiming something false.
    public func volumeScalar(scope: AudioObjectPropertyScope) -> Float? {
        id.optionalValue(of: AudioProperty<Float32>.volumeScalar.scoped(to: scope))
    }

    /// True when the system's own volume keys can move this device.
    ///
    /// macOS drives F10–F12 through the default output's volume control, and a
    /// device that publishes none — every aggregate and multi-output device,
    /// and a good deal of HDMI — simply ignores them. Whole projects exist for
    /// nothing but this: `proxy-audio-device` has over a thousand stars for a
    /// driver that does only it.
    ///
    /// Worth asking rather than assuming, because the answer decides what the
    /// interface should say. This application has a master fader that reaches
    /// the output whatever the device thinks, so the honest thing is to point
    /// at it when the keys will not work rather than to leave somebody pressing
    /// them.
    public func hasSettableVolume(scope: AudioObjectPropertyScope) -> Bool {
        let property = AudioProperty<Float32>.volumeScalar.scoped(to: scope)
        guard id.optionalValue(of: property) != nil else { return false }
        return id.isSettable(property)
    }

    /// A CoreAudio four-character code as the four characters it is.
    ///
    /// Every class, scope and selector in the HAL is one of these, and reading
    /// them as decimal is how somebody spends an afternoon looking up 1986884203.
    public static func fourCharacterCode(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "\(value)" }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Every control the HAL publishes for this device, as a list.
    ///
    /// A device is not one object: it owns controls — volume, mute,
    /// data-source, stereo pan, jack detection — one per channel per scope,
    /// and which of them exist is a property of the driver rather than of the
    /// hardware. The Seiren V3 Pro carries a 0–36 dB gain in its own firmware
    /// and macOS's UAC2 driver publishes no volume control for it at all,
    /// while the V2 X publishes one; nothing about the two devices predicts
    /// that, and the only way to know is to ask.
    ///
    /// Worth having as a list rather than as a handful of specific queries,
    /// because the interesting answer is usually the control nobody thought to
    /// look for.
    public struct Control: Sendable, Hashable {
        public let objectID: AudioObjectID
        /// Four-character class code — `vlme`, `mute`, `dsrc`, `slvl`…
        public let classID: UInt32
        public let scope: UInt32
        public let element: UInt32
        public let isSettable: Bool
        /// Where it currently sits, for the controls that carry a level.
        public let scalar: Float?
        /// The same in decibels, when the driver publishes a mapping.
        public let decibels: Float?

        public var className: String { AudioDevice.fourCharacterCode(classID) }
        public var scopeName: String { AudioDevice.fourCharacterCode(scope) }
    }

    public func controls() -> [Control] {
        let owned = AudioProperty<AudioObjectID>(kAudioObjectPropertyOwnedObjects)
        return
            (try? id.array(
                of: owned, maximumCount: HALSemanticArrayPolicy.maximumOwnedObjects
            ))?.compactMap { object -> Control? in
                guard
                    let classID: UInt32 = object.optionalValue(
                        of: .init(kAudioObjectPropertyClass))
                else { return nil }
                // Streams own no controls and are already reported elsewhere.
                guard classID != kAudioStreamClassID else { return nil }
                let scope: UInt32 =
                    object.optionalValue(of: .init(kAudioControlPropertyScope)) ?? 0
                let element: UInt32 =
                    object.optionalValue(of: .init(kAudioControlPropertyElement)) ?? 0
                let level = AudioProperty<Float32>(kAudioLevelControlPropertyScalarValue)
                return Control(
                    objectID: object, classID: classID, scope: scope, element: element,
                    isSettable: object.isSettable(level),
                    scalar: object.optionalValue(of: level),
                    decibels: object.optionalValue(
                        of: AudioProperty<Float32>(kAudioLevelControlPropertyDecibelValue)))
            } ?? []
    }

    public func isMuted(scope: AudioObjectPropertyScope) -> Bool {
        (id.optionalValue(of: AudioProperty<UInt32>.mute.scoped(to: scope)) ?? 0) != 0
    }

    /// True when a control on this device is altering the signal on its way
    /// out — anything but unity gain and unmuted.
    public func alters(scope: AudioObjectPropertyScope) -> Bool {
        if isMuted(scope: scope) { return true }
        guard let volume = volumeScalar(scope: scope) else { return false }
        return volume < 0.999
    }

    /// The device's own gain, before its converter.
    ///
    /// Worth separating from anything the router does: enough analogue gain
    /// lifts the voice above the converter's noise, but it also consumes the
    /// converter's headroom. A digital trim afterwards can neither recover a
    /// clipped input nor improve its signal-to-noise ratio.
    ///
    /// The Seiren V3 Pro publishes 0 to +36 dB here; the built-in microphone
    /// publishes a scalar with no decibel mapping at all, which is why both are
    /// returned and either can be absent.
    public struct HardwareGain: Sendable, Hashable {
        public let scalar: Float
        /// Nil when the device publishes no decibel mapping for its scalar.
        public let decibels: Float?
        public let decibelRange: ClosedRange<Float>?
        public let isSettable: Bool
        /// Which element answered. Zero is the master; anything else is a
        /// channel, and is worth knowing because a device that publishes only
        /// per-channel controls looks like a device with none.
        public let element: AudioObjectPropertyElement
        /// Every element already proven settable during the low-rate control
        /// snapshot. Slider writes reuse this list instead of rediscovering up
        /// to five properties for every pointer event.
        public let settableElements: [AudioObjectPropertyElement]

        public init(
            scalar: Float,
            decibels: Float?,
            decibelRange: ClosedRange<Float>?,
            isSettable: Bool,
            element: AudioObjectPropertyElement,
            settableElements: [AudioObjectPropertyElement] = []
        ) {
            self.scalar = scalar
            self.decibels = decibels
            self.decibelRange = decibelRange
            self.isSettable = isSettable
            self.element = element
            self.settableElements = settableElements
        }
    }

    /// The device's own gain, and which element it turned out to live on.
    ///
    /// Not only the master element. The master is element 0 and a great many
    /// devices publish there, so asking only for it looks like it works — and
    /// this project shipped for months believing the Seiren V3 Pro had no
    /// hardware gain at all because element 0 answers nothing on it. It has
    /// three, on elements 1, 2 and 3, one per capsule tap, each carrying the
    /// full 0 to +36 dB its firmware documents.
    ///
    /// The written-up reverse engineering said the same thing — that macOS's
    /// UAC2 driver does not expose this device's gain and only a USB control
    /// transfer would reach it. It does expose it. Nobody had asked the right
    /// element.
    public func hardwareGain(scope: AudioObjectPropertyScope) -> HardwareGain? {
        var first: HardwareGain?
        var settableElements: [AudioObjectPropertyElement] = []
        for element in gainElements(scope: scope) {
            let volume = AudioProperty<Float32>(
                kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            guard let scalar = id.optionalValue(of: volume) else { continue }
            let isSettable = id.isSettable(volume)
            if isSettable { settableElements.append(element) }
            if first == nil {
                let range = id.optionalValue(
                    of: AudioProperty<AudioValueRange>(
                        kAudioDevicePropertyVolumeRangeDecibels, scope: scope,
                        element: element))
                first = HardwareGain(
                    scalar: scalar,
                    decibels: id.optionalValue(
                        of: AudioProperty<Float32>(
                            kAudioDevicePropertyVolumeDecibels, scope: scope,
                            element: element)),
                    decibelRange: range.map { Float($0.mMinimum)...Float($0.mMaximum) },
                    isSettable: isSettable,
                    element: element)
            }
            // A settable master governs every channel. Scanning the remaining
            // elements would add property round trips without changing either
            // the reading or what the writer should touch.
            if element == kAudioObjectPropertyElementMain, isSettable {
                break
            }
        }
        guard let first else { return nil }
        return HardwareGain(
            scalar: first.scalar,
            decibels: first.decibels,
            decibelRange: first.decibelRange,
            isSettable: !settableElements.isEmpty,
            element: first.element,
            settableElements: settableElements)
    }

    /// Every channel that carries the gain gets it, not only the one that was
    /// found. A three-capsule microphone with one channel turned up and two
    /// left alone is a device somebody will spend an evening on.
    public func setHardwareGain(scalar: Float, scope: AudioObjectPropertyScope) throws {
        // Keep the public convenience boundary fail-fast too: element
        // discovery itself is HAL work and malformed input earns none of it.
        _ = try AudioHardwareValuePolicy.clampedControlScalar(scalar)
        let elements = hardwareGain(scope: scope)?.settableElements ?? []
        try setHardwareGain(scalar: scalar, scope: scope, elements: elements)
    }

    /// Writes a control through elements discovered by a prior low-rate read.
    ///
    /// Validation happens before the first HAL call. The cached list turns a
    /// three-channel slider tick from property discovery plus three writes into
    /// exactly three writes, while a stale element simply returns its HAL error.
    public func setHardwareGain(
        scalar: Float,
        scope: AudioObjectPropertyScope,
        elements: [AudioObjectPropertyElement]
    ) throws {
        // A NaN written to a device control is not merely bad local state: the
        // audio service is shared with the system Sound menu and every other
        // application.
        let value = try AudioHardwareValuePolicy.clampedControlScalar(scalar)
        guard AudioHardwareValuePolicy.supports(hardwareControlElements: elements) else {
            throw AudioHardwareValueError.unsupportedHardwareControlElements(elements)
        }
        var wrote = false
        var lastError: Error?
        for element in elements {
            let volume = AudioProperty<Float32>(
                kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            do {
                try id.setValue(value, for: volume)
                wrote = true
            } catch {
                lastError = error
            }
            // The master, when it exists, governs the rest — writing the
            // channels afterwards would fight it.
            if element == kAudioObjectPropertyElementMain { break }
        }
        if !wrote, let lastError { throw lastError }
    }

    /// Master first, then each channel. Four is generous: the widest capture
    /// device here has three.
    private func gainElements(
        scope: AudioObjectPropertyScope
    )
        -> [AudioObjectPropertyElement]
    {
        [kAudioObjectPropertyElementMain, 1, 2, 3, 4]
    }

    // MARK: The device's own monitoring

    /// The level at which the device feeds its own input back to its own
    /// output, in its own silicon.
    ///
    /// This is what "zero-latency monitoring" on a microphone's box means, and
    /// it is not a figure of speech: the signal never reaches the computer, so
    /// the delay is the converter and nothing else. This application's own
    /// monitoring is 2.7 ms, which is good and is not zero.
    ///
    /// CoreAudio publishes it under `kAudioDevicePropertyScopePlayThrough`, and
    /// on the Seiren V3 Pro it is three settable controls that nothing on macOS
    /// offers to move — Razer's own software does it through a USB request on
    /// Windows and there is no Synapse here.
    ///
    /// The catch, and it is the reason this is offered rather than switched on:
    /// what the device sends back is the *unprocessed* microphone. None of the
    /// processing this application does can be in it, because none of it has
    /// happened yet.
    public func playThrough() -> HardwareGain? {
        hardwareGain(scope: kAudioDevicePropertyScopePlayThrough)
    }

    public func setPlayThrough(scalar: Float) throws {
        try setHardwareGain(scalar: scalar, scope: kAudioDevicePropertyScopePlayThrough)
    }

    /// Sets the nominal sample rate and waits for the device to actually be at
    /// it.
    ///
    /// A sample rate change is asynchronous: `AudioObjectSetPropertyData`
    /// returns as soon as the HAL has accepted the request, and the hardware
    /// gets there some milliseconds later. Anything that reads the rate back
    /// immediately sees the old value, and — far worse — anything that sets a
    /// rate and then exits can leave the device somewhere it never intended.
    /// That is not a test artifact: it is how the application could quit and
    /// leave somebody's interface at 8 kHz.
    ///
    /// - Parameters:
    ///   - rate: The rate to move to.
    ///   - timeout: How long to wait for the device to arrive.
    /// - Throws: `AudioError` if the HAL rejects the request outright.
    /// - Returns: True when the device was observed at the new rate. False
    ///   means it was accepted and had not arrived within the timeout, which is
    ///   worth reporting rather than assuming.
    @discardableResult
    public func setNominalSampleRate(
        _ rate: Double, timeout: TimeInterval = 1.0
    ) throws
        -> Bool
    {
        guard AudioHardwareValuePolicy.supports(sampleRate: rate) else {
            throw AudioHardwareValueError.unsupportedSampleRate(rate)
        }
        guard AudioHardwareValuePolicy.supports(controlWait: timeout) else {
            throw AudioHardwareValueError.unsupportedControlWait(timeout)
        }
        try id.setValue(rate, for: .nominalSampleRate)
        // Poll rather than register a listener: this is a control-thread
        // operation that happens a handful of times per route, and a listener
        // would have to be installed, waited on and torn down for something
        // that is usually true on the first read.
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let current = currentSampleRate, abs(current - rate) < 0.5 { return true }
            usleep(2000)
        } while Date() < deadline
        return false
    }

    public func setBufferFrameSize(_ frames: UInt32) throws {
        guard AudioHardwareValuePolicy.supports(framesPerSlice: frames) else {
            throw AudioHardwareValueError.unsupportedFramesPerSlice(frames)
        }
        try id.setValue(frames, for: .bufferFrameSize)
    }
}

// MARK: - Enumeration

public enum AudioDevices {
    /// A complete snapshot for callers that asked for every device.
    ///
    /// CLI diagnostics and engine verification depend on `hasInput` agreeing
    /// with an exact non-zero channel count. Only the application's picker
    /// inventory uses the deliberately partial API below.
    public static func all() throws -> [AudioDevice] {
        try AudioObjectID.system.array(
            of: .devices, maximumCount: HALSemanticArrayPolicy.maximumDevices
        ).compactMap {
            try? AudioDevice(id: $0)
        }
    }

    /// Picker inventory that leaves unrelated Bluetooth topology asleep.
    public static func inventory(
        loadingBluetoothCapabilitiesFor selectedUIDs: Set<String>
    ) throws -> [AudioDevice] {
        try AudioObjectID.system.array(
            of: .devices, maximumCount: HALSemanticArrayPolicy.maximumDevices
        ).compactMap {
            try? AudioDevice(
                id: $0, loadingBluetoothCapabilitiesFor: selectedUIDs)
        }
    }

    /// Whether a whole-system enumeration should inspect live topology and
    /// timing.
    ///
    /// Non-Bluetooth devices keep the complete historical snapshot. Bluetooth
    /// details are loaded only for an endpoint the caller named; everything
    /// else carries identity and fixed picker-role metadata only.
    static func shouldLoadDetailedCapabilities(
        transport: AudioTransport, uid: String, selectedUIDs: Set<String>
    ) -> Bool {
        !transport.isBluetooth || selectedUIDs.contains(uid)
    }

    public static func device(uid: String) throws -> AudioDevice? {
        guard let deviceID = try objectID(forUID: uid) else { return nil }
        return try AudioDevice(id: deviceID)
    }

    /// Package construction lookup sharing one admission boundary with the
    /// caller's remaining HAL property reads.
    package static func device(
        uid: String,
        operationAdmission: @escaping @Sendable () -> Bool
    ) throws -> AudioDevice? {
        guard operationAdmission() else { throw CancellationError() }
        guard let deviceID = try objectID(forUID: uid) else { return nil }
        guard operationAdmission() else { throw CancellationError() }
        return try AudioDevice(
            id: deviceID, operationAdmission: operationAdmission)
    }

    /// Resolves one UID without constructing a complete device snapshot.
    ///
    /// Lifecycle waits need only know whether an aggregate still exists.
    /// Constructing `AudioDevice` for every poll would also query its streams,
    /// rates and clock domain while the HAL was in the middle of removing it.
    public static func objectID(forUID uid: String) throws -> AudioObjectID? {
        // A UID already identifies one endpoint. Enumerating every endpoint to
        // resolve it asks every plug-in for its stream topology, live nominal
        // rate, available rates and clock domain. Besides making one lookup
        // proportional to the whole machine, that needlessly wakes unrelated
        // Bluetooth plug-ins during route start, clock setup and rate restore.
        //
        // CoreAudio provides this translation specifically so none of those
        // other endpoints has to be inspected. A missing UID is reported as
        // kAudioObjectUnknown rather than as an error.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var qualifier = uid as CFString
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID.system, &address,
                UInt32(MemoryLayout<CFString>.size), UnsafeRawPointer(pointer),
                &outputSize, &deviceID)
        }
        guard status == noErr else {
            throw AudioHALError.status(
                status, selector: kAudioHardwarePropertyTranslateUIDToDevice,
                object: AudioObjectID.system)
        }
        guard outputSize == UInt32(MemoryLayout<AudioObjectID>.size) else {
            throw AudioHALError.unexpectedSize(
                expected: MemoryLayout<AudioObjectID>.size, actual: Int(outputSize),
                selector: kAudioHardwarePropertyTranslateUIDToDevice)
        }
        return deviceID == kAudioObjectUnknown ? nil : deviceID
    }

    public static func defaultInput() throws -> AudioDevice? {
        let id = try AudioObjectID.system.value(of: .defaultInputDevice)
        return id == kAudioObjectUnknown ? nil : try AudioDevice(id: id)
    }

    /// The system input's identity without asking it for topology or timing.
    ///
    /// Picker defaulting needs only enough information to find the row already
    /// present in its inventory. Constructing a complete `AudioDevice` here can
    /// negotiate with a Bluetooth endpoint merely because the app opened.
    public static func defaultInputUID() throws -> String? {
        try readDefaultDeviceUID(
            readsDefaultID: {
                try AudioObjectID.system.value(of: .defaultInputDevice)
            },
            readsUID: { try $0.string(of: .deviceUID) })
    }

    /// Injectable boundary for the two fixed metadata reads above.
    static func readDefaultDeviceUID(
        readsDefaultID: () throws -> AudioObjectID,
        readsUID: (AudioObjectID) throws -> String
    ) throws -> String? {
        let id = try readsDefaultID()
        return id == kAudioObjectUnknown ? nil : try readsUID(id)
    }

    public static func defaultOutput() throws -> AudioDevice? {
        let id = try AudioObjectID.system.value(of: .defaultOutputDevice)
        return id == kAudioObjectUnknown ? nil : try AudioDevice(id: id)
    }

    /// The system output's identity without asking it for topology or timing.
    public static func defaultOutputUID() throws -> String? {
        try readDefaultDeviceUID(
            readsDefaultID: {
                try AudioObjectID.system.value(of: .defaultOutputDevice)
            },
            readsUID: { try $0.string(of: .deviceUID) })
    }

    /// Points the whole system at a device, the way the Sound pane does.
    ///
    /// By UID and not by ID: the numeric ID is reassigned when a device is
    /// replugged or the machine reboots, so a stored one eventually names
    /// somebody else's hardware. A device that is not here is not an error —
    /// it is the ordinary case of restoring a setup somewhere the interface is
    /// not plugged in — so it is reported rather than thrown.
    ///
    /// - Returns: True when CoreAudio accepted the property write. A caller
    ///   requiring completion must read the default back to observe it.
    @discardableResult
    public static func setDefault(_ uid: String, forInput: Bool) throws -> Bool {
        guard let deviceID = try objectID(forUID: uid) else { return false }
        try AudioObjectID.system.setValue(
            deviceID, for: forInput ? .defaultInputDevice : .defaultOutputDevice)
        return true
    }
}

// MARK: - Clock relationship

/// Whether a signal path between two devices can be sample-exact.
///
/// This is the basis for the app's path-quality readout. Claiming "lossless"
/// without checking this would be a lie whenever two crystals are involved:
/// something has to reconcile them, and reconciliation means resampling.
public enum ClockRelationship: Sendable, Hashable {
    /// One device, or two devices in the same published clock domain. No rate
    /// conversion happens; the path is bit-exact.
    case sameDomain
    /// Distinct published domains. The HAL will drift-correct, which resamples.
    case differentDomains
    /// At least one device publishes no domain. Drift correction is still
    /// applied, so the path must be assumed non-exact.
    case unknown

    public var isBitExact: Bool { self == .sameDomain }
}

extension AudioDevice {
    public func clockRelationship(to other: AudioDevice) -> ClockRelationship {
        if id == other.id { return .sameDomain }
        guard let mine = clockDomain, let theirs = other.clockDomain else { return .unknown }
        return mine == theirs ? .sameDomain : .differentDomains
    }
}
