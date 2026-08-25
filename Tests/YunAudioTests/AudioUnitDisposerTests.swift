import CoreAudio
import Dispatch
import Foundation
import Testing

@testable import YunAudioEngine
@testable import YunAudioHAL

@Suite("Bounded Audio Unit disposal", .serialized)
struct AudioUnitDisposerTests {
    private final class InjectedOwner: AudioUnitTeardownOwner, @unchecked Sendable {
        private enum Phase {
            case ready
            case uninitialised
            case disposed
        }

        private let lock = NSLock()
        private var phase = Phase.ready
        private var uninitialiseCalls = 0
        private var disposeCalls = 0
        private let uninitialise: @Sendable () -> OSStatus
        private let dispose: @Sendable () -> OSStatus
        let teardownReturned = DispatchSemaphore(value: 0)

        init(
            uninitialise: @escaping @Sendable () -> OSStatus = { noErr },
            dispose: @escaping @Sendable () -> OSStatus = { noErr }
        ) {
            self.uninitialise = uninitialise
            self.dispose = dispose
        }

        var audioUnitCount: Int {
            lock.withLock { phase == .disposed ? 0 : 1 }
        }

        var callCounts: (uninitialise: Int, dispose: Int) {
            lock.withLock { (uninitialiseCalls, disposeCalls) }
        }

        func tearDownAudioUnits(
            using gate: AudioUnitTeardownGate
        ) -> AudioUnitOwnerDisposalResult {
            defer { teardownReturned.signal() }
            if lock.withLock({ phase == .ready }) {
                let status = gate.perform(.uninitialise) {
                    lock.withLock { uninitialiseCalls += 1 }
                    return uninitialise()
                }
                guard let status else {
                    return .timedOut(step: .uninitialise, disposedUnits: 0)
                }
                guard status == noErr else {
                    return .operationFailed(
                        step: .uninitialise, status: status, disposedUnits: 0)
                }
                lock.withLock { phase = .uninitialised }
            }

            if lock.withLock({ phase == .uninitialised }) {
                let status = gate.perform(.dispose) {
                    lock.withLock { disposeCalls += 1 }
                    return dispose()
                }
                guard let status else {
                    return .timedOut(step: .dispose, disposedUnits: 0)
                }
                guard status == noErr else {
                    return .operationFailed(
                        step: .dispose, status: status, disposedUnits: 0)
                }
                lock.withLock { phase = .disposed }
                return .complete(disposedUnits: 1)
            }

            return .complete(disposedUnits: 0)
        }
    }

    private final class DisposalResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: AudioUnitOwnerDisposalResult?

        func store(_ value: AudioUnitOwnerDisposalResult) {
            lock.withLock { storage = value }
        }

