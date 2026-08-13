import Foundation
import Testing

@testable import YunAudioApp

private final class SystemQueryTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private final class VirtualSystemQueryDeadlineScheduler: @unchecked Sendable {
    private struct Entry {
        let duration: Duration
        let operation: @Sendable () -> Void
        var isCancelled = false
    }

    private let lock = NSLock()
    private var nextID = 0
    private var entries: [Int: Entry] = [:]

    var scheduler: SystemQueryDeadlineScheduler {
        SystemQueryDeadlineScheduler { [self] duration, operation in
            let id = lock.withLock {
                nextID += 1
                entries[nextID] = Entry(duration: duration, operation: operation)
                return nextID
            }
            return SystemQueryDeadlineHandle { [weak self] in self?.cancel(id) }
        }
    }

    var scheduledIDs: [Int] { lock.withLock { entries.keys.sorted() } }

    func duration(for id: Int) -> Duration? { lock.withLock { entries[id]?.duration } }

    /// May deliberately repeat a callback to prove the lane, not the timer, owns
    /// exact-once arbitration. `includingCancelled` models a callback which won
    /// the cancellation race immediately before invalidation.
    func fire(_ id: Int, includingCancelled: Bool = false) {
        let operation: (@Sendable () -> Void)? = lock.withLock {
            guard let entry = entries[id], includingCancelled || !entry.isCancelled else {
                return nil
            }
            return entry.operation
        }
        operation?()
    }

    private func cancel(_ id: Int) {
        lock.withLock { entries[id]?.isCancelled = true }
    }
}

private final class VirtualMainActorDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@MainActor @Sendable () -> Void] = []

    func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { operations.append(operation) }
    }

    var count: Int { lock.withLock { operations.count } }

    @MainActor
    func runNext() {
        let operation: (@MainActor @Sendable () -> Void)? = lock.withLock {
            guard !operations.isEmpty else { return nil }
            return operations.removeFirst()
        }
        operation?()
    }

    @MainActor
    func runAll() {
        while count > 0 { runNext() }
    }

    @MainActor
    func runNextTwice() {
        let operation: (@MainActor @Sendable () -> Void)? = lock.withLock {
            guard !operations.isEmpty else { return nil }
            return operations.removeFirst()
        }
        operation?()
        operation?()
    }
}

private enum SystemQueryTestFailure: Error {
    case timedOut
}

private func waitForSystemQuery(
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    for _ in 0..<2_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw SystemQueryTestFailure.timedOut
}

private enum SystemQueryTestResponse: Equatable, Sendable {
    case value(Int)
    case deadline(Int)
}

@Suite("Bounded system query lane", .serialized)
struct BoundedSystemQueryLaneTests {
    @MainActor
    @Test("admission preserves the first request and one latest request")
    func firstAndLatestAreDeterministicBeforeTheQueueRuns() async throws {
        let queue = DispatchQueue(label: "yunaudio.test.system-query.first-latest")
        let queueRelease = DispatchSemaphore(value: 0)
        defer { queueRelease.signal() }
        queue.async { queueRelease.wait() }
        let deadlines = VirtualSystemQueryDeadlineScheduler()
        let deliveries = VirtualMainActorDelivery()
        let applied = SystemQueryTestBox<[Int]>([])
        var published: [Int] = []
        let lane = BoundedSystemQueryLane<Int, Int>(
            subsystem: .applicationInventory,
            queue: queue,
            timeout: .seconds(1),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, _ in
                applied.update { $0.append(value) }
                return value
            },
            deadlineResponse: { _ in -1 },
            publish: { published.append($0) })

        #expect(lane.submit(1))
        #expect(lane.submit(2))
        #expect(lane.submit(3))
        #expect(lane.statistics.applications == 0)
        #expect(lane.statistics.activeRequests == 1)
        #expect(lane.statistics.pendingRequests == 1)
        #expect(lane.statistics.maximumPending == 1)
        queueRelease.signal()

