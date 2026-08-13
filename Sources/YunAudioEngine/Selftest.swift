import CoreAudio
import Foundation
import YunAudioRT

/// Deterministic test signal.
///
/// Every value is built from 24 random bits mapped into [-1, 1) by an exact
/// power-of-two divide, so it survives a float32 round trip with no rounding at
/// all. That matters: the whole point is to assert *equality*, and a signal that
/// could not be represented exactly would fail for reasons that have nothing to
/// do with the audio path.
@inline(__always)
package func selftestSample(_ frame: UInt64) -> Float {
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
package struct RTSelftest {
    package var enabled: Int32
    /// Where the generated sequence is written, and where it is read back.
    package var outBuffer: Int32
    package var outChannel: Int32
    package var inBuffer: Int32
    package var inChannel: Int32

    /// Frames of the sequence emitted so far.
    package var generatedFrames: UnsafeMutablePointer<UInt64>
    /// Captured samples from the return path.
    package var capture: UnsafeMutablePointer<Float>
    package var captureCapacity: Int32
    /// Release-published count of immutable capture slots. Readers acquire this
    /// once, then inspect only the prefix the callback has finished writing.
    package var captureCount: OpaquePointer
    /// Value of `generatedFrames` when the first sample was captured, which
    /// anchors the captured run to the generated sequence.
    package var captureStartFrame: UnsafeMutablePointer<UInt64>

    package static func allocate(
        outBuffer: Int32, outChannel: Int32,
        inBuffer: Int32, inChannel: Int32,
        captureFrames: Int
    ) -> UnsafeMutablePointer<RTSelftest> {
        let generated = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        generated.initialize(to: 0)
        let capture = UnsafeMutablePointer<Float>.allocate(capacity: captureFrames)
        capture.initialize(repeating: 0, count: captureFrames)
        let start = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        start.initialize(to: 0)
        guard let count = yun_rt_counter_create(0) else {
            generated.deinitialize(count: 1)
            generated.deallocate()
            capture.deinitialize(count: captureFrames)
            capture.deallocate()
            start.deinitialize(count: 1)
            start.deallocate()
            preconditionFailure("could not allocate the self-test capture counter")
        }

        let selftest = UnsafeMutablePointer<RTSelftest>.allocate(capacity: 1)
        selftest.initialize(
            to: RTSelftest(
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

    package static func deallocate(_ selftest: UnsafeMutablePointer<RTSelftest>) {
        selftest.pointee.generatedFrames.deinitialize(count: 1)
        selftest.pointee.generatedFrames.deallocate()
        selftest.pointee.capture.deinitialize(count: Int(selftest.pointee.captureCapacity))
        selftest.pointee.capture.deallocate()
        yun_rt_counter_free(selftest.pointee.captureCount)
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
    /// Capture-relative bounds and shape of non-identical samples. These stay
    /// empty on success and make one fail-silent hardware callback distinguishable
    /// from continuous conversion without weakening the bit-exact verdict.
    public let firstMismatchOffset: Int?
    public let lastMismatchOffset: Int?
    public let mismatchRunCount: Int
    public let longestMismatchRun: Int
    /// Largest absolute difference across the compared run. Zero is the only
    /// acceptable answer for a path that claims to be lossless.
    public let maxAbsoluteError: Float
    /// Mean absolute difference. This is what separates a resampled path, which
    /// tracks the sequence closely without ever matching it exactly, from a
    /// loopback that carried nothing at all.
    public let meanAbsoluteError: Float

    /// Error at the recovered offset over the error at a typical wrong one.
    ///
    /// Zero means the alignment is exact; one means the winning offset is no
    /// better than chance and nothing came back.
    public let alignmentSeparation: Float

    /// True when the recovered offset stands clearly above the wrong ones.
    ///
    /// Judged by ratio rather than by an absolute error, because the probe is
    /// white noise and resampling low-passes white noise: a path that carries
    /// the signal perfectly can still differ at every single sample. Measured
    /// on a resampled path here: 0.171 mean error against 0.66 for two
    /// unrelated runs — close enough that any fixed cutoff between them would
    /// be a guess about somebody's resampler.
    public var didAlign: Bool { comparedFrames > 0 && alignmentSeparation < 0.6 }

    public var isBitExact: Bool { comparedFrames > 0 && exactMatches == comparedFrames }

    public var summary: String {
        guard comparedFrames > 0 else {
            return "no samples returned — the loopback never carried the signal"
        }
        if isBitExact {
            return
                "bit-exact: \(exactMatches)/\(comparedFrames) samples identical, delay \(delayFrames) frames"
        }
        guard didAlign else {
            // Distinguishing this from "resampled" matters: one is a working
            // path that happens to convert, the other is a path carrying
            // something else entirely, and reporting 0% for both said nothing.
            return String(
                format:
                    "the signal did not come back — the best offset scores %.2f of a "
                    + "typical wrong one, over %d samples",
                alignmentSeparation, comparedFrames)
        }
        let percentage = Double(exactMatches) / Double(comparedFrames) * 100
        let mismatchShape: String
        if let firstMismatchOffset, let lastMismatchOffset {
            mismatchShape = String(
                format: ", mismatch offsets %d...%d in %d run(s), longest %d",
                firstMismatchOffset, lastMismatchOffset, mismatchRunCount,
                longestMismatchRun)
        } else {
            mismatchShape = ""
        }
        return String(
            format:
                "resampled: %d/%d identical (%.2f%%), mean error %.4f, max %.4f, "
                + "delay %d frames, separation %.3f%@",
            exactMatches, comparedFrames, percentage, meanAbsoluteError, maxAbsoluteError,
            delayFrames, alignmentSeparation, mismatchShape)
    }
}

/// One fixed, owned prefix of a loopback capture.
///
/// The realtime writer release-publishes the capture count only after each
/// prefix is complete. Copying exactly that prefix lets evaluation outlive the
/// graph without dereferencing its raw storage after route teardown.
public struct SelftestCapture: Sendable {
    package let startFrame: UInt64
    package let samples: [Float]

    package init(startFrame: UInt64, samples: [Float]) {
        self.startFrame = startFrame
        self.samples = samples
    }

    public var capturedFrames: Int { samples.count }
}

/// ARC lifetime for raw capture storage shared with the realtime graph.
///
/// The callback never retains this object. The engine, any diagnostic lease and
/// a failed-teardown quarantine do, so a route may drop its reference without
/// freeing storage underneath an off-lock capture copy.
package final class RTSelftestOwner: @unchecked Sendable {
    package let block: UnsafeMutablePointer<RTSelftest>

    package init(adopting block: UnsafeMutablePointer<RTSelftest>) {
        self.block = block
    }

    package static func allocate(
        outBuffer: Int32, outChannel: Int32,
        inBuffer: Int32, inChannel: Int32,
        captureFrames: Int
    ) -> RTSelftestOwner {
        RTSelftestOwner(
            adopting: RTSelftest.allocate(
                outBuffer: outBuffer, outChannel: outChannel,
                inBuffer: inBuffer, inChannel: inChannel,
                captureFrames: captureFrames))
    }

    deinit { RTSelftest.deallocate(block) }
}

/// One fixed prefix plus the owner which keeps its raw samples alive.
public final class SelftestCaptureLease: @unchecked Sendable {
    private let owner: RTSelftestOwner
    private let startFrame: UInt64
    public let capturedFrames: Int

    package init(
        owner: RTSelftestOwner, startFrame: UInt64, capturedFrames: Int
    ) {
        self.owner = owner
        self.startFrame = startFrame
        self.capturedFrames = capturedFrames
    }

    /// Copies the already-published immutable prefix on the caller's worker.
    public func capture() -> SelftestCapture {
        SelftestCapture(
            startFrame: startFrame,
            samples: Array(
                UnsafeBufferPointer(
                    start: owner.block.pointee.capture, count: capturedFrames)))
    }
}

extension RTSelftest {
    /// Copies only the immutable prefix published by the realtime callback.
    package static func snapshot(
        _ selftest: UnsafeMutablePointer<RTSelftest>
    ) -> SelftestCapture {
        let capacity = max(0, Int(selftest.pointee.captureCapacity))
        let published = yun_rt_counter_load(selftest.pointee.captureCount)
        let count = Int(min(published, UInt64(capacity)))
        let samples = Array(
            UnsafeBufferPointer(start: selftest.pointee.capture, count: count))
        return SelftestCapture(
            startFrame: count > 0 ? selftest.pointee.captureStartFrame.pointee : 0,
            samples: samples)
    }

    package static func evaluate(
        _ selftest: UnsafeMutablePointer<RTSelftest>,
        maximumDelayFrames: Int = 16384
    ) -> SelftestResult {
        snapshot(selftest).evaluate(maximumDelayFrames: maximumDelayFrames)
    }
}

extension SelftestCapture {
    public static let maximumDelayFrames = 16_384

    /// Aligns the captured run against the generated sequence and grades it.
    ///
    /// The loopback delay is unknown up front — it depends on the driver's ring
    /// buffer and the IO cycle — so it is recovered by trying every plausible
    /// offset and keeping the one that matches best. An offset found this way
    /// is only convincing because an exact match against a 24-bit pseudorandom
    /// sequence cannot happen by chance.
    public func evaluate(
        maximumDelayFrames: Int = SelftestCapture.maximumDelayFrames
    ) -> SelftestResult {
        let count = samples.count
        let capture = samples
        guard count > 64 else {
            return SelftestResult(
                delayFrames: 0, comparedFrames: 0, exactMatches: 0,
                firstMismatchOffset: nil, lastMismatchOffset: nil,
                mismatchRunCount: 0, longestMismatchRun: 0, maxAbsoluteError: 0,
                meanAbsoluteError: 0, alignmentSeparation: 1)
        }

        // Skip the head of the capture: the first cycles can contain the ring
        // buffer's initial silence, which would match nothing.
        let probeOffset = min(count / 4, 4096)
        let probeLength = min(256, count - probeOffset)

        // Scored by how far the returned run sits from the generated one, not
        // by how many samples match it exactly.
        //
        // Exact matching finds the alignment on a clock-locked path and finds
        // nothing at all on a resampled one — every sample differs, every
        // offset scores zero, and the search returns delay 0 with no matches,
        // which is indistinguishable from a loopback that carried silence. A
        // resampled path still tracks the sequence closely, so minimising the
        // difference recovers the alignment either way.
        var bestDelay = 0
        var bestError = Double.infinity
        var errors: [Double] = []
        let maximumDelay = min(
            SelftestCapture.maximumDelayFrames, max(0, maximumDelayFrames))
        errors.reserveCapacity(maximumDelay + 1)
        for delay in 0...maximumDelay {
            guard startFrame &+ UInt64(probeOffset) >= UInt64(delay) else { break }
            var error = 0.0
            var exact = 0
            for index in 0..<probeLength {
                let generatedFrame =
                    startFrame &+ UInt64(probeOffset + index) &- UInt64(delay)
                let expected = selftestSample(generatedFrame)
                let actual = capture[probeOffset + index]
                error += Double(abs(actual - expected))
                if actual == expected { exact += 1 }
            }
            errors.append(error)
            if error < bestError {
                bestError = error
                bestDelay = delay
            }
            // A whole probe run matching a 24-bit pseudorandom sequence exactly
            // cannot happen by chance, so nothing later can beat it.
            if exact == probeLength {
                errors = [error]
                break
            }
        }

        // How much better the winning offset is than a typical wrong one.
        //
        // An absolute threshold cannot answer this. The probe is white noise,
        // and resampling low-passes white noise, so a resampled path that is
        // carrying the signal perfectly well still differs at every sample —
        // measured here at 0.171 against 0.66 for two unrelated runs. Any fixed
        // cutoff between those two numbers is a guess about the resampler.
        // The ratio is not: at the true offset the error is far below the
        // spread of the wrong ones, whatever the path did to the signal.
        let median = errors.sorted()[errors.count / 2]
        let separation = median > 0 ? bestError / median : 0

        // Grade the whole capture at the recovered delay.
        var compared = 0
        var matches = 0
        var maxError: Float = 0
        var totalError = 0.0
        var firstMismatchOffset: Int?
        var lastMismatchOffset: Int?
        var mismatchRunCount = 0
        var currentMismatchRun = 0
        var longestMismatchRun = 0
        for index in 0..<count {
            let absolute = startFrame &+ UInt64(index)
            guard absolute >= UInt64(bestDelay) else { continue }
            let expected = selftestSample(absolute &- UInt64(bestDelay))
            let actual = capture[index]
            compared += 1
            if actual == expected {
                matches += 1
                currentMismatchRun = 0
            } else {
                if currentMismatchRun == 0 { mismatchRunCount += 1 }
                currentMismatchRun += 1
                longestMismatchRun = max(longestMismatchRun, currentMismatchRun)
                if firstMismatchOffset == nil { firstMismatchOffset = index }
                lastMismatchOffset = index
                let error = abs(actual - expected)
                totalError += Double(error)
                if error > maxError { maxError = error }
            }
        }

        return SelftestResult(
            delayFrames: bestDelay,
            comparedFrames: compared,
            exactMatches: matches,
            firstMismatchOffset: firstMismatchOffset,
            lastMismatchOffset: lastMismatchOffset,
            mismatchRunCount: mismatchRunCount,
            longestMismatchRun: longestMismatchRun,
            maxAbsoluteError: maxError,
            meanAbsoluteError: compared > 0 ? Float(totalError / Double(compared)) : 0,
            alignmentSeparation: Float(separation))
    }
}
