import Dispatch
import Foundation
import YunAudioHAL

/// Irreversible system ownership crossed by an unpublished graph constructor.
enum AudioUnitConstructionResource: Sendable, Equatable {
    case changedSampleRate
    case aggregate
    case processTap
    case audioUnit
    case echoCancellation
}

/// Revocable registration for cleanup which must wait behind one timed-out constructor.
final class AudioUnitConstructionCleanupRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private weak var context: AudioUnitConstructionContext?
    private let identifier: UInt64

    fileprivate init(context: AudioUnitConstructionContext, identifier: UInt64) {
        self.context = context
        self.identifier = identifier
    }

    /// The completed object has taken ownership, so construction cleanup must not run.
    func cancel() {
        let context = lock.withLock { () -> AudioUnitConstructionContext? in
            defer { self.context = nil }
            return self.context
        }
        context?.removeDeferredCleanup(identifier)
    }

}

/// A cancellation boundary shared with one unpublished Audio Unit constructor.
///
/// Core Audio cannot cancel a synchronous vendor call already in progress. The
/// context instead prevents work which has not begun from compounding an
/// overrun. The caller never receives a value after cancellation; the lane
/// retains the constructor stack, its partial graph and any late result.
final class AudioUnitConstructionContext: @unchecked Sendable {
    private static let maximumDeferredCleanups = 8

    private let lock = NSLock()
    let deadline: HALTeardownDeadline
    private var cancelled = false
    private var returnWasPublished = false
    private var retainedOwners: [AnyObject] = []
    private var nextCleanupIdentifier: UInt64 = 0
    private var deferredCleanups: [UInt64: @Sendable () -> Void] = [:]
    private let observeResource: @Sendable (AudioUnitConstructionResource) -> Void

    init(
        deadline: HALTeardownDeadline,
        observeResource: @escaping @Sendable (AudioUnitConstructionResource) -> Void = {
            _ in
        }
    ) {
        self.deadline = deadline
        self.observeResource = observeResource
    }

