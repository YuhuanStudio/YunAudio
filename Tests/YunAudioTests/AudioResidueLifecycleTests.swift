import Foundation
import Testing
@testable import YunAudioHAL

@Suite("Process-lifetime audio residue", .serialized)
struct AudioResidueLifecycleTests {
    @Test("failed cleanup has three calls, two exact delays and one retained owner")
    func retryBudgetIsFinite() throws {
        let quarantine = ProcessLifetimeAudioQuarantine(
            retryPolicy: AudioResidueRetryPolicy(delays: [0.125, 0.5]))
        let scheduler = ManualResidueScheduler()
        let calls = LockedCounter()

        BoundedHALDeinitCleanup.quarantine(
            in: quarantine,
            scheduler: scheduler.schedule,
            reason: "injected permanent residue"
        ) {
            calls.increment()
            return false
        }

        #expect(quarantine.telemetry.retainedEntries == 1)
        #expect(quarantine.telemetry.maximumRetainedEntries == 1)
        #expect(quarantine.telemetry.scheduledRetries == 1)
        #expect(quarantine.telemetry.maximumAttemptsPerEntry == 3)
        #expect(quarantine.telemetry.maximumRetryDelay == 0.5)
        let refusal = try #require(quarantine.refusalForNewAudioOwnership())
        #expect(refusal.retainedEntries == 1)
        #expect(refusal.deniedAdmissions == 1)

        #expect(try scheduler.runNext() == 0)
        #expect(try scheduler.runNext() == 0.125)
        #expect(try scheduler.runNext() == 0.5)
        #expect(scheduler.pendingCount == 0)

        let telemetry = quarantine.telemetry
        #expect(calls.value == 3)
        #expect(telemetry.cleanupAttempts == 3)
        #expect(telemetry.retainedEntries == 1)
        #expect(telemetry.maximumRetainedEntries == 1)
        #expect(telemetry.scheduledRetries == 0)
        #expect(telemetry.exhaustedEntries == 1)
        #expect(telemetry.completedEntries == 0)
        #expect(telemetry.deniedAdmissions == 1)

        // Repeated starts see the same process-owned residue. They do not add a
        // cleanup job, reset its budget or grow the retained set.
        for _ in 0..<100 {
            #expect(quarantine.refusalForNewAudioOwnership() != nil)
        }
        #expect(quarantine.telemetry.maximumRetainedEntries == 1)
        #expect(quarantine.telemetry.cleanupAttempts == 3)
        #expect(quarantine.telemetry.deniedAdmissions == 101)
    }

    @Test("a later successful census releases ownership and reopens admission")
    func successfulRetryReopensAdmission() throws {
        let quarantine = ProcessLifetimeAudioQuarantine(
            retryPolicy: AudioResidueRetryPolicy(delays: [0.25, 1, 4]))
        let scheduler = ManualResidueScheduler()
        let calls = LockedCounter()

        BoundedHALDeinitCleanup.quarantine(
            in: quarantine,
            scheduler: scheduler.schedule,
            reason: "injected transient residue"
        ) {
            calls.increment()
            return calls.value == 3
        }

        #expect(quarantine.telemetry.maximumAttemptsPerEntry == 4)
        #expect(quarantine.telemetry.maximumRetryDelay == 4)

        #expect(try scheduler.runNext() == 0)
        #expect(try scheduler.runNext() == 0.25)
        #expect(try scheduler.runNext() == 1)
        #expect(scheduler.pendingCount == 0)

        let telemetry = quarantine.telemetry
        #expect(telemetry.cleanupAttempts == 3)
        #expect(telemetry.completedEntries == 1)
        #expect(telemetry.retainedEntries == 0)
        #expect(telemetry.exhaustedEntries == 0)
        #expect(telemetry.maximumRetainedEntries == 1)
        #expect(telemetry.admitsNewAudioOwnership)
        #expect(quarantine.refusalForNewAudioOwnership() == nil)
    }

    @Test("a route rebuild waits only for the same transient cleanup owner")
    func transientCleanupCanFinishInsideOneBoundedAdmission() {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let token = quarantine.retain(NSObject(), reason: "injected transient owner")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
            quarantine.release(token)
        }

        // The claim is that the wait *blocks* until the transient owner lets go
        // and then succeeds — not that a background release lands within a
        // quarter of a second, which is a statement about the machine's
        // scheduler. Under three hundred parallel suites a 20 ms `asyncAfter`
        // routinely arrives later than that, and the assertion then reported
        // the load as a broken quarantine.
        //
        // The lower bound is the part that means something: it waited rather
        // than returning at once.
        let started = DispatchTime.now().uptimeNanoseconds
        #expect(quarantine.waitForNewAudioOwnership(timeout: TestGate.deadlockSeconds))
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        #expect(elapsed >= 10_000_000)
        #expect(quarantine.count == 0)

