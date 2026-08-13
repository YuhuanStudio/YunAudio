import Foundation
import YunAudioEngine

/// One admitted speech source, independent of its current source-ring slot.
struct TranscriberLifecycleSource: Sendable, Equatable {
    let identity: SourceTapPCMForwarder.Identity
    let name: String
}

/// One desired speech-model topology.
struct TranscriberLifecycleRequest: Sendable, Equatable {
    let topologyGeneration: UInt64
    let transcriptGeneration: UInt64
    let sources: [TranscriberLifecycleSource]

    static func closed(
        topologyGeneration: UInt64, transcriptGeneration: UInt64
    ) -> TranscriberLifecycleRequest {
        TranscriberLifecycleRequest(
            topologyGeneration: topologyGeneration,
            transcriptGeneration: transcriptGeneration, sources: [])
    }
}

/// Owns speech-model starts, final result barriers and their bounded shutdown.
///
/// At most two models start together. A newer topology replaces the one pending
/// request, while every session already returned by an obsolete start remains
/// owned until its final result stream ends. Shutdown races that complete path
/// against a deadline; a timeout publishes once but deliberately retains the
/// worker task and sessions for process-lifetime containment.
final class TranscriberLifecycleWorker: @unchecked Sendable {
    final class Session: @unchecked Sendable {
        let identity: SourceTapPCMForwarder.Identity
        let consume: @Sendable ([Float], Double) -> Void
        private let startOperation: @Sendable (Double) async throws -> Void
        private let stopOperation: @Sendable () async -> Void

        init(
            identity: SourceTapPCMForwarder.Identity,
            consume: @escaping @Sendable ([Float], Double) -> Void,
            start: @escaping @Sendable (Double) async throws -> Void,
            stop: @escaping @Sendable () async -> Void
        ) {
            self.identity = identity
            self.consume = consume
            startOperation = start
            stopOperation = stop
        }

        func start(now: Double) async throws { try await startOperation(now) }
        func stop() async { await stopOperation() }
    }

    struct Binding: @unchecked Sendable {
        let identity: SourceTapPCMForwarder.Identity
        let consume: @Sendable ([Float], Double) -> Void
    }

    struct Snapshot: @unchecked Sendable {
        let topologyGeneration: UInt64
        let transcriptGeneration: UInt64
        let bindings: [Binding]
        let finalisedStop: Bool
        let failure: Transcriber.Unavailable?
    }

    struct Statistics: Sendable, Equatable {
        let submissions: UInt64
        let coalesced: UInt64
        let applications: UInt64
        let publications: UInt64
        let maximumPending: Int
        let activeSessions: Int
        let activeStarts: Int
        let maximumActiveStarts: Int
        let mainThreadStarts: UInt64
        let mainThreadStops: UInt64
        let shutdownTimeouts: UInt64
        let stalePublications: UInt64
        let acceptsRequests: Bool
    }

    typealias Factory = @Sendable (TranscriberLifecycleSource, UInt64) -> Session
    typealias Scheduler =
        @Sendable (
            @escaping @MainActor @Sendable () -> Void
        ) -> Void

    private struct State {
        var acceptsRequests = true
        var latestToken: UInt64 = 0
        var pending: Envelope?
        var isProcessing = false
        var active: [SourceTapPCMForwarder.Identity: ActiveSession] = [:]
        var shutdownFence: OwnedResourceTeardownFence?
        var submissions: UInt64 = 0
        var coalesced: UInt64 = 0
        var applications: UInt64 = 0
        var publications: UInt64 = 0
        var maximumPending = 0
        var activeStarts = 0
        var maximumActiveStarts = 0
        var mainThreadStarts: UInt64 = 0
        var mainThreadStops: UInt64 = 0
        var shutdownTimeouts: UInt64 = 0
        var stalePublications: UInt64 = 0
        var quarantineToken: ProcessLifetimeResourceQuarantine.Token?
    }

    private struct Envelope: Sendable {
        let token: UInt64
        let request: TranscriberLifecycleRequest
    }

    private enum StartOutcome: @unchecked Sendable {
        case started(Session)
        case failed(Session, Transcriber.Unavailable)
    }

    private struct ActiveSession: @unchecked Sendable {
        let transcriptGeneration: UInt64
        let session: Session
    }

