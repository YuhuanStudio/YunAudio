import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine
@testable import YunAudioHAL

private final class LifecycleLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

@Suite("Lifecycle race boundaries", .serialized)
struct LifecycleRaceTests {
    private func routerSnapshot(
        generation: UInt64 = 41,
        routeGeneration: UInt64 = 7,
        graphGeneration: UInt64 = 11,
        routes: [Route] = [
            Route(
                source: ChannelRef(deviceUID: "cached-source", channel: 0),
                destination: ChannelRef(deviceUID: "cached-output", channel: 0))
        ]
    ) -> RoutingEngine.EngineUISnapshot {
        RoutingEngine.EngineUISnapshot(
            generation: generation,
            routeGeneration: routeGeneration,
            graphGeneration: graphGeneration,
            routes: routes,
            processingLatency: ProcessingLatency(sourceFrames: 128, outputFrames: 64),
            voiceIsolationLatencyFrames: 96,
            alignmentFrames: 128,
            failedPlugins: [],
            droppedMonitor: nil,
            droppedExtras: [],
            isolationError: nil,
            activeEffectStages: [.compressor, .limiter],
            effectUpdateRefusal: nil,
            holdsClockLock: true,
            echoCancellationStatus: nil,
            echoCancellationError: nil,
            echoCancellationDetail: nil,
            outputDeviceUIDs: ["cached-output"],
            correctionOutcome: .installed)
    }

    @Test("Router UI reads one cached generation while the engine lock is held")
    @MainActor
    func routerSnapshotReadsNeverJoinEngineLifecycle() async {
        let model = RouterModel(
            startupPolicy: AppStartup.ModelPolicy(kind: .syntheticEvidence))
        let expected = routerSnapshot()
        #expect(model.installEngineSnapshotForDiagnostics(expected))

        let entered = LifecycleLockedBox(false)
        let exited = LifecycleLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            model.withEngineStateLockForDiagnostics {
                entered.update { $0 = true }
                release.wait()
            }
            exited.update { $0 = true }
        }
        while !entered.read() { await Task.yield() }

        let heldAt = DispatchTime.now().uptimeNanoseconds
        var durations: [UInt64] = []
        durations.reserveCapacity(10_000)
        var generationMismatches = 0
        for _ in 0..<10_000 {
            let began = DispatchTime.now().uptimeNanoseconds
            _ = model.activeRoutes
            _ = model.failedPlugins
            _ = model.activeEffectStages
            _ = model.addedLatencyMilliseconds
            _ = model.chainAlignment
            _ = model.totalProcessingLatencyFrames
            _ = model.voiceIsolationLatencyMilliseconds
            _ = model.holdsClockLock
            _ = model.echoCancellationMessage
            _ = model.echoCancellationDetail
            _ = model.correctionBusReport
            _ = model.lastCorrectionOutcome
            if model.engineSnapshotGenerationForDiagnostics != expected.generation {
                generationMismatches += 1
            }
            durations.append(DispatchTime.now().uptimeNanoseconds - began)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - heldAt
        if elapsed < 250_000_000 {
            try? await Task.sleep(for: .nanoseconds(Int64(250_000_000 - elapsed)))
        }
        release.signal()
        while !exited.read() { await Task.yield() }

        durations.sort()
        let p99 = durations[9_899]
        let maximum = durations.last ?? .max
        print("Router cached UI reads p99 \(p99) ns; max \(maximum) ns")
        #expect(generationMismatches == 0)
        #expect(p99 < 2_000_000)
        #expect(maximum < 8_000_000)
        #expect(DispatchTime.now().uptimeNanoseconds - heldAt >= 250_000_000)
    }

