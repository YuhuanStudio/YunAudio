import CoreAudio
import Foundation

/// Formats an untrusted HAL floating-point value without using a trapping
/// `Double`-to-`Int` conversion on the error-reporting path.
public func audioIntegerDescription(_ value: Double) -> String {
    let rounded = value.rounded(.towardZero)
    guard let integer = Int(exactly: rounded) else { return String(describing: value) }
    return String(integer)
}

extension AudioProperty {
    public static var streamDirection: AudioProperty<UInt32> {
        .init(kAudioStreamPropertyDirection)
    }
    public static var startingChannel: AudioProperty<UInt32> {
        .init(kAudioStreamPropertyStartingChannel)
    }
    public static var physicalFormat: AudioProperty<AudioStreamBasicDescription> {
        .init(kAudioStreamPropertyPhysicalFormat)
    }
    public static var virtualFormat: AudioProperty<AudioStreamBasicDescription> {
        .init(kAudioStreamPropertyVirtualFormat)
    }
    public static var availablePhysicalFormats: AudioProperty<AudioStreamRangedDescription> {
        .init(kAudioStreamPropertyAvailablePhysicalFormats)
    }
    public static var availableVirtualFormats: AudioProperty<AudioStreamRangedDescription> {
        .init(kAudioStreamPropertyAvailableVirtualFormats)
    }
}

/// How samples sit in memory on the wire.
///
/// The distinction that matters here is integer versus float: the Seiren V3 Pro
/// advertises 32-bit float support, which on Windows is gated behind Synapse.
/// If the macOS class driver already publishes a float physical format we get
/// it for free, with no reverse engineering at all.
public enum SampleEncoding: Sendable, Hashable, CustomStringConvertible {
    case signedInteger(bits: Int)
    case unsignedInteger(bits: Int)
    case float(bits: Int)
    case other(formatID: UInt32)

    init(_ asbd: AudioStreamBasicDescription) {
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            self = .other(formatID: asbd.mFormatID)
            return
        }
        let bits = Int(asbd.mBitsPerChannel)
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            self = .float(bits: bits)
        } else if asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            self = .signedInteger(bits: bits)
        } else {
            self = .unsignedInteger(bits: bits)
        }
    }

    public var isFloat: Bool {
        if case .float = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case let .signedInteger(bits): "int\(bits)"
        case let .unsignedInteger(bits): "uint\(bits)"
        case let .float(bits): "float\(bits)"
        case let .other(formatID): "format \(fourCharDescription(formatID))"
        }
    }
}

public struct StreamFormat: Sendable, Hashable, CustomStringConvertible {
    public let sampleRate: Double
    public let channels: Int
    public let encoding: SampleEncoding
    public let isInterleaved: Bool

    init(_ asbd: AudioStreamBasicDescription) {
        sampleRate = asbd.mSampleRate
        channels = Int(asbd.mChannelsPerFrame)
        encoding = SampleEncoding(asbd)
        isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    }

    public var description: String {
        let rate = sampleRate == 0 ? "any" : "\(audioIntegerDescription(sampleRate)) Hz"
        return
            "\(rate) · \(channels)ch · \(encoding)\(isInterleaved ? "" : " · non-interleaved")"
    }
}

public struct AudioStream: Sendable, Identifiable {
    public let id: AudioObjectID
    public let isInput: Bool
    /// First channel of the owning device that this stream carries. Needed to
    /// map a device-level channel pair onto the stream that actually holds it.
    public let startingChannel: Int
    /// Format presented to an IOProc. This can differ from the wire encoding.
    public let currentVirtualFormat: StreamFormat?
    public let currentPhysicalFormat: StreamFormat?
    public let availablePhysicalFormats: [StreamFormat]

    public init(id: AudioObjectID) {
        self.id = id
        // Direction is 1 for input, 0 for output.
        isInput = (id.optionalValue(of: .streamDirection) ?? 0) == 1
        startingChannel = Int(id.optionalValue(of: .startingChannel) ?? 1)
        currentVirtualFormat = id.optionalValue(of: .virtualFormat).map(StreamFormat.init)
        currentPhysicalFormat = id.optionalValue(of: .physicalFormat).map(StreamFormat.init)

        let ranged =
            (try? id.array(
                of: .availablePhysicalFormats,
                maximumCount: HALSemanticArrayPolicy.maximumFormatsPerObject)) ?? []
        var seen: Set<StreamFormat> = []
        availablePhysicalFormats = ranged.compactMap { entry in
            let format = StreamFormat(entry.mFormat)
            return seen.insert(format).inserted ? format : nil
        }
    }

    public func setPhysicalFormat(_ format: AudioStreamBasicDescription) throws {
        try id.setValue(format, for: .physicalFormat)
    }
}

extension AudioDevice {
    public func streams(scope: AudioObjectPropertyScope) -> [AudioStream] {
        let property = AudioProperty<AudioObjectID>.streams.scoped(to: scope)
        let ids =
            (try? id.array(
                of: property,
                maximumCount: HALSemanticArrayPolicy.maximumStreamsPerDevice)) ?? []
        return ids.map(AudioStream.init(id:))
    }

    public var inputStreams: [AudioStream] { streams(scope: kAudioObjectPropertyScopeInput) }
    public var outputStreams: [AudioStream] { streams(scope: kAudioObjectPropertyScopeOutput) }

    /// Every distinct physical format the device can present on input.
    public var availableInputFormats: [StreamFormat] {
        var seen: Set<StreamFormat> = []
        return inputStreams.flatMap(\.availablePhysicalFormats).filter {
            seen.insert($0).inserted
        }
    }

    /// True when the hardware will hand us 32-bit float directly, so no
    /// integer quantisation happens anywhere on the capture path.
    public var supportsFloatInput: Bool {
        availableInputFormats.contains { $0.encoding.isFloat }
    }
}