        var value: AudioUnitOwnerDisposalResult? { lock.withLock { storage } }
    }

    private final class GraphAdmissionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: BoundedAudioUnitDisposer.GraphAdmission?

        func store(_ value: BoundedAudioUnitDisposer.GraphAdmission?) {
            lock.withLock { storage = value }
        }

        var value: BoundedAudioUnitDisposer.GraphAdmission? { lock.withLock { storage } }
    }

    private final class ConstructionAdmissionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: AudioUnitGraphAdmissionBox?

        func store(_ value: AudioUnitGraphAdmissionBox?) {
            lock.withLock { storage = value }
        }

        var value: AudioUnitGraphAdmissionBox? { lock.withLock { storage } }
    }

    private func waitUntil(
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return condition()
    }

    private func makeDisposer(
        quarantine: ProcessLifetimeAudioQuarantine,
        asynchronousTimeout: TimeInterval = 0.05,
        beforeTimedOutWaitCancelsTransaction: @escaping @Sendable () -> Void = {},
        beforeSuccessfulQuarantineRelease: @escaping @Sendable () -> Void = {}
    ) -> BoundedAudioUnitDisposer {
        BoundedAudioUnitDisposer(
            quarantine: quarantine,
            asynchronousTimeout: asynchronousTimeout,
            label: "com.yuhuanstudio.yunaudio.tests.au-disposer.\(UUID().uuidString)",
            beforeTimedOutWaitCancelsTransaction: beforeTimedOutWaitCancelsTransaction,
            beforeSuccessfulQuarantineRelease: beforeSuccessfulQuarantineRelease)
    }

    @Test("a timeout enqueue promotes after the old transaction just completed")
    func timeoutEnqueueCannotMissIdlePromotion() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let waitExpired = DispatchSemaphore(value: 0)
        let allowTimeoutPath = DispatchSemaphore(value: 0)
        let disposer = makeDisposer(
            quarantine: quarantine,
            asynchronousTimeout: 5,
            beforeTimedOutWaitCancelsTransaction: {
                waitExpired.signal()
                allowTimeoutPath.wait()
            })
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let first = InjectedOwner(
            uninitialise: {
                firstEntered.signal()
                releaseFirst.wait()
                return noErr
            })
        let deferred = InjectedOwner()
        let returned = DispatchSemaphore(value: 0)
        let result = DisposalResultBox()

        disposer.disposeAfterFence(first)
        #expect(firstEntered.wait(timeout: .now() + TestGate.deadlock) == .success)
        DispatchQueue.global(qos: .userInitiated).async {
            result.store(
                disposer.dispose(
                    deferred, until: HALTeardownDeadline(timeout: 0.02)))
            returned.signal()
        }

        // Freeze the waiter after its DispatchGroup timeout but before it marks
        // the old transaction cancelled or enqueues the deferred owner.
        #expect(waitExpired.wait(timeout: .now() + TestGate.deadlock) == .success)
        releaseFirst.signal()
        #expect(first.teardownReturned.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(
            waitUntil(timeout: 1) {
                disposer.activeTransactionCount == 0
            })

        // The old completion has already checked an empty pending queue. The
        // enqueue below must promote itself or no future event can wake it.
        allowTimeoutPath.signal()
        #expect(returned.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(deferred.teardownReturned.wait(timeout: .now() + TestGate.deadlock) == .success)
        let admission = try #require(
            disposer.acquireGraphAdmission(waitingUpTo: 1))

        let returnedResult = try #require(result.value)
        if case .blockedByRetainedTransaction = returnedResult {
            #expect(true)
        } else {
            Issue.record("the timed-out waiter did not report deferred ownership")
        }
        #expect(deferred.callCounts.uninitialise == 1)
        #expect(deferred.callCounts.dispose == 1)
        #expect(disposer.pendingOwnerCount == 0)
        #expect(disposer.activeTransactionCount == 0)
        #expect(disposer.transactionCount == 2)
        #expect(disposer.maximumTransactionCount == 1)
        #expect(quarantine.count == 0)
        admission.release()
    }

    @Test("hung uninitialise returns at the route deadline and retains one owner")
    func hungUninitialiseIsFailClosed() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var owner: InjectedOwner? = InjectedOwner(
            uninitialise: {
                entered.signal()
                release.wait()
                return noErr
            })
        weak let retainedOwner = owner

        let began = ProcessInfo.processInfo.systemUptime
        let result = disposer.dispose(
            try #require(owner), until: HALTeardownDeadline(timeout: 0.03))
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        #expect(entered.wait(timeout: .now()) == .success)
        #expect(elapsed >= 0.02)
        #expect(elapsed < 0.25)
        #expect(result == .timedOut(step: .uninitialise, disposedUnits: 0))

        owner = nil
        #expect(retainedOwner != nil)
        #expect(quarantine.count == 1)
        #expect(disposer.activeTransactionCount == 1)
        #expect(disposer.transactionCount == 1)
        #expect(disposer.maximumTransactionCount == 1)
        #expect(disposer.acquireGraphAdmission() == nil)

        release.signal()
        #expect(
            try #require(retainedOwner).teardownReturned.wait(
                timeout: .now() + TestGate.deadlock)
                == .success)
        #expect(try #require(retainedOwner).callCounts.uninitialise == 1)
        #expect(try #require(retainedOwner).callCounts.dispose == 0)
        #expect(quarantine.count == 1)
        #expect(disposer.activeTransactionCount == 1)
        #expect(disposer.maximumTransactionCount == 1)
    }

    @Test("successful teardown releases quarantine before immediate graph admission")
    func successIsExactlyOnceAndImmediatelyAdmitsRestart() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let owner = InjectedOwner()

        let first = disposer.dispose(
            owner, until: HALTeardownDeadline(timeout: 1))
        let restartAdmission = try #require(disposer.acquireGraphAdmission())

        #expect(first == .complete(disposedUnits: 1))
        #expect(owner.callCounts.uninitialise == 1)
        #expect(owner.callCounts.dispose == 1)
        #expect(quarantine.count == 0)
        #expect(disposer.activeTransactionCount == 0)
        #expect(disposer.transactionCount == 1)

        restartAdmission.release()
        let repeated = disposer.dispose(
            owner, until: HALTeardownDeadline(timeout: 1))
        #expect(repeated == .complete(disposedUnits: 0))
        #expect(owner.callCounts.uninitialise == 1)
        #expect(owner.callCounts.dispose == 1)
        #expect(disposer.transactionCount == 1)
        #expect(disposer.maximumTransactionCount == 1)
    }

    @Test("graph admission cannot observe successful teardown residue")
    func successfulTokenReleasePrecedesAdmission() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let reachedRelease = DispatchSemaphore(value: 0)
        let allowRelease = DispatchSemaphore(value: 0)
        let disposer = makeDisposer(
            quarantine: quarantine,
            beforeSuccessfulQuarantineRelease: {
                reachedRelease.signal()
                allowRelease.wait()
            })
        let owner = InjectedOwner()
        let admission = GraphAdmissionBox()
        let admissionReturned = DispatchSemaphore(value: 0)

        disposer.disposeAfterFence(owner)
        #expect(reachedRelease.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(quarantine.count == 1)
        #expect(disposer.activeTransactionCount == 1)

        DispatchQueue.global(qos: .userInitiated).async {
            admission.store(
                disposer.acquireGraphAdmissionAfterDraining(waitingUpTo: 1))
            admissionReturned.signal()
        }
        #expect(admissionReturned.wait(timeout: .now() + 0.02) == .timedOut)
        allowRelease.signal()
        #expect(admissionReturned.wait(timeout: .now() + TestGate.deadlock) == .success)
        let accepted = try #require(admission.value)

        #expect(quarantine.count == 0)
        #expect(disposer.activeTransactionCount == 0)
        #expect(owner.callCounts.uninitialise == 1)
        #expect(owner.callCounts.dispose == 1)
        accepted.release()
    }

    @Test("route restart waits for the active and queued owners on the sole disposer")
    func restartAdmissionDrainsSubmittedOwners() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine, asynchronousTimeout: 5)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let first = InjectedOwner(
            uninitialise: {
                firstEntered.signal()
                releaseFirst.wait()
                return noErr
            })
        let second = InjectedOwner()
        let admission = GraphAdmissionBox()
        let admissionReturned = DispatchSemaphore(value: 0)

        disposer.disposeAfterFence(first)
        #expect(firstEntered.wait(timeout: .now() + TestGate.deadlock) == .success)
        disposer.disposeAfterFence(second)
        #expect(disposer.activeTransactionCount == 1)
        #expect(disposer.pendingOwnerCount == 1)

        DispatchQueue.global(qos: .userInitiated).async {
            admission.store(
                disposer.acquireGraphAdmissionAfterDraining(waitingUpTo: 1))
            admissionReturned.signal()
        }
        #expect(admissionReturned.wait(timeout: .now() + 0.02) == .timedOut)
        releaseFirst.signal()
        #expect(admissionReturned.wait(timeout: .now() + TestGate.deadlock) == .success)
        let accepted = try #require(admission.value)

        #expect(first.callCounts.uninitialise == 1)
        #expect(first.callCounts.dispose == 1)
        #expect(second.callCounts.uninitialise == 1)
        #expect(second.callCounts.dispose == 1)
        #expect(disposer.activeTransactionCount == 0)
        #expect(disposer.pendingOwnerCount == 0)
        #expect(disposer.maximumTransactionCount == 1)
        #expect(quarantine.count == 0)
        accepted.release()
    }

    @Test("a fresh graph waits for active and queued chain disposal")
    func freshGraphDrainsSubmittedOwners() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine, asynchronousTimeout: 5)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let first = InjectedOwner(
            uninitialise: {
                firstEntered.signal()
                releaseFirst.wait()
                return noErr
            })
        let second = InjectedOwner()
        let admission = ConstructionAdmissionBox()
        let admissionReturned = DispatchSemaphore(value: 0)

        disposer.disposeAfterFence(first)
        #expect(firstEntered.wait(timeout: .now() + TestGate.deadlock) == .success)
        disposer.disposeAfterFence(second)
        #expect(disposer.activeTransactionCount == 1)
        #expect(disposer.pendingOwnerCount == 1)

        DispatchQueue.global(qos: .userInitiated).async {
            admission.store(
                AudioUnitGraphAdmissionBox(
                    waitingUpTo: 1, disposer: disposer))
            admissionReturned.signal()
        }
        #expect(admissionReturned.wait(timeout: .now()) == .timedOut)
        #expect(disposer.transactionCount == 1)
        #expect(disposer.maximumTransactionCount == 1)

        releaseFirst.signal()
        #expect(admissionReturned.wait(timeout: .now() + TestGate.deadlock) == .success)
        let accepted = try #require(admission.value)

        #expect(first.callCounts.uninitialise == 1)
        #expect(first.callCounts.dispose == 1)
        #expect(second.callCounts.uninitialise == 1)
        #expect(second.callCounts.dispose == 1)
        #expect(disposer.activeTransactionCount == 0)
        #expect(disposer.pendingOwnerCount == 0)
        #expect(disposer.transactionCount == 2)
        #expect(disposer.maximumTransactionCount == 1)
        #expect(quarantine.count == 0)
        accepted.release()
    }

    @Test("a hung transaction never starts a second teardown worker")
    func hungTransactionKeepsOneWorker() {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let release = DispatchSemaphore(value: 0)
        let first = InjectedOwner(
            uninitialise: {
                release.wait()
                return noErr
            })
        let second = InjectedOwner()

        _ = disposer.dispose(
            first, until: HALTeardownDeadline(timeout: 0.02))
        disposer.disposeAfterFence(second)

        #expect(disposer.activeTransactionCount == 1)
        #expect(disposer.transactionCount == 1)
        #expect(disposer.maximumTransactionCount == 1)
        #expect(second.callCounts.uninitialise == 0)
        #expect(second.callCounts.dispose == 0)
        #expect(quarantine.count == 2)

        release.signal()
        #expect(first.teardownReturned.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(disposer.activeTransactionCount == 1)
        #expect(disposer.transactionCount == 1)
        #expect(disposer.maximumTransactionCount == 1)
        #expect(second.callCounts.uninitialise == 0)
        #expect(second.callCounts.dispose == 0)
    }

    @Test("a rejected owner cannot start teardown inside graph construction")
    func rejectedOwnerEndsGraphBeforeDeferredTeardown() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let admission = try #require(disposer.acquireGraphAdmission())
        let rejected = InjectedOwner()

        disposer.disposeAfterFence(rejected)

        #expect(disposer.transactionCount == 0)
        #expect(quarantine.count == 1)
        #expect(disposer.acquireGraphAdmission() == nil)

        admission.release()
        let result = disposer.dispose(
            rejected, until: HALTeardownDeadline(timeout: 1))
        #expect(result.isComplete)
        #expect(rejected.callCounts.uninitialise == 1)
        #expect(rejected.callCounts.dispose == 1)
        #expect(disposer.transactionCount == 1)
        #expect(disposer.maximumTransactionCount == 1)
        #expect(quarantine.count == 0)
    }

    @Test("rejection atomically hands admission to teardown and then resumes")
    func rejectionHandoffCompletesBeforeNextAdmission() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let admission = try #require(disposer.acquireGraphAdmission())
        let rejected = InjectedOwner()

        let result = admission.handOffForDisposal(
            rejected, until: HALTeardownDeadline(timeout: 1))
        let resumed = try #require(disposer.acquireGraphAdmission())

        #expect(result == .complete(disposedUnits: 1))
        #expect(rejected.callCounts.uninitialise == 1)
        #expect(rejected.callCounts.dispose == 1)
        #expect(disposer.transactionCount == 1)
        #expect(disposer.maximumTransactionCount == 1)
        #expect(quarantine.count == 0)
        resumed.release()
    }

    @Test("a failed component creation keeps a non-null out instance for disposal")
    func failedComponentCreationClassifiesOrphanedOwnership() throws {
        let created = AudioComponentCreationOwnership(status: noErr, instance: 17)
        #expect(created.createdInstance == 17)
        #expect(created.orphanedInstance == nil)

        let failed = AudioComponentCreationOwnership(
            status: kAudio_ParamError, instance: 23)
        #expect(failed.createdInstance == nil)
        #expect(failed.orphanedInstance == 23)

        let empty = AudioComponentCreationOwnership<Int>(
            status: kAudio_ParamError, instance: nil)
        #expect(empty.createdInstance == nil)
        #expect(empty.orphanedInstance == nil)

        let malformedSuccess = AudioComponentCreationOwnership<Int>(
            status: noErr, instance: nil)
        #expect(malformedSuccess.status == noErr)
        #expect(malformedSuccess.createdInstance == nil)
        #expect(malformedSuccess.orphanedInstance == nil)
    }

    @Test("each accepted plug-in enters the owned graph before the next can fail")
    func pluginConstructionCommitsOwnershipPerIteration() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/EffectChain.swift",
            encoding: .utf8)
        let plugins = try #require(source.range(of: "for plugin in plugins"))
        let end = try #require(
            source.range(
                of: "// A chain of nothing but the native stage",
                range: plugins.upperBound..<source.endIndex))
        let body = source[plugins.lowerBound..<end.lowerBound]
        let rejection = try #require(body.range(of: "reason: .formatRejected"))
        let disposal = try #require(
            body.range(
                of: "Self.disposeRejectedInstance",
                range: rejection.upperBound..<body.endIndex))
        let abortHandoff = try #require(
            body.range(
                of: "scheduleDetachedTeardown()",
                range: disposal.upperBound..<body.endIndex))
        let commit = try #require(
            body.range(of: "units.insert(", range: abortHandoff.upperBound..<body.endIndex))

        #expect(rejection.lowerBound < disposal.lowerBound)
        #expect(disposal.lowerBound < abortHandoff.lowerBound)
        #expect(abortHandoff.lowerBound < commit.lowerBound)
        #expect(!body.contains("var built"))
        #expect(!body.contains("built.append"))
        #expect(!body.contains("AudioUnitUninitialize"))

        let detachedStart = try #require(
            source.range(of: "private func scheduleDetachedTeardown()"))
        let detachedEnd = try #require(
            source.range(
                of: "private func releaseStorage()",
                range: detachedStart.upperBound..<source.endIndex))
        let detached = source[detachedStart.lowerBound..<detachedEnd.lowerBound]
        #expect(detached.contains("detachResourcesForTeardown()"))
        #expect(detached.contains("disposeAfterFence(detached)"))
        #expect(detached.contains("units.map"))
        #expect(detached.contains("units.removeAll()"))
    }

    @Test("every component creation resolves its out-parameter ownership")
    func allComponentCreationSitesClassifyOutParameterOwnership() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let engine = URL(fileURLWithPath: root)
            .appendingPathComponent("Sources/YunAudioEngine", isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: engine, includingPropertiesForKeys: nil))
        var creationSites = 0
        var filesWithCreation = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(
                contentsOf: url, encoding: .utf8)
            let creations =
                source.components(separatedBy: "AudioComponentInstanceNew(").count - 1
            guard creations > 0 else { continue }
            let ownershipDecisions =
                source.components(separatedBy: "AudioComponentCreationOwnership(").count - 1
            #expect(ownershipDecisions == creations)
            creationSites += creations
            filesWithCreation += 1
        }
        #expect(creationSites == 6)
        #expect(filesWithCreation == 5)
    }

    @Test("hardware probes use bounded teardown rather than synchronous defers")
    func probesUseTheSoleBoundedDisposer() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        for relativePath in [
            "Sources/YunAudioEngine/EchoCancellation.swift",
            "Sources/YunAudioEngine/SoundIsolationProbe.swift",
        ] {
            let source = try String(
                contentsOfFile: root + relativePath, encoding: .utf8)
            #expect(source.contains("handOffForDisposal"))
            #expect(source.contains("AudioUnitResourceCapsule"))
            #expect(!source.contains("defer { AudioUnitUninitialize"))
            #expect(!source.contains("defer { AudioComponentInstanceDispose"))
        }
    }

    @Test("the live echo route waits for an orphaned creation result to be bounded")
    func echoRouteFailsClosedOnOrphanedCreation() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let capture = try String(
            contentsOfFile: root
                + "Sources/YunAudioEngine/EchoCancellingCapture.swift",
            encoding: .utf8)
        let creation = try #require(
            capture.range(of: "AudioComponentInstanceNew(component, &instance)"))
        let ownership = try #require(
            capture.range(
                of: "AudioComponentCreationOwnership(",
                range: creation.upperBound..<capture.endIndex))
        let orphan = try #require(
            capture.range(
                of: "ownership.orphanedInstance",
                range: ownership.upperBound..<capture.endIndex))
        let bounded = try #require(
            capture.range(
                of: "graphAdmission?.handOffForDisposal(",
                range: orphan.upperBound..<capture.endIndex))
        #expect(creation.lowerBound < ownership.lowerBound)
        #expect(ownership.lowerBound < orphan.lowerBound)
        #expect(orphan.lowerBound < bounded.lowerBound)
        #expect(
            capture.contains(
                "BoundedAudioUnitDisposer.shared.acquireGraphAdmission("))

        let router = try String(
            contentsOfFile: root + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        #expect(
            router.contains("!BoundedAudioUnitConstructionLane.shared.admitsConstruction")
                && router.contains("!BoundedAudioUnitDisposer.shared.admitsNewGraph")
                && router.contains("try requireAudioUnitGraphAdmission()"))
    }
}

