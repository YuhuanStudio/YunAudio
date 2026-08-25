import Foundation
import Testing

@testable import YunAudioApp

private final class DiagnosticLifecycleLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

@MainActor
private func diagnosticEventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return predicate()
}

@MainActor
private func holdDiagnosticWork(
    since beganAt: UInt64, for nanoseconds: UInt64 = 250_000_000
) async {
    let now = DispatchTime.now().uptimeNanoseconds
    let elapsed = now >= beganAt ? now - beganAt : 0
    if elapsed < nanoseconds {
        try? await Task.sleep(
            for: .nanoseconds(Int64(nanoseconds - elapsed)))
    }
}

@Suite("Diagnostic lifecycle worker", .serialized)
struct DiagnosticLifecycleWorkerTests {
    @MainActor
    @Test("ten thousand captures evaluate first and latest off MainActor")
    func diagnosticFirstLatestBoundary() async {
        let entered = DiagnosticLifecycleLockedBox(false)
        let applied = DiagnosticLifecycleLockedBox<[UInt64]>([])
        let release = DispatchSemaphore(value: 0)
        var published: [DiagnosticEvaluation<Int>] = []
        let worker = DiagnosticLifecycleWorker<Int, Int>(
            evaluate: { snapshot in
                applied.update { $0.append(snapshot.generation) }
                if snapshot.generation == 0 {
                    entered.update { $0 = true }
                    _ = release.wait(timeout: .now() + TestGate.deadlock)
                }
                return snapshot.capture
            },
            publish: { published.append($0) })

        #expect(worker.submit(DiagnosticCaptureSnapshot(generation: 0, capture: 0)))
        #expect(await diagnosticEventually { entered.read() })
        for generation in 1..<UInt64(10_000) {
            #expect(
                worker.submit(
                    DiagnosticCaptureSnapshot(
                        generation: generation, capture: Int(generation))))
        }

        let blocked = worker.statistics
        #expect(blocked.submissions == 10_000)
        #expect(blocked.coalesced == 9_998)
        #expect(blocked.applications == 1)
        #expect(blocked.activeApplications == 1)
        #expect(blocked.pendingApplications == 1)
        #expect(blocked.maximumActiveApplications == 1)
        #expect(blocked.maximumPendingApplications == 1)
        #expect(blocked.mainThreadApplications == 0)
        #expect(published.isEmpty)

