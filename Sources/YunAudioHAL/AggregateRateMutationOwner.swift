import Foundation

/// Owns the two system mutations needed by a temporary aggregate as one transaction.
///
/// Restoring a physical member while its aggregate still exists asks HAL to reconcile
/// two conflicting clocks. Early graph-construction failures used to do exactly that:
/// the local rate defer ran before the aggregate's deinitialiser had even submitted
/// destruction. This owner makes the only safe order executable and testable:
/// aggregate absence first, then restoration of every physical sample rate.
package final class AggregateRateMutationOwner: @unchecked Sendable {
    typealias Destroy = (HALTeardownDeadline) -> HALDestructionResult
    typealias Restore = ([String: Double], HALTeardownDeadline) -> [String]

    private let lock = NSLock()
    private var aggregateOwner: AnyObject?
    private var destroyAggregate: Destroy?
    private var originalRates: [String: Double] = [:]
    private var cleanupIsRunning = false
    private var cleanupWasQuarantined = false
    private let restore: Restore

    package init() {
        restore = { rates, deadline in
            AggregateDevice.restoreSampleRates(rates, until: deadline)
        }
    }

    /// Injectable owner used to prove ordering without creating a HAL object.
    init(
        ownsAggregate: Bool,
        destroyAggregate: @escaping Destroy,
        restore: @escaping Restore
    ) {
        aggregateOwner = ownsAggregate ? NSObject() : nil
        self.destroyAggregate = ownsAggregate ? destroyAggregate : nil
        self.restore = restore
    }

    /// Publishes the undo value before the setter which may mutate and then time out.
    package func recordOriginal(uid: String, rate: Double) {
        lock.withLock {
            if originalRates[uid] == nil { originalRates[uid] = rate }
        }
    }

    /// Takes ownership immediately after creation, before the next cancellation check.
    package func adopt(_ aggregate: AggregateDevice) {
        lock.withLock {
            precondition(aggregateOwner == nil && destroyAggregate == nil)
            aggregateOwner = aggregate
            destroyAggregate = { deadline in
                aggregate.destroyAndWait(until: deadline)
            }
        }
    }

    /// Transfers the aggregate and rate restoration to the fully built capture.
    package func relinquish() {
        let released: AnyObject? = lock.withLock {
            precondition(!cleanupIsRunning)
            let owner = aggregateOwner
            aggregateOwner = nil
            destroyAggregate = nil
            originalRates.removeAll()
            return owner
        }
        withExtendedLifetime(released) {}
    }

    /// Performs one ordered cleanup attempt against a single absolute deadline.
    ///
    /// A concurrent retry is refused. One synchronous HAL call cannot be cancelled;
    /// admitting another attempt beside it would reproduce the blocked-thread storm
    /// this owner exists to prevent.
    package func cleanUp(until deadline: HALTeardownDeadline) -> Bool {
        let selection: (admitted: Bool, destruction: Destroy?) = lock.withLock {
            guard !cleanupIsRunning else { return (false, nil) }
            cleanupIsRunning = true
            return (true, destroyAggregate)
        }
        guard selection.admitted else { return false }
        defer { lock.withLock { cleanupIsRunning = false } }

        if lock.withLock({ aggregateOwner != nil }) {
            guard
                let destruction = selection.destruction,
                destruction(deadline) == .destroyed
            else {
                return false
            }
            let released: AnyObject? = lock.withLock {
                let owner = aggregateOwner
                aggregateOwner = nil
                destroyAggregate = nil
                return owner
            }
            withExtendedLifetime(released) {}
        }

        let rates = lock.withLock { originalRates }
        guard !rates.isEmpty else { return true }
        let stubborn = Set(restore(rates, deadline))
        lock.withLock {
            originalRates = originalRates.filter { stubborn.contains($0.key) }
        }
        return stubborn.isEmpty
    }

    /// Schedules finite retries on HAL's one existing cleanup owner.
    ///
    /// The quarantine entry is installed before the first asynchronous attempt,
    /// so a failed constructor cannot race a fallback route into the same server.
    package func quarantineForCleanup() {
        let shouldSchedule = lock.withLock { () -> Bool in
            guard !cleanupWasQuarantined else { return false }
            cleanupWasQuarantined = true
            return true
        }
        guard shouldSchedule else { return }
        BoundedHALDeinitCleanup.quarantine(
            reason: "echo-cancellation aggregate and sample-rate cleanup"
        ) { [self] in
            cleanUp(until: HALTeardownDeadline(timeout: 2))
        }
    }

    var remainingRateCount: Int { lock.withLock { originalRates.count } }
    var ownsAggregate: Bool { lock.withLock { aggregateOwner != nil } }
    package var hasPendingOwnership: Bool {
        lock.withLock { aggregateOwner != nil || !originalRates.isEmpty }
    }
}
