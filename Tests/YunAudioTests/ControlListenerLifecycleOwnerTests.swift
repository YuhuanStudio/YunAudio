import Foundation
import Testing
import YunAudioControl

@testable import YunAudioApp

private final class ControlLifecycleGate<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case empty
        case waiting(CheckedContinuation<Value?, Never>)
        case completed(Value?)
    }

    private let lock = NSLock()
    private var state: State = .empty

    func resolve(_ value: Value) {
        let continuation: CheckedContinuation<Value?, Never>? = lock.withLock {
            switch state {
            case .empty:
                state = .completed(value)
                return nil
            case .waiting(let continuation):
                state = .completed(value)
                return continuation
            case .completed:
                return nil
            }
        }
        continuation?.resume(returning: value)
    }

    func wait(timeout: TimeInterval = 2) async -> Value? {
        await withCheckedContinuation { continuation in
            let completed: Value?? = lock.withLock {
                switch state {
                case .empty:
                    state = .waiting(continuation)
                    return nil
                case .waiting:
                    Issue.record("one control lifecycle gate had two waiters")
                    return .some(nil)
                case .completed(let value):
                    return .some(value)
                }
            }
            if let completed { continuation.resume(returning: completed) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                self.timeOut()
            }
        }
    }

    private func timeOut() {
        let continuation: CheckedContinuation<Value?, Never>? = lock.withLock {
            guard case .waiting(let continuation) = state else { return nil }
            state = .completed(nil)
            return continuation
        }
        continuation?.resume(returning: nil)
    }
}

private final class ControlLifecycleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() { lock.withLock { storage += 1 } }
    var value: Int { lock.withLock { storage } }
}

@MainActor
private final class ControlTerminationPublication {
    var audio: ApplicationAudioTeardownResult?
    var controlAcknowledged: Bool?
}

private final class ControlLifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Int
    private let finished = ControlLifecycleGate<Bool>()
    private var samples: [UInt64] = []

    init(expected: Int) {
        self.expected = expected
        samples.reserveCapacity(expected)
    }

    @MainActor
    func record(sentAt: UInt64) {
        let latency = DispatchTime.now().uptimeNanoseconds - sentAt
        let isFinished = lock.withLock {
            samples.append(latency)
            return samples.count == expected
        }
        if isFinished { finished.resolve(true) }
    }

    func wait() async -> Bool { await finished.wait() == true }
    var count: Int { lock.withLock { samples.count } }
    var maximumNanoseconds: UInt64 { lock.withLock { samples.max() ?? 0 } }
}