    var mayBeginOperation: Bool {
        lock.withLock { !cancelled && deadline.hasTimeRemaining }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    /// Claims timeout only while the constructor still owns publication.
    ///
    /// The construction lane uses this instead of a separate cancellation bit
    /// and transaction completion. Whichever side takes this lock first owns
    /// the result: a return prevents a later deadline from cleaning a published
    /// object, while a deadline prevents that returned object from escaping.
    fileprivate func claimTimeoutBeforeReturn() -> Bool {
        lock.withLock {
            guard !returnWasPublished, !cancelled else { return false }
            cancelled = true
            return true
        }
    }

    var hasBeenCancelled: Bool { lock.withLock { cancelled } }

    /// Keeps a partial graph alive beside the timed-out constructor.
    ///
    /// No cleanup is started from this boundary: the vendor call which crossed
    /// the deadline made ownership uncertain, and a second Core Audio call
    /// would compound the same fault. The construction transaction retains
    /// this context in process quarantine.
    func retainAfterCancellation(_ owner: AnyObject) {
        lock.withLock { retainedOwners.append(owner) }
    }

    /// Reserves cleanup on this same worker after an overrun has returned.
    ///
    /// Starting a second queue beside a synchronous Core Audio call which is still
    /// blocked is unsafe. A partial constructor registers its ordered cleanup before
    /// its first mutation; if the deadline expires, the construction worker invokes
    /// it only after the original call and the constructor stack have both returned.
    func deferCleanupAfterCancellation(
        _ cleanup: @escaping @Sendable () -> Void
    ) -> AudioUnitConstructionCleanupRegistration? {
        let identifier: UInt64? = lock.withLock {
            guard !cancelled,
                deferredCleanups.count < Self.maximumDeferredCleanups
            else { return nil }
            nextCleanupIdentifier &+= 1
            let identifier = nextCleanupIdentifier
            deferredCleanups[identifier] = cleanup
            return identifier
        }
        return identifier.map {
            AudioUnitConstructionCleanupRegistration(context: self, identifier: $0)
        }
    }

    fileprivate func removeDeferredCleanup(_ identifier: UInt64) {
        _ = lock.withLock { deferredCleanups.removeValue(forKey: identifier) }
    }

    /// Publishes return or claims the cleanup which a winning timeout reserved.
    ///
    /// This is called on the sole construction worker only after the complete
    /// constructor closure has returned. Cleanup can therefore never overlap
    /// the synchronous vendor call which caused the deadline to expire.
    fileprivate func publishReturnOrClaimDeferredCleanups() -> Bool {
        lock.withLock {
            guard !cancelled, deadline.hasTimeRemaining else {
                cancelled = true
                return false
            }
            returnWasPublished = true
            deferredCleanups.removeAll()
            return true
        }
    }

    /// Runs the cleanup claimed by a timed-out return, exactly once.
    fileprivate func runDeferredCleanupsAfterTimedOutReturn() {
        let cleanups: [@Sendable () -> Void] = lock.withLock {
            guard cancelled, !returnWasPublished else { return [] }
            let cleanups = deferredCleanups.keys.sorted().compactMap {
                deferredCleanups[$0]
            }
            deferredCleanups.removeAll()
            return cleanups
        }
        for cleanup in cleanups { cleanup() }
    }

    var retainedOwnerCount: Int { lock.withLock { retainedOwners.count } }

    /// Records an owner at the boundary where it becomes real, including late work.
    func record(_ resource: AudioUnitConstructionResource) {
        observeResource(resource)
    }
}

/// Starts one construction operation only while both cancellation and the
/// shared monotonic deadline still admit it.
@inline(__always)
func performAudioUnitConstruction<T>(
    until deadline: HALTeardownDeadline,
    context: AudioUnitConstructionContext?,
    _ operation: () -> T
) -> T? {
    if let context {
        guard context.mayBeginOperation else { return nil }
    } else {
        guard deadline.hasTimeRemaining else { return nil }
    }
    return operation()
}

enum AudioUnitLaneResult<Value: Sendable>: Sendable {
    case completed(Value)
    case superseded
    case timedOut
    case refused
}

/// Absolute construction budgets for unpublished Audio Unit graphs.
///
/// VoiceProcessingIO also builds a private aggregate and configures both sides
/// of the unit before initialisation. Measured on real hardware, that complete
/// transaction can return just after the generic two-second graph budget. It
/// remains one transaction on the sole construction lane; this larger budget
/// must not become the default for ordinary effect graphs.
enum AudioUnitConstructionBudget {
    static let standard: TimeInterval = 2
    static let echoCancellation: TimeInterval = 3
}

private protocol AudioUnitLaneTransaction: AnyObject, Sendable {
    var identifier: UUID { get }
    var key: String { get }
    var timeout: TimeInterval { get }
    var hasTerminalResult: Bool { get }
    func run()
    func cancelBeforeStart() -> Bool
    func refuseBeforeStart(_ result: AudioUnitLaneTerminalResult)
    @discardableResult func requestTimeout() -> Bool
    func timeOutInFlight()
}

private enum AudioUnitLaneTerminalResult {
    case superseded
    case timedOut
    case refused
}

/// Exact two-slot policy used by graph construction.
struct AudioUnitFirstLatestBacklog<Value> {
    private(set) var active: Value?
    private(set) var pending: Value?

    var retainedCount: Int { (active == nil ? 0 : 1) + (pending == nil ? 0 : 1) }

    mutating func submit(_ value: Value) -> (startsNow: Bool, superseded: Value?) {
        guard active != nil else {
            active = value
            return (true, nil)
        }
        let superseded = pending
        pending = value
        return (false, superseded)
    }

    mutating func finishActive() -> Value? {
        active = pending
        pending = nil
        return active
    }

