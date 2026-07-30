import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Echo-cancellation reference safety", .serialized)
struct EchoCancellationReferenceSafetyTests {
    @Test("non-finite and subnormal process audio cannot enter the canceller")
    func sanitisesUnsafeReferenceSamples() {
        let source: [Float] = [
            .nan, .infinity, -.infinity,
            .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
            -0.75, 0.5,
        ]
        var destination = [Float](repeating: 99, count: source.count)

        source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                EchoCancellationBridge.copySafeReference(
                    from: sourceBuffer.baseAddress!,
                    to: destinationBuffer.baseAddress!,
                    count: source.count)
            }
        }

        #expect(destination == [0, 0, 0, 0, 0, -0.75, 0.5])
        #expect(destination.allSatisfy { $0.isFinite })
    }

    @Test("a poisoned frame cannot alter the following healthy frame")
    func laterReferenceSamplesRemainExact() {
        let source: [Float] = [.nan, 0.125, -0.25, 1]
        var destination = [Float](repeating: 0, count: source.count)

        source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                EchoCancellationBridge.copySafeReference(
                    from: sourceBuffer.baseAddress!,
                    to: destinationBuffer.baseAddress!,
                    count: source.count)
            }
        }

        #expect(destination == [0, 0.125, -0.25, 1])
    }

    #if DEBUG
        @Test(
            "reference sanitation stays inside the realtime budget",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("reference sanitation stays inside the realtime budget")
    #endif
    func referenceSanitationCost() {
        let frames = 512
        let iterations = 10_000
        let source = (0..<frames).map {
            $0.isMultiple(of: 127) ? Float.nan : Float($0 % 31) / 31 - 0.5
        }
        var destination = [Float](repeating: 0, count: frames)

        source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                EchoCancellationBridge.copySafeReference(
                    from: sourceBuffer.baseAddress!,
                    to: destinationBuffer.baseAddress!,
                    count: frames)
            }
        }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        var checksum: Float = 0
        source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                yun_rt_tripwire_mark_realtime(true)
                for _ in 0..<iterations {
                    checksum += Self.copyReference(
                        from: sourceBuffer.baseAddress!,
                        to: destinationBuffer.baseAddress!,
                        count: frames)
                }
                yun_rt_tripwire_mark_realtime(false)
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before
        let nanosecondsPerCycle = elapsed / UInt64(iterations)

        print(
            "AEC reference sanitation upper bound \(frames)f: "
                + "\(nanosecondsPerCycle) ns/cycle, "
                + "\(allocations) realtime allocations")
        #expect(allocations == 0)
        #expect(
            nanosecondsPerCycle < 100_000,
            "sanitation used \(nanosecondsPerCycle) ns of a 10,666,667 ns callback")
        #expect(destination.allSatisfy { $0.isFinite })
        #expect(checksum.isFinite && abs(checksum) > 1)
    }

    /// Keeps the optimising compiler from collapsing 10,000 identical copies
    /// into the final one whose destination the assertion observes.
    @inline(never)
    private static func copyReference(
        from source: UnsafePointer<Float>,
        to destination: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Float {
        EchoCancellationBridge.copySafeReference(
            from: source, to: destination, count: count)
        // Reading every result makes this an upper bound: it includes one
        // verification pass, and prevents whole-module optimisation from
        // replacing 10,000 identical copies with the final observable one.
        var checksum: Float = 0
        for index in 0..<count {
            checksum += destination[index]
        }
        return checksum
    }
}
