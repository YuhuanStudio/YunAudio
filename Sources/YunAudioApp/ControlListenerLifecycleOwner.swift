import Foundation
import YunAudioControl
import YunDesign

/// The blocking socket lifecycle used by the production owner and deterministic tests.
protocol ControlListenerLifecycleBackend: AnyObject, Sendable {
    var openClientCount: Int { get }
    func start(handler: @escaping ControlListener.Handler) throws
    @discardableResult func stop() -> Bool
}

extension ControlListener: ControlListenerLifecycleBackend {}

/// Owns listener bind, stale-socket probing and bounded stop away from MainActor.
///
/// `ControlListener.start` can spend 200 ms proving that a socket path is stale,
/// while `stop` may wait 250 ms for the accept owner. Both are valid bounded
/// waits and both are far beyond a UI frame. MainActor therefore only changes
/// this generation and admits a serial operation; a stale handler checks the
/// generation before it can reach the model.
final class ControlListenerLifecycleOwner: @unchecked Sendable {
    enum StartResult: Equatable, Sendable {
        case started
        /// The request still owns the sole queue, but an older lifecycle call
        /// has not returned yet. Its eventual entry remains admitted.
        case queued
        case alreadyRunning
        case superseded
        case failed(String)
    }

    struct Statistics: Equatable, Sendable {
        var startApplications: UInt64 = 0
        var stopApplications: UInt64 = 0
        var startTimeouts: UInt64 = 0
        var queuedStartPublications: UInt64 = 0
        var stopTimeouts: UInt64 = 0
        var startPublications: UInt64 = 0
        var supersededStarts: UInt64 = 0
        var stopPublications: UInt64 = 0
        var refusedHandlerAdmissions: UInt64 = 0
        var concurrentLifecycleOperations = 0
        var maximumConcurrentLifecycleOperations = 0
        var activeOwners = 0
        var maximumActiveOwners = 0
        var openClients = 0
    }

    typealias StartCompletion = @MainActor @Sendable (StartResult) -> Void
    typealias StopCompletion = @MainActor @Sendable (Bool) -> Void

    private struct State {
        var generation: UInt64 = 0
        var acceptsStarts = true
        var wantsRunning = false
        var startInFlightGeneration: UInt64?
        var startEnteredGeneration: UInt64?
        var backend: (any ControlListenerLifecycleBackend)?
        var statistics = Statistics()
    }

    private final class StartCompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: StartCompletion?

        init(_ completion: StartCompletion?) { self.completion = completion }

