import Foundation

/// A sole serial owner for system-service work with first/latest admission.
///
/// The first accepted request is reserved before the worker is scheduled, so a
/// burst cannot replace it merely because the queue has not begun running yet.
/// While that request is active, at most one newer value is retained. An API
/// which ignores an elapsed-time budget keeps this one owner until it returns;
/// the lane never creates a replacement thread which could become stuck in the
/// same service beside it.
final class SoleLatestSystemServiceWorker<Request: Sendable, Response: Sendable>:
    @unchecked Sendable
{
    struct Context: @unchecked Sendable {
        fileprivate let isCurrentGeneration: @Sendable () -> Bool

        /// False once a newer request, invalidation or shutdown revoked this work.
        var shouldContinue: Bool { isCurrentGeneration() }
    }

    struct Statistics: Equatable, Sendable {
        fileprivate(set) var submissions: UInt64 = 0
        fileprivate(set) var coalesced: UInt64 = 0
        fileprivate(set) var applications: UInt64 = 0
        fileprivate(set) var publications: UInt64 = 0
        fileprivate(set) var revokedResults: UInt64 = 0
        fileprivate(set) var timedOutApplications: UInt64 = 0
        fileprivate(set) var terminalOperations: UInt64 = 0
        fileprivate(set) var maximumPending: Int = 0
        fileprivate(set) var maximumConcurrentApplications: Int = 0
    }

    private struct Work {
        let request: Request
        let generation: UInt64
    }

    private struct State {
        var active: Work?
        var pending: Work?
        var acceptsWork = true
        var generation: UInt64 = 0
        var concurrentApplications = 0
        var terminal: (@Sendable () -> Void)?
        var statistics = Statistics()
    }

    private let lock = NSLock()
    private var state = State()
    private let queue: DispatchQueue
    private let apply: @Sendable (Request, Context) -> Response
    private let didTimeOut: @Sendable (Response) -> Bool
    private let publish: @MainActor @Sendable (Response) -> Void

    init(
        queue: DispatchQueue,
        apply: @escaping @Sendable (Request, Context) -> Response,
        didTimeOut: @escaping @Sendable (Response) -> Bool = { _ in false },
        publish: @escaping @MainActor @Sendable (Response) -> Void
    ) {
        self.queue = queue
        self.apply = apply
        self.didTimeOut = didTimeOut
        self.publish = publish
    }

    var statistics: Statistics { lock.withLock { state.statistics } }

    @discardableResult
    func submit(_ request: Request) -> Bool {
        let schedulesWorker: Bool? = lock.withLock {
            guard state.acceptsWork else { return nil }
            state.generation &+= 1
            state.statistics.submissions &+= 1
            let work = Work(request: request, generation: state.generation)
            guard state.active != nil else {
                // Reserving here, rather than when the queue eventually wakes,
                // makes "first" a property of admission rather than timing.
                state.active = work
                return true
            }
            if state.pending != nil { state.statistics.coalesced &+= 1 }
            state.pending = work
            state.statistics.maximumPending = max(state.statistics.maximumPending, 1)
            return false
        }
        guard let schedulesWorker else { return false }
        if schedulesWorker { queue.async { [self] in drain() } }
        return true
    }

    /// Revokes old publication while leaving admission open for a refused Quit.
    func invalidate() {
        lock.withLock {
            state.generation &+= 1
            if state.pending != nil { state.statistics.revokedResults &+= 1 }
            state.pending = nil
        }
    }

    /// Closes admission and drops results without waiting for a system service.
    func shutdown() { shutdown(after: nil) }

    /// Closes admission and runs one terminal action behind the active request.
    ///
    /// This is for ownership which cannot be released until earlier calls on the
    /// same framework singleton have returned. The caller never waits for it.
    func shutdown(after terminal: (@Sendable () -> Void)?) {
        let schedulesTerminal: Bool = lock.withLock {
            guard state.acceptsWork else { return false }
            state.acceptsWork = false
            state.generation &+= 1
            if state.pending != nil { state.statistics.revokedResults &+= 1 }
            state.pending = nil
            state.terminal = terminal
            return state.active == nil && terminal != nil
        }
        if schedulesTerminal { queue.async { [self] in runTerminalIfReady() } }
    }

    private func drain() {
        while true {
            guard let work = beginActiveApplication() else {
                runTerminalIfReady()
                return
            }
            let context = Context(isCurrentGeneration: { [weak self] in
                self?.isCurrent(work.generation) == true
            })
            let response = autoreleasepool { apply(work.request, context) }
            let shouldPublish = finishActiveApplication(work, response: response)
            if shouldPublish {
                MainRunLoopDelivery.perform { [self] in
                    deliver(response, generation: work.generation)
                }
            }
        }
    }

    private func beginActiveApplication() -> Work? {
        lock.withLock {
            guard let work = state.active else { return nil }
            state.statistics.applications &+= 1
            state.concurrentApplications += 1
            state.statistics.maximumConcurrentApplications = max(
                state.statistics.maximumConcurrentApplications,
                state.concurrentApplications)
            return work
        }
    }

    private func finishActiveApplication(_ work: Work, response: Response) -> Bool {
        lock.withLock {
            state.concurrentApplications -= 1
            if didTimeOut(response) { state.statistics.timedOutApplications &+= 1 }
            let isCurrent = state.acceptsWork && state.generation == work.generation
            if !isCurrent { state.statistics.revokedResults &+= 1 }
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
                state.statistics.revokedResults &+= 1
                return false
            }
            state.statistics.publications &+= 1
            return true
        }
        if accepted { publish(response) }
    }

    private func runTerminalIfReady() {
        let terminal: (@Sendable () -> Void)? = lock.withLock {
            guard !state.acceptsWork, state.active == nil else { return nil }
            let terminal = state.terminal
            state.terminal = nil
            if terminal != nil { state.statistics.terminalOperations &+= 1 }
            return terminal
        }
        if let terminal { autoreleasepool { terminal() } }
    }
}