    @Test("Router snapshot admission checks generation and graph identity")
    func routerSnapshotIdentityAdmission() {
        let current: UInt64 = 40
        #expect(
            RouterModel.engineSnapshotIsAdmissible(
                currentGeneration: current,
                incoming: routerSnapshot(),
                expectedRouteGeneration: 7,
                minimumGraphGeneration: 11))
        #expect(
            !RouterModel.engineSnapshotIsAdmissible(
                currentGeneration: 41,
                incoming: routerSnapshot(),
                expectedRouteGeneration: 7,
                minimumGraphGeneration: 11))
        #expect(
            !RouterModel.engineSnapshotIsAdmissible(
                currentGeneration: current,
                incoming: routerSnapshot(),
                expectedRouteGeneration: 8,
                minimumGraphGeneration: 11))
        #expect(
            !RouterModel.engineSnapshotIsAdmissible(
                currentGeneration: current,
                incoming: routerSnapshot(),
                expectedRouteGeneration: 7,
                minimumGraphGeneration: 12))
        #expect(
            RouterModel.engineSnapshotIsAdmissible(
                currentGeneration: 0,
                incoming: routerSnapshot(
                    generation: 1, routeGeneration: 8,
                    graphGeneration: 0, routes: []),
                requiresStoppedGraph: true))
        #expect(
            !RouterModel.engineSnapshotIsAdmissible(
                currentGeneration: 0,
                incoming: routerSnapshot(
                    generation: 1, routeGeneration: 8,
                    graphGeneration: 12),
                requiresStoppedGraph: true))
    }

    @Test("termination queue admission has one explicit bounded budget")
    func terminationQueueAdmissionBudget() throws {
        #expect(EngineShutdownDispatcher.routingQueueWaitTimeout == 2.25)

        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let shutdown = try #require(source.range(of: "func shutDown("))
        let dispatcher = try #require(
            source.range(
                of: "EngineShutdownDispatcher.submit(",
                range: shutdown.upperBound..<source.endIndex))
        let wiring = source[dispatcher.lowerBound...]
        #expect(
            wiring.contains(
                "timeout: EngineShutdownDispatcher.routingQueueWaitTimeout"))
        #expect(wiring.contains("teardown: .lifecycleQueueTimedOut"))
        #expect(wiring.contains("snapshot: engineSnapshot"))
    }

    @Test("refused routing restores its observer demand exactly once")
    func refusedRoutingObserverRecoveryIsEpochBounded() {
        var gate = TerminationObserverRecoveryGate()
        let first = gate.begin(needsPolling: true, analysisSampleRate: 48_000)
        let began = DispatchTime.now().uptimeNanoseconds
        var admitted: [TerminationObserverRecoveryGate.Demand] = []
        for _ in 0..<10_000 {
            if let demand = gate.consume(epoch: first, routingFailed: true) {
                admitted.append(demand)
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - began

        #expect(
            admitted == [
                .init(epoch: first, needsPolling: true, analysisSampleRate: 48_000)
            ])
        #expect(elapsed < 8_000_000)

        let second = gate.begin(needsPolling: true, analysisSampleRate: 96_000)
        var nonRoutingAdmissions = 0
        var staleAdmissions = 0
        for _ in 0..<10_000 {
            if gate.consume(epoch: second, routingFailed: false) != nil {
                nonRoutingAdmissions += 1
            }
            if gate.consume(epoch: first, routingFailed: true) != nil {
                staleAdmissions += 1
            }
        }
        print(
            "10,000 refused-routing retries: \(admitted.count) restoration; "
                + "non-routing \(nonRoutingAdmissions); stale \(staleAdmissions); "
                + "\(elapsed) ns")
        #expect(nonRoutingAdmissions == 0)
        #expect(staleAdmissions == 0)
    }

    @Test("clock telemetry stays coherent while its owner is replaced")
    func clockOwnerReplacementIsCoherent() {
        let engine = RoutingEngine()
        let locked = ClockAnchorPublisher(deviceIDForTesting: 0)
        let unlocked = ClockAnchorPublisher(deviceIDForTesting: 0)
        locked.installTelemetryForTesting(.init(isLocked: true, rateRatio: 1.25))
        unlocked.installTelemetryForTesting(.init(isLocked: false, rateRatio: 0.75))
        engine.installClockPublisherForTesting(locked)

        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
            for index in 0..<20_000 {
                if index.isMultiple(of: 2) {
                    locked.installTelemetryForTesting(
                        .init(isLocked: true, rateRatio: 1.25))
                    engine.installClockPublisherForTesting(locked)
                } else {
                    unlocked.installTelemetryForTesting(
                        .init(isLocked: false, rateRatio: 0.75))
                    engine.installClockPublisherForTesting(unlocked)
                }
            }
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 1) == .success)

        var torn = 0
        for _ in 0..<100_000 {
            let snapshot = engine.clockTelemetry
            let isLockedPair = snapshot.isLocked && snapshot.rateRatio == 1.25
            let isUnlockedPair = !snapshot.isLocked && snapshot.rateRatio == 0.75
            if !isLockedPair && !isUnlockedPair { torn += 1 }
        }

        #expect(finished.wait(timeout: .now() + 5) == .success)
        engine.installClockPublisherForTesting(nil)
        print("100,000 clock snapshots across 20,000 owner swaps: \(torn) torn pairs")
        #expect(torn == 0)
    }

    @Test("clock stop drains an in-flight publisher turn within its deadline")
    func clockStopDrainsItsQueue() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let publisher = ClockAnchorPublisher(
            deviceIDForTesting: 0, intervalForTesting: 0.001)
        #expect(
            publisher.start {
                entered.signal()
                _ = release.wait(timeout: .distantFuture)
                return nil
            })
        defer { release.signal() }
        #expect(entered.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(30)
        ) {
            release.signal()
        }
        let began = DispatchTime.now().uptimeNanoseconds
        let result = publisher.stop(until: HALTeardownDeadline(timeout: 1))
        let elapsed = DispatchTime.now().uptimeNanoseconds - began

        #expect(result == .complete)
        #expect(elapsed >= 20_000_000)
        #expect(elapsed < 250_000_000)
    }

    @Test("clock stop times out bounded, retains its owner and succeeds on retry")
    func clockStopTimeoutIsRetryable() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let publisher = ClockAnchorPublisher(
            deviceIDForTesting: 0, intervalForTesting: 0.001)
        #expect(
            publisher.start {
                entered.signal()
                _ = release.wait(timeout: .distantFuture)
                return nil
            })
        defer { release.signal() }
        #expect(entered.wait(timeout: .now() + 1) == .success)

        let began = DispatchTime.now().uptimeNanoseconds
        let first = publisher.stop(until: HALTeardownDeadline(timeout: 0.05))
        let elapsed = DispatchTime.now().uptimeNanoseconds - began

        #expect(first == .timedOut)
        #expect(elapsed >= 40_000_000)
        #expect(elapsed < 250_000_000)
        #expect(publisher.hasRetainedTimerForTesting)
        #expect(publisher.hasPendingDrainForTesting)

        release.signal()
        let retry = publisher.stop(until: HALTeardownDeadline(timeout: 1))
        #expect(retry == .complete)
        #expect(!publisher.hasRetainedTimerForTesting)
        #expect(!publisher.hasPendingDrainForTesting)
    }

    @Test("routing teardown reports clock timeout and retries the retained publisher")
    func routingClockTimeoutIsRetryable() {
        let engine = RoutingEngine()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let publisher = ClockAnchorPublisher(
            deviceIDForTesting: 0, intervalForTesting: 0.001)
        #expect(
            publisher.start {
                entered.signal()
                _ = release.wait(timeout: .distantFuture)
                return nil
            })
        engine.installClockPublisherForTesting(publisher)
        defer { release.signal() }
        #expect(entered.wait(timeout: .now() + 1) == .success)

        let first = engine.stop(timeout: 0.05)
        #expect(first == .clockPublisherTimedOut)
        #expect(engine.lastTeardownResult == .clockPublisherTimedOut)
        #expect(publisher.hasRetainedTimerForTesting)

        release.signal()
        #expect(engine.stop(timeout: 1) == .complete)
        #expect(engine.lastTeardownResult == .complete)
        #expect(!publisher.hasRetainedTimerForTesting)
    }

    @Test("recording polling returns a complete cached frame during teardown")
    func recordingSnapshotDoesNotWaitForStateTeardown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-recording-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = try Recorder(
            directory: directory, format: .wav, channels: 1, sampleRate: 48_000,
            timestamp: Date(timeIntervalSince1970: 0))
        #expect(recorder.waitUntilWriterIsReady(timeout: .now() + 1))
        let engine = RoutingEngine()
        engine.installRecorderForTesting(recorder)
        let expectedURL = recorder.url

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            engine.withStateLockForTesting {
                entered.signal()
                _ = release.wait(timeout: .now() + TestGate.deadlock)
            }
            finished.signal()
        }
        #expect(entered.wait(timeout: .now() + 1) == .success)

        let began = DispatchTime.now().uptimeNanoseconds
        var invalid = 0
        for _ in 0..<10_000 {
            let snapshot = engine.recordingSnapshot
            if !snapshot.isRecording || snapshot.url != expectedURL
                || snapshot.duration != 0 || snapshot.error != nil
            {
                invalid += 1
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - began

        release.signal()
        #expect(finished.wait(timeout: .now() + 1) == .success)
        engine.installRecorderForTesting(nil)
        print(
            "10,000 contended recording snapshots: \(elapsed) ns; "
                + "\(invalid) incomplete frames")
        #expect(invalid == 0)
        #expect(elapsed < 100_000_000)
    }

    @Test("deferred shutdown returns before work and replies after its drain")
    @MainActor
    func deferredShutdownDoesNotBlockMainActor() async {
        let queue = DispatchQueue(label: "yunaudio.shutdown.test")
        let release = DispatchSemaphore(value: 0)
        let began = DispatchTime.now().uptimeNanoseconds

        let result = await withCheckedContinuation { continuation in
            EngineShutdownDispatcher.submit(
                on: queue,
                work: {
                    let released = release.wait(timeout: .now() + .milliseconds(250))
                    return released == .success ? 73 : -1
                },
                completion: { value in continuation.resume(returning: value) })
            let submission = DispatchTime.now().uptimeNanoseconds - began
            print("shutdown MainActor submission: \(submission) ns")
            #expect(submission < 100_000_000)
            release.signal()
        }

        #expect(result == 73)
    }

    @Test("queued engine shutdown produces one bounded timeout reply")
    @MainActor
    func queuedShutdownCannotHoldAppKitForever() async throws {
        let queue = DispatchQueue(label: "yunaudio.shutdown.timeout.test")
        let release = DispatchSemaphore(value: 0)
        let workBegins = LifecycleLockedBox(0)
        let completions = LifecycleLockedBox<[Int]>([])
        queue.async { release.wait() }

        let began = DispatchTime.now().uptimeNanoseconds
        let result = await withCheckedContinuation { continuation in
            EngineShutdownDispatcher.submit(
                on: queue,
                timeout: 0.02,
                timeoutResult: -91,
                work: {
                    workBegins.update { $0 += 1 }
                    return 73
                },
                completion: { value in
                    completions.update { $0.append(value) }
                    continuation.resume(returning: value)
                })
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - began
        #expect(result == -91)
        #expect(elapsed >= 5_000_000)
        #expect(elapsed < 250_000_000)
        #expect(workBegins.read() == 0)
        #expect(completions.read() == [-91])

        release.signal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(workBegins.read() == 0)
        #expect(completions.read() == [-91])
    }

    @Test("termination starts once and awaits one deferred reply")
    func terminationGateIsIdempotent() {
        var gate = ApplicationTerminationGate()
        #expect(gate.begin(hasTeardown: false) == .terminateNow)
        #expect(gate.begin(hasTeardown: true) == .beginLater)
        #expect(gate.begin(hasTeardown: true) == .awaitExistingReply)
        #expect(gate.isPending)
        gate.complete()
        #expect(!gate.isPending)
        #expect(gate.begin(hasTeardown: true) == .beginLater)
    }

    @Test("shutdown fences every Core Audio owner before the routing engine")
    func shutdownOwnerOrdering() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "func shutDown("))
        let end = try #require(
            source.range(
                of: "/// Plain evidence returned after a start",
                range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        let player = try #require(
            body.range(of: "madeSongPlayer?.requestTerminationStop()"))
        let stage = try #require(body.range(of: "func finaliseAcceptedTermination()"))
        let engine = try #require(body.range(of: "EngineShutdownDispatcher.submit("))

        #expect(player.lowerBound < engine.lowerBound)
        #expect(engine.lowerBound < stage.lowerBound)
        #expect(body.ranges(of: "madeSongPlayer?.requestTerminationStop()").count == 1)
        #expect(body.ranges(of: "madeNowPlayingStage?.standDown()").count == 1)
    }
}
