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
        #expect(firstEntered.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global(qos: .userInitiated).async {
            result.store(
                disposer.dispose(
                    deferred, until: HALTeardownDeadline(timeout: 0.02)))
            returned.signal()
        }

        // Freeze the waiter after its DispatchGroup timeout but before it marks
        // the old transaction cancelled or enqueues the deferred owner.
        #expect(waitExpired.wait(timeout: .now() + 1) == .success)
        releaseFirst.signal()
        #expect(first.teardownReturned.wait(timeout: .now() + 1) == .success)
        #expect(
            waitUntil(timeout: 1) {
                disposer.activeTransactionCount == 0
            })

        // The old completion has already checked an empty pending queue. The
        // enqueue below must promote itself or no future event can wake it.
        allowTimeoutPath.signal()
        #expect(returned.wait(timeout: .now() + 1) == .success)
        #expect(deferred.teardownReturned.wait(timeout: .now() + 1) == .success)
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
            try #require(retainedOwner).teardownReturned.wait(timeout: .now() + 1)
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
        #expect(reachedRelease.wait(timeout: .now() + 1) == .success)
        #expect(quarantine.count == 1)
        #expect(disposer.activeTransactionCount == 1)

        DispatchQueue.global(qos: .userInitiated).async {
            admission.store(
                disposer.acquireGraphAdmissionAfterDraining(waitingUpTo: 1))
            admissionReturned.signal()
        }
        #expect(admissionReturned.wait(timeout: .now() + 0.02) == .timedOut)
        allowRelease.signal()
        #expect(admissionReturned.wait(timeout: .now() + 1) == .success)
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
        #expect(firstEntered.wait(timeout: .now() + 1) == .success)
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
        #expect(admissionReturned.wait(timeout: .now() + 1) == .success)
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
        #expect(firstEntered.wait(timeout: .now() + 1) == .success)
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
        #expect(admissionReturned.wait(timeout: .now() + 1) == .success)
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
        #expect(first.teardownReturned.wait(timeout: .now() + 1) == .success)
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
