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

    init(rawValue: UInt32?) {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        case kAudioDeviceTransportTypeAVB: self = .avb
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
}

// MARK: - Device

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
    public let nominalSampleRate: Double
    public let availableSampleRates: [Double]
    /// Stable across units of the same product, unlike `uid`. What device-
    /// specific knowledge keys on.
    public let modelUID: String?
    /// Devices sharing a non-zero clock domain are driven by one clock, so a
    /// path between them needs no rate conversion. Zero means "not published",
    /// which is not the same as "shared" — see `ClockRelationship`.
    public let clockDomain: UInt32?

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    public init(id: AudioObjectID) throws {
        self.id = id
        uid = try id.string(of: .deviceUID)
        name = id.optionalString(of: .deviceName) ?? uid
        manufacturer = id.optionalString(of: .manufacturer)
        modelUID = id.optionalString(of: .modelUID)
        transport = AudioTransport(rawValue: id.optionalValue(of: .transportType))
        inputChannels = Self.channelCount(of: id, scope: kAudioObjectPropertyScopeInput)
        outputChannels = Self.channelCount(of: id, scope: kAudioObjectPropertyScopeOutput)
        nominalSampleRate = id.optionalValue(of: .nominalSampleRate) ?? 0

        let ranges = (try? id.array(of: .availableNominalSampleRates)) ?? []
        availableSampleRates = Self.expand(ranges)

        // A published domain of 0 means the device did not join a domain, so it
        // is preserved as nil rather than being compared as a real value.
        let domain = id.optionalValue(of: .clockDomain)
        clockDomain = (domain == 0) ? nil : domain
    }

    /// Sums the channels across every buffer in the stream configuration for a
    /// scope. Multi-stream devices (the Seiren V3 Pro exposes several) report
    /// one buffer per stream, so reading only the first undercounts.
    static func channelCount(of id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        let property = AudioProperty<AudioBufferList>.streamConfiguration.scoped(to: scope)
        guard let byteCount = try? id.dataSize(of: property), byteCount > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        var address = property.address
        var size = UInt32(byteCount)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
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
            if range.mMinimum == range.mMaximum {
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

    /// Presentation latency in frames for a scope, combining the device's own
    /// latency with the safety offset the HAL keeps ahead of the IO cycle.
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
    /// Worth separating from anything the router does: this happens in the
    /// hardware ahead of the analogue-to-digital step, so turning it up costs
    /// nothing in headroom. A digital trim after the fact can only ever amplify
    /// what the converter already decided, noise included. The right order is
    /// this first, then the trim.
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
    }

    public func hardwareGain(scope: AudioObjectPropertyScope) -> HardwareGain? {
        let volume = AudioProperty<Float32>.volumeScalar.scoped(to: scope)
        guard let scalar = id.optionalValue(of: volume) else { return nil }
        let decibels = id.optionalValue(
            of: AudioProperty<Float32>.volumeDecibels.scoped(to: scope))
        let range = id.optionalValue(
            of: AudioProperty<AudioValueRange>.volumeDecibelRange.scoped(to: scope))
        return HardwareGain(
            scalar: scalar,
            decibels: decibels,
            decibelRange: range.map { Float($0.mMinimum)...Float($0.mMaximum) },
            isSettable: id.isSettable(volume))
    }

    public func setHardwareGain(scalar: Float, scope: AudioObjectPropertyScope) throws {
        try id.setValue(
            Float32(max(0, min(1, scalar))),
            for: AudioProperty<Float32>.volumeScalar.scoped(to: scope))
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
        try id.setValue(frames, for: .bufferFrameSize)
    }
}

// MARK: - Enumeration

public enum AudioDevices {
    public static func all() throws -> [AudioDevice] {
        try AudioObjectID.system.array(of: .devices).compactMap { try? AudioDevice(id: $0) }
    }

    public static func device(uid: String) throws -> AudioDevice? {
        try all().first { $0.uid == uid }
    }

    public static func defaultInput() throws -> AudioDevice? {
        let id = try AudioObjectID.system.value(of: .defaultInputDevice)
        return id == kAudioObjectUnknown ? nil : try AudioDevice(id: id)
    }

    public static func defaultOutput() throws -> AudioDevice? {
        let id = try AudioObjectID.system.value(of: .defaultOutputDevice)
        return id == kAudioObjectUnknown ? nil : try AudioDevice(id: id)
    }

    /// Points the whole system at a device, the way the Sound pane does.
    ///
    /// By UID and not by ID: the numeric ID is reassigned when a device is
    /// replugged or the machine reboots, so a stored one eventually names
    /// somebody else's hardware. A device that is not here is not an error —
    /// it is the ordinary case of restoring a setup somewhere the interface is
    /// not plugged in — so it is reported rather than thrown.
    ///
    /// - Returns: True when the system moved.
    @discardableResult
    public static func setDefault(_ uid: String, forInput: Bool) throws -> Bool {
        guard let device = try device(uid: uid) else { return false }
        try AudioObjectID.system.setValue(
            device.id, for: forInput ? .defaultInputDevice : .defaultOutputDevice)
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