    mutating func removePending() -> Value? {
        defer { pending = nil }
        return pending
    }
}

private final class AudioUnitTransaction<Value: Sendable>: @unchecked Sendable,
    AudioUnitLaneTransaction
{
    let identifier = UUID()
    let key: String
    let timeout: TimeInterval
    let completion = DispatchGroup()

    private let lock = NSLock()
    private var operation: (@Sendable () -> Value)?
    private var result: AudioUnitLaneResult<Value>?
    private var lateResult: Value?
    private var terminal = false
    private var started = false
    private var retainedLease: AudioUnitOwnerControlLease?
    private let didReturn: @Sendable (AudioUnitTransaction<Value>, Value) -> Void
    private let didTimeOut: @Sendable (AudioUnitTransaction<Value>) -> Bool

    init(
        key: String,
        timeout: TimeInterval,
        lease: AudioUnitOwnerControlLease? = nil,
        operation: @escaping @Sendable () -> Value,
        didReturn: @escaping @Sendable (AudioUnitTransaction<Value>, Value) -> Void,
        didTimeOut: @escaping @Sendable (AudioUnitTransaction<Value>) -> Bool
    ) {
        self.key = key
        self.timeout = max(0, timeout)
        retainedLease = lease
        self.operation = operation
        self.didReturn = didReturn
        self.didTimeOut = didTimeOut
        completion.enter()
    }

    func run() {
        guard
            let operation = lock.withLock({ () -> (@Sendable () -> Value)? in
                guard !terminal else { return nil }
                started = true
                return self.operation
            })
        else { return }
        let value = operation()
        didReturn(self, value)
    }

    var hasTerminalResult: Bool { lock.withLock { terminal } }

    func cancelBeforeStart() -> Bool {
        var leaseToRelease: AudioUnitOwnerControlLease?
        let cancelled = lock.withLock { () -> Bool in
            guard !started, !terminal else { return false }
            terminal = true
            result = .timedOut
            operation = nil
            leaseToRelease = retainedLease
            retainedLease = nil
            return true
        }
        if cancelled {
            leaseToRelease?.release()
            completion.leave()
        }
        return cancelled
    }

    func complete(_ value: Value) {
        var leaseToRelease: AudioUnitOwnerControlLease?
        let shouldSignal = lock.withLock { () -> Bool in
            guard !terminal else {
                // A result which arrived after timeout is itself an owner. It
                // remains beside the transaction instead of deinitialising on
                // the vendor callback thread.
                lateResult = value
                return false
            }
            terminal = true
            result = .completed(value)
            operation = nil
            leaseToRelease = retainedLease
            retainedLease = nil
            return true
        }
        if shouldSignal {
            leaseToRelease?.release()
            completion.leave()
        }
    }

    func refuseBeforeStart(_ terminalResult: AudioUnitLaneTerminalResult) {
        var leaseToRelease: AudioUnitOwnerControlLease?
        let shouldSignal = lock.withLock { () -> Bool in
            guard !terminal else { return false }
            terminal = true
            switch terminalResult {
            case .superseded: result = .superseded
            case .timedOut: result = .timedOut
            case .refused: result = .refused
            }
            operation = nil
            leaseToRelease = retainedLease
            retainedLease = nil
            return true
        }
        if shouldSignal {
            leaseToRelease?.release()
            completion.leave()
        }
    }

    func timeOutInFlight() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !terminal else { return false }
            terminal = true
            result = .timedOut
            // Both closure and lease deliberately stay retained. The call may
            // still be executing and teardown must not release its owner.
            return true
        }
        if shouldSignal {
            completion.leave()
        }
    }

    @discardableResult
    func requestTimeout() -> Bool {
        didTimeOut(self)
    }

    func wait(until deadline: HALTeardownDeadline) -> AudioUnitLaneResult<Value> {
        let remaining = deadline.remainingTimeInterval
        guard remaining > 0 else {
            if !requestTimeout() { completion.wait() }
            return lock.withLock { result ?? .timedOut }
        }
        if completion.wait(timeout: .now() + remaining) != .success {
            // Return publication and timeout share one arbiter. If return won
            // but has not yet signalled its transaction, wait for that bounded
            // post-call publication instead of manufacturing a timeout result.
            if !requestTimeout() { completion.wait() }
        }
        return lock.withLock { result ?? .timedOut }
    }
}

