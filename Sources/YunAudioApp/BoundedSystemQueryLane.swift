import Foundation

/// The blocking system-service domains which must never share an execution owner.
///
/// A call which has entered Core Audio, AppKit or a vendor property getter cannot
/// be cancelled safely. A separate serial queue for each domain confines that
/// failure: an unavailable capture census cannot delay a device change, hardware
/// write, or the diagnostic evidence needed to explain the failure.
enum SystemQuerySubsystem: String, CaseIterable, Sendable {
    case captureResolution = "capture-resolution"
    case applicationInventory = "application-inventory"
    case deviceInventory = "device-inventory"
    case deviceHydration = "device-hydration"
    case hardwareRead = "hardware-read"
    case hardwareWrite = "hardware-write"
    case diagnostics

    var queueLabel: String {
        "com.yuhuanstudio.yunaudio.system-query.\(rawValue)"
    }

    func makeQueue() -> DispatchQueue {
        DispatchQueue(label: queueLabel, qos: .utility)
    }
}

/// The outer deadline budgets for bounded UI-facing queries.
///
/// These are response budgets, not permission to replace a blocked owner. A
/// late framework call remains quarantined on its subsystem lane after its
/// fallback is published. Capture is shortest because Start/Stop state is in
/// front of a person; inventories tolerate one second because their last good
/// snapshot remains useful, and diagnostics may spend two seconds collecting
/// evidence without delaying any control lane.
extension SystemQuerySubsystem {
    var defaultTimeout: Duration {
        switch self {
        case .captureResolution: .milliseconds(250)
        case .applicationInventory: .seconds(1)
        case .deviceInventory: .seconds(1)
        case .deviceHydration: .seconds(1)
        case .hardwareRead: .milliseconds(250)
        case .hardwareWrite: .milliseconds(250)
        case .diagnostics: .seconds(2)
        }
    }
}

/// Idempotent cancellation for one deadline callback.
final class SystemQueryDeadlineHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let action = lock.withLock {
            let action = cancellation
            cancellation = nil
            return action
        }
        action?()
    }
}

private final class SystemQueryDeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isWaiting = true

    func claim() -> Bool {
        lock.withLock {
            guard isWaiting else { return false }
            isWaiting = false
            return true
        }
    }

    func cancel() {
        lock.withLock { isWaiting = false }
    }
}

/// Injectable scheduling for deadline-versus-return arbitration.
struct SystemQueryDeadlineScheduler: Sendable {
    private let scheduleOperation:
        @Sendable (
            Duration, @escaping @Sendable () -> Void
        ) -> SystemQueryDeadlineHandle

    init(
        _ schedule:
            @escaping @Sendable (
                Duration, @escaping @Sendable () -> Void
            ) -> SystemQueryDeadlineHandle
    ) {
        scheduleOperation = schedule
    }

    func schedule(
        after duration: Duration,
        _ operation: @escaping @Sendable () -> Void
    ) -> SystemQueryDeadlineHandle {
        scheduleOperation(duration, operation)
    }

    /// The timer owner is independent of every query queue. Its callbacks only
    /// arbitrate state and enqueue a value; they never call the system service.
    static let continuous = SystemQueryDeadlineScheduler { duration, operation in
        let gate = SystemQueryDeadlineGate()
        let interval = dispatchInterval(for: duration)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) {
            if gate.claim() { operation() }
        }
        return SystemQueryDeadlineHandle { gate.cancel() }
    }

    private static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return .nanoseconds(0)
        }
        let seconds = UInt64(components.seconds)
        let fractional = UInt64(components.attoseconds / 1_000_000_000)
        let whole = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !whole.overflow else { return .nanoseconds(Int.max) }
        let total = whole.partialValue.addingReportingOverflow(fractional)
        guard !total.overflow else { return .nanoseconds(Int.max) }
        return .nanoseconds(Int(min(total.partialValue, UInt64(Int.max))))
    }
}