        release.signal()
        #expect(await diagnosticEventually { worker.statistics.publications == 1 })
        #expect(applied.read() == [0, 9_999])
        #expect(
            published
                == [DiagnosticEvaluation(captureGeneration: 9_999, result: 9_999)])
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.publications == 1)
        #expect(worker.statistics.revokedResults == 1)
        #expect(worker.statistics.maximumActiveApplications == 1)
        worker.shutdown()
    }

    @MainActor
    @Test("submission and Stop invalidation stay bounded behind 250 ms evaluation")
    func diagnosticAdmissionDistribution() async {
        let beganAt = DiagnosticLifecycleLockedBox<UInt64?>(nil)
        let release = DispatchSemaphore(value: 0)
        var published: [DiagnosticEvaluation<Int>] = []
        let worker = DiagnosticLifecycleWorker<Int, Int>(
            evaluate: { snapshot in
                beganAt.update { $0 = DispatchTime.now().uptimeNanoseconds }
                _ = release.wait(timeout: .now() + TestGate.deadlock)
                return snapshot.capture
            },
            publish: { published.append($0) })

        #expect(worker.submit(DiagnosticCaptureSnapshot(generation: 0, capture: 0)))
        #expect(await diagnosticEventually { beganAt.read() != nil })

        var durations: [UInt64] = []
        durations.reserveCapacity(1_000)
        for generation in 1...UInt64(1_000) {
            let started = DispatchTime.now().uptimeNanoseconds
            #expect(
                worker.submit(
                    DiagnosticCaptureSnapshot(
                        generation: generation, capture: Int(generation))))
            durations.append(DispatchTime.now().uptimeNanoseconds - started)
        }
        durations.sort()
        let p99 = durations[989]
        let maximum = durations.last ?? .max

        let stopStarted = DispatchTime.now().uptimeNanoseconds
        worker.invalidate()
        let stopAdmission = DispatchTime.now().uptimeNanoseconds - stopStarted

        #expect(p99 < 2_000_000)
        #expect(maximum < 8_000_000)
        #expect(stopAdmission < 8_000_000)
        #expect(worker.statistics.activeApplications == 1)
        #expect(worker.statistics.pendingApplications == 0)
        #expect(worker.statistics.maximumActiveApplications == 1)
        #expect(worker.statistics.maximumPendingApplications == 1)
        #expect(worker.statistics.mainThreadApplications == 0)

        await holdDiagnosticWork(since: beganAt.read() ?? 0)
        release.signal()
        #expect(await diagnosticEventually { worker.statistics.activeApplications == 0 })
        #expect(published.isEmpty)
        #expect(worker.statistics.publications == 0)
        #expect(worker.statistics.revokedResults == 1)
        worker.shutdown()
    }

    @MainActor
    @Test("Stop revokes a result already waiting for MainActor delivery")
    func diagnosticDeliveryGeneration() async {
        let pendingDelivery = DiagnosticLifecycleLockedBox<
            (@MainActor @Sendable () -> Void)?
        >(nil)
        var published: [DiagnosticEvaluation<Int>] = []
        let worker = DiagnosticLifecycleWorker<Int, Int>(
            evaluate: { $0.capture },
            scheduleMain: { delivery in
                pendingDelivery.update { $0 = delivery }
            },
            publish: { published.append($0) })

        #expect(worker.submit(DiagnosticCaptureSnapshot(generation: 7, capture: 42)))
        #expect(await diagnosticEventually { pendingDelivery.read() != nil })
        worker.invalidate()
        pendingDelivery.read()?()

        #expect(published.isEmpty)
        #expect(worker.statistics.publications == 0)
        #expect(worker.statistics.revokedResults == 1)
        worker.shutdown()
    }

    @MainActor
    @Test("Cancel generation defeats a Begin delayed for 250 ms")
    func calibrationCancelDefeatsLateBegin() async {
        let beganAt = DiagnosticLifecycleLockedBox<UInt64?>(nil)
        let applied = DiagnosticLifecycleLockedBox<[CalibrationIntent]>([])
        let release = DispatchSemaphore(value: 0)
        var published: [CalibrationLifecycleCompletion<Bool>] = []
        let worker = CalibrationLifecycleWorker<Bool>(
            lifecycleQueue: DispatchQueue(
                label: "yunaudio.test.calibration-lifecycle"),
            apply: { intent, permit in
                if intent.desiredState == .active, beganAt.read() == nil {
                    beganAt.update { $0 = DispatchTime.now().uptimeNanoseconds }
                    _ = release.wait(timeout: .now() + TestGate.deadlock)
                }
                // Production checks this after taking RoutingEngine.stateLock.
                guard permit.mayMutateEngine else { return false }
                applied.update { $0.append(intent) }
                return true
            },
            publish: { published.append($0) })

        let begin = worker.begin()
        #expect(begin?.generation == 1)
        #expect(await diagnosticEventually { beganAt.read() != nil })
        var durations: [UInt64] = []
        durations.reserveCapacity(9_999)
        for _ in 1..<9_999 {
            let started = DispatchTime.now().uptimeNanoseconds
            #expect(worker.submit(.active) != nil)
            durations.append(DispatchTime.now().uptimeNanoseconds - started)
        }
        let cancelStarted = DispatchTime.now().uptimeNanoseconds
        let cancel = worker.cancel()
        let cancelAdmission = DispatchTime.now().uptimeNanoseconds - cancelStarted
        durations.append(cancelAdmission)
        durations.sort()
        let p99Index = max(
            0, min(durations.count - 1, Int(ceil(Double(durations.count) * 0.99)) - 1))

        #expect(cancel?.generation == 10_000)
        #expect(durations[p99Index] < 2_000_000)
        #expect((durations.last ?? .max) < 8_000_000)
        #expect(cancelAdmission < 8_000_000)
        #expect(worker.statistics.submissions == 10_000)
        #expect(worker.statistics.coalesced == 9_998)
        #expect(worker.statistics.activeApplications == 1)
        #expect(worker.statistics.pendingApplications == 1)
        #expect(worker.statistics.maximumActiveApplications == 1)
        #expect(worker.statistics.maximumPendingApplications == 1)
        #expect(worker.statistics.mainThreadApplications == 0)

        await holdDiagnosticWork(since: beganAt.read() ?? 0)
        release.signal()
        #expect(await diagnosticEventually { worker.statistics.publications == 1 })

        let expected = CalibrationIntent(
            generation: 10_000, desiredState: .inactive)
        #expect(applied.read() == [expected])
        #expect(
            published
                == [CalibrationLifecycleCompletion(intent: expected, outcome: true)])
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.publications == 1)
        #expect(worker.statistics.revokedResults == 1)
        #expect(worker.statistics.maximumActiveApplications == 1)
        #expect(worker.statistics.mainThreadApplications == 0)
        worker.shutdown()
    }
}
