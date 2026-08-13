import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Echo-cancellation provider buffer safety", .serialized)
struct EchoCancellationProviderBufferTests {
    @Test("a short provider read silences only the valid buffer tail")
    func shortReadStaysInsideBuffer() {
        var storage: [Float] = [99, -1, -1, -1, -1, 77]
        let result = storage.withUnsafeMutableBufferPointer { buffer in
            EchoCancellingCapture.fillFarEnd(
                into: buffer.baseAddress! + 1,
                requestedFrames: 8,
                sampleCapacity: 4,
                provider: { destination, frames in
                    guard frames == 4 else { return -1 }
                    destination[0] = 0.25
                    destination[1] = -0.25
                    return 2
                })
        }

        #expect(
            result
                == FarEndFillResult(
                    requestedFrames: 8, bufferFrames: 4, writtenFrames: 2))
        #expect(storage == [99, 0.25, -0.25, 0, 0, 77])
    }

    @Test("a negative provider report cannot clear before the buffer")
    func clampsNegativeProviderCount() {
        var storage: [Float] = [99, 1, 1, 1, 1, 77]
        let result = storage.withUnsafeMutableBufferPointer { buffer in
            EchoCancellingCapture.fillFarEnd(
                into: buffer.baseAddress! + 1,
                requestedFrames: 4,
                sampleCapacity: 4,
                provider: { _, _ in -1 })
        }

        #expect(result.writtenFrames == 0)
        #expect(storage == [99, 0, 0, 0, 0, 77])
    }

    @Test("an over-reported provider count is clamped to the offered frames")
    func clampsOverReportedProviderCount() {
        var storage: [Float] = [99, 0, 0, 0, 0, 77]
        let result = storage.withUnsafeMutableBufferPointer { buffer in
            EchoCancellingCapture.fillFarEnd(
                into: buffer.baseAddress! + 1,
                requestedFrames: 4,
                sampleCapacity: 4,
                provider: { destination, frames in
                    for frame in 0..<frames {
                        destination[frame] = Float(frame + 1)
                    }
                    return 999
                })
        }

        #expect(result.writtenFrames == 4)
        #expect(storage == [99, 1, 2, 3, 4, 77])
    }

    @Test("an absent provider produces bounded silence")
    func absentProviderIsSilence() {
        var storage: [Float] = [99, 1, 1, 1, 77]
        let result = storage.withUnsafeMutableBufferPointer { buffer in
            EchoCancellingCapture.fillFarEnd(
                into: buffer.baseAddress! + 1,
                requestedFrames: 3,
                sampleCapacity: 3,
                provider: nil)
        }

        #expect(result.writtenFrames == 0)
        #expect(storage == [99, 0, 0, 0, 77])
    }

    @Test("malformed frame capacities fail without touching memory")
    func malformedCapacitiesFailClosed() {
        var sample: Float = 99
        withUnsafeMutablePointer(to: &sample) { destination in
            #expect(
                EchoCancellingCapture.fillFarEnd(
                    into: destination,
                    requestedFrames: Int.max,
                    sampleCapacity: 1,
                    provider: nil)
                    == .init(
                        requestedFrames: 0,
                        bufferFrames: 0,
                        writtenFrames: 0))
            #expect(
                EchoCancellingCapture.fillFarEnd(
                    into: destination,
                    requestedFrames: 1,
                    sampleCapacity: Int.max,
                    provider: nil
                ).bufferFrames == 0)
            #expect(
                EchoCancellingCapture.fillFarEnd(
                    into: destination,
                    requestedFrames: -1,
                    sampleCapacity: -1,
                    provider: nil
                ).bufferFrames == 0)
        }
        #expect(sample == 99)
    }

    #if DEBUG
        @Test(
            "short-read handling stays inside the realtime budget",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("short-read handling stays inside the realtime budget")
    #endif
    func shortReadCost() {
        let frames = 512
        let iterations = 10_000
        var destination = [Float](repeating: 1, count: frames)
        let provider: EchoCancellingCapture.FarEndProvider = { buffer, offered in
            let written = offered * 3 / 4
            buffer.update(repeating: 0.25, count: written)
            return written
        }

        destination.withUnsafeMutableBufferPointer {
            _ = EchoCancellingCapture.fillFarEnd(
                into: $0.baseAddress!,
                requestedFrames: frames,
                sampleCapacity: $0.count,
                provider: provider)
        }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        var checksum: Float = 0
        destination.withUnsafeMutableBufferPointer { buffer in
            yun_rt_tripwire_mark_realtime(true)
            for _ in 0..<iterations {
                checksum += Self.fillAndConsume(
                    buffer.baseAddress!, frames: frames, provider: provider)
            }
            yun_rt_tripwire_mark_realtime(false)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before
        let nanosecondsPerCycle = elapsed / UInt64(iterations)

        print(
            "AEC provider short-read upper bound \(frames)f: "
                + "\(nanosecondsPerCycle) ns/cycle, "
                + "\(allocations) realtime allocations")
        #expect(allocations == 0)
        #expect(
            nanosecondsPerCycle < 100_000,
            "provider handling used \(nanosecondsPerCycle) ns of a 10,666,667 ns callback")
        #expect(checksum.isFinite && abs(checksum) > 1)
    }

    /// Includes a full verification pass so whole-module optimisation cannot
    /// collapse 10,000 identical fills into the final observable one.
    @inline(never)
    private static func fillAndConsume(
        _ destination: UnsafeMutablePointer<Float>,
        frames: Int,
        provider: @escaping EchoCancellingCapture.FarEndProvider
    ) -> Float {
        _ = EchoCancellingCapture.fillFarEnd(
            into: destination,
            requestedFrames: frames,
            sampleCapacity: frames,
            provider: provider)
        var checksum: Float = 0
        for frame in 0..<frames {
            checksum += destination[frame]
        }
        return checksum
    }
}
