import Foundation
import Testing

@testable import YunAudioApp

private final class RouteStartRaceBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

@Suite("Route start intent", .serialized)
struct RouteStartIntentTests {
    @Test("cancellation before handover retires Start without an engine owner")
    func cancellationBeforeAdmission() {
        let intent = RouteStartIntent()

        #expect(intent.phase == .resolvingCapture)
        #expect(intent.cancel() == .finishWithoutEngine)
        #expect(intent.phase == .cancelled)
        #expect(intent.isCancelled)
        #expect(intent.admitEngineLifecycle() == .cancelled)
        #expect(intent.cancel() == .alreadyCancelled)
    }

    @Test("cancellation after handover waits for the sole engine owner")
    func admissionBeforeCancellation() {
        let intent = RouteStartIntent()

        #expect(intent.admitEngineLifecycle() == .admitted)
        #expect(intent.phase == .engineLifecycle)
        #expect(!intent.isCancelled)
        #expect(intent.admitEngineLifecycle() == .alreadyAdmitted)
        #expect(intent.cancel() == .awaitEngineOwner)
        #expect(intent.phase == .cancelled)
        #expect(intent.cancel() == .alreadyCancelled)
    }

    @Test("a late resolution can never admit an engine after cancellation")
    func lateResolutionIsRefused() {
        let engineStarts = RouteStartRaceBox(0)
        let intent = RouteStartIntent()

        let disposition = intent.cancel()
        if intent.admitEngineLifecycle() == .admitted {
            engineStarts.update { $0 += 1 }
        }

        #expect(disposition == .finishWithoutEngine)
        #expect(engineStarts.read() == 0)
        #expect(intent.isCancelled)
    }

    @Test("ten thousand cancellation and admission races have one coherent winner")
    func cancellationAdmissionRaceIsLinearised() {
        let iterations = 10_000
        let queue = DispatchQueue(
            label: "yunaudio.test.route-start-intent", attributes: .concurrent)
        var cancellationWon = 0
        var engineWon = 0
        var invalid = 0

        for _ in 0..<iterations {
            let intent = RouteStartIntent()
            let barrier = DispatchSemaphore(value: 0)
            let finished = DispatchGroup()
            let admission = RouteStartRaceBox<RouteStartIntent.EngineAdmission?>(nil)
            let cancellation = RouteStartRaceBox<
                RouteStartIntent.CancellationDisposition?
            >(nil)

            finished.enter()
            queue.async {
                barrier.wait()
                admission.update { $0 = intent.admitEngineLifecycle() }
                finished.leave()
            }
            finished.enter()
            queue.async {
                barrier.wait()
                cancellation.update { $0 = intent.cancel() }
                finished.leave()
            }
            barrier.signal()
            barrier.signal()
            finished.wait()

            switch (admission.read(), cancellation.read()) {
            case (.cancelled, .finishWithoutEngine):
                cancellationWon += 1
            case (.admitted, .awaitEngineOwner):
                engineWon += 1
            default:
                invalid += 1
            }
            if intent.phase != .cancelled || !intent.isCancelled { invalid += 1 }
        }

        print(
            "10,000 route-start handovers: \(cancellationWon) cancellation-first, "
                + "\(engineWon) engine-first, \(invalid) invalid")
        #expect(cancellationWon + engineWon == iterations)
        #expect(invalid == 0)
    }
}