/// The only lane which may construct a route-owned Audio Unit graph.
///
/// One wedged vendor call consumes this lane for the process lifetime. There is
/// no replacement worker: spawning one would turn a toggle storm into an
/// unbounded set of blocked threads inside `coreaudiod`. While healthy, one
/// active request and the latest pending request are the complete backlog.
final class BoundedAudioUnitConstructionLane: @unchecked Sendable {
    static let shared = BoundedAudioUnitConstructionLane()

    /// A second lane, used only for the echo canceller's construction.
    ///
    /// A quarantine is for the life of the process — correctly, because a
    /// synchronous vendor call that has not returned may still be holding
    /// memory nobody can account for. That makes *which* lane gets quarantined
    /// the whole question, and on 2026-08-25 the answer cost the application
    /// everything it does.
    ///
    /// Constructing the voice-processing unit reached
    /// `AudioDeviceCreateIOProcID` inside `AudioComponentInstanceNew`, sent a
    /// mach message to coreaudiod, and never came back. The three-second budget
    /// expired, the shared lane quarantined itself, and from that moment the
    /// process could not build *any* graph — a plain microphone into a pair of
    /// headphones included. The application went on accepting Start and
    /// reporting success, with `running` never becoming true.
    ///
    /// Its own lane does not stop the wedge and cannot: nothing here can cancel
    /// that call.
    ///
    /// It was expected to change the blast radius, and it does not — that claim
    /// was made here before it had been measured, and measuring it on
    /// 2026-08-26 showed why. The lanes are separate; the quarantine they both
    /// use is not. `ProcessLifetimeAudioQuarantine.shared` is what refuses a
    /// new graph, a wedged constructor leaves an entry in it that is never
    /// released, and a plain route is refused after an echo wedge exactly as it
    /// was before.
    ///
    /// What the separation does buy is the diagnosis. `admitsConstruction` on
    /// this lane says the echo canceller is what wedged, so the application can
    /// name the cause instead of reporting a residue count — and that is what
    /// `mustBeRelaunched` and `echoCancellationNeedsRelaunch` are read from.
    ///
    /// Giving this lane its own quarantine as well would be the containment,
    /// and it is not done, because it is a memory-safety bet: the quarantine
    /// exists to stop a new graph being built while a call that may still touch
    /// Core Audio objects is in flight. Getting that wrong is a fault in the
    /// realtime path, which is worse than the lost session it would save.
    ///
    /// Serialisation is not weakened. The echo canceller is constructed and
    /// finished before graph construction begins, so the two lanes are never
    /// running a constructor at the same time — the separation is about which
    /// quarantine a failure lands in, not about concurrency.
    static let echoCancellation = BoundedAudioUnitConstructionLane(
        label: "com.yuhuanstudio.yunaudio.audio-unit-construction.echo")

    private let lock = NSLock()
    private let worker: DispatchQueue
    private let deadlineQueue: DispatchQueue
    private let quarantine: ProcessLifetimeAudioQuarantine
    private var backlog = AudioUnitFirstLatestBacklog<any AudioUnitLaneTransaction>()
    private var isQuarantined = false
    private var started = 0
    private var maximumConcurrent = 0
    private let afterConstructorReturnedBeforePublication: @Sendable () -> Void
    private let afterReturnClaimedBeforeTransactionPublication: @Sendable () -> Void

