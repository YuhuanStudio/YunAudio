/// Hard allocation and format bounds for the two echo-cancellation bridges.
///
/// Values in this path originate in HAL properties and ASBDs. Converting a
/// non-finite `Double` or an oversized integer before proving its range can
/// trap; accepting it can turn one corrupt property into an unbounded realtime
/// allocation. Every caller obtains one complete layout here before allocating
/// its first byte.
enum EchoCancellationCapacityPolicy {
    static let minimumCaptureBufferFrames = 8_192
    static let maximumCaptureBufferFrames = 16_384
    static let scratchFrames = AudioProcessingContract.maximumFramesPerSlice
    static let maximumRingSeconds = 2.0
    static let maximumRingFrames: UInt32 = 768_000
    static let maximumRingStorageFrames: UInt32 = 1_048_576
    static let floatBytes = MemoryLayout<Float>.size

    struct CaptureAllocation: Sendable, Equatable {
        let bufferFrames: Int
        let bufferFrameCount: UInt32
        let bufferBytes: UInt32
        let unitSliceFrames: UInt32
    }

    struct RingAllocation: Sendable, Equatable {
        let ringFrames: UInt32
        let ringStorageFrames: UInt32
        let ringBytes: UInt32
        let scratchFrames: Int
        let scratchFrameCount: UInt32
        let scratchBytes: UInt32
    }

    static func isValidSampleRate(_ value: Double) -> Bool {
        AudioProcessingContract.supports(sampleRate: value)
    }

    static func requestedSliceFrames(_ value: Int) -> UInt32? {
        guard AudioProcessingContract.supports(framesPerSlice: value) else {
            return nil
        }
        return UInt32(exactly: value)
    }

    /// Zero is HAL's usable "not reported" value; a real slice is at most
    /// 4,096 frames. Keeping those meanings separate prevents UInt32.max from
    /// becoming a 16-GiB headroom request.
    static func deviceSliceFrames(_ value: UInt32) -> Int? {
        guard value == 0 || AudioProcessingContract.supports(framesPerSlice: value)
        else { return nil }
        return Int(exactly: value)
    }

    static func isValidChannelCount(_ value: UInt32) -> Bool {
        guard let admitted = AudioProcessingContract.admittedChannelCount(value) else {
            return false
        }
        return admitted > 0
    }

    static func isValidRingSeconds(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value <= maximumRingSeconds
    }

    static func checkedUInt32Product(_ lhs: UInt32, _ rhs: UInt32) -> UInt32? {
        guard let lhs = Int(exactly: lhs),
            let rhs = Int(exactly: rhs),
            let value = AudioProcessingContract.checkedProduct(lhs, rhs)
        else { return nil }
        return UInt32(exactly: value)
    }

    static func checkedByteCount(frames: Int, channels: Int = 1) -> UInt32? {
        guard channels > 0,
            let bytes = AudioProcessingContract.checkedProduct(
                frames, channels, floatBytes)
        else { return nil }
        return UInt32(exactly: bytes)
    }

    static func bytesPerFrame(channels: UInt32, nonInterleaved: Bool) -> UInt32? {
        guard isValidChannelCount(channels) else { return nil }
        let storedChannels: UInt32 = nonInterleaved ? 1 : channels
        return checkedUInt32Product(UInt32(floatBytes), storedChannels)
    }

    static func captureAllocation(
        requestedSliceFrames requested: Int,
        deviceSliceFrames reported: UInt32
    ) -> CaptureAllocation? {
        guard let requested = requestedSliceFrames(requested),
            let device = deviceSliceFrames(reported)
        else { return nil }
        guard
            let headroom = AudioProcessingContract.checkedProduct(device, 4)
        else { return nil }

        let frames = max(
            minimumCaptureBufferFrames, max(Int(requested), headroom))
        guard frames <= maximumCaptureBufferFrames,
            let bufferFrameCount = UInt32(exactly: frames),
            let bytes = checkedByteCount(frames: frames),
            let unitSlice = UInt32(exactly: max(Int(requested), device))
        else { return nil }
        return CaptureAllocation(
            bufferFrames: frames,
            bufferFrameCount: bufferFrameCount,
            bufferBytes: bytes,
            unitSliceFrames: unitSlice)
    }

    static func ringFrameCapacity(sampleRate: Double, seconds: Double) -> UInt32? {
        guard isValidSampleRate(sampleRate),
            isValidRingSeconds(seconds)
        else { return nil }

        let product = sampleRate * seconds
        guard product.isFinite, product >= 1 else { return nil }
        let rounded = product.rounded(.up)
        guard rounded <= Double(maximumRingFrames) else { return nil }
        return UInt32(exactly: rounded)
    }

    /// Mirrors YunRTRing's minimum and power-of-two rounding so the allocation
    /// byte count is proved here rather than inferred from requested frames.
    static func ringStorageFrameCapacity(requestedFrames: UInt32) -> UInt32? {
        guard requestedFrames > 0, requestedFrames <= maximumRingFrames else {
            return nil
        }
        var frames: UInt32 = 1_024
        while frames < requestedFrames {
            guard let doubled = checkedUInt32Product(frames, 2) else { return nil }
            frames = doubled
        }
        guard frames <= maximumRingStorageFrames else { return nil }
        return frames
    }

    static func ringAllocation(
        sampleRate: Double,
        seconds: Double,
        requestedSliceFrames: Int,
        sourceChannels: UInt32 = 1
    ) -> RingAllocation? {
        guard Self.requestedSliceFrames(requestedSliceFrames) != nil,
            isValidChannelCount(sourceChannels),
            let ringFrames = ringFrameCapacity(
                sampleRate: sampleRate, seconds: seconds),
            let ringStorageFrames = ringStorageFrameCapacity(
                requestedFrames: ringFrames),
            let ringStorageFrameCount = Int(exactly: ringStorageFrames),
            let ringBytes = checkedByteCount(frames: ringStorageFrameCount),
            let scratchFrameCount = UInt32(exactly: scratchFrames),
            let scratchBytes = checkedByteCount(frames: scratchFrames)
        else { return nil }
        return RingAllocation(
            ringFrames: ringFrames,
            ringStorageFrames: ringStorageFrames,
            ringBytes: ringBytes,
            scratchFrames: scratchFrames,
            scratchFrameCount: scratchFrameCount,
            scratchBytes: scratchBytes)
    }
}
