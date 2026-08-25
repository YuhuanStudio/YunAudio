import Foundation
import Testing

@testable import YunAudioApp

private final class LightingAccessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) { lock.withLock { events.append(event) } }

    var snapshot: [String] { lock.withLock { events } }
}

private final class LightingAccessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() { lock.withLock { storage += 1 } }

    var value: Int { lock.withLock { storage } }
}

@Suite("Lighting background resource use")
struct LightingResourceTests {

    /// How long to wait on a semaphore before calling it a deadlock.
    ///
    /// These are ordering tests: the waits synchronise, they do not assert
    /// latency. A one-second budget asserted that a `.utility` thread gets
    /// scheduled within a second, which is a property of the machine — and
    /// with forty suites running in parallel it is routinely false. Six
    /// failures in one run, none of them about the code, all of them passing
    /// alone. A genuine hang still fails, just later.
    static let aHang = DispatchTimeInterval.seconds(30)

    @Test("a cached frame cannot satisfy any later HID read fence")
    func frameReadEvidenceRequiresTheExactCompletion() {
        var evidence = LightingFrameReadEvidence()
        let first = evidence.begin()
        evidence.publish(
            LightingFrameReadSnapshot(revision: first, frame: Array(repeating: 1, count: 36)))
        let second = evidence.begin()

        #expect(evidence.completion(for: first)?.frame?.count == 36)
        #expect(evidence.completion(for: second) == nil)

        evidence.publish(
            LightingFrameReadSnapshot(revision: second, frame: Array(repeating: 2, count: 36)))
        #expect(evidence.completion(for: first) == nil)
        #expect(evidence.completion(for: second)?.frame?.first == 2)

        let third = evidence.begin()
        evidence.publish(LightingFrameReadSnapshot(revision: third, frame: nil))
        #expect(evidence.completion(for: third) != nil)
        #expect(evidence.completion(for: third)?.frame == nil)
    }

    @Test("six requested HID reads require six matching publications")
    func sixFrameReadFencesNeedSixCompletions() {
        var evidence = LightingFrameReadEvidence()
        var completed = 0
        var frames: [[UInt8]] = []

        for value in UInt8(0)..<6 {
            let revision = evidence.begin()
            #expect(evidence.completion(for: revision) == nil)
            evidence.publish(
                LightingFrameReadSnapshot(
                    revision: revision, frame: Array(repeating: value, count: 36)))
            if let snapshot = evidence.completion(for: revision) {
                completed += 1
                if let frame = snapshot.frame { frames.append(frame) }
            }
        }

        #expect(completed == 6)
        #expect(frames.count == 6)
        #expect(Set(frames).count == 6)
    }

    @Test("10,000 revoked HID callers perform zero device operations")
    func revokedEpochRejectsEveryOldCaller() {
        let access = LightingDeviceAccessGate()
        let token = access.advance()
        let deviceLock = NSLock()
        let operations = LightingAccessCounter()
        var refusals = 0

        access.revoke()
        for _ in 0..<10_000 {
            let result = access.perform(token, deviceLock: deviceLock) {
                operations.increment()
                return true
            }
            if result == nil { refusals += 1 }
        }

        #expect(refusals == 10_000)
        #expect(operations.value == 0)
    }

    @Test("a caller queued on the device lock cannot write after revocation")
    func queuedCallerCannotRelightAfterTeardown() {
        let access = LightingDeviceAccessGate()
        let token = access.advance()
        let deviceLock = NSLock()
        let beganWaiting = DispatchSemaphore(value: 0)
        let requestFinished = DispatchSemaphore(value: 0)
        let teardownFinished = DispatchSemaphore(value: 0)
        let normalOperations = LightingAccessCounter()
        let teardownOperations = LightingAccessCounter()

        deviceLock.lock()
        DispatchQueue.global(qos: .utility).async {
            beganWaiting.signal()
            _ = access.perform(token, deviceLock: deviceLock) {
                normalOperations.increment()
            }
            requestFinished.signal()
        }
        #expect(beganWaiting.wait(timeout: .now() + Self.aHang) == .success)

        access.revoke()
        DispatchQueue.global(qos: .utility).async {
            deviceLock.withLock { teardownOperations.increment() }
            teardownFinished.signal()
        }
        deviceLock.unlock()

        #expect(requestFinished.wait(timeout: .now() + Self.aHang) == .success)
        #expect(teardownFinished.wait(timeout: .now() + Self.aHang) == .success)
        #expect(normalOperations.value == 0)
        #expect(teardownOperations.value == 1)
    }