    init(
        quarantine: ProcessLifetimeAudioQuarantine = .shared,
        label: String = "com.yuhuanstudio.yunaudio.audio-unit-construction",
        afterConstructorReturnedBeforePublication: @escaping @Sendable () -> Void = {},
        afterReturnClaimedBeforeTransactionPublication: @escaping @Sendable () -> Void = {}
    ) {
        self.quarantine = quarantine
        self.afterConstructorReturnedBeforePublication =
            afterConstructorReturnedBeforePublication
        self.afterReturnClaimedBeforeTransactionPublication =
            afterReturnClaimedBeforeTransactionPublication
        worker = DispatchQueue(label: label, qos: .userInitiated)
        deadlineQueue = DispatchQueue(label: label + ".deadline", qos: .utility)
    }

    var activeCount: Int { lock.withLock { backlog.active == nil ? 0 : 1 } }
    var pendingCount: Int { lock.withLock { backlog.pending == nil ? 0 : 1 } }
    var startedCount: Int { lock.withLock { started } }
    var maximumConcurrentCount: Int { lock.withLock { maximumConcurrent } }
    var admitsConstruction: Bool { lock.withLock { !isQuarantined } }

    func perform<Value: Sendable>(
        timeout: TimeInterval = AudioUnitConstructionBudget.standard,
        observing observeResource:
            @escaping @Sendable (
                AudioUnitConstructionResource
            ) -> Void = { _ in },
        _ operation: @escaping @Sendable (AudioUnitConstructionContext) -> Value
    ) -> AudioUnitLaneResult<Value> {
        let deadline = HALTeardownDeadline(timeout: timeout)
        let context = AudioUnitConstructionContext(
            deadline: deadline, observeResource: observeResource)
        let transaction = AudioUnitTransaction<Value>(
            key: "graph", timeout: timeout, operation: { operation(context) },
            didReturn: { [weak self, context] transaction, value in
                self?.afterConstructorReturnedBeforePublication()
                if context.publishReturnOrClaimDeferredCleanups() {
                    self?.afterReturnClaimedBeforeTransactionPublication()
                    self?.didReturn(transaction, value: value)
                } else {
                    // The return path can observe the timeout before the deadline
                    // callback reaches the lane. Establish quarantine first, then
                    // retain the late value and finally run its ordered cleanup.
                    self?.didTimeOut(transaction)
                    self?.didReturn(transaction, value: value)
                    context.runDeferredCleanupsAfterTimedOutReturn()
                }
            },
            didTimeOut: { [weak self, context] transaction in
                guard context.claimTimeoutBeforeReturn() else { return false }
                self?.didTimeOut(transaction)
                return true
            })
        submit(transaction, timeout: timeout)
        return transaction.wait(until: deadline)
    }

    private func submit(_ transaction: any AudioUnitLaneTransaction, timeout: TimeInterval) {
        let action: (start: Bool, superseded: (any AudioUnitLaneTransaction)?, refused: Bool) =
            lock.withLock {
                guard !isQuarantined else { return (false, nil, true) }
                let submission = backlog.submit(transaction)
                if submission.startsNow {
                    started += 1
                    maximumConcurrent = max(maximumConcurrent, 1)
                    return (true, nil, false)
                }
                return (false, submission.superseded, false)
            }
        action.superseded?.refuseBeforeStart(.superseded)
        if action.refused {
            transaction.refuseBeforeStart(.refused)
            return
        }
        if action.start {
            start(transaction)
            scheduleTimeout(for: transaction, timeout: timeout)
        }
    }

    private func start(_ transaction: any AudioUnitLaneTransaction) {
        worker.async { transaction.run() }
    }

