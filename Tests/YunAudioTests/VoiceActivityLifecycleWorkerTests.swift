import CoreAudio
import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine
@testable import YunAudioHAL

@Suite("Bounded system voice activity lifecycle", .serialized)
struct VoiceActivityLifecycleWorkerTests {
    private final class FakeOwner: @unchecked Sendable {}

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func update<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.withLock { body(&value) }
        }

        var snapshot: Value { lock.withLock { value } }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var availabilityCallsStorage = 0
        private var startCallsStorage = 0
        private var stopCallsStorage = 0
        private var eventsStorage: [VoiceActivityLifecycleEvent] = []

        func recordAvailability() -> Int {
            lock.withLock {
                availabilityCallsStorage += 1
                return availabilityCallsStorage
            }
        }

        func recordStart() { lock.withLock { startCallsStorage += 1 } }
        func recordStop() { lock.withLock { stopCallsStorage += 1 } }
        func record(_ event: VoiceActivityLifecycleEvent) {
            lock.withLock { eventsStorage.append(event) }
        }

        var availabilityCalls: Int { lock.withLock { availabilityCallsStorage } }
        var startCalls: Int { lock.withLock { startCallsStorage } }
        var stopCalls: Int { lock.withLock { stopCallsStorage } }
        var events: [VoiceActivityLifecycleEvent] { lock.withLock { eventsStorage } }
    }

    private func worker(
        state: State,
        quarantine: ProcessLifetimeAudioQuarantine = ProcessLifetimeAudioQuarantine(),
        timeout: TimeInterval = 0.5,
        isAvailable: @escaping @Sendable (AudioObjectID) -> Bool = { _ in true },
        start:
            @escaping @Sendable (
                AudioObjectID,
                @escaping @Sendable (Bool) -> Void,
                @escaping @Sendable () -> Void
            ) -> FakeOwner? = { _, _, _ in FakeOwner() },
        stop: @escaping @Sendable (FakeOwner) -> Bool = { _ in true },
        onEvent: @escaping @Sendable (VoiceActivityLifecycleEvent) -> Void = { _ in }
    ) -> VoiceActivityLifecycleWorker<FakeOwner> {
        VoiceActivityLifecycleWorker<FakeOwner>(
            operations: .init(
                isAvailable: { device in
                    _ = state.recordAvailability()
                    return isAvailable(device)
                },
                start: { device, _, onChange, cleanupFailed in
                    state.recordStart()
                    return start(device, onChange, cleanupFailed)
                },
                isObserving: { _ in true },
                stop: { owner in
                    state.recordStop()
                    return stop(owner)
                }),
            quarantine: quarantine,
            operationTimeout: timeout,
            label: "yunaudio.voice-activity.test.\(UUID().uuidString)",
            publish: { event in
                state.record(event)
                onEvent(event)
            })
    }

    @Test("ten thousand requests execute only the first and latest HAL read")
    func firstAndLatestBacklogIsBounded() throws {
        let state = State()
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let latestPublished = DispatchSemaphore(value: 0)
        let call = LockedBox(0)
        let latestToken = LockedBox<VoiceActivityLifecycleToken?>(nil)

        let worker = worker(
            state: state,
            timeout: 2,
            isAvailable: { _ in
                let current = call.update {
                    $0 += 1
                    return $0
                }
                if current == 1 {
                    firstEntered.signal()
                    _ = releaseFirst.wait(timeout: .now() + 2)
                }
                return true
            },
            onEvent: { event in
                guard case .availability(let token, true) = event,
                    token == latestToken.snapshot
                else { return }
                latestPublished.signal()
            })
        let first = try #require(worker.requestAvailability(on: 1))
        #expect(firstEntered.wait(timeout: .now() + 1) == .success)

        for device in 2...10_000 {
            latestToken.update {
                $0 = worker.requestAvailability(on: AudioObjectID(device))
            }
        }
        releaseFirst.signal()

        #expect(latestPublished.wait(timeout: .now() + 2) == .success)
        let telemetry = worker.telemetry
        #expect(first != latestToken.snapshot)
        #expect(state.availabilityCalls == 2)
        #expect(telemetry.submittedRequests == 10_000)
        #expect(telemetry.startedOperations == 2)
        #expect(telemetry.maximumPendingRequests == 1)
        #expect(telemetry.maximumConcurrentOperations == 1)
        #expect(telemetry.coalescedRequests == 9_998)
    }

    @Test("Stop rejects a constructor which returns after cancellation")
    func lateStartCannotPublish() throws {
        let state = State()
        let startEntered = DispatchSemaphore(value: 0)
        let releaseStart = DispatchSemaphore(value: 0)
        let quarantine = ProcessLifetimeAudioQuarantine()
        let worker = worker(
            state: state,
            quarantine: quarantine,
            timeout: 2,
            start: { _, onChange, _ in
                onChange(true)
                startEntered.signal()
                _ = releaseStart.wait(timeout: .now() + 2)
                return FakeOwner()
            })

        #expect(worker.requestStart(on: 7, activation: .enableIfNeeded) != nil)
        #expect(startEntered.wait(timeout: .now() + 1) == .success)
        let fence = worker.requestStop()

        let routeTeardown = DispatchSemaphore(value: 0)
        DispatchQueue(label: "yunaudio.route-teardown.independent").async {
            routeTeardown.signal()
        }
        #expect(routeTeardown.wait(timeout: .now() + 0.1) == .success)

        releaseStart.signal()
        #expect(fence.wait(timeout: 1) == .complete)
        #expect(state.startCalls == 1)
        #expect(state.stopCalls == 1)
        #expect(fence.completionCount == 1)
        #expect(quarantine.count == 0)
        #expect(
            state.events.allSatisfy {
                if case .started = $0 { return false }
                if case .speaking = $0 { return false }
                return true
            })
    }

    @Test("ten thousand Stops share one owner cleanup and one completion")
    func repeatedStopIsExactlyOnce() throws {
        let state = State()
        let started = DispatchSemaphore(value: 0)
        let stopEntered = DispatchSemaphore(value: 0)
        let releaseStop = DispatchSemaphore(value: 0)
        let worker = worker(
            state: state,
            timeout: 2,
            stop: { _ in
                stopEntered.signal()
                _ = releaseStop.wait(timeout: .now() + 2)
                return true
            },
            onEvent: { event in
                if case .started = event { started.signal() }
            })
        #expect(worker.requestStart(on: 9, activation: .enableIfNeeded) != nil)
        #expect(started.wait(timeout: .now() + 1) == .success)

        let first = worker.requestStop()
        #expect(stopEntered.wait(timeout: .now() + 1) == .success)
        for _ in 1..<10_000 {
            #expect(worker.requestStop() === first)
        }
        releaseStop.signal()

        #expect(first.wait(timeout: 1) == .complete)
        #expect(first.completionCount == 1)
        #expect(state.stopCalls == 1)
        #expect(worker.telemetry.maximumPendingRequests == 1)
        #expect(worker.telemetry.maximumConcurrentOperations == 1)
    }

    @Test("an uncancellable HAL stop times out without occupying route teardown")
    func stopDeadlineIsNumericAndIndependent() throws {
        let state = State()
        let started = DispatchSemaphore(value: 0)
        let stopEntered = DispatchSemaphore(value: 0)
        let releaseStop = DispatchSemaphore(value: 0)
        let quarantine = ProcessLifetimeAudioQuarantine()
        let worker = worker(
            state: state,
            quarantine: quarantine,
            timeout: 0.02,
            stop: { _ in
                stopEntered.signal()
                _ = releaseStop.wait(timeout: .now() + 2)
                return true
            },
            onEvent: { event in
                if case .started = event { started.signal() }
            })
        #expect(worker.requestStart(on: 11, activation: .enableIfNeeded) != nil)
        #expect(started.wait(timeout: .now() + 1) == .success)

        let fence = worker.requestStop()
        #expect(stopEntered.wait(timeout: .now() + 1) == .success)
        let routeFinished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "yunaudio.route-stop.deadline-test").async {
            routeFinished.signal()
        }

        let began = DispatchTime.now().uptimeNanoseconds
        let result = fence.wait(timeout: 0.05)
        let elapsed = DispatchTime.now().uptimeNanoseconds - began

        #expect(routeFinished.wait(timeout: .now() + 0.1) == .success)
        #expect(result == .timedOut)
        #expect(elapsed >= 40_000_000)
        #expect(elapsed < 250_000_000)
        #expect(quarantine.count == 1)
        #expect(worker.telemetry.timedOutOperations == 1)

        releaseStop.signal()
        #expect(fence.wait(timeout: 1) == .complete)
        #expect(fence.completionCount == 1)
        #expect(quarantine.count == 0)
    }

    @Test("a failed restore retains one residue and refuses another detector")
    func failedCleanupFailsClosed() throws {
        let state = State()
        let started = DispatchSemaphore(value: 0)
        let quarantine = ProcessLifetimeAudioQuarantine()
        let worker = worker(
            state: state,
            quarantine: quarantine,
            stop: { _ in false },
            onEvent: { event in
                if case .started = event { started.signal() }
            })
        #expect(worker.requestStart(on: 13, activation: .enableIfNeeded) != nil)
        #expect(started.wait(timeout: .now() + 1) == .success)

        let fence = worker.requestStop()
        #expect(fence.wait(timeout: 1) == .operationFailed)
        #expect(fence.completionCount == 1)
        #expect(state.stopCalls == 1)
        #expect(quarantine.count == 1)
        #expect(worker.requestStart(on: 13, activation: .enableIfNeeded) == nil)
        #expect(worker.telemetry.refusedRequests == 1)
    }

    @Test("another subsystem's residue refuses ownership but not capability reads")
    func processWideResidueIsSharedAdmission() throws {
        let state = State()
        let availability = DispatchSemaphore(value: 0)
        let quarantine = ProcessLifetimeAudioQuarantine()
        let residue = NSObject()
        let residueToken = quarantine.retain(residue, reason: "injected Audio Unit residue")
        defer { quarantine.release(residueToken) }
        let worker = worker(
            state: state,
            quarantine: quarantine,
            onEvent: { event in
                if case .availability = event { availability.signal() }
            })

        #expect(worker.requestAvailability(on: 17) != nil)
        #expect(availability.wait(timeout: .now() + 1) == .success)
        #expect(worker.requestStart(on: 17, activation: .enableIfNeeded) == nil)
        #expect(state.availabilityCalls == 1)
        #expect(state.startCalls == 0)
        #expect(worker.telemetry.refusedRequests == 1)
        #expect(quarantine.count == 1)
    }

    @Test("an availability answer returning after timeout is discarded")
    func lateAvailabilityIsNotPublished() throws {
        let state = State()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let timedOut = DispatchSemaphore(value: 0)
        let worker = worker(
            state: state,
            timeout: 0.02,
            isAvailable: { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                returned.signal()
                return true
            },
            onEvent: { event in
                if case .timedOut = event { timedOut.signal() }
            })

        #expect(worker.requestAvailability(on: 19) != nil)
        #expect(entered.wait(timeout: .now() + 1) == .success)
        #expect(timedOut.wait(timeout: .now() + 0.25) == .success)
        release.signal()
        #expect(returned.wait(timeout: .now() + 1) == .success)
        let settled = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.02) {
            settled.signal()
        }
        _ = settled.wait(timeout: .now() + 0.25)

        #expect(
            state.events.allSatisfy {
                if case .availability = $0 { return false }
                return true
            })
        #expect(worker.telemetry.timedOutOperations == 1)
    }

    @Test("application shutdown joins every owner and completes exactly once")
    @MainActor
    func applicationShutdownJoinIsExact() {
        var completeResults: [ApplicationAudioTeardownResult] = []
        let complete = ApplicationAudioShutdownJoin { completeResults.append($0) }
        complete.receive(voiceActivity: .complete)
        #expect(completeResults.isEmpty)
        complete.receive(routing: .complete)
        complete.receive(transcription: .complete)
        complete.receive(localSong: .complete)
        complete.receive(lighting: .complete)
        complete.receive(voiceActivity: .operationFailed)
        complete.receive(routing: .ioProcStopFailed(-1))
        complete.receive(localSong: .timedOut)
        complete.receive(lighting: .operationFailed)
        #expect(completeResults == [.complete])

        var detectorResults: [ApplicationAudioTeardownResult] = []
        let detector = ApplicationAudioShutdownJoin { detectorResults.append($0) }
        detector.receive(routing: .complete)
        detector.receive(voiceActivity: .timedOut)
        detector.receive(transcription: .complete)
        detector.receive(localSong: .complete)
        detector.receive(lighting: .complete)
        #expect(detectorResults == [.voiceActivity(.timedOut)])

        var routeResults: [ApplicationAudioTeardownResult] = []
        let route = ApplicationAudioShutdownJoin { routeResults.append($0) }
        route.receive(voiceActivity: .operationFailed)
        route.receive(routing: .ioProcStopFailed(-73))
        route.receive(transcription: .timedOut)
        route.receive(localSong: .timedOut)
        route.receive(lighting: .operationFailed)
        #expect(routeResults == [.routing(.ioProcStopFailed(-73))])

        var songResults: [ApplicationAudioTeardownResult] = []
        let song = ApplicationAudioShutdownJoin { songResults.append($0) }
        song.receive(routing: .complete)
        song.receive(voiceActivity: .complete)
        song.receive(transcription: .complete)
        song.receive(localSong: .timedOut)
        song.receive(lighting: .complete)
        song.receive(localSong: .complete)
        #expect(songResults == [.localSong(.timedOut)])

        var lightingResults: [ApplicationAudioTeardownResult] = []
        let lighting = ApplicationAudioShutdownJoin { lightingResults.append($0) }
        lighting.receive(routing: .complete)
        lighting.receive(voiceActivity: .complete)
        lighting.receive(transcription: .complete)
        lighting.receive(localSong: .complete)
        lighting.receive(lighting: .operationFailed)
        lighting.receive(lighting: .complete)
        #expect(lightingResults == [.lighting(.operationFailed)])

        var transcriptionResults: [ApplicationAudioTeardownResult] = []
        let transcription = ApplicationAudioShutdownJoin {
            transcriptionResults.append($0)
        }
        transcription.receive(routing: .complete)
        transcription.receive(voiceActivity: .complete)
        transcription.receive(transcription: .timedOut)
        transcription.receive(localSong: .complete)
        transcription.receive(lighting: .complete)
        #expect(transcriptionResults == [.transcription(.timedOut)])

        #expect(ApplicationAudioTeardownResult.complete.allowsProcessExit)
        #expect(
            ApplicationAudioTeardownResult.localSong(.timedOut).allowsProcessExit)
        #expect(
            ApplicationAudioTeardownResult.lighting(.operationFailed).allowsProcessExit)
        #expect(
            ApplicationAudioTeardownResult.transcription(.timedOut).allowsProcessExit)
        #expect(
            !ApplicationAudioTeardownResult.routing(.ioProcStopFailed(-1))
                .allowsProcessExit)
        #expect(
            !ApplicationAudioTeardownResult.routing(.lifecycleQueueTimedOut)
                .allowsProcessExit)
        #expect(
            !ApplicationAudioTeardownResult.voiceActivity(.timedOut).allowsProcessExit)
        #expect(!ApplicationAudioTeardownResult.localSong(.timedOut).isComplete)
        #expect(!ApplicationAudioTeardownResult.lighting(.operationFailed).isComplete)

        var completeReport: ApplicationAudioTeardownReport?
        let concurrentFailures = ApplicationAudioShutdownJoin(reporting: {
            completeReport = $0
        })
        concurrentFailures.receive(routing: .ioProcStopFailed(-91))
        concurrentFailures.receive(voiceActivity: .complete)
        concurrentFailures.receive(transcription: .timedOut)
        concurrentFailures.receive(localSong: .timedOut)
        concurrentFailures.receive(lighting: .operationFailed)
        #expect(completeReport?.result == .routing(.ioProcStopFailed(-91)))
        #expect(completeReport?.localSong == .timedOut)
        #expect(completeReport?.lighting == .operationFailed)
    }

    @Test("shutdown delivery completes inside AppKit-style nested run loops")
    @MainActor
    func shutdownDeliveryIsNestedRunLoopSafe() {
        let engineQueue = DispatchQueue(label: "yunaudio.test.nested-shutdown.engine")
        let detector = VoiceActivityStopFence(completedWith: .complete)
        let transcription = OwnedResourceTeardownFence(completedWith: .complete)
        let song = OwnedResourceTeardownFence(completedWith: .complete)
        let lighting = OwnedResourceTeardownFence(completedWith: .complete)
        var answer: ApplicationAudioTeardownResult?
        let join = ApplicationAudioShutdownJoin { answer = $0 }

        EngineShutdownDispatcher.submit(
            on: engineQueue, work: { RoutingTeardownResult.complete },
            completion: { join.receive(routing: $0) })
        VoiceActivityShutdownDispatcher.submit(detector, timeout: 0.25) {
            join.receive(voiceActivity: $0)
        }
        OwnedResourceShutdownDispatcher.submit(transcription) {
            join.receive(transcription: $0)
        }
        OwnedResourceShutdownDispatcher.submit(song) {
            join.receive(localSong: $0)
        }
        OwnedResourceShutdownDispatcher.submit(lighting) {
            join.receive(lighting: $0)
        }

        let deadline = Date(timeIntervalSinceNow: 1)
        while answer == nil, Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        #expect(answer == .complete)
    }
}
