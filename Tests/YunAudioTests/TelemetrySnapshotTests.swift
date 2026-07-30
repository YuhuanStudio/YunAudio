import Foundation
import Testing

@testable import YunAudioEngine

@Suite("Engine telemetry snapshot")
struct TelemetrySnapshotTests {
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
        #expect(entered.wait(timeout: .now() + 1) == .success)

        let started = DispatchTime.now().uptimeNanoseconds
        let contended = engine.telemetrySnapshotIfAvailable
        let contendedNanoseconds = DispatchTime.now().uptimeNanoseconds - started

        #expect(contended == nil)
        #expect(contendedNanoseconds < 5_000_000)

        release.signal()
        #expect(finished.wait(timeout: .now() + 1) == .success)

        let recovered = engine.telemetrySnapshotIfAvailable
        print(
            "contended telemetry snapshot: \(contendedNanoseconds) ns; "
                + "recovered \(recovered?.routePeaks.count ?? 0) routes")
        #expect(recovered == expected)
    }
}
