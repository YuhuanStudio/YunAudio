import Foundation

/// One immutable diagnostic capture tied to the engine generation which made it.
///
/// The payload is deliberately generic. The engine boundary may transfer an
/// owned buffer rather than copy it while holding its lifecycle lock; the
/// diagnostics worker only needs a value which can safely cross threads.
struct DiagnosticCaptureSnapshot<Capture: Sendable>: Sendable {
    let generation: UInt64
    let capture: Capture
}

extension DiagnosticCaptureSnapshot: Equatable where Capture: Equatable {}

/// A diagnostic answer which retains the capture generation it describes.
struct DiagnosticEvaluation<Result: Sendable>: Sendable {
    let captureGeneration: UInt64
    let result: Result
}

extension DiagnosticEvaluation: Equatable where Result: Equatable {}

/// Observable proof that one slow operation cannot create an unbounded queue.
struct DiagnosticLifecycleStatistics: Equatable, Sendable {
    let submissions: UInt64
    let coalesced: UInt64
    let applications: UInt64
    let publications: UInt64
    let revokedResults: UInt64
    let activeApplications: Int
    let pendingApplications: Int
    let maximumActiveApplications: Int
    let maximumPendingApplications: Int
    let mainThreadApplications: UInt64
}

private struct DiagnosticApplicationContext: Sendable {
    let isCurrentGeneration: @Sendable () -> Bool

    var isCurrent: Bool { isCurrentGeneration() }
}