/// One bounded first/latest owner for a synchronous system query.
///
/// Admission reserves the first request synchronously and retains at most one
/// newer request. Reaching the deadline publishes one fallback but deliberately
/// leaves the call as this lane's sole owner until it returns. That late call is
/// quarantined: its answer is discarded and no replacement thread is spawned
/// beside a framework which may be wedged. Invalidation and shutdown revoke the
/// generation synchronously and never join the query queue.
final class BoundedSystemQueryLane<Request: Sendable, Response: Sendable>:
    @unchecked Sendable
{
    struct Context: @unchecked Sendable {
        fileprivate enum Status: Equatable {
            case current
            case revoked
            case deadlineExpired
        }

        fileprivate let readStatus: @Sendable () -> Status

        /// True only while this exact request may still publish a normal answer.
        var shouldContinue: Bool { readStatus() == .current }

        /// True after the deadline won, while the system call still owns the lane.
        var hasReachedDeadline: Bool { readStatus() == .deadlineExpired }
    }

    struct Statistics: Equatable, Sendable {
        fileprivate(set) var submissions: UInt64 = 0
        fileprivate(set) var rejectedSubmissions: UInt64 = 0
        fileprivate(set) var coalesced: UInt64 = 0
        fileprivate(set) var applications: UInt64 = 0
        fileprivate(set) var publications: UInt64 = 0
        fileprivate(set) var revokedResults: UInt64 = 0
        fileprivate(set) var duplicateDeliveries: UInt64 = 0
        fileprivate(set) var deadlineExpirations: UInt64 = 0
        fileprivate(set) var quarantinedReturns: UInt64 = 0
        fileprivate(set) var invalidations: UInt64 = 0
        fileprivate(set) var shutdowns: UInt64 = 0
        fileprivate(set) var activeRequests: Int = 0
        fileprivate(set) var pendingRequests: Int = 0
        fileprivate(set) var quarantinedRequests: Int = 0
        fileprivate(set) var maximumPending: Int = 0
        fileprivate(set) var maximumConcurrentApplications: Int = 0
        fileprivate(set) var maximumQuarantinedApplications: Int = 0
    }

    private struct Work {
        let request: Request
        let generation: UInt64
    }

    private struct Active {
        let work: Work
        var hasBegun = false
        var deadlineIsArmed = false
        var deadlineHasExpired = false
        var deadlineHandle: SystemQueryDeadlineHandle?
    }

    private struct State {
        var active: Active?
        var pending: Work?
        var acceptsWork = true
        var generation: UInt64 = 0
        var concurrentApplications = 0
        var nextPublicationID: UInt64 = 0
        var claimedPublicationID: UInt64?
        var statistics = Statistics()
    }

    private let lock = NSLock()
    private var state = State()
    let subsystem: SystemQuerySubsystem
    private let queue: DispatchQueue
    private let timeout: Duration
    private let deadlineScheduler: SystemQueryDeadlineScheduler
    private let scheduleOnMainActor:
        @Sendable (
            @escaping @MainActor @Sendable () -> Void
        ) -> Void
    private let apply: @Sendable (Request, Context) -> Response
    private let deadlineResponse: @Sendable (Request) -> Response
    private let publish: @MainActor @Sendable (Response) -> Void

    init(
        subsystem: SystemQuerySubsystem,
        queue: DispatchQueue? = nil,
        timeout: Duration? = nil,
        deadlineScheduler: SystemQueryDeadlineScheduler = .continuous,
        scheduleOnMainActor:
            @escaping @Sendable (
                @escaping @MainActor @Sendable () -> Void
            ) -> Void = { MainRunLoopDelivery.perform($0) },
        apply: @escaping @Sendable (Request, Context) -> Response,
        deadlineResponse: @escaping @Sendable (Request) -> Response,
        publish: @escaping @MainActor @Sendable (Response) -> Void
    ) {
        self.subsystem = subsystem
        self.queue = queue ?? subsystem.makeQueue()
        self.timeout = timeout ?? subsystem.defaultTimeout
        self.deadlineScheduler = deadlineScheduler
        self.scheduleOnMainActor = scheduleOnMainActor
        self.apply = apply
        self.deadlineResponse = deadlineResponse
        self.publish = publish
    }

    var statistics: Statistics {
        lock.withLock {
            var snapshot = state.statistics
            snapshot.activeRequests = state.active == nil ? 0 : 1
            snapshot.pendingRequests = state.pending == nil ? 0 : 1
            snapshot.quarantinedRequests = state.active?.deadlineHasExpired == true ? 1 : 0
            return snapshot
        }
    }

    @discardableResult
    func submit(_ request: Request) -> Bool {
        let schedulesWorker: Bool? = lock.withLock {
            // Once the owner has missed its deadline, another request has no
            // execution deadline to inherit: the synchronous framework call may
            // never return. Refuse it immediately so its UI cannot enter a new
            // busy state behind quarantined work. Admission reopens only if that
            // original owner eventually returns.
            guard state.acceptsWork, state.active?.deadlineHasExpired != true else {
                state.statistics.rejectedSubmissions &+= 1
                return nil
            }
            state.generation &+= 1
            state.claimedPublicationID = nil
            state.statistics.submissions &+= 1
            let work = Work(request: request, generation: state.generation)
            guard state.active != nil else {
                // Reservation must happen before dispatch: otherwise a burst can
                // replace the first value before its queue has even observed it.
                state.active = Active(work: work)
                return true
            }
            if state.pending != nil {
                state.statistics.coalesced &+= 1
                state.statistics.revokedResults &+= 1
            }
            state.pending = work
            state.statistics.maximumPending = max(state.statistics.maximumPending, 1)
            return false
        }
        guard let schedulesWorker else { return false }
        if schedulesWorker { queue.async { [self] in drain() } }
        return true
    }

    /// Revokes queued and in-flight publication while keeping admission open.
    @discardableResult
    func invalidate() -> Bool {
        let result = revoke(closingAdmission: false)
        return result.didRevoke
    }

    /// Permanently closes admission without joining an entered system call.
    @discardableResult
    func shutdown() -> Bool {
        let result = revoke(closingAdmission: true)
        result.deadlineHandle?.cancel()
        return result.didRevoke
    }

    /// Schedules cancellation state after synchronous generation revocation.
    ///
    /// Stop uses this only for capture resolution. The notification is not
    /// generation-gated: it retires that exact Start intent on the next main
    /// run-loop turn without waiting for the blocked system query to return.
    @discardableResult
    func invalidate(
        notifying notification: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard invalidate() else { return false }
        scheduleOnMainActor(notification)
        return true
    }

    /// The shutdown counterpart for process termination state.
    @discardableResult
    func shutdown(
        notifying notification: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard shutdown() else { return false }
        scheduleOnMainActor(notification)
        return true
    }

    private func revoke(
        closingAdmission: Bool
    ) -> (didRevoke: Bool, deadlineHandle: SystemQueryDeadlineHandle?) {
        lock.withLock {
            guard state.acceptsWork else { return (false, nil) }
            state.generation &+= 1
            state.claimedPublicationID = nil
            if closingAdmission {
                state.acceptsWork = false
                state.statistics.shutdowns &+= 1
            } else {
                state.statistics.invalidations &+= 1
            }
            if state.pending != nil { state.statistics.revokedResults &+= 1 }
            state.pending = nil
            guard var active = state.active else { return (true, nil) }
            guard active.hasBegun else {
                state.statistics.revokedResults &+= 1
                state.active = nil
                return (true, nil)
            }
            // Revoking a result is not cancellation of the synchronous system
            // call which owns this lane. When admission remains open, its
            // watchdog must remain armed: a new request may otherwise wait
            // forever behind an old vendor call whose deadline was silently
            // removed. The old generation cannot publish a normal answer, but
            // its deadline still quarantines the owner and fails the newest
            // visible waiter. Permanent shutdown has no future waiter, so it
            // can retire the timer without joining the call.
            let deadlineHandle: SystemQueryDeadlineHandle?
            if closingAdmission {
                active.deadlineIsArmed = false
                deadlineHandle = active.deadlineHandle
                active.deadlineHandle = nil
            } else {
                deadlineHandle = nil
            }
            state.active = active
            return (true, deadlineHandle)
        }
    }

    private func drain() {
        while let work = beginActiveApplication() {
            let context = Context(readStatus: { [weak self] in
                self?.status(for: work.generation) ?? .revoked
            })
            let response = autoreleasepool { apply(work.request, context) }
            let shouldPublish = finishActiveApplication(work)
            if shouldPublish {
                scheduleOnMainActor { [self] in
                    deliver(response, generation: work.generation)
                }
            }
        }
    }

    private func beginActiveApplication() -> Work? {
        let work: Work? = lock.withLock {
            guard state.acceptsWork, var active = state.active, !active.hasBegun else {
                return nil
            }
            active.hasBegun = true
            active.deadlineIsArmed = true
            state.active = active
            state.statistics.applications &+= 1
            state.concurrentApplications += 1
            state.statistics.maximumConcurrentApplications = max(
                state.statistics.maximumConcurrentApplications,
                state.concurrentApplications)
            return active.work
        }
        guard let work else { return nil }

        let handle = deadlineScheduler.schedule(after: timeout) { [weak self] in
            self?.deadlineReached(for: work)
        }
        let retained = lock.withLock {
            guard var active = state.active,
                active.work.generation == work.generation,
                active.deadlineIsArmed,
                !active.deadlineHasExpired
            else { return false }
            active.deadlineHandle = handle
            state.active = active
            return true
        }
        if !retained { handle.cancel() }
        return work
    }

    private func deadlineReached(for work: Work) {
        let publication: (work: Work, id: UInt64)? = lock.withLock {
            guard var active = state.active,
                active.work.generation == work.generation,
                active.hasBegun,
                active.deadlineIsArmed,
                !active.deadlineHasExpired
            else { return nil }
            active.deadlineIsArmed = false
            active.deadlineHasExpired = true
            state.active = active
            state.statistics.deadlineExpirations &+= 1
            state.statistics.maximumQuarantinedApplications = max(
                state.statistics.maximumQuarantinedApplications, 1)
            guard state.acceptsWork else { return nil }

            // A newer request may have arrived while the synchronous framework
            // call was already stuck. It cannot begin until that owner returns,
            // so leaving it pending would also leave its UI state without any
            // deadline at all. Fail the latest visible intent using this lane's
            // deadline, without pretending that it ran or opening a replacement
            // owner beside the quarantined call.
            let visibleWork = state.pending ?? active.work
            if state.pending != nil {
                state.statistics.revokedResults &+= 1
                state.pending = nil
            }
            guard state.generation == visibleWork.generation else { return nil }
            return (visibleWork, reservePublicationLocked())
        }
        guard let publication else { return }
        let response = deadlineResponse(publication.work.request)
        scheduleOnMainActor { [self] in
            deliver(
                response,
                generation: publication.work.generation,
                publicationID: publication.id)
        }
    }

    private func finishActiveApplication(_ work: Work) -> Bool {
        let result: (shouldPublish: Bool, deadlineHandle: SystemQueryDeadlineHandle?) =
            lock.withLock {
                guard let active = state.active,
                    active.work.generation == work.generation
                else { return (false, nil) }
                state.concurrentApplications -= 1
                let isCurrent = state.acceptsWork && state.generation == work.generation
                let shouldPublish = isCurrent && !active.deadlineHasExpired
                if active.deadlineHasExpired {
                    state.statistics.quarantinedReturns &+= 1
                } else if !isCurrent {
                    state.statistics.revokedResults &+= 1
                }
                let deadlineHandle = active.deadlineHandle
                state.active = state.pending.map { Active(work: $0) }
                state.pending = nil
                return (shouldPublish, deadlineHandle)
            }
        result.deadlineHandle?.cancel()
        return result.shouldPublish
    }

    private func status(for generation: UInt64) -> Context.Status {
        lock.withLock {
            guard let active = state.active, active.work.generation == generation else {
                return .revoked
            }
            guard state.acceptsWork, state.generation == generation else { return .revoked }
            if active.deadlineHasExpired { return .deadlineExpired }
            return .current
        }
    }

    @MainActor
    private func deliver(
        _ response: Response,
        generation: UInt64,
        publicationID: UInt64? = nil
    ) {
        let accepted = lock.withLock {
            guard state.acceptsWork, state.generation == generation else {
                state.statistics.revokedResults &+= 1
                return false
            }
            if let publicationID {
                guard state.claimedPublicationID != publicationID else {
                    state.statistics.duplicateDeliveries &+= 1
                    return false
                }
                state.claimedPublicationID = publicationID
            }
            state.statistics.publications &+= 1
            return true
        }
        if accepted { publish(response) }
    }

    private func reservePublicationLocked() -> UInt64 {
        state.nextPublicationID &+= 1
        return state.nextPublicationID
    }
}
