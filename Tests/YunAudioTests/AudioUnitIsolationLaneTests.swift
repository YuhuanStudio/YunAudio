import AudioToolbox
import CoreAudio
import Dispatch
import Foundation
import Testing

@testable import YunAudioEngine
@testable import YunAudioHAL

@Suite("Audio Unit construction and control isolation", .serialized)
struct AudioUnitIsolationLaneTests {
    private final class Values<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Element] = []

        func append(_ value: Element) {
            lock.withLock { storage.append(value) }
        }

        var snapshot: [Element] { lock.withLock { storage } }
    }

    private final class LifetimeProbe: @unchecked Sendable {}

    private func wait(
        timeout: TimeInterval = 1,
        until condition: () -> Bool
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return condition()
    }

    @Test("echo cancellation has one larger absolute construction budget")
    func echoCancellationConstructionBudgetIsLocalAndBounded() {
        #expect(AudioUnitConstructionBudget.standard == 2)
        #expect(AudioUnitConstructionBudget.echoCancellation == 3)

        let start: UInt64 = 10_000_000_000
        let deadline = HALTeardownDeadline(
            timeout: AudioUnitConstructionBudget.echoCancellation,
            nowUptimeNanoseconds: start)
        #expect(
            deadline.remainingTimeInterval(
                nowUptimeNanoseconds: start + 2_100_000_000) == 0.9)
        #expect(
            deadline.remainingTimeInterval(
                nowUptimeNanoseconds: start + 3_000_000_000) == 0)
    }

    @Test("a hung constructor releases the engine queue at one absolute deadline")
    func hungConstructionCannotBlockStopLane() {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let lane = BoundedAudioUnitConstructionLane(
            quarantine: quarantine,
            label: "com.yuhuanstudio.yunaudio.tests.au-construction.hung")
        let engineQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.tests.au-construction.engine")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopReached = DispatchSemaphore(value: 0)
        let results = Values<String>()
        let began = ProcessInfo.processInfo.systemUptime

        engineQueue.async {
            let result: AudioUnitLaneResult<Int> = lane.perform(timeout: 0.03) { _ in
                entered.signal()
                release.wait()
                return 17
            }
            if case .timedOut = result { results.append("timed-out") }
        }
        #expect(entered.wait(timeout: .now() + TestGate.deadlock) == .success)
        engineQueue.async {
            results.append("stop")
            stopReached.signal()
        }

        #expect(stopReached.wait(timeout: .now() + TestGate.deadlock) == .success)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        #expect(elapsed >= 0.02)
        #expect(elapsed < 0.3)
        #expect(results.snapshot == ["timed-out", "stop"])
        #expect(lane.activeCount == 1)
        #expect(lane.pendingCount == 0)
        #expect(lane.startedCount == 1)
        #expect(lane.maximumConcurrentCount == 1)
        #expect(quarantine.count == 1)

        let refused: AudioUnitLaneResult<Int> = lane.perform(timeout: 0.03) { _ in 23 }
        if case .refused = refused {
            #expect(true)
        } else {
            Issue.record("a timed-out construction lane admitted a replacement")
        }
        #expect(lane.startedCount == 1)
        release.signal()
    }

    @Test("timeout retains partial owners and suppresses every later construction stage")
    func constructionCancellationIsCheckedBetweenOperations() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let lane = BoundedAudioUnitConstructionLane(
            quarantine: quarantine,
            label: "com.yuhuanstudio.yunaudio.tests.au-construction.checkpoints")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let contexts = Values<AudioUnitConstructionContext>()
        let stages = Values<Int>()
        let partialOwner = LifetimeProbe()

        let result: AudioUnitLaneResult<Int> = lane.perform(timeout: 0.02) { context in
            contexts.append(context)
            _ = performAudioUnitConstruction(
                until: context.deadline, context: context
            ) {
                stages.append(1)
                entered.signal()
                release.wait()
                return noErr
            }
            context.retainAfterCancellation(partialOwner)
            _ = performAudioUnitConstruction(
                until: context.deadline, context: context
            ) {
                stages.append(2)
                return noErr
            }
            returned.signal()
            return 17
        }

        #expect(entered.wait(timeout: .now()) == .success)
        if case .timedOut = result {
            #expect(true)
        } else {
            Issue.record("the construction transaction escaped its deadline")
        }
        release.signal()
        #expect(returned.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(stages.snapshot == [1])
        #expect(try #require(contexts.snapshot.first).retainedOwnerCount == 1)
        #expect(quarantine.count == 1)
        #expect(lane.activeCount == 1)
        #expect(lane.startedCount == 1)
        #expect(lane.maximumConcurrentCount == 1)
    }

    @Test("late construction success is retained and never published")
    func lateConstructionResultStaysQuarantined() {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let lane = BoundedAudioUnitConstructionLane(
            quarantine: quarantine,
            label: "com.yuhuanstudio.yunaudio.tests.au-construction.late")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let probe = LifetimeProbe()
        weak let weakProbe: LifetimeProbe? = probe

        let result: AudioUnitLaneResult<LifetimeProbe?> = lane.perform(timeout: 0.02) { _ in
            entered.signal()
            release.wait()
            return probe
        }
        #expect(entered.wait(timeout: .now()) == .success)
        if case .timedOut = result {
            #expect(true)
        } else {
            Issue.record("late constructor value escaped its deadline")
        }

        release.signal()
        #expect(wait { lane.activeCount == 1 })
        #expect(weakProbe != nil)
        #expect(quarantine.count == 1)
        #expect(lane.startedCount == 1)
        #expect(lane.maximumConcurrentCount == 1)
    }

    @Test("constructor return and timeout have one publication winner")
    func constructionReturnTimeoutPublicationIsLinearizable() {
        let timedOutQuarantine = ProcessLifetimeAudioQuarantine()
        let returnedBeforePublication = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let timedOutLane = BoundedAudioUnitConstructionLane(
            quarantine: timedOutQuarantine,
            label: "com.yuhuanstudio.yunaudio.tests.au-construction.return-timeout",
            afterConstructorReturnedBeforePublication: {
                returnedBeforePublication.signal()
                releasePublication.wait()
            })
        let timedOutCompletion = DispatchSemaphore(value: 0)
        let timedOutResults = Values<String>()
        let timedOutCleanups = Values<Int>()
        let timedOutOperations = Values<Int>()

        DispatchQueue.global().async {
            let result: AudioUnitLaneResult<Int> = timedOutLane.perform(timeout: 0.03) {
                context in
                timedOutOperations.append(1)
                _ = context.deferCleanupAfterCancellation {
                    timedOutCleanups.append(1)
                }
                return 17
            }
            if case .timedOut = result { timedOutResults.append("timed-out") }
            timedOutCompletion.signal()
        }

        #expect(returnedBeforePublication.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(timedOutCompletion.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(timedOutResults.snapshot == ["timed-out"])
        #expect(timedOutOperations.snapshot.count == 1)
        #expect(timedOutCleanups.snapshot.count == 0)
        #expect(timedOutLane.activeCount == 1)
        #expect(timedOutLane.pendingCount == 0)
        #expect(timedOutLane.startedCount == 1)
        #expect(timedOutLane.maximumConcurrentCount == 1)
        #expect(timedOutQuarantine.count == 1)
        #expect(!timedOutLane.admitsConstruction)

        let refused: AudioUnitLaneResult<Int> = timedOutLane.perform(timeout: 0.03) { _ in
            timedOutOperations.append(2)
            return 23
        }
        if case .refused = refused {
            #expect(true)
        } else {
            Issue.record("a timeout winner admitted another constructor")
        }
        #expect(timedOutOperations.snapshot.count == 1)

        releasePublication.signal()
        #expect(wait { timedOutCleanups.snapshot.count == 1 })
        Thread.sleep(forTimeInterval: 0.03)
        #expect(timedOutCleanups.snapshot.count == 1)
        #expect(timedOutResults.snapshot.count == 1)
        #expect(timedOutLane.activeCount == 1)
        #expect(timedOutLane.pendingCount == 0)
        #expect(timedOutQuarantine.count == 1)
        #expect(!timedOutLane.admitsConstruction)

        let completedQuarantine = ProcessLifetimeAudioQuarantine()
        let returnClaimed = DispatchSemaphore(value: 0)
        let releaseCompletedPublication = DispatchSemaphore(value: 0)
        let completedLane = BoundedAudioUnitConstructionLane(
            quarantine: completedQuarantine,
            label: "com.yuhuanstudio.yunaudio.tests.au-construction.return-success",
            afterReturnClaimedBeforeTransactionPublication: {
                returnClaimed.signal()
                releaseCompletedPublication.wait()
            })
        let completedCleanups = Values<Int>()
        let completedResults = Values<Int>()
        let completedCompletion = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let completed: AudioUnitLaneResult<Int> = completedLane.perform(timeout: 0.03) {
                context in
                _ = context.deferCleanupAfterCancellation {
                    completedCleanups.append(1)
                }
                return 29
            }
            if case .completed(let value) = completed { completedResults.append(value) }
            completedCompletion.signal()
        }

        #expect(returnClaimed.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(completedCompletion.wait(timeout: .now() + 0.08) == .timedOut)
        #expect(completedResults.snapshot.count == 0)
        #expect(completedCleanups.snapshot.count == 0)
        #expect(completedLane.activeCount == 1)
        #expect(completedLane.pendingCount == 0)
        #expect(completedQuarantine.count == 0)
        #expect(completedLane.admitsConstruction)

        releaseCompletedPublication.signal()
        #expect(completedCompletion.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(wait { completedLane.activeCount == 0 })
        #expect(completedResults.snapshot == [29])
        #expect(completedResults.snapshot.count == 1)
        #expect(completedCleanups.snapshot.count == 0)
        #expect(completedLane.activeCount == 0)
        #expect(completedLane.pendingCount == 0)
        #expect(completedLane.startedCount == 1)
        #expect(completedLane.maximumConcurrentCount == 1)
        #expect(completedQuarantine.count == 0)
        #expect(completedLane.admitsConstruction)
    }

    @Test("construction retains exactly one active and the latest pending request")
    func constructionIsFirstLatest() {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let lane = BoundedAudioUnitConstructionLane(
            quarantine: quarantine,
            label: "com.yuhuanstudio.yunaudio.tests.au-construction.latest")
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstEntered = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        let thirdDone = DispatchSemaphore(value: 0)
        let outcomes = Values<String>()

        DispatchQueue.global().async {
            let result: AudioUnitLaneResult<Int> = lane.perform(timeout: 1) { _ in
                firstEntered.signal()
                releaseFirst.wait()
                return 0
            }
            if case .completed(0) = result { outcomes.append("first") }
            firstDone.signal()
        }
        #expect(firstEntered.wait(timeout: .now() + TestGate.deadlock) == .success)

        DispatchQueue.global().async {
            let result: AudioUnitLaneResult<Int> = lane.perform(timeout: 1) { _ in 1 }
            if case .superseded = result { outcomes.append("superseded") }
            secondDone.signal()
        }
        #expect(wait { lane.pendingCount == 1 })

        DispatchQueue.global().async {
            let result: AudioUnitLaneResult<Int> = lane.perform(timeout: 1) { _ in 2 }
            if case .completed(2) = result { outcomes.append("latest") }
            thirdDone.signal()
        }
        #expect(secondDone.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(lane.activeCount == 1)
        #expect(lane.pendingCount == 1)

        releaseFirst.signal()
        #expect(firstDone.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(thirdDone.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(Set(outcomes.snapshot) == Set(["first", "superseded", "latest"]))
        #expect(lane.startedCount == 2)
        #expect(lane.maximumConcurrentCount == 1)
        #expect(lane.activeCount == 0)
        #expect(lane.pendingCount == 0)
        #expect(quarantine.count == 0)
    }

    @Test("ten thousand construction toggles retain first and latest only")
    func constructionStormPolicyIsExactlyTwoSlots() throws {
        var backlog = AudioUnitFirstLatestBacklog<Int>()
        let first = backlog.submit(0)
        #expect(first.startsNow)
        #expect(first.superseded == nil)

        var superseded = 0
        var maximumRetained = backlog.retainedCount
        for value in 1..<10_000 {
            let submission = backlog.submit(value)
            #expect(!submission.startsNow)
            if submission.superseded != nil { superseded += 1 }
            maximumRetained = max(maximumRetained, backlog.retainedCount)
        }

        #expect(backlog.active == 0)
        #expect(backlog.pending == 9_999)
        #expect(maximumRetained == 2)
        #expect(superseded == 9_998)
        #expect(backlog.finishActive() == 9_999)
        #expect(backlog.pending == nil)
        #expect(backlog.retainedCount == 1)
        #expect(backlog.finishActive() == nil)
        #expect(backlog.retainedCount == 0)
    }

    @Test("ten thousand controls execute first and keyed latest only")
    func controlStormIsFirstLatest() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let lane = BoundedAudioUnitControlLane(
            quarantine: quarantine, operationTimeout: 2,
            label: "com.yuhuanstudio.yunaudio.tests.au-control.storm")
        let owner = AudioUnitOwnerControlGate()
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstEntered = DispatchSemaphore(value: 0)
        let latestReturned = DispatchSemaphore(value: 0)
        let executed = Values<Int>()

        let firstLease = try #require(owner.acquire())
        #expect(
            lane.submit(key: "plugin:mix", lease: firstLease) { _ in
                executed.append(0)
                firstEntered.signal()
                releaseFirst.wait()
            })
        #expect(firstEntered.wait(timeout: .now() + TestGate.deadlock) == .success)

        for value in 1..<10_000 {
            let lease = try #require(owner.acquire())
            #expect(
                lane.submit(key: "plugin:mix", lease: lease) { _ in
                    executed.append(value)
                    if value == 9_999 { latestReturned.signal() }
                })
        }

        #expect(lane.activeCount == 1)
        #expect(lane.pendingCount == 1)
        #expect(owner.activeLeaseCount <= 2)
        releaseFirst.signal()
        #expect(latestReturned.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(wait { lane.activeCount == 0 })
        #expect(executed.snapshot == [0, 9_999])
        #expect(lane.startedCount == 2)
        #expect(lane.maximumConcurrentCount == 1)
        #expect(lane.pendingCount == 0)
        #expect(owner.activeLeaseCount == 0)
        #expect(quarantine.count == 0)
    }

    @Test("a hung control lease prevents concurrent owner teardown")
    func hungControlRetainsOwnerAcrossLateReturn() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let lane = BoundedAudioUnitControlLane(
            quarantine: quarantine, operationTimeout: 0.03,
            label: "com.yuhuanstudio.yunaudio.tests.au-control.hung")
        let gate = AudioUnitOwnerControlGate()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let owner = LifetimeProbe()
        weak let retainedOwner = owner
        let lease = try #require(gate.acquire())

        #expect(
            lane.submit(key: "plugin:hung", lease: lease) { _ in
                withExtendedLifetime(owner) {
                    entered.signal()
                    release.wait()
                }
            })
        #expect(entered.wait(timeout: .now() + TestGate.deadlock) == .success)
        let began = ProcessInfo.processInfo.systemUptime
        #expect(!gate.closeForTeardown(waitingUpTo: 0.01))
        #expect(ProcessInfo.processInfo.systemUptime - began < 0.1)
        #expect(wait { quarantine.count == 1 })
        #expect(gate.activeLeaseCount == 1)
        #expect(retainedOwner != nil)
        #expect(lane.startedCount == 1)
        #expect(lane.maximumConcurrentCount == 1)

        release.signal()
        Thread.sleep(forTimeInterval: 0.03)
        #expect(gate.activeLeaseCount == 1)
        #expect(retainedOwner != nil)
        #expect(quarantine.count == 1)
        #expect(lane.activeCount == 1)
    }

    @Test("a returned control error releases its lease without quarantine")
    func returnedControlErrorIsNotAStall() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let lane = BoundedAudioUnitControlLane(
            quarantine: quarantine, operationTimeout: 0.2,
            label: "com.yuhuanstudio.yunaudio.tests.au-control.error")
        let gate = AudioUnitOwnerControlGate()
        let lease = try #require(gate.acquire())

        let result: AudioUnitLaneResult<OSStatus> = lane.perform(
            key: "plugin:error", lease: lease
        ) { _ in
            kAudio_ParamError
        }
        if case .completed(let status) = result {
            #expect(status == kAudio_ParamError)
        } else {
            Issue.record("a returned Audio Unit error was mistaken for a hang")
        }
        #expect(wait { lane.activeCount == 0 })
        #expect(gate.activeLeaseCount == 0)
        #expect(gate.closeForTeardown())
        #expect(quarantine.count == 0)
        #expect(lane.startedCount == 1)
        #expect(lane.maximumConcurrentCount == 1)
    }

    @Test("saved and installed async-only Audio Units are refused before sync creation")
    func asynchronousInstantiationPolicyIsExplicit() throws {
        let oldJSON = """
            {
              "type": 1635083896,
              "subType": 1635083896,
              "manufacturer": 1635083896,
              "name": "legacy",
              "manufacturerName": "maker",
              "loadsInProcess": true
            }
            """
        let legacy = try JSONDecoder().decode(
            AudioUnitPlugin.self, from: Data(oldJSON.utf8))
        #expect(!legacy.requiresAsyncInstantiation)

        let asynchronous = AudioUnitPlugin(
            type: kAudioUnitType_Effect, subType: 1, manufacturer: 2,
            name: "async", manufacturerName: "maker", loadsInProcess: true,
            requiresAsyncInstantiation: true)
        #expect(throws: RoutingError.self) {
            try RoutingEngine.validateProcessingResources(
                effects: [], plugins: [asynchronous], voiceIsolation: nil)
        }

        let root = PreferencesCompletenessTests.sourceRootForTests
        let effectChain = try String(
            contentsOfFile: root + "Sources/YunAudioEngine/EffectChain.swift",
            encoding: .utf8)
        let isolation = try String(
            contentsOfFile: root + "Sources/YunAudioEngine/VoiceIsolation.swift",
            encoding: .utf8)
        #expect(
            effectChain.ranges(of: "AudioUnitPlugins.requiresAsyncInstantiation").count == 2)
        #expect(
            effectChain.ranges(of: "AudioComponentInstanceNew(").count == 2)
        #expect(isolation.contains("AudioUnitPlugins.requiresAsyncInstantiation(component)"))
    }

    /// The echo bridge is built on a bounded lane, once, and on the lane that
    /// is *not* the one every route needs.
    ///
    /// Reproduced on 2026-08-25: the voice-processing unit's construction
    /// reached `AudioDeviceCreateIOProcID`, sent a mach message to coreaudiod
    /// and never returned. The lane kept the wedged worker and quarantined
    /// itself for the life of the process — correctly — and because it was the
    /// shared lane, the application could no longer build any graph at all
    /// while still accepting Start and reporting success.
    ///
    /// So "which lane" is the whole claim, and putting it back on the shared
    /// one is a single-word edit that would look harmless.
    @Test("the echo bridge is built on its own bounded lane, exactly once")
    func echoBridgeConstructionCannotPinTheEngineLockForever() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "var bridge: EchoCancellationBridge?"))
        let end = try #require(
            source.range(
                of: "let cancelsEcho = bridge != nil",
                range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        let lane = try #require(
            body.range(of: "BoundedAudioUnitConstructionLane.echoCancellation.perform"))
        let constructor = try #require(body.range(of: "try EchoCancellationBridge("))
        // The residue check still follows the constructor, and still asks the
        // shared lane — the one that speaks for the graph about to be built.
        let quarantine = try #require(
            body.range(of: "!BoundedAudioUnitConstructionLane.shared.admitsConstruction"))

        #expect(lane.lowerBound < constructor.lowerBound)
        #expect(constructor.lowerBound < quarantine.lowerBound)
        #expect(body.ranges(of: "EchoCancellationBridge(").count == 1)
        #expect(
            body.ranges(of: "BoundedAudioUnitConstructionLane.echoCancellation.perform")
                .count == 1)
        // And never on the shared lane, which is the regression this guards.
        #expect(
            body.ranges(of: "BoundedAudioUnitConstructionLane.shared.perform").isEmpty,
            "the echo canceller is back on the lane every route needs")
        #expect(body.contains("constructionContext: context"))
    }

    @Test("echo construction forwards cancellation through every nested owner")
    func echoConstructionHasNestedCancellationCheckpoints() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let bridge = try String(
            contentsOfFile: root + "Sources/YunAudioEngine/EchoCancellationBridge.swift",
            encoding: .utf8)
        let capture = try String(
            contentsOfFile: root + "Sources/YunAudioEngine/EchoCancellingCapture.swift",
            encoding: .utf8)
        let farEnd = try String(
            contentsOfFile: root + "Sources/YunAudioEngine/FarEndCapture.swift",
            encoding: .utf8)
        let device = try String(
            contentsOfFile: root + "Sources/YunAudioHAL/AudioDevice.swift",
            encoding: .utf8)
        let tap = try String(
            contentsOfFile: root + "Sources/YunAudioHAL/ProcessTap.swift",
            encoding: .utf8)

        #expect(
            bridge.ranges(of: "constructionContext: constructionContext").count >= 2)
        #expect(capture.contains("performAudioUnitConstruction("))
        #expect(capture.contains("operationAdmission: { constructionContext.mayBeginOperation"))
        #expect(farEnd.contains("retryAdmission: { constructionContext?.mayBeginOperation"))
        #expect(device.contains("operationAdmission: @escaping @Sendable () -> Bool"))
        #expect(tap.ranges(of: "retryAdmission()").count >= 3)
    }

    @Test("polling getters publish asynchronously after releasing the route lock")
    func pollingNeverWaitsForVendorCodeOnMainActor() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let meterStart = try #require(source.range(of: "public func gainReduction("))
        let metadataStart = try #require(
            source.range(
                of: "public func pluginParameters(_ id:",
                range: meterStart.upperBound..<source.endIndex))
        let availableStart = try #require(
            source.range(
                of: "public func pluginParametersIfAvailable(",
                range: metadataStart.upperBound..<source.endIndex))
        let setterStart = try #require(
            source.range(
                of: "public func setPluginParameter(",
                range: availableStart.upperBound..<source.endIndex))
        let meter = source[meterStart.lowerBound..<metadataStart.lowerBound]
        let available = source[availableStart.lowerBound..<setterStart.lowerBound]

        let meterUnlock = try #require(meter.range(of: "stateLock.unlock()"))
        let meterSubmit = try #require(
            meter.range(of: "BoundedAudioUnitControlLane.shared.submit"))
        #expect(meterUnlock.lowerBound < meterSubmit.lowerBound)
        #expect(!meter.contains(".perform("))

        let metadataUnlock = try #require(available.range(of: "stateLock.unlock()"))
        let metadataSubmit = try #require(
            available.range(of: "BoundedAudioUnitControlLane.shared.submit"))
        #expect(metadataUnlock.lowerBound < metadataSubmit.lowerBound)
        #expect(!available.contains(".perform("))
    }
}