private func startControlLifecycleProbe(samples: Int) -> ControlLifecycleProbe {
    let probe = ControlLifecycleProbe(expected: samples)
    DispatchQueue(label: "yunaudio.test.control-lifecycle-sentinel", qos: .userInitiated)
        .async {
            for _ in 0..<samples {
                let delivered = DispatchSemaphore(value: 0)
                let sentAt = DispatchTime.now().uptimeNanoseconds
                MainRunLoopDelivery.perform {
                    probe.record(sentAt: sentAt)
                    delivered.signal()
                }
                guard delivered.wait(timeout: .now() + 1) == .success else { return }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    return probe
}

private final class BlockingControlLifecycleBackend: ControlListenerLifecycleBackend,
    @unchecked Sendable
{
    private struct State {
        var handler: ControlListener.Handler?
        var openClients = 0
        var startCalls = 0
        var stopCalls = 0
        var concurrentCalls = 0
        var maximumConcurrentCalls = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let startDelay: TimeInterval
    private let stopDelay: TimeInterval
    private let openClientsAfterStart: Int
    private let startBarrier: DispatchSemaphore?
    private let stopBarrier: DispatchSemaphore?
    let startEntered = ControlLifecycleGate<Bool>()
    let stopEntered = ControlLifecycleGate<Bool>()

    init(
        startDelay: TimeInterval = 0, stopDelay: TimeInterval = 0,
        openClientsAfterStart: Int = 0, startBarrier: DispatchSemaphore? = nil,
        stopBarrier: DispatchSemaphore? = nil
    ) {
        self.startDelay = startDelay
        self.stopDelay = stopDelay
        self.openClientsAfterStart = openClientsAfterStart
        self.startBarrier = startBarrier
        self.stopBarrier = stopBarrier
    }

    var openClientCount: Int { lock.withLock { state.openClients } }
    var startCalls: Int { lock.withLock { state.startCalls } }
    var stopCalls: Int { lock.withLock { state.stopCalls } }
    var maximumConcurrentCalls: Int { lock.withLock { state.maximumConcurrentCalls } }
    var capturedHandler: ControlListener.Handler? { lock.withLock { state.handler } }

    func start(handler: @escaping ControlListener.Handler) throws {
        beginCall(isStart: true)
        defer { endCall() }
        let waitsAtBarrier = lock.withLock {
            state.handler = handler
            return state.startCalls == 1
        }
        startEntered.resolve(true)
        if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
        if waitsAtBarrier { startBarrier?.wait() }
        lock.withLock { state.openClients = openClientsAfterStart }
    }

    func stop() -> Bool {
        beginCall(isStart: false)
        defer { endCall() }
        stopEntered.resolve(true)
        if stopDelay > 0 { Thread.sleep(forTimeInterval: stopDelay) }
        let waitsAtBarrier = lock.withLock { state.stopCalls == 1 }
        if waitsAtBarrier { stopBarrier?.wait() }
        lock.withLock { state.openClients = 0 }
        return true
    }

    private func beginCall(isStart: Bool) {
        lock.withLock {
            if isStart { state.startCalls += 1 } else { state.stopCalls += 1 }
            state.concurrentCalls += 1
            state.maximumConcurrentCalls = max(
                state.maximumConcurrentCalls, state.concurrentCalls)
        }
    }

    private func endCall() {
        lock.withLock {
            precondition(state.concurrentCalls == 1)
            state.concurrentCalls = 0
        }
    }
}

@Suite("Off-main control listener lifecycle", .serialized)
@MainActor
struct ControlListenerLifecycleOwnerTests {
    @Test("200 ms start and 250 ms stop never hold MainActor")
    func blockingLifecycleLeavesMainActorResponsive() async throws {
        let backend = BlockingControlLifecycleBackend(
            startDelay: 0.2, stopDelay: 0.25, openClientsAfterStart: 3)
        let starts = ControlLifecycleCounter()
        let stops = ControlLifecycleCounter()
        let startResult = ControlLifecycleGate<ControlListenerLifecycleOwner.StartResult>()
        let stopResult = ControlLifecycleGate<Bool>()
        let owner = ControlListenerLifecycleOwner(makeBackend: { backend })

        // What main-runloop delivery costs in this run with the owner idle.
        //
        // The claim is that a 200 ms start does not hold the main actor, and an
        // absolute budget cannot make it: swift-testing runs suites in
        // parallel, so the other suites' own main-actor work lands in the same
        // measurement. This asserted 8 ms flat and consequently failed in every
        // full run and passed alone — a test that reports the machine's load as
        // a defect in the code teaches everybody to ignore it.
        //
        // The floor stays, so a quiet machine still holds the tight budget.
        let baseline = startControlLifecycleProbe(samples: 60)
        #expect(await baseline.wait())
        let ceiling = max(8_000_000, baseline.maximumNanoseconds * 2)

        let startAdmission = DispatchTime.now().uptimeNanoseconds
        owner.start(handler: { _, _, reply in reply(.message("unused")) }) { result in
            starts.increment()
            startResult.resolve(result)
        }
        let startAdmissionCost = DispatchTime.now().uptimeNanoseconds - startAdmission
        #expect(startAdmissionCost < ceiling)
        try #require(await backend.startEntered.wait() == true)
        let startProbe = startControlLifecycleProbe(samples: 120)
        #expect(await startProbe.wait())
        #expect(startProbe.count == 120)
        #expect(
            startProbe.maximumNanoseconds < ceiling,
            "start held the main actor for \(startProbe.maximumNanoseconds) ns, idle baseline \(baseline.maximumNanoseconds) ns")
        #expect(await startResult.wait() == .started)
        #expect(starts.value == 1)
        #expect(owner.statistics.openClients == 3)

        let stopAdmission = DispatchTime.now().uptimeNanoseconds
        owner.shutdown { acknowledged in
            stops.increment()
            stopResult.resolve(acknowledged)
        }
        let stopAdmissionCost = DispatchTime.now().uptimeNanoseconds - stopAdmission
        #expect(stopAdmissionCost < ceiling)
        try #require(await backend.stopEntered.wait() == true)
        let stopProbe = startControlLifecycleProbe(samples: 160)
        #expect(await stopProbe.wait())
        #expect(stopProbe.count == 160)
        #expect(
            stopProbe.maximumNanoseconds < ceiling,
            "stop held the main actor for \(stopProbe.maximumNanoseconds) ns, idle baseline \(baseline.maximumNanoseconds) ns")
        #expect(await stopResult.wait() == true)
        #expect(stops.value == 1)

        let statistics = owner.statistics
        #expect(statistics.startApplications == 1)
        #expect(statistics.stopApplications == 1)
        #expect(statistics.startPublications == 1)
        #expect(statistics.stopPublications == 1)
        #expect(statistics.maximumConcurrentLifecycleOperations == 1)
        #expect(statistics.maximumActiveOwners == 1)
        #expect(statistics.activeOwners == 0)
        #expect(statistics.openClients == 0)
        #expect(backend.startCalls == 1)
        #expect(backend.stopCalls == 1)
        #expect(backend.maximumConcurrentCalls == 1)
    }

    @Test("stop revokes an in-flight start and every late handler")
    func stopSupersedesStartAndLateHandler() async throws {
        let barrier = DispatchSemaphore(value: 0)
        let backend = BlockingControlLifecycleBackend(
            openClientsAfterStart: 4, startBarrier: barrier)
        let applications = ControlLifecycleCounter()
        let replies = ControlLifecycleCounter()
        let startCompletions = ControlLifecycleCounter()
        let stopCompletions = ControlLifecycleCounter()
        let startResult = ControlLifecycleGate<ControlListenerLifecycleOwner.StartResult>()
        let stopResult = ControlLifecycleGate<Bool>()
        let replyResult = ControlLifecycleGate<ControlReply>()
        let owner = ControlListenerLifecycleOwner(makeBackend: { backend })

        owner.start(
            handler: { _, _, reply in
                applications.increment()
                reply(.message("applied"))
            },
            completion: { result in
                startCompletions.increment()
                startResult.resolve(result)
            })
        try #require(await backend.startEntered.wait() == true)
        owner.shutdown { acknowledged in
            stopCompletions.increment()
            stopResult.resolve(acknowledged)
        }

        let handler = try #require(backend.capturedHandler)
        handler(
            .status,
            ControlRequestDeadline(
                uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        ) { reply in
            replies.increment()
            replyResult.resolve(reply)
        }
        try #require(await replyResult.wait() != nil)
        #expect(applications.value == 0)
        #expect(replies.value == 1)

        barrier.signal()
        #expect(await startResult.wait() == .superseded)
        #expect(await stopResult.wait() == true)
        #expect(startCompletions.value == 1)
        #expect(stopCompletions.value == 1)
        #expect(applications.value == 0)

        let statistics = owner.statistics
        #expect(statistics.supersededStarts == 1)
        #expect(statistics.refusedHandlerAdmissions == 1)
        #expect(statistics.maximumConcurrentLifecycleOperations == 1)
        #expect(statistics.maximumActiveOwners == 1)
        #expect(statistics.activeOwners == 0)
        #expect(statistics.openClients == 0)
        #expect(backend.startCalls == 1)
        #expect(backend.stopCalls == 1)
    }

    @Test("a stuck start times out once and its late backend is quarantined")
    func startWatchdogIsExactOnceAndStopsLateBackend() async throws {
        let barrier = DispatchSemaphore(value: 0)
        let backend = BlockingControlLifecycleBackend(
            openClientsAfterStart: 2, startBarrier: barrier)
        let applications = ControlLifecycleCounter()
        let replies = ControlLifecycleCounter()
        let completions = ControlLifecycleCounter()
        let completion = ControlLifecycleGate<ControlListenerLifecycleOwner.StartResult>()
        let lateReply = ControlLifecycleGate<ControlReply>()
        let owner = ControlListenerLifecycleOwner(
            startTimeout: 0.05, makeBackend: { backend })

        owner.start(
            handler: { _, _, reply in
                applications.increment()
                reply(.message("applied"))
            },
            completion: { result in
                completions.increment()
                completion.resolve(result)
            })
        try #require(await backend.startEntered.wait() == true)
        guard let result = await completion.wait(), case .failed = result else {
            Issue.record("the start watchdog did not publish its bounded failure")
            barrier.signal()
            return
        }
        #expect(completions.value == 1)
        #expect(owner.statistics.startTimeouts == 1)
        #expect(owner.statistics.activeOwners == 1)

        let handler = try #require(backend.capturedHandler)
        handler(
            .status,
            ControlRequestDeadline(
                uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        ) { reply in
            replies.increment()
            lateReply.resolve(reply)
        }
        try #require(await lateReply.wait() != nil)
        #expect(applications.value == 0)
        #expect(replies.value == 1)

        barrier.signal()
        for _ in 0..<200 where owner.statistics.activeOwners != 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(completions.value == 1)
        #expect(applications.value == 0)
        #expect(owner.statistics.startApplications == 1)
        #expect(owner.statistics.startPublications == 1)
        #expect(owner.statistics.supersededStarts == 1)
        #expect(owner.statistics.refusedHandlerAdmissions == 1)
        #expect(owner.statistics.activeOwners == 0)
        #expect(owner.statistics.openClients == 0)
        #expect(backend.startCalls == 1)
        #expect(backend.stopCalls == 1)
    }

    @Test("refused termination reuses one serial owner and accepted exit seals it")
    func terminationRecoveryNeverOverlapsLifecycleOwners() async throws {
        let barrier = DispatchSemaphore(value: 0)
        let backend = BlockingControlLifecycleBackend(
            openClientsAfterStart: 2, startBarrier: barrier)
        let ownerConstructions = ControlLifecycleCounter()
        ownerConstructions.increment()
        let owner = ControlListenerLifecycleOwner(
            startTimeout: 0.2, stopTimeout: 0.04, makeBackend: { backend })
        let firstStart = ControlLifecycleGate<ControlListenerLifecycleOwner.StartResult>()
        let stop = ControlLifecycleGate<Bool>()
        let recovery = ControlLifecycleGate<ControlListenerLifecycleOwner.StartResult>()
        let sealed = ControlLifecycleGate<ControlListenerLifecycleOwner.StartResult>()
        let applications = ControlLifecycleCounter()
        let lateReplies = ControlLifecycleCounter()

        owner.start(
            handler: { _, _, reply in
                applications.increment()
                reply(.message("applied"))
            },
            completion: { firstStart.resolve($0) })
        try #require(await backend.startEntered.wait() == true)
        let oldHandler = try #require(backend.capturedHandler)

        // Termination revokes synchronously, while its owner queue remains
        // occupied by the deliberately stuck first bind.
        owner.stop { stop.resolve($0) }
        #expect(await stop.wait() == false)

        // AppKit refuses Quit. Recovery is admitted on this same serial owner,
        // not beside the old bind which has not returned yet.
        owner.start(
            handler: { _, _, reply in
                applications.increment()
                reply(.message("recovered"))
            },
            completion: { recovery.resolve($0) })
        oldHandler(
            .status,
            ControlRequestDeadline(
                uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        ) { _ in lateReplies.increment() }
        #expect(applications.value == 0)
        #expect(lateReplies.value == 1)

        barrier.signal()
        #expect(await firstStart.wait() == .superseded)
        #expect(await recovery.wait() == .started)
        #expect(ownerConstructions.value == 1)
        #expect(backend.startCalls == 2)
        #expect(backend.maximumConcurrentCalls == 1)
        #expect(owner.statistics.maximumActiveOwners == 1)
        #expect(owner.statistics.openClients == 2)

        let acceptedStop = ControlLifecycleGate<Bool>()
        owner.shutdown { acceptedStop.resolve($0) }
        #expect(await acceptedStop.wait() == true)
        owner.start(
            handler: { _, _, reply in reply(.message("impossible")) },
            completion: { sealed.resolve($0) })
        #expect(await sealed.wait() == .superseded)
        #expect(backend.startCalls == 2)
        #expect(backend.maximumConcurrentCalls == 1)
        #expect(owner.statistics.activeOwners == 0)
        #expect(owner.statistics.openClients == 0)
    }

    @Test("recovery queued beyond its admission deadline still starts on the sole owner")
    func terminationRecoverySurvivesQueueDelay() async throws {
        let barrier = DispatchSemaphore(value: 0)
        let backend = BlockingControlLifecycleBackend(
            openClientsAfterStart: 2, startBarrier: barrier)
        let owner = ControlListenerLifecycleOwner(
            startTimeout: 0.05, stopTimeout: 0.01, makeBackend: { backend })
        let firstStart = ControlLifecycleGate<ControlListenerLifecycleOwner.StartResult>()
        let stop = ControlLifecycleGate<Bool>()
        let recovery = ControlLifecycleGate<ControlListenerLifecycleOwner.StartResult>()

        owner.start(
            handler: { _, _, reply in reply(.message("old")) },
            completion: { firstStart.resolve($0) })
        try #require(await backend.startEntered.wait() == true)
        owner.stop { stop.resolve($0) }
        #expect(await stop.wait() == false)

        owner.start(
            handler: { _, _, reply in reply(.message("recovered")) },
            completion: { recovery.resolve($0) })
        #expect(await recovery.wait() == .queued)
        #expect(backend.startCalls == 1)
        #expect(owner.statistics.queuedStartPublications == 1)

        barrier.signal()
        #expect(await firstStart.wait() == .superseded)
        for _ in 0..<400
        where backend.startCalls != 2 || owner.statistics.openClients != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(backend.startCalls == 2)
        #expect(owner.statistics.openClients == 2)
        #expect(owner.statistics.startApplications == 2)
        #expect(owner.statistics.startTimeouts == 0)
        #expect(owner.statistics.maximumConcurrentLifecycleOperations == 1)

        let accepted = ControlLifecycleGate<Bool>()
        owner.shutdown { accepted.resolve($0) }
        #expect(await accepted.wait() == true)
        #expect(backend.stopCalls == 2)
        #expect(owner.statistics.openClients == 0)
    }

    @Test("recovery queued behind a stuck running stop restores the socket")
    func terminationRecoverySurvivesRunningStopDelay() async throws {
        let stopBarrier = DispatchSemaphore(value: 0)
        let backend = BlockingControlLifecycleBackend(
            openClientsAfterStart: 2, stopBarrier: stopBarrier)
        let owner = ControlListenerLifecycleOwner(
            startTimeout: 0.05, stopTimeout: 0.01, makeBackend: { backend })
        let firstStart = ControlLifecycleGate<ControlListenerLifecycleOwner.StartResult>()
        let stop = ControlLifecycleGate<Bool>()
        let recovery = ControlLifecycleGate<ControlListenerLifecycleOwner.StartResult>()

        owner.start(
            handler: { _, _, reply in reply(.message("first")) },
            completion: { firstStart.resolve($0) })
        #expect(await firstStart.wait() == .started)
        #expect(owner.statistics.openClients == 2)

        owner.stop { stop.resolve($0) }
        try #require(await backend.stopEntered.wait() == true)
        #expect(await stop.wait() == false)
        owner.start(
            handler: { _, _, reply in reply(.message("recovered")) },
            completion: { recovery.resolve($0) })
        #expect(await recovery.wait() == .queued)
        #expect(backend.startCalls == 1)

        stopBarrier.signal()
        for _ in 0..<400
        where backend.startCalls != 2 || owner.statistics.openClients != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(backend.startCalls == 2)
        #expect(backend.stopCalls == 1)
        #expect(owner.statistics.openClients == 2)
        #expect(owner.statistics.startTimeouts == 0)
        #expect(owner.statistics.maximumConcurrentLifecycleOperations == 1)
        #expect(backend.maximumConcurrentCalls == 1)

        let accepted = ControlLifecycleGate<Bool>()
        owner.shutdown { accepted.resolve($0) }
        #expect(await accepted.wait() == true)
        #expect(backend.stopCalls == 2)
        #expect(owner.statistics.openClients == 0)
    }

    @Test("audio and control teardown publish one result only after both owners")
    func terminationJoinIsOrderIndependentAndExactOnce() {
        let publications = ControlLifecycleCounter()
        let published = ControlTerminationPublication()
        let join = ApplicationControlTerminationJoin { audio, control in
            publications.increment()
            published.audio = audio
            published.controlAcknowledged = control
        }

        join.receiveControl(acknowledged: false)
        #expect(publications.value == 0)
        join.receive(audio: .complete)
        #expect(publications.value == 1)
        #expect(published.audio == .complete)
        #expect(published.controlAcknowledged == false)
    }
}