    private func scheduleTimeout(
        for transaction: any AudioUnitLaneTransaction, timeout: TimeInterval
    ) {
        deadlineQueue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
            guard self != nil else { return }
            _ = transaction.requestTimeout()
        }
    }

    private func didReturn<Value: Sendable>(
        _ transaction: AudioUnitTransaction<Value>, value: Value
    ) {
        transaction.complete(value)
        let next: (any AudioUnitLaneTransaction)? = lock.withLock {
            guard backlog.active?.identifier == transaction.identifier, !isQuarantined else {
                return nil
            }
            let successor = backlog.finishActive()
            if successor != nil {
                started += 1
                maximumConcurrent = max(maximumConcurrent, 1)
            }
            return successor
        }
        if let next {
            start(next)
            scheduleTimeout(for: next, timeout: next.timeout)
        }
    }

    private func didTimeOut(_ transaction: any AudioUnitLaneTransaction) {
        var cancelledSuccessor: (any AudioUnitLaneTransaction)?
        let action:
            (
                activeTimedOut: Bool,
                pendingTimedOut: Bool,
                refusedPending: (any AudioUnitLaneTransaction)?
            ) = lock.withLock {
                if backlog.active?.identifier == transaction.identifier {
                    guard !transaction.hasTerminalResult else {
                        return (false, false, nil)
                    }
                    if transaction.cancelBeforeStart() {
                        let successor = backlog.finishActive()
                        if let successor {
                            started += 1
                            maximumConcurrent = max(maximumConcurrent, 1)
                            cancelledSuccessor = successor
                        }
                        return (false, false, nil)
                    }
                    guard !isQuarantined else { return (false, false, nil) }
                    isQuarantined = true
                    let refused = backlog.removePending()
                    // The waiter may wake as soon as this terminal publication
                    // is signalled. Establish both refusal and process ownership
                    // first so no observer sees a timed-out result without its
                    // quarantine fence.
                    _ = quarantine.retain(
                        transaction,
                        reason: "Audio Unit construction transaction timed out")
                    transaction.timeOutInFlight()
                    return (true, false, refused)
                }
                if backlog.pending?.identifier == transaction.identifier {
                    _ = backlog.removePending()
                    return (false, true, nil)
                }
                return (false, false, nil)
            }
        if let successor = cancelledSuccessor {
            start(successor)
            scheduleTimeout(for: successor, timeout: successor.timeout)
        }
        if action.activeTimedOut {
            action.refusedPending?.refuseBeforeStart(.refused)
        } else if action.pendingTimedOut {
            transaction.refuseBeforeStart(.timedOut)
        }
    }
}

/// A lease held from state snapshot until a vendor control call has returned.
final class AudioUnitOwnerControlLease: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: AudioUnitOwnerControlGate?

    fileprivate init(gate: AudioUnitOwnerControlGate) {
        self.gate = gate
    }

    func release() {
        let gate = lock.withLock { () -> AudioUnitOwnerControlGate? in
            defer { self.gate = nil }
            return self.gate
        }
        gate?.releaseLease()
    }

    deinit { release() }
}

/// Excludes owner teardown from every queued or executing control call.
final class AudioUnitOwnerControlGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var leaseCount = 0
    private var isClosing = false

    func acquire() -> AudioUnitOwnerControlLease? {
        condition.lock()
        defer { condition.unlock() }
        guard !isClosing else { return nil }
        leaseCount += 1
        return AudioUnitOwnerControlLease(gate: self)
    }

    fileprivate func releaseLease() {
        condition.lock()
        leaseCount -= 1
        precondition(leaseCount >= 0)
        if leaseCount == 0 { condition.broadcast() }
        condition.unlock()
    }

    /// Closes admission and gives ordinary parameter calls one short grace.
    ///
    /// A genuine parameter operation normally completes well within one audio
    /// cycle. Fifty milliseconds prevents harmless Stop/control overlap from
    /// becoming residue, while remaining negligible beside the route's
    /// two-second teardown budget. Refusal permanently closes this owner.
    func closeForTeardown(waitingUpTo timeout: TimeInterval = 0.05) -> Bool {
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        condition.lock()
        isClosing = true
        while leaseCount > 0 {
            if !condition.wait(until: deadline) {
                condition.unlock()
                return false
            }
        }
        condition.unlock()
        return true
    }

    var activeLeaseCount: Int {
        condition.withLock { leaseCount }
    }
}