/// A serial first/latest owner with generation-checked MainActor publication.
///
/// The first request is reserved during submission rather than when the queue
/// eventually wakes. While it is active, every intermediate value is replaced
/// by the newest one. A second generation check at delivery closes the window
/// between finishing background work and its MainActor callback.
private final class DiagnosticLatestLane<Request: Sendable, Response: Sendable>:
    @unchecked Sendable
{
    typealias MainScheduler =
        @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    private struct Work: Sendable {
        let request: Request
        let generation: UInt64
    }

    private struct State {
        var acceptsWork = true
        var generation: UInt64 = 0
        var active: Work?
        var pending: Work?
        var hasWorker = false
        var activeApplications = 0
        var submissions: UInt64 = 0
        var coalesced: UInt64 = 0
        var applications: UInt64 = 0
        var publications: UInt64 = 0
        var revokedResults: UInt64 = 0
        var maximumActiveApplications = 0
        var maximumPendingApplications = 0
        var mainThreadApplications: UInt64 = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let queue: DispatchQueue
    private let apply: @Sendable (Request, DiagnosticApplicationContext) -> Response
    private let scheduleMain: MainScheduler
    private let publish: @MainActor @Sendable (Response) -> Void

    init(
        queue: DispatchQueue,
        apply: @escaping @Sendable (Request, DiagnosticApplicationContext) -> Response,
        scheduleMain: @escaping MainScheduler,
        publish: @escaping @MainActor @Sendable (Response) -> Void
    ) {
        self.queue = queue
        self.apply = apply
        self.scheduleMain = scheduleMain
        self.publish = publish
    }

    var statistics: DiagnosticLifecycleStatistics {
        lock.withLock {
            DiagnosticLifecycleStatistics(
                submissions: state.submissions,
                coalesced: state.coalesced,
                applications: state.applications,
                publications: state.publications,
                revokedResults: state.revokedResults,
                activeApplications: state.activeApplications,
                pendingApplications: state.pending == nil ? 0 : 1,
                maximumActiveApplications: state.maximumActiveApplications,
                maximumPendingApplications: state.maximumPendingApplications,
                mainThreadApplications: state.mainThreadApplications)
        }
    }

    @discardableResult
    func submit(_ request: Request) -> Bool {
        submit { _ in request } != nil
    }

    /// Constructs the visible request generation inside the admission lock.
    ///
    /// Calibration cancellation can race a blocked Begin from another thread.
    /// Assigning the intent outside this lock would let generation 2 enter the
    /// lane before generation 1 and make the older desire win.
    func submit(_ makeRequest: (UInt64) -> Request) -> Request? {
        let decision: (request: Request, schedulesWorker: Bool, displaced: Work?)? =
            lock.withLock {
                guard state.acceptsWork else { return nil }
                state.generation &+= 1
                if state.generation == 0 { state.generation = 1 }
                let request = makeRequest(state.generation)
                let work = Work(request: request, generation: state.generation)
                state.submissions &+= 1
                var displaced: Work?
                if state.active == nil {
                    state.active = work
                } else {
                    if state.pending != nil { state.coalesced &+= 1 }
                    displaced = state.pending
                    state.pending = work
                    state.maximumPendingApplications = max(
                        state.maximumPendingApplications, 1)
                }
                guard !state.hasWorker else { return (request, false, displaced) }
                state.hasWorker = true
                return (request, true, displaced)
            }
        guard let decision else { return nil }
        // A request may own a large raw capture lease. Keep its final ARC
        // release outside the lane lock so deallocation cannot extend the
        // critical section or re-enter this owner while admission is blocked.
        withExtendedLifetime(decision.displaced) {}
        if decision.schedulesWorker { queue.async { [self] in drain() } }
        return decision.request
    }

    /// Revokes queued and in-flight work without joining the worker.
    func invalidate() {
        let displaced = lock.withLock { () -> Work? in
            state.generation &+= 1
            if state.generation == 0 { state.generation = 1 }
            let displaced = state.pending
            state.pending = nil
            return displaced
        }
        withExtendedLifetime(displaced) {}
    }

    /// Permanently closes admission without joining the worker.
    func shutdown() {
        let displaced = lock.withLock { () -> Work? in
            state.acceptsWork = false
            state.generation &+= 1
            if state.generation == 0 { state.generation = 1 }
            let displaced = state.pending
            state.pending = nil
            return displaced
        }
        withExtendedLifetime(displaced) {}
    }

    private func drain() {
        while let work = beginApplication() {
            let context = DiagnosticApplicationContext(
                isCurrentGeneration: { [weak self] in
                    self?.isCurrent(work.generation) == true
                })
            let response = autoreleasepool { apply(work.request, context) }
            if finishApplication(work) {
                scheduleMain { [self] in
                    deliver(response, generation: work.generation)
                }
            }
        }
    }

    private func beginApplication() -> Work? {
        let isMainThread = Thread.isMainThread
        return lock.withLock {
            guard let work = state.active else {
                state.hasWorker = false
                return nil
            }
            state.applications &+= 1
            state.activeApplications += 1
            state.maximumActiveApplications = max(
                state.maximumActiveApplications, state.activeApplications)
            if isMainThread { state.mainThreadApplications &+= 1 }
            return work
        }
    }

    private func finishApplication(_ work: Work) -> Bool {
        lock.withLock {
            precondition(state.active?.generation == work.generation)
            state.activeApplications -= 1
            let isCurrent = state.acceptsWork && state.generation == work.generation
            if !isCurrent { state.revokedResults &+= 1 }
            state.active = state.pending
            state.pending = nil
            return isCurrent
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { state.acceptsWork && state.generation == generation }
    }

    @MainActor
    private func deliver(_ response: Response, generation: UInt64) {
        let accepted = lock.withLock {
            guard state.acceptsWork, state.generation == generation else {
                state.revokedResults &+= 1
                return false
            }
            state.publications &+= 1
            return true
        }
        if accepted { publish(response) }
    }
}

/// Runs complete diagnostic evaluation on one bounded worker away from MainActor.
///
/// Submission never evaluates the payload. At most one capture is active and
/// one newer capture is retained; only the latest generation may publish.
final class DiagnosticLifecycleWorker<Capture: Sendable, Result: Sendable>:
    @unchecked Sendable
{
    typealias MainScheduler =
        @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    private let lane:
        DiagnosticLatestLane<
            DiagnosticCaptureSnapshot<Capture>, DiagnosticEvaluation<Result>
        >

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.diagnostics", qos: .userInitiated),
        evaluate: @escaping @Sendable (DiagnosticCaptureSnapshot<Capture>) -> Result,
        scheduleMain: @escaping MainScheduler = { body in
            Task { @MainActor in body() }
        },
        publish: @escaping @MainActor @Sendable (DiagnosticEvaluation<Result>) -> Void
    ) {
        lane = DiagnosticLatestLane(
            queue: queue,
            apply: { snapshot, _ in
                DiagnosticEvaluation(
                    captureGeneration: snapshot.generation,
                    result: evaluate(snapshot))
            },
            scheduleMain: scheduleMain,
            publish: publish)
    }

    @discardableResult
    func submit(_ snapshot: DiagnosticCaptureSnapshot<Capture>) -> Bool {
        lane.submit(snapshot)
    }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }

    var statistics: DiagnosticLifecycleStatistics { lane.statistics }
}

