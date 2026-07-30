import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

/// The formant stage runs inside `EffectChain.render`, on the IO thread.
///
/// A direct allocation assertion belongs here because the ordinary callback
/// benchmark does not build an effect chain. Leaving that gap once allowed
/// per-hop scratch arrays and array-backed Accelerate calls to ship behind a
/// callback that otherwise reported zero allocations.
@Suite("Formant realtime performance", .serialized)
struct FormantPerformanceTests {
    #if DEBUG
        @Test(
            "supported callback sizes allocate nothing",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("supported callback sizes allocate nothing")
    #endif
    func noRealtimeAllocations() throws {
        let source = (0..<48_000).map {
            Float(sin(2 * Double.pi * 180 * Double($0) / 48_000)) * 0.25
        }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        for blockFrames in [64, 128, 256, 512] {
            let shifter = try #require(FormantShifter())
            shifter.ratio = 1.25
            var samples = source

            // Warm the Accelerate setup and every lazy Swift runtime path
            // before the interval. Only the steady-state callback contract is
            // in scope.
            samples.withUnsafeMutableBufferPointer {
                shifter.process($0.baseAddress!, count: blockFrames)
            }

            RoutingEngine.enableAllocationTripwire()
            let before = RoutingEngine.allocationViolations
            let started = DispatchTime.now().uptimeNanoseconds
            samples.withUnsafeMutableBufferPointer { buffer in
                yun_rt_tripwire_mark_realtime(true)
                var start = 0
                while start < buffer.count {
                    let frames = min(blockFrames, buffer.count - start)
                    shifter.process(
                        buffer.baseAddress! + start, count: frames)
                    start += frames
                }
                yun_rt_tripwire_mark_realtime(false)
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            let allocations = RoutingEngine.allocationViolations - before
            RoutingEngine.disableAllocationTripwire()

            print(
                "formant \(blockFrames) frames: \(elapsed) ns/s of audio, "
                    + "\(allocations) realtime allocations")
            #expect(
                allocations == 0,
                "\(blockFrames)-frame callbacks allocated \(allocations) times")
        }
    }
}
