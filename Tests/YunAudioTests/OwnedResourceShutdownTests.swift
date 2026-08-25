import Foundation
import Testing
import YunAudioHAL

@testable import YunAudioApp

@Suite("Bounded secondary-owner shutdown")
struct OwnedResourceShutdownTests {
    private final class StubOwner: @unchecked Sendable {}
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func increment() { lock.withLock { storage += 1 } }
        var value: Int { lock.withLock { storage } }
    }

    @Test("10,000 repeated requests share one owner, operation and fence")
    func stormSharesOneOperation() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let resourceQuarantine = ProcessLifetimeResourceQuarantine()
        let quarantine = ProcessLifetimeAudioQuarantine()
        let worker = BoundedOwnerShutdownWorker<StubOwner>(
            operationTimeout: 1,
            label: "yunaudio.test.owner-shutdown-storm",
            resourceQuarantine: resourceQuarantine,
            audioQuarantine: quarantine,
            quarantineReason: "test owner",
            operation: { _, _ in
                entered.signal()
                _ = release.wait(timeout: .now() + TestGate.deadlock)
                return true
            })
        let owner = StubOwner()
        let first = worker.submit(owner)
        #expect(entered.wait(timeout: .now() + 1) == .success)

        for _ in 1..<10_000 {
            #expect(worker.submit(owner) === first)
        }
        let active = worker.telemetry
        #expect(active.submittedRequests == 10_000)
        #expect(active.startedOperations == 1)
        #expect(active.sharedRequests == 9_999)
        #expect(active.maximumConcurrentOperations == 1)
        #expect(active.retainedOwner)
        #expect(resourceQuarantine.count == 1)
        #expect(quarantine.count == 1)

        release.signal()
        #expect(first.wait(timeout: 1) == .complete)
        #expect(first.completionCount == 1)
        let complete = worker.telemetry
        #expect(complete.startedOperations == 1)
        #expect(complete.maximumConcurrentOperations == 1)
        #expect(!complete.retainedOwner)
        #expect(resourceQuarantine.count == 0)
        #expect(quarantine.count == 0)
    }

    @Test("a deadline before worker entry can retry the same retained owner once")
    func timeoutBeforeEntryIsRetryable() {
        let workerQueue = DispatchQueue(label: "yunaudio.test.owner-shutdown-blocked")
        let queueEntered = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        workerQueue.async {
            queueEntered.signal()
            _ = releaseQueue.wait(timeout: .now() + TestGate.deadlock)
        }
        #expect(queueEntered.wait(timeout: .now() + 1) == .success)

        let operations = Counter()
        let resourceQuarantine = ProcessLifetimeResourceQuarantine()
        let audioQuarantine = ProcessLifetimeAudioQuarantine()
        let worker = BoundedOwnerShutdownWorker<StubOwner>(
            operationTimeout: 0.1,
            label: "yunaudio.test.owner-shutdown-before-entry",
            resourceQuarantine: resourceQuarantine,
            audioQuarantine: audioQuarantine,
            quarantineReason: "test queued owner",
            workerQueue: workerQueue,
            operation: { _, _ in
                operations.increment()
                return true
            })

        let first = worker.submit(StubOwner())
        #expect(first.wait(timeout: 0.25) == .timedOutBeforeEntry)
        #expect(first.completionCount == 1)
        #expect(operations.value == 0)
        #expect(worker.telemetry.startedOperations == 0)
        #expect(worker.telemetry.timedOutBeforeEntry == 1)
        #expect(worker.telemetry.timedOutAfterEntry == 0)
        #expect(resourceQuarantine.count == 1)
        #expect(audioQuarantine.count == 1)

        let retry = worker.retryAfterTimeoutBeforeEntry()
        #expect(retry != nil)
        releaseQueue.signal()
        #expect(retry?.wait(timeout: 0.5) == .complete)
        #expect(retry?.completionCount == 1)
        #expect(operations.value == 1)
        #expect(worker.telemetry.startedOperations == 1)
        #expect(worker.telemetry.retriedBeforeEntry == 1)
        #expect(worker.telemetry.maximumConcurrentOperations == 1)
        #expect(resourceQuarantine.count == 0)
        #expect(audioQuarantine.count == 0)
    }

    @Test("a hung call returns its numeric timeout and retains the owner")
    func hangIsBoundedAndRetained() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let resourceQuarantine = ProcessLifetimeResourceQuarantine()
        let quarantine = ProcessLifetimeAudioQuarantine()
        let worker = BoundedOwnerShutdownWorker<StubOwner>(
            operationTimeout: 0.02,
            label: "yunaudio.test.owner-shutdown-timeout",
            resourceQuarantine: resourceQuarantine,
            audioQuarantine: quarantine,
            quarantineReason: "test timed-out owner",
            operation: { _, _ in
                entered.signal()
                _ = release.wait(timeout: .now() + TestGate.deadlock)
                returned.signal()
                return true
            })
        var owner: StubOwner? = StubOwner()
        weak let retained = owner
        let began = DispatchTime.now().uptimeNanoseconds
        let fence = worker.submit(owner!)
        owner = nil
        #expect(entered.wait(timeout: .now() + 1) == .success)

        #expect(fence.wait(timeout: 0.25) == .timedOut)
        let elapsed = DispatchTime.now().uptimeNanoseconds - began
        #expect(elapsed >= 10_000_000)
        #expect(elapsed < 150_000_000)
        #expect(retained != nil)
        #expect(resourceQuarantine.count == 1)
        #expect(quarantine.count == 1)
        #expect(worker.telemetry.timedOutOperations == 1)
        #expect(worker.telemetry.timedOutBeforeEntry == 0)
        #expect(worker.telemetry.timedOutAfterEntry == 1)
        #expect(worker.telemetry.maximumConcurrentOperations == 1)
        #expect(worker.retryAfterTimeoutBeforeEntry() == nil)

        release.signal()
        #expect(returned.wait(timeout: .now() + 1) == .success)
        // A late successful return is not evidence that a timed-out callback
        // owner was clean at the deadline, and cannot release or republish it.
        #expect(fence.wait(timeout: 0) == .timedOut)
        #expect(fence.completionCount == 1)
        #expect(retained != nil)
        #expect(resourceQuarantine.count == 1)
        #expect(quarantine.count == 1)
        #expect(worker.telemetry.startedOperations == 1)

        let replacement = StubOwner()
        #expect(worker.submit(replacement) === fence)
        #expect(worker.telemetry.startedOperations == 1)
        #expect(worker.telemetry.sharedRequests == 1)
    }

    @Test("local-song queue admission timeout retries without constructing a peer")
    func localSongQueueAdmissionRetries() {
        let queue = DispatchQueue(label: "yunaudio.test.local-song-admission")
        let queueEntered = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        queue.async {
            queueEntered.signal()
            _ = releaseQueue.wait(timeout: .now() + TestGate.deadlock)
        }
        #expect(queueEntered.wait(timeout: .now() + 1) == .success)

        let quarantine = ProcessLifetimeAudioQuarantine()
        let worker = LocalSongOperationWorker(
            queue: queue, audioQuarantine: quarantine, publish: { _ in })
        let first = worker.requestTerminationStop(timeout: 0.1)
        #expect(first.wait(timeout: 0.25) == .timedOutBeforeEntry)
        #expect(first.completionCount == 1)
        #expect(quarantine.count == 1)
        #expect(quarantine.refusalForNewAudioOwnership() != nil)

        let retry = worker.requestTerminationStop(timeout: 0.1)
        #expect(retry !== first)
        #expect(quarantine.count == 1)
        releaseQueue.signal()
        #expect(retry.wait(timeout: 0.5) == .complete)
        #expect(retry.completionCount == 1)
        #expect(quarantine.count == 0)
        #expect(quarantine.refusalForNewAudioOwnership() == nil)
    }

    @Test("a failed call is terminal and retains its callback owner")
    func failureIsRetained() {
        let resourceQuarantine = ProcessLifetimeResourceQuarantine()
        let quarantine = ProcessLifetimeAudioQuarantine()
        let worker = BoundedOwnerShutdownWorker<StubOwner>(
            operationTimeout: 1,
            label: "yunaudio.test.owner-shutdown-failure",
            resourceQuarantine: resourceQuarantine,
            audioQuarantine: quarantine,
            quarantineReason: "test failed owner",
            operation: { _, _ in false })
        var owner: StubOwner? = StubOwner()
        weak let retained = owner
        let fence = worker.submit(owner!)
        owner = nil

        #expect(fence.wait(timeout: 1) == .operationFailed)
        #expect(fence.completionCount == 1)
        #expect(retained != nil)
        #expect(resourceQuarantine.count == 1)
        #expect(quarantine.count == 1)
        #expect(worker.telemetry.failedOperations == 1)
        #expect(worker.telemetry.retainedOwner)
    }

    @Test("a late framework return cannot admit the next teardown call")
    func timeoutClosesStepAdmission() {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let operationReturned = DispatchSemaphore(value: 0)
        let secondCalls = Counter()
        let resourceQuarantine = ProcessLifetimeResourceQuarantine()
        let worker = BoundedOwnerShutdownWorker<StubOwner>(
            operationTimeout: 0.02,
            label: "yunaudio.test.owner-shutdown-steps",
            resourceQuarantine: resourceQuarantine,
            quarantineReason: "test gated owner",
            operation: { _, gate in
                guard
                    gate.perform({
                        firstEntered.signal()
                        _ = releaseFirst.wait(timeout: .now() + TestGate.deadlock)
                        return true
                    }) == true
                else {
                    operationReturned.signal()
                    return false
                }
                let second = gate.perform {
                    secondCalls.increment()
                    return true
                }
                operationReturned.signal()
                return second ?? false
            })
        let fence = worker.submit(StubOwner())
        #expect(firstEntered.wait(timeout: .now() + 1) == .success)
        #expect(fence.wait(timeout: 0.25) == .timedOut)
        releaseFirst.signal()
        #expect(operationReturned.wait(timeout: .now() + 1) == .success)
        #expect(secondCalls.value == 0)
        #expect(fence.completionCount == 1)
        #expect(worker.telemetry.startedOperations == 1)
        #expect(resourceQuarantine.count == 1)
    }

    @Test("production termination submits all owners before peripheral framework cleanup")
    func productionOrderingIsExplicit() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let router = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let start = try #require(router.range(of: "func shutDown("))
        let end = try #require(
            router.range(
                of: "/// Plain evidence returned after a start",
                range: start.upperBound..<router.endIndex))
        let shutdown = router[start.lowerBound..<end.lowerBound]
        let route = try #require(shutdown.range(of: "EngineShutdownDispatcher.submit("))
        let detector = try #require(
            shutdown.range(of: "VoiceActivityShutdownDispatcher.submit("))
        let song = try #require(
            shutdown.range(of: "OwnedResourceShutdownDispatcher.submit(localSong)"))
        let lighting = try #require(
            shutdown.range(of: "OwnedResourceShutdownDispatcher.submit(lightRing)"))
        let finalise = try #require(shutdown.range(of: "func finaliseAcceptedTermination()"))

        #expect(route.lowerBound < finalise.lowerBound)
        #expect(detector.lowerBound < finalise.lowerBound)
        #expect(song.lowerBound < finalise.lowerBound)
        #expect(lighting.lowerBound < finalise.lowerBound)
        #expect(shutdown.contains("madeNowPlayingStage?.standDown()"))
        #expect(!shutdown[..<finalise.lowerBound].contains("madeNowPlayingStage?.standDown()"))
        #expect(!shutdown.contains("madeSongPlayer?.stop()"))
        #expect(shutdown.contains("madeSongPlayer?.requestTerminationStop()"))

        let app = try String(
            contentsOfFile: root + "Sources/YunAudioApp/YunAudioApp.swift",
            encoding: .utf8)
        let modelStop = try #require(
            app.range(of: "model.shutDown { join.receive(audio: $0) }"))
        let refused = try #require(app.range(of: "if !result.allowsProcessExit"))
        let accepted = try #require(
            app.range(
                of: "model.finaliseAcceptedTermination()",
                range: refused.upperBound..<app.endIndex))
        let listenerStop = try #require(
            app.range(
                of: "controlLifecycle.stop { join.receiveControl(acknowledged: $0) }",
                range: modelStop.upperBound..<app.endIndex))
        #expect(modelStop.lowerBound < listenerStop.lowerBound)
        #expect(refused.lowerBound < accepted.lowerBound)
        #expect(!app.contains("model.lighting.stop()"))
    }

    @Test("MediaPlayer stand-down relinquishes local state before external cleanup")
    func mediaPlayerStandDownIsNonBlocking() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/NowPlayingStage.swift",
            encoding: .utf8)
        let stage = try #require(source.range(of: "final class NowPlayingStage"))
        let start = try #require(
            source.range(
                of: "func standDown()", range: stage.upperBound..<source.endIndex))
        let body = source[start.lowerBound...]
        let revoke = try #require(body.range(of: "commands = nil"))
        let queue = try #require(body.range(of: "systemServiceWorker.shutdown(after:"))
        let release = try #require(body.range(of: "owner.standDown()"))

        #expect(revoke.lowerBound < queue.lowerBound)
        #expect(queue.lowerBound < release.lowerBound)
        #expect(!body.prefix(upTo: queue.lowerBound).contains("removeTarget("))
        #expect(!body.prefix(upTo: queue.lowerBound).contains("nowPlayingInfo = nil"))
        #expect(source.contains("final class NowPlayingSystemServiceOwner"))
        #expect(
            source.contains("for (command, token) in handlers { command.removeTarget(token) }"))
    }

    @Test("a refused termination keeps process services and worker admission alive")
    func refusedTerminationIsRecoverable() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let router = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let shutdownStart = try #require(router.range(of: "func shutDown("))
        let finaliseStart = try #require(
            router.range(
                of: "func finaliseAcceptedTermination()",
                range: shutdownStart.upperBound..<router.endIndex))
        let finaliseEnd = try #require(
            router.range(
                of: "/// Plain evidence returned after a start",
                range: finaliseStart.upperBound..<router.endIndex))
        let shutdown = router[shutdownStart.lowerBound..<finaliseStart.lowerBound]
        let finalise = router[finaliseStart.lowerBound..<finaliseEnd.lowerBound]

        #expect(shutdown.contains("pluginRegistryWorker.invalidate()"))
        #expect(shutdown.contains("localSongMetadataWorker.invalidate()"))
        #expect(shutdown.contains("localSongResourceWorker.invalidate()"))
        #expect(!shutdown.contains("pluginRegistryWorker.shutdown()"))
        #expect(!shutdown.contains("hotkeys.tearDown()"))
        #expect(!shutdown.contains("midiControl.tearDown"))
        #expect(!shutdown.contains("madeNowPlayingStage?.standDown()"))
        #expect(shutdown.contains("self.terminationIsPending = false"))
        #expect(shutdown.contains("recoverProcessServicesAfterRefusedTermination("))

        #expect(finalise.contains("pluginRegistryWorker.shutdown()"))
        #expect(finalise.contains("hotkeys?.tearDown()"))
        #expect(finalise.contains("midiControl.tearDown"))
        #expect(finalise.contains("madeNowPlayingStage?.standDown()"))

        let recoveryStart = try #require(
            router.range(of: "private func recoverProcessServicesAfterRefusedTermination("))
        let recoveryEnd = try #require(
            router.range(
                of: "func finaliseAcceptedTermination()",
                range: recoveryStart.upperBound..<router.endIndex))
        let recovery = router[recoveryStart.lowerBound..<recoveryEnd.lowerBound]
        #expect(recovery.contains("PermissionCentre.shared.refreshSafeStatuses()"))
        #expect(recovery.contains("madeLocalSongOperations = nil"))
        #expect(recovery.contains("madeSongPlayer = nil"))
        #expect(recovery.contains("let replacement = LightingController()"))
        #expect(recovery.contains("lighting = replacement"))

        let app = try String(
            contentsOfFile: root + "Sources/YunAudioApp/YunAudioApp.swift",
            encoding: .utf8)
        let refused = try #require(app.range(of: "if !result.allowsProcessExit"))
        let refusalReply = try #require(
            app.range(of: "reply(false)", range: refused.upperBound..<app.endIndex))
        let finalisation = try #require(
            app.range(
                of: "model.finaliseAcceptedTermination()",
                range: refusalReply.upperBound..<app.endIndex))
        #expect(refusalReply.lowerBound < finalisation.lowerBound)
    }

    @Test("termination permanently revokes song and light owner construction")
    func productionOwnersCannotReappear() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let song = try String(
            contentsOfFile: root + "Sources/YunAudioApp/LocalSongPlayer.swift",
            encoding: .utf8)
        let requestStart = try #require(song.range(of: "func requestTerminationStop()"))
        let requestEnd = try #require(
            song.range(
                of: "/// Seconds into the song",
                range: requestStart.upperBound..<song.endIndex))
        let request = song[requestStart.lowerBound..<requestEnd.lowerBound]
        #expect(request.contains("if let terminationFence"))
        #expect(request.contains("retryAfterTimeoutBeforeEntry()"))
        #expect(request.contains("self.output = nil"))
        #expect(request.contains("decoder?.shutdown()"))
        #expect(!request.contains("output.node.stop()"))
        #expect(!request.contains("output.engine.stop()"))

        let lighting = try String(
            contentsOfFile: root + "Sources/YunAudioApp/LightingController.swift",
            encoding: .utf8)
        #expect(lighting.contains("if let terminationFence"))
        #expect(lighting.contains("retryAfterTimeoutBeforeEntry()"))
        #expect(lighting.contains("isTerminating = true"))
        #expect(lighting.contains("guard !isTerminating else { return }"))
        #expect(lighting.contains("self.device = nil"))
        let lightRequestStart = try #require(
            lighting.range(of: "func requestTerminationStop()"))
        let lightRequestEnd = try #require(
            lighting.range(
                of: "private func applyBrightness()",
                range: lightRequestStart.upperBound..<lighting.endIndex))
        let lightRequest = lighting[
            lightRequestStart.lowerBound..<lightRequestEnd.lowerBound]
        #expect(!lightRequest.contains("deviceLock.lock()"))
        #expect(!lightRequest.contains("device.send("))
    }
}