        let retained = quarantine.retain(NSObject(), reason: "injected permanent owner")
        let refusalStarted = DispatchTime.now().uptimeNanoseconds
        // This one keeps its short budget: nothing will release it, so the wait
        // must return on its own deadline rather than on somebody's scheduling.
        #expect(!quarantine.waitForNewAudioOwnership(timeout: 0.02))
        #expect(DispatchTime.now().uptimeNanoseconds - refusalStarted < 2_000_000_000)
        #expect(quarantine.count == 1)
        quarantine.release(retained)
    }

    @Test("an accepted asynchronous destroy is never resubmitted after a census timeout")
    func acceptedDestroyIsNotResubmitted() throws {
        let quarantine = ProcessLifetimeAudioQuarantine(
            retryPolicy: AudioResidueRetryPolicy(delays: [0.25, 1, 4]))
        let scheduler = ManualResidueScheduler()
        let requests = LockedCounter()
        let censuses = LockedCounter()
        let request = HALDestructionRequestCoordinator(requestWasAccepted: false)

        BoundedHALDeinitCleanup.quarantine(
            in: quarantine,
            scheduler: scheduler.schedule,
            reason: "injected accepted asynchronous destroy"
        ) {
            let status = request.request {
                requests.increment()
                return noErr
            }
            guard status == noErr else { return false }
            censuses.increment()
            return censuses.value == 3
        }

        #expect(try scheduler.runNext() == 0)
        #expect(try scheduler.runNext() == 0.25)
        #expect(try scheduler.runNext() == 1)
        #expect(requests.value == 1)
        #expect(censuses.value == 3)
        #expect(quarantine.telemetry.cleanupAttempts == 3)
        #expect(quarantine.telemetry.completedEntries == 1)
        #expect(quarantine.telemetry.retainedEntries == 0)
    }

    @Test("structural lint keeps residue admission before each route-owned HAL creation")
    func creationAdmissionPrecedesHAL() throws {
        // The executable acceptance is `retryBudgetIsFinite` and
        // `successfulRetryReopensAdmission` above. This source check only keeps
        // their fail-closed policy wired ahead of the three production creation
        // boundaries without touching live audio hardware.
        let root = PreferencesCompletenessTests.sourceRootForTests
        let routing = try String(
            contentsOfFile: root + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let processTap = try String(
            contentsOfFile: root + "Sources/YunAudioHAL/ProcessTap.swift",
            encoding: .utf8)
        let aggregate = try String(
            contentsOfFile: root + "Sources/YunAudioHAL/AggregateDevice.swift",
            encoding: .utf8)

        let start = try #require(routing.range(of: "private func startLocked("))
        let startEnd = try #require(
            routing.range(
                of: "private func startAttempt(",
                range: start.upperBound..<routing.endIndex))
        let startBody = routing[start.lowerBound..<startEnd.lowerBound]
        let attempt = try #require(startBody.range(of: "try startAttempt("))
        let routingAdmission = try #require(
            startBody.range(of: "refusalForNewAudioOwnership()"))
        #expect(routingAdmission.lowerBound < attempt.lowerBound)

        let tapInitialiser = try #require(
            processTap.range(of: "package init(\n        processIDs:"))
        let tapInitialiserEnd = try #require(
            processTap.range(
                of: "/// What the HAL is actually holding for this tap",
                range: tapInitialiser.upperBound..<processTap.endIndex))
        let tapBody = processTap[tapInitialiser.lowerBound..<tapInitialiserEnd.lowerBound]
        let tapCreate = try #require(
            tapBody.range(of: "var attempt = Self.create("))
        let tapAdmission = try #require(
            tapBody.range(of: "refusalForNewAudioOwnership()"))
        #expect(tapAdmission.lowerBound < tapCreate.lowerBound)

        let aggregateInitialiser = try #require(
            aggregate.range(of: "public init(\n        name:"))
        let aggregateInitialiserEnd = try #require(
            aggregate.range(
                of: "/// An aggregate whose only members are process taps.",
                range: aggregateInitialiser.upperBound..<aggregate.endIndex))
        let aggregateBody =
            aggregate[aggregateInitialiser.lowerBound..<aggregateInitialiserEnd.lowerBound]
        let aggregateCreate = try #require(
            aggregateBody.range(of: "id = try Self.createAggregate("))
        let aggregateAdmission = try #require(
            aggregateBody.range(of: "refusalForNewAudioOwnership()"))
        #expect(aggregateAdmission.lowerBound < aggregateCreate.lowerBound)

        let tapsOnlyInitialiser = try #require(
            aggregate.range(of: "private init(\n        name: String, taps:"))
        let tapsOnlyInitialiserEnd = try #require(
            aggregate.range(
                of: "private static func createAggregate(",
                range: tapsOnlyInitialiser.upperBound..<aggregate.endIndex))
        let tapsOnlyBody =
            aggregate[tapsOnlyInitialiser.lowerBound..<tapsOnlyInitialiserEnd.lowerBound]
        let tapsOnlyAdmission = try #require(
            tapsOnlyBody.range(of: "refusalForNewAudioOwnership()"))
        let tapsOnlyCreate = try #require(
            tapsOnlyBody.range(of: "id = try Self.createAggregate("))
        #expect(tapsOnlyAdmission.lowerBound < tapsOnlyCreate.lowerBound)
    }
}

private final class ManualResidueScheduler: @unchecked Sendable {
    private struct Scheduled {
        let delay: TimeInterval
        let operation: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var scheduled: [Scheduled] = []

    var schedule: BoundedHALDeinitCleanup.Scheduler {
        { [self] delay, operation in
            lock.withLock {
                scheduled.append(Scheduled(delay: delay, operation: operation))
            }
        }
    }

    var pendingCount: Int { lock.withLock { scheduled.count } }

    func runNext() throws -> TimeInterval {
        let next = try #require(
            lock.withLock {
                scheduled.isEmpty ? nil : scheduled.removeFirst()
            })
        next.operation()
        return next.delay
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }

    func increment() {
        lock.withLock { stored += 1 }
    }
}