/// The invariant the echo canceller's start classification rests on.
///
/// `EchoCancellationBridge.startFarEnd` treats `.blockedByRetainedTransaction`
/// as an ordinary start refusal — the far-end unit was never touched — rather
/// than as a terminal teardown verdict. That is only sound if a deferred command
/// provably never runs its operation, so it is asserted here rather than
/// reasoned about there.
///
/// Recording the deferral as a teardown verdict was the whole dropout defect:
/// `stop()` returns `lastTeardownResult` before tearing anything down, so one
/// instant of contention during a route build left every later Stop a no-op and
/// the router quarantining a route whose graph was already freed.
@Suite("Deferred lifecycle commands never run")
struct DeferredLifecycleCommandTests {

    /// A route teardown owner, which is the opposite contract to a command:
    /// it stays queued until it has fenced its callbacks, and the disposer
    /// never cancels it.
    private final class QueuedOwner: AudioUnitTeardownOwner, @unchecked Sendable {
        private let lock = NSLock()
        private var disposed = false
        private var runs = 0

        var audioUnitCount: Int { lock.withLock { disposed ? 0 : 1 } }
        var teardownRuns: Int { lock.withLock { runs } }

        func tearDownAudioUnits(
            using gate: AudioUnitTeardownGate
        ) -> AudioUnitOwnerDisposalResult {
            _ = gate.perform(.dispose) { noErr }
            lock.withLock {
                runs += 1
                disposed = true
            }
            return .complete(disposedUnits: 1)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test("a command deferred behind graph construction never touches its unit")
    func deferredCommandNeverRunsItsOperation() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = BoundedAudioUnitDisposer(
            quarantine: quarantine,
            asynchronousTimeout: 0.05,
            label: "com.yuhuanstudio.yunaudio.tests.deferred.\(UUID().uuidString)")
        let admission = try #require(disposer.acquireGraphAdmission())
        let owner = NSObject()
        let runs = Counter()
        let command = BoundedAudioUnitLifecycleCommand(
            retaining: owner, step: .start, quarantineOnError: true
        ) {
            runs.increment()
            return noErr
        }

        // The deadline expires while the graph admission is still held, which is
        // the contention a second route being built produces.
        let result = disposer.dispose(
            command, until: HALTeardownDeadline(timeout: 0.05))

        #expect(result == .blockedByRetainedTransaction(retainedUnits: 1))
        #expect(runs.count == 0)

        // Promotion happens on release, and the cancelled bit was stored under
        // the disposer's own lock before the enqueue — so the promoted command
        // still must not start the unit.
        admission.release()
        let drained = disposer.dispose(
            AudioUnitOwnerCapsule([]), until: HALTeardownDeadline(timeout: 1))
        // The promoted command reports the step it never took, which is what
        // the cancelled bit is for: the unit is untouched and says so.
        #expect(drained == .timedOut(step: .start, disposedUnits: 0))
        #expect(runs.count == 0)
        #expect(command.completedStatus == nil)
    }

