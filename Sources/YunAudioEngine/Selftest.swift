import CoreAudio
import Foundation

/// Deterministic test signal.
///
/// Every value is built from 24 random bits mapped into [-1, 1) by an exact
/// power-of-two divide, so it survives a float32 round trip with no rounding at
/// all. That matters: the whole point is to assert *equality*, and a signal that
/// could not be represented exactly would fail for reasons that have nothing to
/// do with the audio path.
@inline(__always)
func selftestSample(_ frame: UInt64) -> Float {
    var x = frame &* 0x9E37_79B9_7F4A_7C15
    x ^= x >> 30
    x = x &* 0xBF58_476D_1CE4_E5B9
    x ^= x >> 27
    x = x &* 0x94D0_49BB_1331_11EB
    x ^= x >> 31
    let bits = UInt32(truncatingIfNeeded: x) >> 8  // 24 bits
    return (Float(bits) - 8_388_608.0) / 8_388_608.0
}

/// Realtime-side state for the loopback integrity check.
///
/// Lives beside the graph and is only consulted when `enabled` is set, so the
/// normal audio path pays nothing for its existence.
struct RTSelftest {
    var enabled: Int32
    /// Where the generated sequence is written, and where it is read back.
    var outBuffer: Int32
    var outChannel: Int32
    var inBuffer: Int32
    var inChannel: Int32

    /// Frames of the sequence emitted so far.
    var generatedFrames: UnsafeMutablePointer<UInt64>
    /// Captured samples from the return path.
    var capture: UnsafeMutablePointer<Float>
    var captureCapacity: Int32
    var captureCount: UnsafeMutablePointer<Int32>
    /// Value of `generatedFrames` when the first sample was captured, which
    /// anchors the captured run to the generated sequence.
    var captureStartFrame: UnsafeMutablePointer<UInt64>

    static func allocate(
        outBuffer: Int32, outChannel: Int32,
        inBuffer: Int32, inChannel: Int32,
        captureFrames: Int
    ) -> UnsafeMutablePointer<RTSelftest> {
        let generated = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        generated.initialize(to: 0)
        let capture = UnsafeMutablePointer<Float>.allocate(capacity: captureFrames)
        capture.initialize(repeating: 0, count: captureFrames)
        let count = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        count.initialize(to: 0)
        let start = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        start.initialize(to: 0)

        let selftest = UnsafeMutablePointer<RTSelftest>.allocate(capacity: 1)
        selftest.initialize(to: RTSelftest(
            enabled: 1,
            outBuffer: outBuffer, outChannel: outChannel,
            inBuffer: inBuffer, inChannel: inChannel,
            generatedFrames: generated,
            capture: capture,
            captureCapacity: Int32(captureFrames),
            captureCount: count,
            captureStartFrame: start))
        return selftest
    }

    static func deallocate(_ selftest: UnsafeMutablePointer<RTSelftest>) {
        selftest.pointee.generatedFrames.deinitialize(count: 1)
        selftest.pointee.generatedFrames.deallocate()
        selftest.pointee.capture.deinitialize(count: Int(selftest.pointee.captureCapacity))
        selftest.pointee.capture.deallocate()
        selftest.pointee.captureCount.deinitialize(count: 1)
        selftest.pointee.captureCount.deallocate()
        selftest.pointee.captureStartFrame.deinitialize(count: 1)
        selftest.pointee.captureStartFrame.deallocate()
        selftest.deinitialize(count: 1)
        selftest.deallocate()
    }
}

/// Outcome of comparing what came back against what was sent.
public struct SelftestResult: Sendable {
    /// Loopback delay in frames, recovered from the data rather than assumed.
    public let delayFrames: Int
    public let comparedFrames: Int
    public let exactMatches: Int
    /// Largest absolute difference across the compared run. Zero is the only
    /// acceptable answer for a path that claims to be lossless.
    public let maxAbsoluteError: Float

    public var isBitExact: Bool { comparedFrames > 0 && exactMatches == comparedFrames }

    public var summary: String {
        guard comparedFrames > 0 else { return "no samples returned — the loopback never carried the signal" }
        if isBitExact {
            return "bit-exact: \(exactMatches)/\(comparedFrames) samples identical, delay \(delayFrames) frames"
        }
        let percentage = Double(exactMatches) / Double(comparedFrames) * 100
        return String(
            format: "NOT bit-exact: %d/%d identical (%.2f%%), max error %.9f, delay %d frames",
            exactMatches, comparedFrames, percentage, maxAbsoluteError, delayFrames)
    }
}

extension RTSelftest {
    /// Aligns the captured run against the generated sequence and grades it.
    ///
    /// The loopback delay is unknown up front — it depends on the driver's ring
    /// buffer and the IO cycle — so it is recovered by trying every plausible
    /// offset and keeping the one that matches best. An offset found this way
    /// is only convincing because an exact match against a 24-bit pseudorandom
    /// sequence cannot happen by chance.
    static func evaluate(
        _ selftest: UnsafeMutablePointer<RTSelftest>,
        maximumDelayFrames: Int = 16384
    ) -> SelftestResult {
        let count = Int(selftest.pointee.captureCount.pointee)
        let startFrame = selftest.pointee.captureStartFrame.pointee
        let capture = selftest.pointee.capture
        guard count > 64 else {
            return SelftestResult(
                delayFrames: 0, comparedFrames: 0, exactMatches: 0, maxAbsoluteError: 0)
        }

        // Skip the head of the capture: the first cycles can contain the ring
        // buffer's initial silence, which would match nothing.
        let probeOffset = min(count / 4, 4096)
        let probeLength = min(256, count - probeOffset)

        var bestDelay = 0
        var bestScore = -1
        for delay in 0...maximumDelayFrames {
            guard startFrame &+ UInt64(probeOffset) >= UInt64(delay) else { break }
            var score = 0
            for index in 0..<probeLength {
                let generatedFrame =
                    startFrame &+ UInt64(probeOffset + index) &- UInt64(delay)
                if capture[probeOffset + index] == selftestSample(generatedFrame) {
                    score += 1
                }
            }
            if score > bestScore {
                bestScore = score
                bestDelay = delay
                if score == probeLength { break }
            }
        }

        // Grade the whole capture at the recovered delay.
        var compared = 0
        var matches = 0
        var maxError: Float = 0
        for index in 0..<count {
            let absolute = startFrame &+ UInt64(index)
            guard absolute >= UInt64(bestDelay) else { continue }
            let expected = selftestSample(absolute &- UInt64(bestDelay))
            let actual = capture[index]
            compared += 1
            if actual == expected {
                matches += 1
            } else {
                let error = abs(actual - expected)
                if error > maxError { maxError = error }
            }
        }

        return SelftestResult(
            delayFrames: bestDelay,
            comparedFrames: compared,
            exactMatches: matches,
            maxAbsoluteError: maxError)
    }
}
