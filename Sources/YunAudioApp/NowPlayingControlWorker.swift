import Foundation

/// The player and exact track which one external control is allowed to reach.
///
/// `trackIdentity` is deliberately carried into the blocking operation. The
/// eventual AppleScript must compare it inside the same event which mutates the
/// player; checking it before entering somebody else's stalled process leaves a
/// time-of-check/time-of-use hole wide enough to seek the next song.
struct NowPlayingControlTarget: Hashable, Sendable {
    let application: String
    let bundleIdentifier: String?
    let trackIdentity: String
}

/// One immutable target epoch and request identity.
struct NowPlayingControlContext: Hashable, Sendable {
    let target: NowPlayingControlTarget
    let targetEpoch: UInt64
    let requestToken: UInt64
}

enum NowPlayingControlEdge: Equatable, Sendable {
    case playPause
    case next
    case previous
}

enum NowPlayingControlCommand: Equatable, Sendable {
    case seek(seconds: Double)
    case edge(NowPlayingControlEdge)
}

/// The complete value handed to the sole blocking sender.
struct NowPlayingControlApplication: Equatable, Sendable {
    let context: NowPlayingControlContext
    let command: NowPlayingControlCommand
}

struct NowPlayingControlCompletion: Equatable, Sendable {
    let application: NowPlayingControlApplication
    let succeeded: Bool
}

/// Serialises blocking player control without turning scrub gestures into work.
///
/// Continuous seeks retain the first request already owned by the lane and one
/// newest pending value. Discrete transport edges retain order in a separate
/// bounded FIFO. A target change synchronously revokes both pending shapes, but
/// never pretends an Apple event which already entered another process was
/// cancelled; that one sender remains the sole owner until it returns.
final class NowPlayingControlWorker: @unchecked Sendable {
    static let maximumPendingEdges = 32
    static let minimumSeekIntervalNanoseconds: UInt64 = 50_000_000

    enum Refusal: Equatable, Sendable {
        case noTarget
        case invalidSeek
        case edgeBacklogFull
        case shutDown
    }

    enum Submission: Equatable, Sendable {
        case accepted
        case coalesced
        case refused(Refusal)

        var wasAccepted: Bool {
            switch self {
            case .accepted, .coalesced: true
            case .refused: false
            }
        }
    }

    struct Statistics: Equatable, Sendable {
        let targetEpoch: UInt64
        let targetChanges: UInt64
        let seekSubmissions: UInt64
        let edgeSubmissions: UInt64
        let coalescedSeeks: UInt64
        let revokedSeeks: UInt64
        let revokedEdges: UInt64
        let edgeOverflows: UInt64
        let refusedRequests: UInt64
        let applications: UInt64
        let publications: UInt64
        let staleCompletions: UInt64
        let stalePublications: UInt64
        let activeApplications: Int
        let maximumConcurrentApplications: Int
        let pendingSeeks: Int
        let pendingEdges: Int
        let maximumPendingSeeks: Int
        let maximumPendingEdges: Int
        let scheduledRuns: Int
        let maximumScheduledRuns: Int
        let mainThreadApplications: UInt64
        let acceptsRequests: Bool
    }

    typealias Apply = @Sendable (NowPlayingControlApplication) -> Bool
    typealias MainScheduler =
        @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    private struct State {
        var acceptsRequests = true
        var target: NowPlayingControlTarget?
        var targetEpoch: UInt64 = 0
        var nextRequestToken: UInt64 = 0
        var ready: NowPlayingControlApplication?
        var active: NowPlayingControlApplication?
        var pendingSeek: NowPlayingControlApplication?
        var edges: [NowPlayingControlApplication] = []
        var edgeHead = 0
        var runIsScheduled = false
        var lastSeekStartedAt: UInt64?

        var targetChanges: UInt64 = 0
        var seekSubmissions: UInt64 = 0
        var edgeSubmissions: UInt64 = 0
        var coalescedSeeks: UInt64 = 0
        var revokedSeeks: UInt64 = 0
        var revokedEdges: UInt64 = 0
        var edgeOverflows: UInt64 = 0
        var refusedRequests: UInt64 = 0
        var applications: UInt64 = 0
        var publications: UInt64 = 0
        var staleCompletions: UInt64 = 0
        var stalePublications: UInt64 = 0
        var maximumConcurrentApplications = 0
        var maximumPendingSeeks = 0
        var maximumPendingEdges = 0
        var maximumScheduledRuns = 0
        var mainThreadApplications: UInt64 = 0

        var pendingEdgeCount: Int {
            edges.count - edgeHead
                + (ready?.command.isEdge == true ? 1 : 0)
        }

        var pendingSeekCount: Int { pendingSeek == nil ? 0 : 1 }
    }

    private struct Schedule: Sendable {
        let delayNanoseconds: UInt64
    }

    private let lock = NSLock()
    private var state = State()
    private let queue: DispatchQueue
    private let apply: Apply
    private let scheduleMain: MainScheduler
    private let publish: @MainActor @Sendable (NowPlayingControlCompletion) -> Void
    private let minimumSeekInterval: UInt64