    /// The deferral resolves once nothing else is building.
    ///
    /// The clean-machine run left this open: ten automatic Stops across two
    /// seconds, and `audioUnitOwner(.blockedByRetainedTransaction(3))` still
    /// standing. That is not a timeout — the flow check builds routes
    /// back-to-back, so a graph admission was almost always in flight and the
    /// pending owners' quarantine tokens kept `admitsNewGraph` false the whole
    /// time. Whether that is a stall or merely contention is the difference
    /// between a leak and a retry that needs a quiet moment, and it is settled
    /// here rather than argued about.
    @Test("a deferred owner is disposed as soon as construction stops")
    func deferralResolvesWhenNothingIsBuilding() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = BoundedAudioUnitDisposer(
            quarantine: quarantine,
            asynchronousTimeout: 0.05,
            label: "com.yuhuanstudio.yunaudio.tests.resolve.\(UUID().uuidString)")
        let admission = try #require(disposer.acquireGraphAdmission())
        // A route teardown owner, not a command: the disposer cancels a
        // deferred command by design, so one would prove nothing here.
        let work = QueuedOwner()

        let blocked = disposer.dispose(work, until: HALTeardownDeadline(timeout: 0.05))
        #expect(blocked == .blockedByRetainedTransaction(retainedUnits: 1))
        #expect(!disposer.admitsNewGraph)
        #expect(disposer.pendingOwnerCount == 1)

