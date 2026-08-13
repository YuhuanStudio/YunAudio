import YunAudioHAL

/// Numeric limits shared by every live-audio processing boundary.
///
/// Core Audio reports these values at runtime, while callers can also request
/// them before a device exists. Keeping one contract prevents an accepted HAL
/// value from becoming an integer trap or an unbounded control-thread allocation
/// in a downstream analyser or realtime graph.
enum AudioProcessingContract {
    static let minimumSampleRate = AudioHardwareValuePolicy.minimumSampleRate
    static let maximumSampleRate = AudioHardwareValuePolicy.maximumSampleRate
    static let maximumFramesPerSlice = Int(
        AudioHardwareValuePolicy.maximumFramesPerSlice)
    static let maximumChannelTopology = 64

    static func supports(sampleRate: Double) -> Bool {
        AudioHardwareValuePolicy.supports(sampleRate: sampleRate)
    }

    static func supports(framesPerSlice: Int) -> Bool {
        guard let frames = UInt32(exactly: framesPerSlice) else { return false }
        return AudioHardwareValuePolicy.supports(framesPerSlice: frames)
    }

    static func supports(framesPerSlice: UInt32) -> Bool {
        AudioHardwareValuePolicy.supports(framesPerSlice: framesPerSlice)
    }

    static func admittedChannelCount(_ value: Int) -> Int? {
        guard value >= 0, value <= maximumChannelTopology else { return nil }
        return value
    }

    static func admittedChannelCount(_ value: UInt32) -> Int? {
        guard value <= UInt32(maximumChannelTopology) else { return nil }
        return Int(value)
    }

    /// Returns the bounded sum only when every individual dimension and the
    /// complete channel topology fit the realtime graph.
    static func admittedChannelTotal(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            guard let value = admittedChannelCount(value) else { return nil }
            let (next, overflowed) = total.addingReportingOverflow(value)
            guard !overflowed, next <= maximumChannelTopology else { return nil }
            total = next
        }
        return total
    }

    /// Multiplies allocation dimensions only when every factor and the result
    /// can be represented by `Int`.
    static func checkedProduct(_ lhs: Int, _ rhs: Int) -> Int? {
        guard lhs >= 0, rhs >= 0 else { return nil }
        let (product, overflowed) = lhs.multipliedReportingOverflow(by: rhs)
        return overflowed ? nil : product
    }

    static func checkedProduct(_ first: Int, _ second: Int, _ third: Int) -> Int? {
        guard let partial = checkedProduct(first, second) else { return nil }
        return checkedProduct(partial, third)
    }
}
