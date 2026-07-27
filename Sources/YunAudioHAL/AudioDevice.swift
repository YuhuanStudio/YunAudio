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

    public func setNominalSampleRate(_ rate: Double) throws {
        try id.setValue(rate, for: .nominalSampleRate)
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