/// The bounded, keyed lane for all non-render Audio Unit controls.
///
/// One operation executes at a time. Pending values coalesce by semantic key,
/// so ten thousand movements of one knob execute the first and latest only.
/// A finite key cap prevents attacker-controlled plugin parameter identifiers
/// from becoming an allocation queue.
final class BoundedAudioUnitControlLane: @unchecked Sendable {
    static let shared = BoundedAudioUnitControlLane()
    static let maximumPendingKeys = 64

    private let lock = NSLock()
    private let worker: DispatchQueue
    private let deadlineQueue: DispatchQueue
    private let quarantine: ProcessLifetimeAudioQuarantine
    private let operationTimeout: TimeInterval
    private var active: (any AudioUnitLaneTransaction)?
    private var pendingByKey: [String: any AudioUnitLaneTransaction] = [:]
    private var pendingOrder: [String] = []
    private var isQuarantined = false
    private var started = 0
    private var maximumConcurrent = 0

    init(
        quarantine: ProcessLifetimeAudioQuarantine = .shared,
        operationTimeout: TimeInterval = 0.25,
        label: String = "com.yuhuanstudio.yunaudio.audio-unit-control"
    ) {
        self.quarantine = quarantine
        self.operationTimeout = max(0, operationTimeout)
        worker = DispatchQueue(label: label, qos: .userInitiated)
        deadlineQueue = DispatchQueue(label: label + ".deadline", qos: .utility)
    }

    var activeCount: Int { lock.withLock { active == nil ? 0 : 1 } }
    var pendingCount: Int { lock.withLock { pendingByKey.count } }
    var startedCount: Int { lock.withLock { started } }
    var maximumConcurrentCount: Int { lock.withLock { maximumConcurrent } }

    @discardableResult
    func submit<Value: Sendable>(
        key: String,
        lease: AudioUnitOwnerControlLease,
        operation: @escaping @Sendable (AudioUnitConstructionContext) -> Value
    ) -> Bool {
        let transaction = makeTransaction(key: key, lease: lease, operation: operation)
        return submit(transaction)
    }

    func perform<Value: Sendable>(
        key: String,
        lease: AudioUnitOwnerControlLease,
        timeout: TimeInterval? = nil,
        operation: @escaping @Sendable (AudioUnitConstructionContext) -> Value
    ) -> AudioUnitLaneResult<Value> {
        let requestedTimeout = timeout ?? operationTimeout
        let transaction = makeTransaction(
            key: key, lease: lease, timeout: requestedTimeout,
            operation: operation)
        guard submit(transaction) else { return .refused }
        return transaction.wait(
            until: HALTeardownDeadline(timeout: requestedTimeout))
    }

    private func makeTransaction<Value: Sendable>(
        key: String,
        lease: AudioUnitOwnerControlLease,
        timeout: TimeInterval? = nil,
        operation: @escaping @Sendable (AudioUnitConstructionContext) -> Value
    ) -> AudioUnitTransaction<Value> {
        let transactionTimeout = max(0, timeout ?? operationTimeout)
        let context = AudioUnitConstructionContext(
            deadline: HALTeardownDeadline(timeout: transactionTimeout))
        return AudioUnitTransaction<Value>(
            key: key, timeout: transactionTimeout, lease: lease,
            operation: { operation(context) },
            didReturn: { [weak self] transaction, value in
                self?.didReturn(transaction, value: value)
            },
            didTimeOut: { [weak self, context] transaction in
                context.cancel()
                self?.didTimeOut(transaction)
                return true
            })
    }