        // Exactly what the flow check never gave it: a moment with nothing
        // under construction.
        admission.release()

        let deadline = DispatchTime.now() + .seconds(5)
        while DispatchTime.now() < deadline, !disposer.admitsNewGraph {
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(disposer.admitsNewGraph)
        #expect(disposer.pendingOwnerCount == 0)
        #expect(quarantine.count == 0)
        // Promoted *and* executed. A queue that drains without doing the work
        // would look identical from `admitsNewGraph` alone.
        //
        // The caller cancels a command it has given up on, and a route
        // teardown owner does not — so this is the deferral resolving, which
        // is what the flow check could never give it a quiet moment to do.
        #expect(work.teardownRuns == 1)
    }

    /// Both places that classify a deferral now agree, and neither is a
    /// teardown path.
    ///
    /// `EchoCancellingCapture.performLifecycleCommand` runs the bypass property
    /// and the start-retry pause. It gates itself and `stop()` on
    /// `lastTeardownResult`, so recording a deferral there refused every later
    /// command as well as tearing nothing down — one bypass toggle at the wrong
    /// instant and the capture was finished for the life of the process.
    @Test("a deferral is not recorded as a teardown verdict in either classifier")
    func deferralIsNeverATeardownVerdict() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        // Anchored on the two runners that submit a *command*. The owner-based
        // classifiers beside them — `captureResult(from:owner:)` and the one in
        // `stop(until:)` — are genuine teardown paths, where a deferral does
        // mean work is outstanding and the conservative reading is right.
        let runners = [
            ("EchoCancellationBridge.swift", "private func startFarEnd("),
            ("EchoCancellingCapture.swift", "private func performLifecycleCommand("),
        ]
        for (file, runner) in runners {
            let source = try String(
                contentsOfFile: root + "Sources/YunAudioEngine/" + file,
                encoding: .utf8)
            let runnerStart = try #require(source.range(of: runner))
            let start = try #require(
                source.range(
                    of: "case .blockedByRetainedTransaction:",
                    range: runnerStart.upperBound..<source.endIndex))
            let end =
                source.range(
                    of: "case .ownerRetained", range: start.upperBound..<source.endIndex)?
                .lowerBound
                ?? source.index(start.upperBound, offsetBy: 900)
            let branch = source[start.upperBound..<end]
            #expect(
                !branch.contains("lastTeardownResult ="),
                "\(file) still records a deferred command as a teardown verdict")
            #expect(branch.contains("cancelBeforeStart()"))
        }
    }
}