    init(
        queue: DispatchQueue? = nil,
        minimumSeekIntervalNanoseconds: UInt64 =
            NowPlayingControlWorker.minimumSeekIntervalNanoseconds,
        apply: @escaping Apply,
        scheduleMain: @escaping MainScheduler = MainRunLoopDelivery.perform,
        publish: @escaping @MainActor @Sendable (NowPlayingControlCompletion) -> Void
    ) {
        self.queue =
            queue
            ?? DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.now-playing-control",
                qos: .userInitiated)
        minimumSeekInterval = minimumSeekIntervalNanoseconds
        self.apply = apply
        self.scheduleMain = scheduleMain
        self.publish = publish
        state.edges.reserveCapacity(Self.maximumPendingEdges)
    }

    /// Replaces the only target and revokes work which has not entered the sender.
    ///
    /// The returned epoch can be retained by integration code for diagnostics;
    /// callers do not manufacture epochs themselves.
    @discardableResult
    func replaceTarget(_ target: NowPlayingControlTarget?) -> UInt64 {
        lock.withLock {
            guard state.acceptsRequests else { return state.targetEpoch }
            state.targetEpoch &+= 1
            state.targetChanges &+= 1
            state.target = target
            state.lastSeekStartedAt = nil
            revokePendingLocked()
            return state.targetEpoch
        }
    }

    @discardableResult
    func submitSeek(seconds: Double) -> Submission {
        var schedule: Schedule?
        let result: Submission = lock.withLock {
            state.seekSubmissions &+= 1
            guard state.acceptsRequests else { return refuseLocked(.shutDown) }
            guard seconds.isFinite, seconds >= 0 else {
                return refuseLocked(.invalidSeek)
            }
            guard let context = makeContextLocked() else {
                return refuseLocked(.noTarget)
            }
            let request = NowPlayingControlApplication(
                context: context, command: .seek(seconds: seconds))
            if state.ready == nil, state.active == nil {
                state.ready = request
                schedule = scheduleIfNeededLocked()
                return .accepted
            }
            let result: Submission = state.pendingSeek == nil ? .accepted : .coalesced
            if state.pendingSeek != nil { state.coalescedSeeks &+= 1 }
            state.pendingSeek = request
            state.maximumPendingSeeks = max(state.maximumPendingSeeks, 1)
            return result
        }
        if let schedule { dispatch(schedule) }
        return result
    }

    @discardableResult
    func submitEdge(_ edge: NowPlayingControlEdge) -> Submission {
        var schedule: Schedule?
        let result: Submission = lock.withLock {
            state.edgeSubmissions &+= 1
            guard state.acceptsRequests else { return refuseLocked(.shutDown) }
            guard let context = makeContextLocked() else {
                return refuseLocked(.noTarget)
            }
            guard state.pendingEdgeCount < Self.maximumPendingEdges else {
                state.edgeOverflows &+= 1
                return refuseLocked(.edgeBacklogFull)
            }
            let request = NowPlayingControlApplication(
                context: context, command: .edge(edge))
            if state.ready == nil, state.active == nil {
                state.ready = request
                schedule = scheduleIfNeededLocked()
            } else {
                state.edges.append(request)
                state.maximumPendingEdges = max(
                    state.maximumPendingEdges, state.pendingEdgeCount)
            }
            return .accepted
        }
        if let schedule { dispatch(schedule) }
        return result
    }

    /// Closes admission and revokes pending controls without joining the sender.
    func shutdown() {
        lock.withLock {
            guard state.acceptsRequests else { return }
            state.acceptsRequests = false
            state.targetEpoch &+= 1
            state.target = nil
            state.lastSeekStartedAt = nil
            revokePendingLocked()
        }
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(
                targetEpoch: state.targetEpoch,
                targetChanges: state.targetChanges,
                seekSubmissions: state.seekSubmissions,
                edgeSubmissions: state.edgeSubmissions,
                coalescedSeeks: state.coalescedSeeks,
                revokedSeeks: state.revokedSeeks,
                revokedEdges: state.revokedEdges,
                edgeOverflows: state.edgeOverflows,
                refusedRequests: state.refusedRequests,
                applications: state.applications,
                publications: state.publications,
                staleCompletions: state.staleCompletions,
                stalePublications: state.stalePublications,
                activeApplications: state.active == nil ? 0 : 1,
                maximumConcurrentApplications: state.maximumConcurrentApplications,
                pendingSeeks: state.pendingSeekCount,
                pendingEdges: state.pendingEdgeCount,
                maximumPendingSeeks: state.maximumPendingSeeks,
                maximumPendingEdges: state.maximumPendingEdges,
                scheduledRuns: state.runIsScheduled ? 1 : 0,
                maximumScheduledRuns: state.maximumScheduledRuns,
                mainThreadApplications: state.mainThreadApplications,
                acceptsRequests: state.acceptsRequests)
        }
    }

    private func makeContextLocked() -> NowPlayingControlContext? {
        guard let target = state.target else { return nil }
        state.nextRequestToken &+= 1
        return NowPlayingControlContext(
            target: target, targetEpoch: state.targetEpoch,
            requestToken: state.nextRequestToken)
    }

    private func refuseLocked(_ reason: Refusal) -> Submission {
        state.refusedRequests &+= 1
        return .refused(reason)
    }

    private func revokePendingLocked() {
        if state.ready?.command.isSeek == true { state.revokedSeeks &+= 1 }
        if state.ready?.command.isEdge == true { state.revokedEdges &+= 1 }
        if state.pendingSeek != nil { state.revokedSeeks &+= 1 }
        state.revokedEdges &+= UInt64(state.edges.count - state.edgeHead)
        state.ready = nil
        state.pendingSeek = nil
        state.edges.removeAll(keepingCapacity: true)
        state.edgeHead = 0
    }

    private func scheduleIfNeededLocked() -> Schedule? {
        guard state.acceptsRequests, state.active == nil, state.ready != nil,
            !state.runIsScheduled
        else { return nil }
        state.runIsScheduled = true
        state.maximumScheduledRuns = max(state.maximumScheduledRuns, 1)
        return Schedule(delayNanoseconds: seekDelayLocked())
    }

    private func seekDelayLocked(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64 {
        guard state.ready?.command.isSeek == true, let last = state.lastSeekStartedAt else {
            return 0
        }
        let deadline = last.addingReportingOverflow(minimumSeekInterval)
        guard !deadline.overflow else { return minimumSeekInterval }
        guard now < deadline.partialValue else { return 0 }
        return deadline.partialValue - now
    }

    private func dispatch(_ schedule: Schedule) {
        let clamped = min(schedule.delayNanoseconds, UInt64(Int.max))
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamped))) { [self] in
            runScheduled()
        }
    }

    private func runScheduled() {
        var reschedule: Schedule?
        let request: NowPlayingControlApplication? = lock.withLock {
            state.runIsScheduled = false
            guard state.acceptsRequests, let ready = state.ready else { return nil }
            let delay = seekDelayLocked()
            guard delay == 0 else {
                reschedule = scheduleIfNeededLocked()
                return nil
            }
            state.ready = nil
            state.active = ready
            state.applications &+= 1
            state.maximumConcurrentApplications = max(
                state.maximumConcurrentApplications, 1)
            if ready.command.isSeek {
                state.lastSeekStartedAt = DispatchTime.now().uptimeNanoseconds
            }
            return ready
        }
        if let reschedule {
            dispatch(reschedule)
            return
        }
        guard let request else { return }

        let ranOnMainThread = Thread.isMainThread
        let succeeded = apply(request)
        finish(request, succeeded: succeeded, ranOnMainThread: ranOnMainThread)
    }

    private func finish(
        _ request: NowPlayingControlApplication, succeeded: Bool,
        ranOnMainThread: Bool
    ) {
        var schedules: Schedule?
        let completion: NowPlayingControlCompletion? = lock.withLock {
            guard state.active?.context.requestToken == request.context.requestToken else {
                return nil
            }
            state.active = nil
            if ranOnMainThread { state.mainThreadApplications &+= 1 }
            let isCurrent = contextIsCurrentLocked(request.context)
            if !isCurrent { state.staleCompletions &+= 1 }
            promoteNextLocked()
            schedules = scheduleIfNeededLocked()
            return isCurrent
                ? NowPlayingControlCompletion(
                    application: request, succeeded: succeeded)
                : nil
        }
        if let completion {
            scheduleMain { [weak self] in self?.deliver(completion) }
        }
        if let schedules { dispatch(schedules) }
    }

    private func promoteNextLocked() {
        guard state.ready == nil, state.active == nil, state.acceptsRequests else { return }
        if state.edgeHead < state.edges.count {
            state.ready = state.edges[state.edgeHead]
            state.edgeHead += 1
            if state.edgeHead == state.edges.count {
                state.edges.removeAll(keepingCapacity: true)
                state.edgeHead = 0
            } else if state.edgeHead >= 16 {
                state.edges.removeFirst(state.edgeHead)
                state.edgeHead = 0
            }
            return
        }
        state.ready = state.pendingSeek
        state.pendingSeek = nil
    }

    private func contextIsCurrentLocked(_ context: NowPlayingControlContext) -> Bool {
        state.acceptsRequests && state.targetEpoch == context.targetEpoch
            && state.target == context.target
    }

    @MainActor
    private func deliver(_ completion: NowPlayingControlCompletion) {
        let isCurrent = lock.withLock {
            guard contextIsCurrentLocked(completion.application.context) else {
                state.stalePublications &+= 1
                return false
            }
            state.publications &+= 1
            return true
        }
        if isCurrent { publish(completion) }
    }
}

private extension NowPlayingControlCommand {
    var isSeek: Bool {
        if case .seek = self { return true }
        return false
    }

    var isEdge: Bool {
        if case .edge = self { return true }
        return false
    }
}