    private func submit(_ transaction: any AudioUnitLaneTransaction) -> Bool {
        let action:
            (
                start: Bool,
                superseded: (any AudioUnitLaneTransaction)?,
                refused: Bool
            ) = lock.withLock {
                guard !isQuarantined else { return (false, nil, true) }
                guard active != nil else {
                    active = transaction
                    started += 1
                    maximumConcurrent = max(maximumConcurrent, 1)
                    return (true, nil, false)
                }
                if let replaced = pendingByKey[transaction.key] {
                    pendingByKey[transaction.key] = transaction
                    return (false, replaced, false)
                }
                guard pendingOrder.count < Self.maximumPendingKeys else {
                    return (false, nil, true)
                }
                pendingByKey[transaction.key] = transaction
                pendingOrder.append(transaction.key)
                return (false, nil, false)
            }
        action.superseded?.refuseBeforeStart(.superseded)
        if action.refused {
            transaction.refuseBeforeStart(.refused)
            return false
        }
        if action.start {
            start(transaction)
            scheduleTimeout(for: transaction)
        }
        return true
    }

    private func start(_ transaction: any AudioUnitLaneTransaction) {
        worker.async { transaction.run() }
    }

    private func scheduleTimeout(for transaction: any AudioUnitLaneTransaction) {
        deadlineQueue.asyncAfter(deadline: .now() + transaction.timeout) { [weak self] in
            guard self != nil else { return }
            _ = transaction.requestTimeout()
        }
    }

    private func didReturn<Value: Sendable>(
        _ transaction: AudioUnitTransaction<Value>, value: Value
    ) {
        transaction.complete(value)
        let next: (any AudioUnitLaneTransaction)? = lock.withLock {
            guard active?.identifier == transaction.identifier, !isQuarantined else {
                return nil
            }
            active = nil
            while !pendingOrder.isEmpty {
                let key = pendingOrder.removeFirst()
                guard let successor = pendingByKey.removeValue(forKey: key) else {
                    continue
                }
                active = successor
                started += 1
                maximumConcurrent = max(maximumConcurrent, 1)
                return successor
            }
            return nil
        }
        if let next {
            start(next)
            scheduleTimeout(for: next)
        }
    }

    private func didTimeOut(_ transaction: any AudioUnitLaneTransaction) {
        var cancelledSuccessor: (any AudioUnitLaneTransaction)?
        let action:
            (
                activeTimedOut: Bool,
                pendingTimedOut: Bool,
                refused: [any AudioUnitLaneTransaction]
            ) = lock.withLock {
                if active?.identifier == transaction.identifier {
                    guard !transaction.hasTerminalResult else {
                        return (false, false, [])
                    }
                    if transaction.cancelBeforeStart() {
                        active = nil
                        while !pendingOrder.isEmpty {
                            let key = pendingOrder.removeFirst()
                            guard let successor = pendingByKey.removeValue(forKey: key) else {
                                continue
                            }
                            active = successor
                            started += 1
                            maximumConcurrent = max(maximumConcurrent, 1)
                            cancelledSuccessor = successor
                            break
                        }
                        return (false, false, [])
                    }
                    guard !isQuarantined else { return (false, false, []) }
                    isQuarantined = true
                    let refused = Array(pendingByKey.values)
                    pendingByKey.removeAll()
                    pendingOrder.removeAll()
                    return (true, false, refused)
                }
                if pendingByKey[transaction.key]?.identifier == transaction.identifier {
                    pendingByKey.removeValue(forKey: transaction.key)
                    pendingOrder.removeAll { $0 == transaction.key }
                    return (false, true, [])
                }
                return (false, false, [])
            }
        if let successor = cancelledSuccessor {
            start(successor)
            scheduleTimeout(for: successor)
        }
        if action.activeTimedOut {
            _ = quarantine.retain(
                transaction, reason: "Audio Unit control transaction timed out")
            transaction.timeOutInFlight()
            for pending in action.refused { pending.refuseBeforeStart(.refused) }
        } else if action.pendingTimedOut {
            transaction.refuseBeforeStart(.timedOut)
        }
    }
}