        func claim() -> StartCompletion? {
            lock.withLock {
                let claimed = completion
                completion = nil
                return claimed
            }
        }
    }

    private final class StopCompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: StopCompletion?

        init(_ completion: StopCompletion?) { self.completion = completion }

        func claim() -> StopCompletion? {
            lock.withLock {
                let claimed = completion
                completion = nil
                return claimed
            }
        }
    }

    private let lock = NSLock()
    private var state = State()
    private let ownerQueue: DispatchQueue
    private let makeBackend: @Sendable () -> any ControlListenerLifecycleBackend
    private let startTimeout: TimeInterval
    private let stopTimeout: TimeInterval
    private let scheduleOnMainActor:
        @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    init(
        label: String = "com.yuhuanstudio.yunaudio.control-lifecycle",
        startTimeout: TimeInterval = 0.5,
        stopTimeout: TimeInterval = 0.4,
        makeBackend: @escaping @Sendable () -> any ControlListenerLifecycleBackend = {
            ControlListener()
        },
        scheduleOnMainActor:
            @escaping @Sendable (
                @escaping @MainActor @Sendable () -> Void
            ) -> Void = { MainRunLoopDelivery.perform($0) }
    ) {
        ownerQueue = DispatchQueue(label: label, qos: .userInitiated)
        self.startTimeout = startTimeout
        self.stopTimeout = stopTimeout
        self.makeBackend = makeBackend
        self.scheduleOnMainActor = scheduleOnMainActor
    }

    var statistics: Statistics {
        let snapshot: (Statistics, (any ControlListenerLifecycleBackend)?) = lock.withLock {
            (state.statistics, state.backend)
        }
        var statistics = snapshot.0
        statistics.openClients = snapshot.1?.openClientCount ?? 0
        return statistics
    }

    /// Admits a start and returns before any filesystem or socket operation.
    func start(handler: @escaping ControlListener.Handler, completion: StartCompletion? = nil) {
        let completionGate = StartCompletionGate(completion)
        let admission: (UInt64, StartResult?) = lock.withLock {
            guard state.acceptsStarts else { return (state.generation, .superseded) }
            guard !state.wantsRunning else {
                return (state.generation, .alreadyRunning)
            }
            state.generation &+= 1
            state.wantsRunning = true
            state.startInFlightGeneration = state.generation
            state.startEnteredGeneration = nil
            return (state.generation, nil)
        }
        if let refused = admission.1 {
            publishStart(refused, generation: admission.0, completionGate: completionGate)
            return
        }
        let generation = admission.0
        scheduleStartAdmissionWatchdog(
            generation: generation, completionGate: completionGate)
        ownerQueue.async {
            self.performStart(
                generation: generation, handler: handler, completionGate: completionGate)
        }
    }

    /// Invalidates handler admission immediately and performs the socket join off-main.
    func stop(completion: StopCompletion? = nil) {
        let completionGate = StopCompletionGate(completion)
        lock.withLock {
            state.generation &+= 1
            state.wantsRunning = false
        }
        scheduleStopWatchdog(completionGate)
        ownerQueue.async {
            self.performStop(completionGate: completionGate)
        }
    }

    /// Permanently rejects future starts. Used only after AppKit accepts Quit.
    func shutdown(completion: StopCompletion? = nil) {
        let completionGate = StopCompletionGate(completion)
        lock.withLock {
            state.acceptsStarts = false
            state.generation &+= 1
            state.wantsRunning = false
        }
        scheduleStopWatchdog(completionGate)
        ownerQueue.async {
            self.performStop(completionGate: completionGate)
        }
    }

    private func performStart(
        generation: UInt64, handler: @escaping ControlListener.Handler,
        completionGate: StartCompletionGate
    ) {
        beginLifecycleApplication(isStart: true)
        defer { endLifecycleApplication() }
        let entered = lock.withLock {
            guard state.acceptsStarts, state.wantsRunning,
                state.generation == generation,
                state.startInFlightGeneration == generation
            else { return false }
            state.startEnteredGeneration = generation
            return true
        }
        guard entered else {
            finishStartCensus(generation: generation)
            markSupersededStart()
            publishStart(
                .superseded, generation: generation, completionGate: completionGate)
            return
        }
        scheduleEnteredStartWatchdog(
            generation: generation, completionGate: completionGate)
        beginBackendCensus()
        let backend = makeBackend()
        do {
            try backend.start { [weak self] request, deadline, reply in
                guard let self else {
                    reply(.failure(loc("The application is no longer available.")))
                    return
                }
                guard self.isWanted(generation) else {
                    self.lock.withLock {
                        self.state.statistics.refusedHandlerAdmissions &+= 1
                    }
                    reply(.failure(loc("The control listener is stopping.")))
                    return
                }
                handler(request, deadline, reply)
            }
        } catch {
            let result: StartResult = lock.withLock {
                if state.startInFlightGeneration == generation {
                    state.startInFlightGeneration = nil
                }
                if state.startEnteredGeneration == generation {
                    state.startEnteredGeneration = nil
                }
                state.statistics.activeOwners = 0
                guard state.generation == generation, state.wantsRunning else {
                    return .superseded
                }
                state.wantsRunning = false
                return .failed(String(describing: error))
            }
            if result == .superseded { markSupersededStart() }
            publishStart(result, generation: generation, completionGate: completionGate)
            return
        }

        let publishes = lock.withLock {
            if state.startInFlightGeneration == generation {
                state.startInFlightGeneration = nil
            }
            if state.startEnteredGeneration == generation {
                state.startEnteredGeneration = nil
            }
            guard state.acceptsStarts, state.wantsRunning, state.generation == generation else {
                return false
            }
            state.backend = backend
            return true
        }
        guard publishes else {
            _ = backend.stop()
            lock.withLock { state.statistics.activeOwners = 0 }
            markSupersededStart()
            publishStart(
                .superseded, generation: generation, completionGate: completionGate)
            return
        }
        publishStart(.started, generation: generation, completionGate: completionGate)
    }

    private func performStop(completionGate: StopCompletionGate) {
        beginLifecycleApplication(isStart: false)
        defer { endLifecycleApplication() }
        let backend = lock.withLock { state.backend }
        let acknowledged = backend?.stop() ?? true
        lock.withLock {
            if let backend, state.backend === backend { state.backend = nil }
            state.statistics.activeOwners = 0
        }
        guard let completion = completionGate.claim() else { return }
        scheduleOnMainActor {
            self.lock.withLock { self.state.statistics.stopPublications &+= 1 }
            completion(acknowledged)
        }
    }

    private func publishStart(
        _ result: StartResult, generation: UInt64, completionGate: StartCompletionGate
    ) {
        let delivered = lock.withLock { () -> StartResult in
            let requiresCurrentGeneration = result == .started || result == .queued
            guard requiresCurrentGeneration,
                state.generation != generation || !state.wantsRunning
            else { return result }
            state.statistics.supersededStarts &+= 1
            return .superseded
        }
        guard let completion = completionGate.claim() else { return }
        scheduleOnMainActor {
            self.lock.withLock {
                self.state.statistics.startPublications &+= 1
            }
            completion(delivered)
        }
    }

    private func scheduleStartAdmissionWatchdog(
        generation: UInt64, completionGate: StartCompletionGate
    ) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + startTimeout) {
            let remainedQueued = self.lock.withLock {
                guard self.state.startInFlightGeneration == generation,
                    self.state.startEnteredGeneration != generation,
                    self.state.generation == generation, self.state.wantsRunning
                else { return false }
                self.state.statistics.queuedStartPublications &+= 1
                return true
            }
            guard remainedQueued else { return }
            self.publishStart(
                .queued, generation: generation, completionGate: completionGate)
        }
    }

    private func scheduleEnteredStartWatchdog(
        generation: UInt64, completionGate: StartCompletionGate
    ) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + startTimeout) {
            let timedOut = self.lock.withLock {
                guard self.state.startInFlightGeneration == generation,
                    self.state.startEnteredGeneration == generation,
                    self.state.generation == generation, self.state.wantsRunning
                else { return false }
                self.state.generation &+= 1
                self.state.wantsRunning = false
                self.state.statistics.startTimeouts &+= 1
                return true
            }
            guard timedOut else { return }
            self.publishStart(
                .failed(loc("The control listener did not start before the deadline.")),
                generation: generation, completionGate: completionGate)
        }
    }

    private func scheduleStopWatchdog(_ completionGate: StopCompletionGate) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + stopTimeout) {
            guard let completion = completionGate.claim() else { return }
            self.lock.withLock {
                self.state.statistics.stopTimeouts &+= 1
                self.state.statistics.stopPublications &+= 1
            }
            self.scheduleOnMainActor { completion(false) }
        }
    }

    private func isWanted(_ generation: UInt64) -> Bool {
        lock.withLock {
            state.acceptsStarts && state.wantsRunning && state.generation == generation
        }
    }

    private func markSupersededStart() {
        lock.withLock { state.statistics.supersededStarts &+= 1 }
    }

    private func beginBackendCensus() {
        lock.withLock {
            state.statistics.activeOwners = 1
            state.statistics.maximumActiveOwners = max(
                state.statistics.maximumActiveOwners, state.statistics.activeOwners)
        }
    }

    private func finishStartCensus(generation: UInt64) {
        lock.withLock {
            if state.startInFlightGeneration == generation {
                state.startInFlightGeneration = nil
            }
            if state.startEnteredGeneration == generation {
                state.startEnteredGeneration = nil
            }
            state.statistics.activeOwners = 0
        }
    }

    private func beginLifecycleApplication(isStart: Bool) {
        lock.withLock {
            if isStart {
                state.statistics.startApplications &+= 1
            } else {
                state.statistics.stopApplications &+= 1
            }
            state.statistics.concurrentLifecycleOperations += 1
            state.statistics.maximumConcurrentLifecycleOperations = max(
                state.statistics.maximumConcurrentLifecycleOperations,
                state.statistics.concurrentLifecycleOperations)
        }
    }

    private func endLifecycleApplication() {
        lock.withLock {
            precondition(state.statistics.concurrentLifecycleOperations == 1)
            state.statistics.concurrentLifecycleOperations = 0
        }
    }

    deinit {
        let backend = lock.withLock { state.backend }
        if backend != nil {
            NonBlockingDiagnostic.write(
                "control lifecycle owner released before explicit shutdown\n")
        }
    }
}