        try await waitForSystemQuery { deliveries.count == 1 }
        deliveries.runAll()
        #expect(applied.read() == [1, 3])
        #expect(published == [3])
        #expect(lane.statistics.submissions == 3)
        #expect(lane.statistics.coalesced == 1)
        #expect(lane.statistics.applications == 2)
        #expect(lane.statistics.revokedResults == 2)
        #expect(lane.statistics.maximumConcurrentApplications == 1)
        #expect(lane.statistics.activeRequests == 0)
    }

    @MainActor
    @Test("ten thousand submissions retain one active and one pending request")
    func saturationCannotCreateAReplacementOwner() async throws {
        let deadlines = VirtualSystemQueryDeadlineScheduler()
        let deliveries = VirtualMainActorDelivery()
        let began = SystemQueryTestBox(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let applied = SystemQueryTestBox<[Int]>([])
        var published: [Int] = []
        let lane = BoundedSystemQueryLane<Int, Int>(
            subsystem: .deviceInventory,
            queue: DispatchQueue(label: "yunaudio.test.system-query.saturation"),
            timeout: .seconds(1),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, _ in
                applied.update { $0.append(value) }
                if value == 0 {
                    began.update { $0 = true }
                    release.wait()
                }
                return value
            },
            deadlineResponse: { _ in -1 },
            publish: { published.append($0) })

        #expect(lane.submit(0))
        try await waitForSystemQuery { began.read() }
        for value in 1..<10_000 { #expect(lane.submit(value)) }

        #expect(lane.statistics.submissions == 10_000)
        #expect(lane.statistics.coalesced == 9_998)
        #expect(lane.statistics.applications == 1)
        #expect(lane.statistics.activeRequests == 1)
        #expect(lane.statistics.pendingRequests == 1)
        #expect(lane.statistics.maximumPending == 1)
        #expect(lane.statistics.maximumConcurrentApplications == 1)

        release.signal()
        try await waitForSystemQuery { deliveries.count == 1 }
        deliveries.runAll()
        #expect(applied.read() == [0, 9_999])
        #expect(published == [9_999])
        #expect(lane.statistics.applications == 2)
        #expect(lane.statistics.maximumConcurrentApplications == 1)
        #expect(lane.statistics.revokedResults == 9_999)
    }

    @MainActor
    @Test("a deadline publishes exactly once and quarantines the late return")
    func deadlineAndReturnHaveOneWinner() async throws {
        let deadlines = VirtualSystemQueryDeadlineScheduler()
        let deliveries = VirtualMainActorDelivery()
        let began = SystemQueryTestBox(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let continued = SystemQueryTestBox<Bool?>(nil)
        let applied = SystemQueryTestBox<[Int]>([])
        let deadlineResponses = SystemQueryTestBox(0)
        var published: [SystemQueryTestResponse] = []
        let lane = BoundedSystemQueryLane<Int, SystemQueryTestResponse>(
            subsystem: .hardwareRead,
            queue: DispatchQueue(label: "yunaudio.test.system-query.deadline"),
            timeout: .milliseconds(250),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, context in
                applied.update { $0.append(value) }
                if value == 1 {
                    began.update { $0 = true }
                    release.wait()
                    continued.update { $0 = context.shouldContinue }
                }
                return .value(value)
            },
            deadlineResponse: { value in
                deadlineResponses.update { $0 += 1 }
                return .deadline(value)
            },
            publish: { published.append($0) })

        #expect(lane.submit(1))
        try await waitForSystemQuery { began.read() && deadlines.scheduledIDs.count == 1 }
        let deadlineID = try #require(deadlines.scheduledIDs.first)
        #expect(deadlines.duration(for: deadlineID) == .milliseconds(250))
        deadlines.fire(deadlineID)
        deadlines.fire(deadlineID)

        #expect(lane.statistics.deadlineExpirations == 1)
        #expect(lane.statistics.quarantinedRequests == 1)
        #expect(lane.statistics.maximumQuarantinedApplications == 1)
        #expect(lane.statistics.applications == 1)
        #expect(deliveries.count == 1)
        deliveries.runNextTwice()
        #expect(published == [.deadline(1)])
        #expect(deadlineResponses.read() == 1)
        #expect(lane.statistics.publications == 1)
        #expect(lane.statistics.duplicateDeliveries == 1)

        #expect(!lane.submit(2))
        #expect(lane.statistics.applications == 1)
        #expect(lane.statistics.pendingRequests == 0)
        #expect(lane.statistics.rejectedSubmissions == 1)
        release.signal()
        try await waitForSystemQuery { lane.statistics.activeRequests == 0 }
        #expect(lane.submit(2))
        try await waitForSystemQuery { deliveries.count == 1 }
        deliveries.runAll()

        #expect(continued.read() == false)
        #expect(applied.read() == [1, 2])
        #expect(published == [.deadline(1), .value(2)])
        #expect(lane.statistics.quarantinedReturns == 1)
        #expect(lane.statistics.applications == 2)
        #expect(lane.statistics.publications == 2)
        #expect(lane.statistics.maximumConcurrentApplications == 1)
    }

    @MainActor
    @Test("a returned answer cancels its deadline before publication")
    func returnBeforeDeadlineCannotPublishFallback() async throws {
        let deadlines = VirtualSystemQueryDeadlineScheduler()
        let deliveries = VirtualMainActorDelivery()
        var published: [SystemQueryTestResponse] = []
        let lane = BoundedSystemQueryLane<Int, SystemQueryTestResponse>(
            subsystem: .hardwareRead,
            timeout: .milliseconds(250),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, _ in .value(value) },
            deadlineResponse: { .deadline($0) },
            publish: { published.append($0) })

        #expect(lane.submit(4))
        try await waitForSystemQuery {
            deliveries.count == 1 && deadlines.scheduledIDs.count == 1
        }
        let deadlineID = try #require(deadlines.scheduledIDs.first)
        deadlines.fire(deadlineID, includingCancelled: true)
        deliveries.runAll()

        #expect(published == [.value(4)])
        #expect(lane.statistics.applications == 1)
        #expect(lane.statistics.deadlineExpirations == 0)
        #expect(lane.statistics.quarantinedReturns == 0)
        #expect(lane.statistics.publications == 1)
    }

    @MainActor
    @Test("a blocked owner fails the latest waiter without starting replacement work")
    func deadlineFailsLatestPendingIntentAndRejectsQuarantineAdmission() async throws {
        let deadlines = VirtualSystemQueryDeadlineScheduler()
        let deliveries = VirtualMainActorDelivery()
        let began = SystemQueryTestBox(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let applied = SystemQueryTestBox<[Int]>([])
        var published: [SystemQueryTestResponse] = []
        let lane = BoundedSystemQueryLane<Int, SystemQueryTestResponse>(
            subsystem: .deviceHydration,
            queue: DispatchQueue(label: "yunaudio.test.system-query.pending-deadline"),
            timeout: .seconds(1),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, _ in
                applied.update { $0.append(value) }
                if value == 1 {
                    began.update { $0 = true }
                    release.wait()
                }
                return .value(value)
            },
            deadlineResponse: { .deadline($0) },
            publish: { published.append($0) })

        #expect(lane.submit(1))
        try await waitForSystemQuery { began.read() && deadlines.scheduledIDs.count == 1 }
        #expect(lane.invalidate())
        #expect(lane.submit(2))
        let deadlineID = try #require(deadlines.scheduledIDs.first)
        deadlines.fire(deadlineID)

        #expect(lane.statistics.applications == 1)
        #expect(lane.statistics.activeRequests == 1)
        #expect(lane.statistics.pendingRequests == 0)
        #expect(lane.statistics.quarantinedRequests == 1)
        deliveries.runAll()
        #expect(published == [.deadline(2)])
        #expect(applied.read() == [1])

        #expect(!lane.submit(3))
        #expect(lane.statistics.applications == 1)
        #expect(lane.statistics.pendingRequests == 0)
        #expect(lane.statistics.rejectedSubmissions == 1)
        release.signal()
        try await waitForSystemQuery { lane.statistics.activeRequests == 0 }
        #expect(lane.submit(4))
        try await waitForSystemQuery { deliveries.count == 1 }
        deliveries.runAll()
        #expect(applied.read() == [1, 4])
        #expect(published == [.deadline(2), .value(4)])
        #expect(lane.statistics.invalidations == 1)
        #expect(lane.statistics.maximumConcurrentApplications == 1)
        #expect(lane.statistics.quarantinedReturns == 1)
    }

    @MainActor
    @Test("generation revocation defeats a late return and a cancelled deadline race")
    func invalidationRevokesLateWorkButKeepsAdmissionOpen() async throws {
        let deadlines = VirtualSystemQueryDeadlineScheduler()
        let deliveries = VirtualMainActorDelivery()
        let began = SystemQueryTestBox(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let continued = SystemQueryTestBox<Bool?>(nil)
        var published: [Int] = []
        let lane = BoundedSystemQueryLane<Int, Int>(
            subsystem: .deviceHydration,
            queue: DispatchQueue(label: "yunaudio.test.system-query.revoke"),
            timeout: .milliseconds(250),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, context in
                if value == 1 {
                    began.update { $0 = true }
                    release.wait()
                    continued.update { $0 = context.shouldContinue }
                }
                return value
            },
            deadlineResponse: { _ in -1 },
            publish: { published.append($0) })

        #expect(lane.submit(1))
        try await waitForSystemQuery { began.read() && deadlines.scheduledIDs.count == 1 }
        let oldDeadline = try #require(deadlines.scheduledIDs.first)
        #expect(lane.invalidate())
        #expect(lane.submit(2))
        release.signal()
        try await waitForSystemQuery { deliveries.count == 1 }
        deadlines.fire(oldDeadline, includingCancelled: true)
        #expect(lane.statistics.deadlineExpirations == 0)
        deliveries.runAll()
        #expect(continued.read() == false)
        #expect(published == [2])
        #expect(lane.statistics.invalidations == 1)
        #expect(lane.statistics.revokedResults == 1)
        #expect(lane.statistics.maximumConcurrentApplications == 1)
    }

    @MainActor
    @Test("capture cancellation clears busy state one turn before a blocked return")
    func cancellationNotificationDoesNotWaitOrStartTheEngine() async throws {
        let deadlines = VirtualSystemQueryDeadlineScheduler()
        let deliveries = VirtualMainActorDelivery()
        let began = SystemQueryTestBox(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let context = SystemQueryTestBox<BoundedSystemQueryLane<Int, Int>.Context?>(nil)
        var isBusy = true
        var isStarting = true
        var engineStarts = 0
        let lane = BoundedSystemQueryLane<Int, Int>(
            subsystem: .captureResolution,
            queue: DispatchQueue(label: "yunaudio.test.system-query.capture-stop"),
            timeout: .seconds(1),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, queryContext in
                context.update { $0 = queryContext }
                began.update { $0 = true }
                release.wait()
                return value
            },
            deadlineResponse: { _ in -1 },
            publish: { _ in engineStarts += 1 })

        #expect(lane.submit(1))
        try await waitForSystemQuery { began.read() }
        #expect(context.read()?.shouldContinue == true)
        let notification: @MainActor @Sendable () -> Void = {
            isBusy = false
            isStarting = false
        }
        let invalidated = lane.invalidate(notifying: notification)
        #expect(invalidated)
        #expect(context.read()?.shouldContinue == false)
        #expect(isBusy)
        #expect(isStarting)
        #expect(deliveries.count == 1)

        deliveries.runNext()
        #expect(!isBusy)
        #expect(!isStarting)
        #expect(engineStarts == 0)
        #expect(lane.statistics.activeRequests == 1)

        release.signal()
        try await waitForSystemQuery { lane.statistics.activeRequests == 0 }
        deliveries.runAll()
        #expect(engineStarts == 0)
        #expect(lane.statistics.publications == 0)
    }

    @MainActor
    @Test("invalidation drops one pending request behind the active owner")
    func invalidationClearsThePendingSlotSynchronously() async throws {
        let deadlines = VirtualSystemQueryDeadlineScheduler()
        let deliveries = VirtualMainActorDelivery()
        let began = SystemQueryTestBox(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let applied = SystemQueryTestBox<[Int]>([])
        let lane = BoundedSystemQueryLane<Int, Int>(
            subsystem: .deviceInventory,
            timeout: .seconds(1),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, _ in
                applied.update { $0.append(value) }
                if value == 1 {
                    began.update { $0 = true }
                    release.wait()
                }
                return value
            },
            deadlineResponse: { _ in -1 },
            publish: { _ in })

        #expect(lane.submit(1))
        try await waitForSystemQuery { began.read() }
        #expect(lane.submit(2))
        #expect(lane.statistics.pendingRequests == 1)
        #expect(lane.invalidate())
        #expect(lane.statistics.pendingRequests == 0)
        #expect(lane.statistics.revokedResults == 1)
        release.signal()
        try await waitForSystemQuery { lane.statistics.activeRequests == 0 }

        #expect(applied.read() == [1])
        #expect(deliveries.count == 0)
        #expect(lane.statistics.revokedResults == 2)
    }

    @MainActor
    @Test("shutdown closes admission synchronously without joining the owner")
    func shutdownDoesNotWaitForAnEnteredSystemCall() async throws {
        let deadlines = VirtualSystemQueryDeadlineScheduler()
        let deliveries = VirtualMainActorDelivery()
        let began = SystemQueryTestBox(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let context = SystemQueryTestBox<BoundedSystemQueryLane<Int, Int>.Context?>(nil)
        let lane = BoundedSystemQueryLane<Int, Int>(
            subsystem: .hardwareWrite,
            queue: DispatchQueue(label: "yunaudio.test.system-query.shutdown"),
            timeout: .seconds(1),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, queryContext in
                context.update { $0 = queryContext }
                began.update { $0 = true }
                release.wait()
                return value
            },
            deadlineResponse: { _ in -1 },
            publish: { _ in })

        #expect(lane.submit(1))
        try await waitForSystemQuery { began.read() }
        #expect(lane.shutdown())
        #expect(context.read()?.shouldContinue == false)
        #expect(lane.statistics.activeRequests == 1)
        #expect(!lane.submit(2))
        #expect(!lane.shutdown())
        #expect(lane.statistics.shutdowns == 1)
        #expect(lane.statistics.rejectedSubmissions == 1)

        release.signal()
        try await waitForSystemQuery { lane.statistics.activeRequests == 0 }
        deliveries.runAll()
        #expect(lane.statistics.publications == 0)
        #expect(lane.statistics.revokedResults == 1)
    }

    @MainActor
    @Test("shutdown drops an admitted query which has not entered the service")
    func queuedQueryIsRevokedBeforeApplicationBegins() async throws {
        let queue = DispatchQueue(label: "yunaudio.test.system-query.queued-shutdown")
        let queueRelease = DispatchSemaphore(value: 0)
        defer { queueRelease.signal() }
        let queueTail = SystemQueryTestBox(false)
        queue.async { queueRelease.wait() }
        let deadlines = VirtualSystemQueryDeadlineScheduler()
        let deliveries = VirtualMainActorDelivery()
        let applications = SystemQueryTestBox(0)
        let lane = BoundedSystemQueryLane<Int, Int>(
            subsystem: .applicationInventory,
            queue: queue,
            timeout: .seconds(1),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, _ in
                applications.update { $0 += 1 }
                return value
            },
            deadlineResponse: { _ in -1 },
            publish: { _ in })

        #expect(lane.submit(1))
        #expect(lane.statistics.activeRequests == 1)
        #expect(lane.shutdown())
        #expect(lane.statistics.activeRequests == 0)
        queue.async { queueTail.update { $0 = true } }
        queueRelease.signal()
        try await waitForSystemQuery { queueTail.read() }

        #expect(applications.read() == 0)
        #expect(deadlines.scheduledIDs.isEmpty)
        #expect(deliveries.count == 0)
        #expect(lane.statistics.applications == 0)
        #expect(lane.statistics.revokedResults == 1)
    }

    @MainActor
    @Test("a blocked subsystem cannot starve another subsystem")
    func subsystemQueuesAreIsolated() async throws {
        let labels = SystemQuerySubsystem.allCases.map(\.queueLabel)
        #expect(labels.count == 7)
        #expect(Set(labels).count == 7)
        #expect(SystemQuerySubsystem.captureResolution.defaultTimeout == .milliseconds(250))
        #expect(SystemQuerySubsystem.applicationInventory.defaultTimeout == .seconds(1))
        #expect(SystemQuerySubsystem.deviceInventory.defaultTimeout == .seconds(1))
        #expect(SystemQuerySubsystem.deviceHydration.defaultTimeout == .seconds(1))
        #expect(SystemQuerySubsystem.hardwareRead.defaultTimeout == .milliseconds(250))
        #expect(SystemQuerySubsystem.hardwareWrite.defaultTimeout == .milliseconds(250))
        #expect(SystemQuerySubsystem.diagnostics.defaultTimeout == .seconds(2))

        let deadlines = VirtualSystemQueryDeadlineScheduler()
        let deliveries = VirtualMainActorDelivery()
        let captureBegan = SystemQueryTestBox(false)
        let captureRelease = DispatchSemaphore(value: 0)
        defer { captureRelease.signal() }
        var diagnosticPublications = 0
        let capture = BoundedSystemQueryLane<Int, Int>(
            subsystem: .captureResolution,
            timeout: .seconds(1),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, _ in
                captureBegan.update { $0 = true }
                captureRelease.wait()
                return value
            },
            deadlineResponse: { _ in -1 },
            publish: { _ in })
        let diagnostics = BoundedSystemQueryLane<Int, Int>(
            subsystem: .diagnostics,
            timeout: .seconds(1),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: deliveries.schedule,
            apply: { value, _ in value },
            deadlineResponse: { _ in -1 },
            publish: { _ in diagnosticPublications += 1 })

        #expect(capture.submit(1))
        try await waitForSystemQuery { captureBegan.read() }
        #expect(diagnostics.submit(2))
        try await waitForSystemQuery { deliveries.count == 1 }
        deliveries.runAll()

        #expect(diagnosticPublications == 1)
        #expect(capture.statistics.activeRequests == 1)
        #expect(capture.statistics.applications == 1)
        #expect(diagnostics.statistics.applications == 1)
        #expect(diagnostics.statistics.publications == 1)
        #expect(diagnostics.statistics.maximumConcurrentApplications == 1)

        #expect(capture.invalidate())
        captureRelease.signal()
        try await waitForSystemQuery { capture.statistics.activeRequests == 0 }
        deliveries.runAll()
        #expect(capture.statistics.publications == 0)
    }
}
