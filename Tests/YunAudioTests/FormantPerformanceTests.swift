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
            "one second of formant processing allocates nothing",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("one second of formant processing allocates nothing")
    #endif
    func noRealtimeAllocations() throws {
        let shifter = try #require(FormantShifter())
        shifter.ratio = 1.25
        var samples = (0..<48_000).map {
            Float(sin(2 * Double.pi * 180 * Double($0) / 48_000)) * 0.25
        }

        // Warm the Accelerate setup and every lazy Swift runtime path before
        // the interval. Only the steady-state callback contract is in scope.
        samples.withUnsafeMutableBufferPointer {
            shifter.process($0.baseAddress!, count: FormantShifter.windowSize)
        }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        samples.withUnsafeMutableBufferPointer {
            yun_rt_tripwire_mark_realtime(true)
            shifter.process($0.baseAddress!, count: $0.count)
            yun_rt_tripwire_mark_realtime(false)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before

        print(
            "formant steady state: \(elapsed) ns/s of audio, "
                + "\(allocations) realtime allocations")
        #expect(allocations == 0, "one second allocated \(allocations) times")
    }
}
