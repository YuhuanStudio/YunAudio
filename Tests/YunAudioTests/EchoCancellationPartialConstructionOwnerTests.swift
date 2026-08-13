import Foundation
import Testing

@testable import YunAudioEngine
@testable import YunAudioHAL

@Suite("Echo-cancellation partial construction ownership", .serialized)
struct EchoCancellationPartialConstructionOwnerTests {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ value: String) { lock.withLock { storage.append(value) } }
        var values: [String] { lock.withLock { storage } }
    }

    private func makeDisposer(
        quarantine: ProcessLifetimeAudioQuarantine
    ) -> BoundedAudioUnitDisposer {
        BoundedAudioUnitDisposer(
            quarantine: quarantine,
            asynchronousTimeout: 0.05,
            label: "com.yuhuanstudio.yunaudio.tests.aec-partial.\(UUID().uuidString)")
    }

    @Test("mutation-only handoff keeps admission closed through ordered cleanup")
    func mutationOnlyHandoffIsOneAdmissionTransaction() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let admission = try #require(
            disposer.acquireGraphAdmission(waitingUpTo: 0.1))
        let trace = Trace()
        let mutation = AggregateRateMutationOwner(
            ownsAggregate: true,
            destroyAggregate: { _ in
                trace.append("destroy")
                let unexpected = disposer.acquireGraphAdmission(waitingUpTo: 0)
                trace.append(unexpected == nil ? "closed-after-destroy" : "open-after-destroy")
                unexpected?.release()
                return .destroyed
            },
            restore: { _, _ in
                trace.append("restore")
                let unexpected = disposer.acquireGraphAdmission(waitingUpTo: 0)
                trace.append(unexpected == nil ? "closed-after-restore" : "open-after-restore")
                unexpected?.release()
                return []
            })
        mutation.recordOriginal(uid: "microphone", rate: 96_000)
        let owner = EchoCancellationPartialConstructionOwner(
            mutation: mutation, admission: admission)

        let result = owner.handOffForDisposal(
            until: HALTeardownDeadline(timeout: 1))

        #expect(result == .complete(disposedUnits: 0))
        #expect(
            trace.values
                == [
                    "destroy", "closed-after-destroy", "restore",
                    "closed-after-restore",
                ])
        #expect(!owner.hasTeardownWork)
        #expect(quarantine.count == 0)
        #expect(disposer.activeTransactionCount == 0)
        let reopened = try #require(
            disposer.acquireGraphAdmission(waitingUpTo: 0.1))
        reopened.release()
    }

    @Test("a cancelled AU gate cannot begin aggregate or rate cleanup")
    func cancelledGateRetainsEveryMutation() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let admission = try #require(
            disposer.acquireGraphAdmission(waitingUpTo: 0.1))
        let trace = Trace()
        let mutation = AggregateRateMutationOwner(
            ownsAggregate: true,
            destroyAggregate: { _ in
                trace.append("destroy")
                return .destroyed
            },
            restore: { _, _ in
                trace.append("restore")
                return []
            })
        mutation.recordOriginal(uid: "microphone", rate: 96_000)
        let owner = EchoCancellationPartialConstructionOwner(
            mutation: mutation, admission: admission)
        let gate = AudioUnitTeardownGate()
        _ = gate.cancel()

        let result = owner.tearDownAudioUnits(using: gate)

        #expect(result == .timedOut(step: nil, disposedUnits: 0))
        #expect(trace.values.isEmpty)
        #expect(owner.hasTeardownWork)
        #expect(mutation.ownsAggregate)
        #expect(mutation.remainingRateCount == 1)
        #expect(disposer.acquireGraphAdmission(waitingUpTo: 0) == nil)
    }

    @Test("failed aggregate absence retains rates and keeps admission closed")
    func failedAggregateCensusFailsClosed() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let admission = try #require(
            disposer.acquireGraphAdmission(waitingUpTo: 0.1))
        let trace = Trace()
        let mutation = AggregateRateMutationOwner(
            ownsAggregate: true,
            destroyAggregate: { _ in
                trace.append("destroy")
                return .timedOut
            },
            restore: { _, _ in
                trace.append("restore")
                return []
            })
        mutation.recordOriginal(uid: "microphone", rate: 96_000)
        let owner = EchoCancellationPartialConstructionOwner(
            mutation: mutation, admission: admission)

        let result = owner.handOffForDisposal(
            until: HALTeardownDeadline(timeout: 1))

        #expect(result == .ownerRetained(disposedUnits: 0))
        #expect(trace.values == ["destroy"])
        #expect(owner.hasTeardownWork)
        #expect(mutation.ownsAggregate)
        #expect(mutation.remainingRateCount == 1)
        #expect(quarantine.count == 1)
        #expect(disposer.activeTransactionCount == 1)
        #expect(disposer.acquireGraphAdmission(waitingUpTo: 0) == nil)
    }

    @Test("a stubborn rate remains owned after aggregate destruction")
    func failedRateRestorationFailsClosed() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let admission = try #require(
            disposer.acquireGraphAdmission(waitingUpTo: 0.1))
        let trace = Trace()
        let mutation = AggregateRateMutationOwner(
            ownsAggregate: true,
            destroyAggregate: { _ in
                trace.append("destroy")
                return .destroyed
            },
            restore: { rates, _ in
                trace.append("restore:\(rates.keys.sorted().joined(separator: ","))")
                return ["microphone"]
            })
        mutation.recordOriginal(uid: "microphone", rate: 96_000)
        let owner = EchoCancellationPartialConstructionOwner(
            mutation: mutation, admission: admission)

        let result = owner.handOffForDisposal(
            until: HALTeardownDeadline(timeout: 1))

        #expect(result == .ownerRetained(disposedUnits: 0))
        #expect(trace.values == ["destroy", "restore:microphone"])
        #expect(owner.hasTeardownWork)
        #expect(!mutation.ownsAggregate)
        #expect(mutation.remainingRateCount == 1)
        #expect(quarantine.count == 1)
        #expect(disposer.activeTransactionCount == 1)
        #expect(disposer.acquireGraphAdmission(waitingUpTo: 0) == nil)
    }

    @Test("cancellation retains the combined owner exactly once")
    func cancellationRetentionIsIdempotent() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let admission = try #require(
            disposer.acquireGraphAdmission(waitingUpTo: 0.1))
        let mutation = AggregateRateMutationOwner(
            ownsAggregate: false,
            destroyAggregate: { _ in .destroyed },
            restore: { _, _ in [] })
        mutation.recordOriginal(uid: "microphone", rate: 96_000)
        let owner = EchoCancellationPartialConstructionOwner(
            mutation: mutation, admission: admission)
        let context = AudioUnitConstructionContext(
            deadline: HALTeardownDeadline(timeout: 1))
        context.cancel()

        owner.retainOnce(afterCancellationIn: context)
        owner.retainOnce(afterCancellationIn: context)

        #expect(context.retainedOwnerCount == 1)
        #expect(owner.hasTeardownWork)
        #expect(disposer.acquireGraphAdmission(waitingUpTo: 0) == nil)
    }
}