/// The newest calibration state requested by the interface.
enum CalibrationDesiredState: Equatable, Sendable {
    case active
    case inactive
}

/// One calibration desire and its monotonic admission generation.
struct CalibrationIntent: Equatable, Sendable {
    let generation: UInt64
    let desiredState: CalibrationDesiredState
}

/// A revocable permit checked at the engine mutation point.
///
/// The engine integration must read `mayMutateEngine` only after acquiring its
/// lifecycle lock and immediately before changing calibration state. A Begin
/// which was waiting for that lock will then observe a later Cancel generation
/// and leave the engine inactive.
struct CalibrationMutationPermit: Sendable {
    fileprivate let isCurrentGeneration: @Sendable () -> Bool

    var mayMutateEngine: Bool { isCurrentGeneration() }
}

/// The value-only completion of one calibration lifecycle mutation.
///
/// `Outcome` deliberately preserves the engine's typed result. Collapsing a
/// revoked generation, a missing route and an RT publication failure into one
/// Boolean would make the interface report the wrong recovery action.
struct CalibrationLifecycleCompletion<Outcome: Equatable & Sendable>:
    Equatable, Sendable
{
    let intent: CalibrationIntent
    let outcome: Outcome
}

/// Submits the latest desired calibration state to one engine lifecycle owner.
///
/// The queue is required rather than defaulted: integration must pass the
/// engine's existing serial lifecycle queue, not accidentally create a second
/// owner beside it.
final class CalibrationLifecycleWorker<Outcome: Equatable & Sendable>:
    @unchecked Sendable
{
    typealias MainScheduler =
        @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    typealias Apply =
        @Sendable (CalibrationIntent, CalibrationMutationPermit) -> Outcome

    private let lane:
        DiagnosticLatestLane<
            CalibrationIntent, CalibrationLifecycleCompletion<Outcome>
        >

    init(
        lifecycleQueue: DispatchQueue,
        apply: @escaping Apply,
        scheduleMain: @escaping MainScheduler = { body in
            Task { @MainActor in body() }
        },
        publish:
            @escaping @MainActor @Sendable (
                CalibrationLifecycleCompletion<Outcome>
            ) -> Void
    ) {
        lane = DiagnosticLatestLane(
            queue: lifecycleQueue,
            apply: { intent, context in
                CalibrationLifecycleCompletion(
                    intent: intent,
                    outcome: apply(
                        intent,
                        CalibrationMutationPermit(
                            isCurrentGeneration: context.isCurrentGeneration)))
            },
            scheduleMain: scheduleMain,
            publish: publish)
    }

    @discardableResult
    func submit(_ desiredState: CalibrationDesiredState) -> CalibrationIntent? {
        lane.submit { generation in
            CalibrationIntent(generation: generation, desiredState: desiredState)
        }
    }

    @discardableResult
    func begin() -> CalibrationIntent? { submit(.active) }

    @discardableResult
    func cancel() -> CalibrationIntent? { submit(.inactive) }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }

    var statistics: DiagnosticLifecycleStatistics { lane.statistics }
}