    @Test("teardown is the final device operation after an entered HID call")
    func enteredCallPrecedesFinalDarken() {
        let access = LightingDeviceAccessGate()
        let token = access.advance()
        let deviceLock = NSLock()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let normalFinished = DispatchSemaphore(value: 0)
        let teardownFinished = DispatchSemaphore(value: 0)
        let recorder = LightingAccessRecorder()

        DispatchQueue.global(qos: .utility).async {
            _ = access.perform(token, deviceLock: deviceLock) {
                recorder.record("normal-entered")
                entered.signal()
                _ = release.wait(timeout: .now() + Self.aHang)
                recorder.record("normal-returned")
            }
            normalFinished.signal()
        }
        #expect(entered.wait(timeout: .now() + Self.aHang) == .success)

        access.revoke()
        DispatchQueue.global(qos: .utility).async {
            deviceLock.withLock { recorder.record("darkened") }
            teardownFinished.signal()
        }
        release.signal()

        #expect(normalFinished.wait(timeout: .now() + Self.aHang) == .success)
        #expect(teardownFinished.wait(timeout: .now() + Self.aHang) == .success)
        #expect(recorder.snapshot == ["normal-entered", "normal-returned", "darkened"])
    }

    @Test("no current device still waits for the shared access lock")
    func absentDeviceDoesNotBypassLockFence() {
        let deviceLock = NSLock()
        let entered = DispatchSemaphore(value: 0)
        let resourceQuarantine = ProcessLifetimeResourceQuarantine()
        let worker = BoundedOwnerShutdownWorker<LightingTerminationOwner>(
            operationTimeout: 0.03,
            label: "yunaudio.test.lighting-absent-device-lock",
            resourceQuarantine: resourceQuarantine,
            quarantineReason: "test absent light ring",
            operation: { owner, gate in
                entered.signal()
                return owner.darken(using: gate)
            })

        deviceLock.lock()
        let fence = worker.submit(
            LightingTerminationOwner(
                device: nil, deviceLock: deviceLock, renderThread: nil))
        #expect(entered.wait(timeout: .now() + Self.aHang) == .success)
        #expect(fence.wait(timeout: 0.25) == .timedOut)
        #expect(worker.telemetry.timedOutAfterEntry == 1)
        #expect(resourceQuarantine.count == 1)
        deviceLock.unlock()

        // A return after the deadline cannot weaken the settled ownership claim.
        #expect(fence.wait(timeout: 0.05) == .timedOut)
        #expect(fence.completionCount == 1)
        #expect(resourceQuarantine.count == 1)
    }

    @Test("an absent-device lock fence preserves before-entry retry")
    func absentDeviceRetryUsesTheSameOwner() {
        let workerQueue = DispatchQueue(label: "yunaudio.test.lighting-retry-queue")
        let queueEntered = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        workerQueue.async {
            queueEntered.signal()
            _ = releaseQueue.wait(timeout: .now() + Self.aHang)
        }
        #expect(queueEntered.wait(timeout: .now() + Self.aHang) == .success)

        let resourceQuarantine = ProcessLifetimeResourceQuarantine()
        let worker = BoundedOwnerShutdownWorker<LightingTerminationOwner>(
            operationTimeout: 0.05,
            label: "yunaudio.test.lighting-absent-device-retry",
            resourceQuarantine: resourceQuarantine,
            quarantineReason: "test queued absent light ring",
            workerQueue: workerQueue,
            operation: { $0.darken(using: $1) })
        let first = worker.submit(
            LightingTerminationOwner(
                device: nil, deviceLock: NSLock(), renderThread: nil))

        #expect(first.wait(timeout: 0.2) == .timedOutBeforeEntry)
        let retry = worker.retryAfterTimeoutBeforeEntry()
        #expect(retry != nil)
        releaseQueue.signal()
        #expect(retry?.wait(timeout: 0.5) == .complete)
        #expect(worker.telemetry.startedOperations == 1)
        #expect(worker.telemetry.retriedBeforeEntry == 1)
        #expect(resourceQuarantine.count == 0)
    }