    private let lock = NSLock()
    private var state = State()
    private let factory: Factory
    private let publish: @MainActor @Sendable (Snapshot) -> Void
    private let schedule: Scheduler
    private let deadlineQueue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.transcriber-finalisation-deadline",
        qos: .utility)
    private let resourceQuarantine: ProcessLifetimeResourceQuarantine

    init(
        factory: @escaping Factory,
        schedule: @escaping Scheduler = {
            MainRunLoopDelivery.perform($0)
        },
        resourceQuarantine: ProcessLifetimeResourceQuarantine = .shared,
        publish: @escaping @MainActor @Sendable (Snapshot) -> Void
    ) {
        self.factory = factory
        self.schedule = schedule
        self.resourceQuarantine = resourceQuarantine
        self.publish = publish
    }

    @discardableResult
    func submit(_ request: TranscriberLifecycleRequest) -> Bool {
        let starts = lock.withLock { () -> Bool in
            guard state.acceptsRequests else { return false }
            state.submissions &+= 1
            if state.pending != nil { state.coalesced &+= 1 }
            state.latestToken &+= 1
            state.pending = Envelope(token: state.latestToken, request: request)
            state.maximumPending = max(state.maximumPending, 1)
            guard !state.isProcessing else { return false }
            state.isProcessing = true
            return true
        }
        if starts { startProcessing() }
        return true
    }

    /// Permanently ends admission and returns the exact-once bounded result.
    func shutdown(
        topologyGeneration: UInt64, transcriptGeneration: UInt64,
        timeout: TimeInterval = 0.5
    ) -> OwnedResourceTeardownFence {
        let decision = lock.withLock {
            if let fence = state.shutdownFence { return (fence, false, false) }
            let fence = OwnedResourceTeardownFence()
            state.shutdownFence = fence
            state.acceptsRequests = false
            if state.pending != nil { state.coalesced &+= 1 }
            state.latestToken &+= 1
            state.pending = Envelope(
                token: state.latestToken,
                request: .closed(
                    topologyGeneration: topologyGeneration,
                    transcriptGeneration: transcriptGeneration))
            state.maximumPending = max(state.maximumPending, 1)
            let starts = !state.isProcessing
            if starts { state.isProcessing = true }
            return (fence, starts, true)
        }
        if decision.1 { startProcessing() }
        if decision.2 {
            deadlineQueue.asyncAfter(deadline: .now() + max(0, timeout)) { [self] in
                // A Speech finaliser has no cancellation contract. Make the
                // process-lifetime retention explicit instead of relying on an
                // async task frame accidentally keeping the model alive. The
                // quarantine must be visible before the timeout fence wakes an
                // observer; the reverse order made a completed timeout briefly
                // claim no retained owner in a fresh full-suite run.
                let token = resourceQuarantine.retain(self)
                lock.withLock {
                    state.shutdownTimeouts &+= 1
                    state.quarantineToken = token
                }
                guard decision.0.complete(.timedOut) else {
                    let shouldRelease = lock.withLock {
                        guard state.quarantineToken == token else { return false }
                        state.shutdownTimeouts &-= 1
                        state.quarantineToken = nil
                        return true
                    }
                    if shouldRelease { resourceQuarantine.release(token) }
                    return
                }
            }
        }
        return decision.0
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(
                submissions: state.submissions, coalesced: state.coalesced,
                applications: state.applications, publications: state.publications,
                maximumPending: state.maximumPending,
                activeSessions: state.active.count,
                activeStarts: state.activeStarts,
                maximumActiveStarts: state.maximumActiveStarts,
                mainThreadStarts: state.mainThreadStarts,
                mainThreadStops: state.mainThreadStops,
                shutdownTimeouts: state.shutdownTimeouts,
                stalePublications: state.stalePublications,
                acceptsRequests: state.acceptsRequests)
        }
    }

    private func startProcessing() {
        Task.detached(priority: .userInitiated) { [self] in await processRequests() }
    }

    private func processRequests() async {
        while true {
            if let envelope = takePendingRequest() {
                await apply(envelope)
                continue
            }
            let finish = lock.withLock {
                () -> (retry: Bool, fence: OwnedResourceTeardownFence?) in
                // A submit can land after `takePendingRequest` saw nil. The
                // current task still owns processing in that race, so consume
                // it here rather than leaving pending work behind an eternal
                // `isProcessing == true` flag.
                guard state.pending == nil else { return (true, nil) }
                state.isProcessing = false
                let fence = state.active.isEmpty ? state.shutdownFence : nil
                return (false, fence)
            }
            if finish.retry { continue }
            if let fence = finish.fence { _ = fence.complete(.complete) }
            return
        }
    }

    private func takePendingRequest() -> Envelope? {
        lock.withLock {
            guard let pending = state.pending else { return nil }
            state.pending = nil
            state.applications &+= 1
            return pending
        }
    }

    private func apply(_ envelope: Envelope) async {
        let request = envelope.request
        let desired = Set(request.sources.map(\.identity))
        let obsolete = lock.withLock {
            state.active.values.compactMap { active in
                !desired.contains(active.session.identity)
                    || active.transcriptGeneration != request.transcriptGeneration
                    ? active.session : nil
            }
        }
        if !obsolete.isEmpty {
            await stop(obsolete)
            lock.withLock {
                for session in obsolete
                where state.active[session.identity]?.session === session {
                    state.active[session.identity] = nil
                }
            }
        }

        let existing = lock.withLock { Set(state.active.keys) }
        var missing = request.sources.filter { !existing.contains($0.identity) }
        var started: [Session] = []
        var failure: Transcriber.Unavailable?
        let now = Date().timeIntervalSince1970

        while !missing.isEmpty, failure == nil {
            let batch = Array(
                missing.prefix(TranscriptionAdmission.maximumConcurrentStarts))
            missing.removeFirst(batch.count)
            let outcomes = await start(
                batch, generation: request.transcriptGeneration, now: now)
            for outcome in outcomes {
                switch outcome {
                case .started(let session):
                    started.append(session)
                case let .failed(session, reason):
                    failure = reason
                    await stop([session])
                }
            }
            if !isCurrent(envelope.token) { break }
        }

        guard failure == nil, isCurrent(envelope.token) else {
            await stop(started)
            schedulePublicationIfCurrent(envelope, failure: failure)
            return
        }
        lock.withLock {
            for session in started {
                state.active[session.identity] = ActiveSession(
                    transcriptGeneration: request.transcriptGeneration,
                    session: session)
            }
        }
        schedulePublicationIfCurrent(envelope, failure: nil)
    }

    private func start(
        _ sources: [TranscriberLifecycleSource], generation: UInt64, now: Double
    ) async -> [StartOutcome] {
        await withTaskGroup(of: StartOutcome.self, returning: [StartOutcome].self) { group in
            for source in sources {
                let session = factory(source, generation)
                group.addTask { [self] in
                    recordStartBegan()
                    defer { recordStartEnded() }
                    do {
                        try await session.start(now: now)
                        return .started(session)
                    } catch let unavailable as Transcriber.Unavailable {
                        return .failed(session, unavailable)
                    } catch {
                        return .failed(session, .failed(String(describing: error)))
                    }
                }
            }
            var outcomes: [StartOutcome] = []
            outcomes.reserveCapacity(sources.count)
            for await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
    }

    private func stop(_ sessions: [Session]) async {
        guard !sessions.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { [self] in
                    recordStopThread()
                    await session.stop()
                }
            }
        }
    }

    private func recordStopThread() {
        if Thread.isMainThread {
            lock.withLock { state.mainThreadStops &+= 1 }
        }
    }

    private func recordStartBegan() {
        let isMain = Thread.isMainThread
        lock.withLock {
            state.activeStarts += 1
            state.maximumActiveStarts = max(
                state.maximumActiveStarts, state.activeStarts)
            if isMain { state.mainThreadStarts &+= 1 }
        }
    }

    private func recordStartEnded() {
        lock.withLock { state.activeStarts -= 1 }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.withLock { token == state.latestToken }
    }

    private func schedulePublicationIfCurrent(
        _ envelope: Envelope,
        failure: Transcriber.Unavailable?
    ) {
        let request = envelope.request
        let snapshot: Snapshot? = lock.withLock {
            guard envelope.token == state.latestToken else { return nil }
            let bindings = request.sources.compactMap { source -> Binding? in
                guard let active = state.active[source.identity],
                    active.transcriptGeneration == request.transcriptGeneration
                else { return nil }
                let session = active.session
                return Binding(identity: session.identity, consume: session.consume)
            }
            return Snapshot(
                topologyGeneration: request.topologyGeneration,
                transcriptGeneration: request.transcriptGeneration,
                bindings: bindings, finalisedStop: request.sources.isEmpty,
                failure: failure)
        }
        guard let snapshot else { return }
        schedule { [self] in deliver(snapshot, token: envelope.token) }
    }

    @MainActor
    private func deliver(_ snapshot: Snapshot, token: UInt64) {
        let isLatest = lock.withLock {
            guard token == state.latestToken else {
                state.stalePublications &+= 1
                return false
            }
            state.publications &+= 1
            return true
        }
        guard isLatest else { return }
        publish(snapshot)
    }
}
