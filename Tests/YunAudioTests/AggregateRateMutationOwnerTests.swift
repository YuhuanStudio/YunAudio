import Foundation
import Testing

@testable import YunAudioEngine
@testable import YunAudioHAL

@Suite("Aggregate and sample-rate construction ownership")
struct AggregateRateMutationOwnerTests {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ value: String) { lock.withLock { storage.append(value) } }
        var values: [String] { lock.withLock { storage } }
    }

    @Test("an aggregate is absent before any physical rate is restored")
    func aggregatePrecedesRateRestoration() {
        let trace = Trace()
        let owner = AggregateRateMutationOwner(
            ownsAggregate: true,
            destroyAggregate: { _ in
                trace.append("destroy")
                return .destroyed
            },
            restore: { rates, _ in
                trace.append("restore:\(rates.count)")
                return []
            })
        owner.recordOriginal(uid: "microphone", rate: 96_000)
        owner.recordOriginal(uid: "speaker", rate: 44_100)

        #expect(owner.cleanUp(until: HALTeardownDeadline(timeout: 1)))
        #expect(trace.values == ["destroy", "restore:2"])
        #expect(!owner.ownsAggregate)
        #expect(owner.remainingRateCount == 0)
    }

    @Test("a failed aggregate census never starts sample-rate restoration")
    func failedDestructionRetainsEverything() {
        let trace = Trace()
        let owner = AggregateRateMutationOwner(
            ownsAggregate: true,
            destroyAggregate: { _ in
                trace.append("destroy")
                return .timedOut
            },
            restore: { _, _ in
                trace.append("restore")
                return []
            })
        owner.recordOriginal(uid: "microphone", rate: 96_000)

        #expect(!owner.cleanUp(until: HALTeardownDeadline(timeout: 1)))
        #expect(trace.values == ["destroy"])
        #expect(owner.ownsAggregate)
        #expect(owner.remainingRateCount == 1)
    }

    @Test("a stubborn rate remains journalled for one later retry")
    func retryKeepsOnlyStubbornRates() {
        let trace = Trace()
        let attempts = LockedAttemptCount()
        let owner = AggregateRateMutationOwner(
            ownsAggregate: false,
            destroyAggregate: { _ in
                Issue.record("rate-only cleanup tried to destroy an aggregate")
                return .destroyed
            },
            restore: { rates, _ in
                let attempt = attempts.take()
                trace.append("restore:\(rates.keys.sorted().joined(separator: ","))")
                return attempt == 1 ? ["speaker"] : []
            })
        owner.recordOriginal(uid: "microphone", rate: 96_000)
        owner.recordOriginal(uid: "speaker", rate: 44_100)

        #expect(!owner.cleanUp(until: HALTeardownDeadline(timeout: 1)))
        #expect(owner.remainingRateCount == 1)
        #expect(owner.cleanUp(until: HALTeardownDeadline(timeout: 1)))
        #expect(
            trace.values == [
                "restore:microphone,speaker",
                "restore:speaker",
            ])
        #expect(owner.remainingRateCount == 0)
    }

    @Test("a timed-out constructor cleans only after its blocking call returns")
    func cancelledConstructionDefersCleanupToItsOwnWorker() {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let lane = BoundedAudioUnitConstructionLane(
            quarantine: quarantine,
            label: "com.yuhuanstudio.yunaudio.tests.partial-mutation")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let trace = Trace()

        let result: AudioUnitLaneResult<Int> = lane.perform(timeout: 0.02) { context in
            let registration = context.deferCleanupAfterCancellation {
                trace.append("cleanup")
                cleaned.signal()
            }
            #expect(registration != nil)
            entered.signal()
            release.wait()
            trace.append("returned")
            return 1
        }

        #expect(entered.wait(timeout: .now()) == .success)
        if case .timedOut = result {
            #expect(true)
        } else {
            Issue.record("constructor escaped its deadline")
        }
        #expect(cleaned.wait(timeout: .now() + 0.02) == .timedOut)
        release.signal()
        #expect(cleaned.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(trace.values == ["returned", "cleanup"])
        #expect(quarantine.count == 1)
    }

    @Test("resource observation names every irreversible construction boundary")
    func constructionResourceObservationIsExact() {
        let observed = Trace()
        let context = AudioUnitConstructionContext(
            deadline: HALTeardownDeadline(timeout: 1),
            observeResource: { value in observed.append(String(describing: value)) })

        for value in [
            AudioUnitConstructionResource.processTap,
            .changedSampleRate,
            .aggregate,
            .audioUnit,
            .echoCancellation,
        ] {
            context.record(value)
        }
        #expect(
            observed.values
                == [
                    "processTap", "changedSampleRate", "aggregate", "audioUnit",
                    "echoCancellation",
                ]
        )
    }

    private final class LockedAttemptCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func take() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }
}