    @Test("ten idle minutes schedule no light rendering in every mode")
    func inactiveModesHaveZeroLoops() {
        var loops = 0
        for mode in LightingMode.allCases {
            if let interval = LightingController.workerInterval(
                mode: mode, isSignalActive: false)
            {
                loops += Int(600 / interval)
            }
        }

        // Spectrum alone previously scheduled 18,000 wake-ups in this window.
        #expect(loops == 0)
        #expect(
            LightingController.workerInterval(mode: .level, isSignalActive: true)
                == 1.0 / 30)
        #expect(
            LightingController.workerInterval(mode: .spectrum, isSignalActive: true)
                == 1.0 / 30)
        #expect(
            LightingController.workerInterval(mode: .solid, isSignalActive: true) == nil)
        #expect(
            LightingController.workerInterval(mode: .off, isSignalActive: true) == nil)
        #expect(
            !LightingController.shouldApplyBrightness(
                mode: .level, isSignalActive: false))
        #expect(
            !LightingController.shouldApplyBrightness(
                mode: .spectrum, isSignalActive: false))
        #expect(
            LightingController.shouldApplyBrightness(
                mode: .level, isSignalActive: true))
        #expect(
            LightingController.shouldApplyBrightness(
                mode: .spectrum, isSignalActive: true))
        #expect(
            LightingController.shouldApplyBrightness(
                mode: .solid, isSignalActive: false))
    }

    @Test("only an active level display consumes meter updates")
    func signalUpdateSchedulingMatchesFrameInputs() {
        let pollsPerHour = 20 * 60 * 60

        for mode in LightingMode.allCases {
            var updates = 0
            for _ in 0..<pollsPerHour {
                if LightingController.needsSignalUpdate(
                    mode: mode, isSignalActive: true)
                {
                    updates += 1
                }
            }
            #expect(updates == (mode == .level ? pollsPerHour : 0))
        }

        #expect(
            !LightingController.needsSignalUpdate(
                mode: .level, isSignalActive: false))
    }

    @Test("the router gates the render-state write before reading its meters")
    func routerUsesSignalUpdateGate() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let router = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let lightingLap = try #require(router.range(of: "lap(\"lighting\")"))
        let pollEnd = try #require(
            router.range(
                of: "// MARK: Transcription",
                range: lightingLap.upperBound..<router.endIndex))
        let polling = router[lightingLap.lowerBound..<pollEnd.lowerBound]
        let gate = try #require(polling.range(of: "lighting.needsSignalUpdate"))
        let meter = try #require(polling.range(of: "levels.max()"))
        #expect(gate.lowerBound < meter.lowerBound)

        let controller = try String(
            contentsOfFile: root + "Sources/YunAudioApp/LightingController.swift",
            encoding: .utf8)
        let updateComment = try #require(
            controller.range(of: "/// Called from the router's poll"))
        let gateComment = try #require(
            controller.range(
                of: "/// Whether the router's meter poll",
                range: updateComment.upperBound..<controller.endIndex))
        let update = controller[updateComment.lowerBound..<gateComment.lowerBound]
        #expect(update.ranges(of: "renderState.update(level:").count == 1)
    }

    @Test("launch discovery never scans HID on the MainActor first frame")
    func discoveryIsDeferred() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let lighting = try String(
            contentsOfFile: root + "Sources/YunAudioApp/LightingController.swift",
            encoding: .utf8)
        let initStart = try #require(lighting.range(of: "init() {}"))
        let initEnd = try #require(
            lighting.range(
                of: "func refreshDevice()",
                range: initStart.upperBound..<lighting.endIndex))
        let initialisation = lighting[initStart.lowerBound..<initEnd.lowerBound]
        #expect(initialisation.ranges(of: "RazerDevice.discover()").isEmpty)

        let workerStart = try #require(
            lighting.range(of: "private func runDeviceDiscovery("))
        let workerEnd = try #require(
            lighting.range(
                of: "private func finishDeviceDiscovery(",
                range: workerStart.upperBound..<lighting.endIndex))
        let worker = lighting[workerStart.lowerBound..<workerEnd.lowerBound]
        #expect(worker.ranges(of: "RazerDevice.discover()").count == 1)
        #expect(worker.ranges(of: "discoveryQueue.async").count == 1)

        let applyStart = try #require(
            lighting.range(of: "private func applyDiscoveredDevice("))
        let applyEnd = try #require(
            lighting.range(
                of: "/// Called from the router's poll",
                range: applyStart.upperBound..<lighting.endIndex))
        let apply = lighting[applyStart.lowerBound..<applyEnd.lowerBound]
        #expect(apply.ranges(of: "RazerDevice.discover()").isEmpty)
    }

    @Test("a failed device is probed at a bounded rate")
    func failuresBackOff() {
        var backoff = LightingRetryBackoff()
        let frameInterval = 1.0 / 30
        var elapsed = 0.0
        var attempts = 0

        while elapsed < 60 {
            attempts += 1
            elapsed += backoff.failed(frameInterval: frameInterval)
        }

        // The old loop made 1,800 blocking request/reply transactions in this
        // minute. Exponential delays make fifteen, including the first probe.
        #expect(attempts == 15)
        #expect(attempts < 1_800 / 100)
        #expect(elapsed >= 60)
    }

    @Test("one successful frame restores immediate rendering")
    func successResetsBackoff() {
        var backoff = LightingRetryBackoff()
        let frameInterval = 1.0 / 30
        for _ in 0..<20 {
            _ = backoff.failed(frameInterval: frameInterval)
        }
        #expect(backoff.failed(frameInterval: frameInterval) == 8)

        backoff.succeeded()
        #expect(backoff.failed(frameInterval: frameInterval) == frameInterval)
    }
}
