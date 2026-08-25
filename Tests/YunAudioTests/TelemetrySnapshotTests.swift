import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Engine telemetry snapshot")
struct TelemetrySnapshotTests {
    @Test("a calibration poll never waits behind the engine state lock")
    func calibrationUsesTheLastCompleteFrameUnderContention() {
        let engine = RoutingEngine()
        engine.installCalibrationSnapshotForTesting([(energy: 0.5, frames: 2)])
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            engine.withStateLockForTesting {
                entered.signal()
                release.wait()
            }
            finished.signal()
        }
        #expect(entered.wait(timeout: .now() + TestGate.deadlock) == .success)

        let started = DispatchTime.now().uptimeNanoseconds
        let levels = engine.calibrationLevels(sampleRate: 2)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        release.signal()
        #expect(finished.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(levels.count == 1)
        #expect(abs(levels[0].decibels + 6.020_599_913) < 0.000_001)
        #expect(levels[0].seconds == 1)
        #expect(elapsed < 8_000_000)
    }

    @Test("contention is nil and the next snapshot is coherent")
    func contentionDoesNotInventSilence() {
        let engine = RoutingEngine()
        let expected = RoutingEngine.TelemetrySnapshot(
            routePeaks: [0.125, 0.375, 0.625],
            outputPeak: 0.875,
            outputClippedSamples: 41,
            failedPlugins: [
                AudioUnitLoadFailure(
                    name: "Refused Unit", reason: .formatRejected, status: -10868)
            ],
            droppedMonitor: RoutingEngine.DroppedMonitor(
                uid: "display-output", reason: "format unavailable"))
        engine.installTelemetryForTesting(expected)

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            engine.withStateLockForTesting {
                entered.signal()
                release.wait()
            }
            finished.signal()
        }
        #expect(entered.wait(timeout: .now() + TestGate.deadlock) == .success)

        let started = DispatchTime.now().uptimeNanoseconds
        let contended = engine.telemetrySnapshotIfAvailable
        let contendedNanoseconds = DispatchTime.now().uptimeNanoseconds - started

        #expect(contended == nil)
        #expect(contendedNanoseconds < 5_000_000)

        release.signal()
        #expect(finished.wait(timeout: .now() + TestGate.deadlock) == .success)

        let recovered = engine.telemetrySnapshotIfAvailable
        print(
            "contended telemetry snapshot: \(contendedNanoseconds) ns; "
                + "recovered \(recovered?.routePeaks.count ?? 0) routes")
        #expect(recovered == expected)
    }

    @Test("a busy reusable read leaves the last complete frame untouched")
    func reusableReadPreservesFrameDuringContention() {
        let engine = RoutingEngine()
        let expected = RoutingEngine.TelemetrySnapshot(
            routePeaks: [0.25, 0.5],
            outputPeak: 0.75,
            outputClippedSamples: 3,
            failedPlugins: [],
            droppedMonitor: nil)
        engine.installTelemetryForTesting(expected)

        var peaks = [-1 as Float]
        let first = engine.readTelemetry(into: &peaks)
        #expect(peaks == expected.routePeaks)
        #expect(first?.outputPeak == expected.outputPeak)

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            engine.withStateLockForTesting {
                entered.signal()
                release.wait()
            }
            finished.signal()
        }
        #expect(entered.wait(timeout: .now() + TestGate.deadlock) == .success)

        let unavailable = engine.readTelemetry(into: &peaks)
        #expect(unavailable == nil)
        #expect(peaks == expected.routePeaks)

        release.signal()
        #expect(finished.wait(timeout: .now() + TestGate.deadlock) == .success)
    }
}

@Suite("Engine telemetry polling performance", .serialized)
struct TelemetryPollingPerformanceTests {
    #if DEBUG
        @Test(
            "reusable telemetry removes steady poll allocations",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("reusable telemetry removes steady poll allocations")
    #endif
    func reusableStorage() {
        let engine = RoutingEngine()
        let fixture = RoutingEngine.TelemetrySnapshot(
            routePeaks: (0..<16).map { Float($0 + 1) / 32 },
            outputPeak: 0.75,
            outputClippedSamples: 7,
            failedPlugins: [],
            droppedMonitor: nil)
        engine.installTelemetryForTesting(fixture)

        // Warm the lock, graph walk and reusable storage before either timed
        // section. The comparison is the steady twenty-hertz path.
        _ = engine.telemetrySnapshotIfAvailable
        var reusablePeaks: [Float] = []
        _ = engine.readTelemetry(into: &reusablePeaks)

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }

        let legacy = Self.measureLegacy(engine, iterations: 10_000)
        let reusable = Self.measureReusable(
            engine, routePeaks: &reusablePeaks, iterations: 10_000)

        print(
            "10,000 telemetry polls: snapshot \(legacy.nanoseconds) ns / "
                + "\(legacy.allocations) allocations; reusable "
                + "\(reusable.nanoseconds) ns / \(reusable.allocations) allocations")
        #expect(legacy.checksum == reusable.checksum)
        #expect(legacy.allocations >= 9_000)
        #expect(reusable.allocations == 0)
        #expect(reusable.nanoseconds < legacy.nanoseconds)
    }

    private static func measureLegacy(
        _ engine: RoutingEngine, iterations: Int
    ) -> (allocations: UInt64, nanoseconds: UInt64, checksum: Int) {
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        var checksum = 0
        for _ in 0..<iterations {
            guard let snapshot = engine.telemetrySnapshotIfAvailable else { continue }
            checksum &+= Int(snapshot.routePeaks[0] * 1_000)
            checksum &+= Int(snapshot.outputPeak * 1_000)
        }
        yun_rt_tripwire_mark_realtime(false)
        return (
            RoutingEngine.allocationViolations - before,
            DispatchTime.now().uptimeNanoseconds - started,
            checksum
        )
    }

    private static func measureReusable(
        _ engine: RoutingEngine, routePeaks: inout [Float], iterations: Int
    ) -> (allocations: UInt64, nanoseconds: UInt64, checksum: Int) {
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        var checksum = 0
        for _ in 0..<iterations {
            guard let values = engine.readTelemetry(into: &routePeaks) else { continue }
            checksum &+= Int(routePeaks[0] * 1_000)
            checksum &+= Int(values.outputPeak * 1_000)
        }
        yun_rt_tripwire_mark_realtime(false)
        return (
            RoutingEngine.allocationViolations - before,
            DispatchTime.now().uptimeNanoseconds - started,
            checksum
        )
    }
}
