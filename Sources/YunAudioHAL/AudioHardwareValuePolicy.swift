import CoreAudio
import Foundation

/// Values the routing and DSP implementation can represent with bounded
/// storage. HAL metadata is a report, not permission to allocate from it.
public enum AudioHardwareValuePolicy {
    public static let minimumSampleRate = 8_000.0
    public static let maximumSampleRate = 384_000.0
    public static let maximumFramesPerSlice: UInt32 = 4_096
    public static let maximumControlWait: TimeInterval = 10
    public static let maximumHardwareControlElements = 5

    public static func supports(sampleRate: Double) -> Bool {
        sampleRate.isFinite
            && sampleRate >= minimumSampleRate
            && sampleRate <= maximumSampleRate
    }

    public static func supports(framesPerSlice: UInt32) -> Bool {
        framesPerSlice > 0 && framesPerSlice <= maximumFramesPerSlice
    }

    public static func supports(controlWait: TimeInterval) -> Bool {
        controlWait.isFinite && controlWait > 0 && controlWait <= maximumControlWait
    }

    /// Converts a finite UI scalar to the exact range accepted by Core Audio.
    /// Non-finite values are rejected rather than handed to `coreaudiod`.
    public static func clampedControlScalar(_ value: Float) throws -> Float32 {
        guard value.isFinite else {
            throw AudioHardwareValueError.unsupportedControlScalar(value)
        }
        return Float32(max(0, min(1, value)))
    }

    public static func supports(
        hardwareControlElements elements: [AudioObjectPropertyElement]
    ) -> Bool {
        !elements.isEmpty
            && elements.count <= maximumHardwareControlElements
            && Set(elements).count == elements.count
            && elements.allSatisfy { $0 <= 4 }
    }
}

public enum AudioHardwareValueError: Error, CustomStringConvertible, Sendable {
    case unsupportedSampleRate(Double)
    case unsupportedFramesPerSlice(UInt32)
    case unsupportedControlWait(TimeInterval)
    case unsupportedControlScalar(Float)
    case unsupportedHardwareControlElements([AudioObjectPropertyElement])

    public var description: String {
        switch self {
        case .unsupportedSampleRate(let rate):
            "unsupported audio sample rate \(audioIntegerDescription(rate)) Hz"
        case .unsupportedFramesPerSlice(let frames):
            "unsupported audio slice of \(frames) frames"
        case .unsupportedControlWait(let timeout):
            "unsupported audio control wait of \(String(describing: timeout)) seconds"
        case .unsupportedControlScalar(let scalar):
            "unsupported audio control scalar \(String(describing: scalar))"
        case .unsupportedHardwareControlElements(let elements):
            "unsupported audio control elements \(elements)"
        }
    }
}
