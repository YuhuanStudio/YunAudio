import Foundation
import JavaScriptCore
import YunAudioControl
import YunAudioRT
import YunDesign

/// Owns JavaScriptCore away from MainActor and bounds every way work can enter it.
///
/// The application never waits for this owner. MainActor callers submit value-only
/// work and return; `yun.*` spends the same absolute entry deadline while its small
/// model admission is delivered back to MainActor.
final class ScriptService: @unchecked Sendable {
    static let executionTimeLimit: TimeInterval = 0.25
    static let maximumSourceBytes = 64 * 1024
    static let maximumResultBytes = 64 * 1024
    static let maximumErrorBytes = 4 * 1024
    static let maximumOutputBytes = 64 * 1024
    static let maximumOutputLines = 200
    static let maximumHandlers = 128
    static let maximumRPCsPerEntry = 128
    static let maximumQueuedManualEntries = 16
    static let maximumQueuedResidentEdges = 128
    static let maximumCausalResidentEvents = 128
    /// A native RPC action is part of MainActor's global latency budget. The
    /// production bridge may snapshot state or admit asynchronous model work;
    /// it may not perform HAL, JavaScript or file work before replying.
    static let maximumMainActorRPCSeconds: TimeInterval = 0.008

    enum Event: String, CaseIterable, Sendable {
        case routingStarted = "start"
        case routingStopped = "stop"
        case muted
        case unmuted
        case recordingStarted = "recordStart"
        case recordingStopped = "recordStop"
        case speakingWhileMuted
        case deviceAppeared
        case deviceDisappeared
        case tick
    }

    /// The complete typed boundary from JavaScript back to the application.
    enum RPC: Equatable, Sendable {
        case perform(RemoteCommand)
        case status
        case names
    }

    enum RPCReply: Equatable, Sendable {
        case performed(message: String?, commandFailed: Bool)
        case status(JSONValue)
        case names(presets: [String], configs: [String])
        case failure(String)
    }

    enum EntryKind: Equatable, Sendable {
        case manual
        case reload
        case residentEdge
        case tick
    }

    enum Refusal: Equatable, Sendable {
        case stopped
        case sourceTooLarge
        case payloadTooLarge
        case manualQueueFull
        case residentEdgeQueueFull
        case causalEventLimit
    }

    /// A monotonic boundary owned by the caller which admitted this work.
    ///
    /// The service still enforces its shorter 250 ms interpreter limit. This
    /// value prevents a socket or other bounded transaction from silently
    /// receiving a fresh budget after it has already waited elsewhere.
    struct Deadline: Equatable, Sendable {
        let uptimeNanoseconds: UInt64

        init(_ controlDeadline: ControlRequestDeadline) {
            uptimeNanoseconds = controlDeadline.uptimeNanoseconds
        }

        init(uptimeNanoseconds: UInt64) {
            self.uptimeNanoseconds = uptimeNanoseconds
        }
    }

    /// An opaque lease carried through model work which may complete later.
    ///
    /// A queue cap cannot stop a resident handler which creates exactly one
    /// successor after every dequeue. Keeping this lease with the asynchronous
    /// model intent makes that entire causal chain spend one finite budget,
    /// including route and recording callbacks which arrive after the RPC has
    /// returned.
    struct Causality: @unchecked Sendable {
        fileprivate let serviceIdentifier: UUID
        fileprivate let serviceGeneration: UInt64
        fileprivate let residentGeneration: UInt64
        fileprivate let eventBudget: CausalEventBudget
    }

    enum Submission: Equatable, Sendable {
        case accepted(UInt64)
        case coalesced(UInt64)
        case ignored
        case refused(Refusal)
    }

    struct Result: Equatable, Sendable {
        var value: String
        var log: [String]
        var error: String?

        var isSuccess: Bool { error == nil }
    }

    /// One completed application command, without the temporal coupling of a
    /// separate `lastCommandFailed` flag.
    struct CommandOutcome: Equatable, Sendable {
        var message: String?
        var failed: Bool

        static func success(_ message: String?) -> CommandOutcome {
            CommandOutcome(message: message, failed: false)
        }

        static func failure(_ message: String?) -> CommandOutcome {
            CommandOutcome(message: message, failed: true)
        }
    }

    struct Statistics: Equatable, Sendable {
        var manualSubmissions: UInt64 = 0
        var reloadSubmissions: UInt64 = 0
        var residentEdgeSubmissions: UInt64 = 0
        var tickSubmissions: UInt64 = 0
        var refusedManualSubmissions: UInt64 = 0
        var refusedResidentEdges: UInt64 = 0
        var refusedCausalEvents: UInt64 = 0
        var coalescedTicks: UInt64 = 0
        var revokedEntries: UInt64 = 0
        /// Entries whose admission-time deadline elapsed before their worker
        /// application began. These create no JavaScript context and perform no RPC.
        var expiredEntries: UInt64 = 0
        var entryApplications: UInt64 = 0
        var manualApplications: UInt64 = 0
        var reloadApplications: UInt64 = 0
        var residentEdgeApplications: UInt64 = 0
        var tickApplications: UInt64 = 0
        var resultPublications: UInt64 = 0
        var revokedCompletions: UInt64 = 0
        var rpcSubmissions: UInt64 = 0
        var rpcApplications: UInt64 = 0
        var refusedRPCs: UInt64 = 0
        var revokedRPCs: UInt64 = 0
        var deadlineRPCs: UInt64 = 0
        var mainActorRPCDeadlineOverruns: UInt64 = 0
        var overBudgetMainActorRPCs: UInt64 = 0
        var maximumMainActorRPCNanoseconds: UInt64 = 0
        var lateRPCJobs: UInt64 = 0
        var activeEntries: Int = 0
        var queuedManualEntries: Int = 0
        var queuedResidentEdges: Int = 0
        var pendingTicks: Int = 0
        var pendingRPCs: Int = 0
        var maximumQueuedManualEntries: Int = 0
        var maximumQueuedResidentEdges: Int = 0
        var maximumPendingTicks: Int = 0
        var maximumPendingRPCs: Int = 0
        var maximumConcurrentExecutions: Int = 0
        var residentOwners: Int = 0
        var maximumResidentOwners: Int = 0
        var releasedResidentOwners: UInt64 = 0
        var createdJavaScriptContexts: UInt64 = 0
        var liveJavaScriptContexts: Int = 0
        var maximumLiveJavaScriptContexts: Int = 0
    }

    /// Published only for an entry which reaches its exact generation. Reload,
    /// stop and latest-value replacement suppress stale callbacks rather than
    /// letting old UI or control state overtake the new generation.
    typealias Completion = @MainActor @Sendable (Result) -> Void
    typealias RPCHandler = @MainActor @Sendable (RPC, Causality) -> RPCReply

    private enum Payload: Sendable {
        case manual(String)
        case reload(String)
        case unload
        case residentEdge(Event, JSONValue)
        case tick(JSONValue)
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: Completion?

        init(_ completion: Completion?) { self.completion = completion }

        var isArmed: Bool { lock.withLock { completion != nil } }

        @discardableResult
        func discard() -> Bool {
            lock.withLock {
                guard completion != nil else { return false }
                completion = nil
                return true
            }
        }

        @MainActor
        func finish(_ result: Result) -> Bool {
            let claimed = lock.withLock {
                let claimed = completion
                completion = nil
                return claimed
            }
            claimed?(result)
            return claimed != nil
        }
    }

    /// Shared by every edge synchronously caused by one root entry. A ring cap
    /// cannot stop a handler which creates exactly one successor after each
    /// dequeue; this total budget can.
    fileprivate final class CausalEventBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining = ScriptService.maximumCausalResidentEvents

        func claim() -> Bool {
            lock.withLock {
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
        }
    }

    private struct Entry: Sendable {
        let identifier: UInt64
        let serviceGeneration: UInt64
        let residentGeneration: UInt64?
        let deadlineUptimeNanoseconds: UInt64
        let kind: EntryKind
        let payload: Payload
        let causalEventBudget: CausalEventBudget
        let completion: CompletionGate
    }

    /// A fixed-capacity FIFO makes the edge bound structural, rather than a
    /// convention around an Array which can still grow during a storm.
    private struct EntryFIFO {
        private var storage: [Entry?]
        private var head = 0
        private(set) var count = 0

        init(capacity: Int) {
            storage = [Entry?](repeating: nil, count: capacity)
        }

        var capacity: Int { storage.count }
        var first: Entry? { count == 0 ? nil : storage[head] }

        mutating func append(_ entry: Entry) -> Bool {
            guard count < capacity else { return false }
            storage[(head + count) % capacity] = entry
            count += 1
            return true
        }

        mutating func removeFirst() -> Entry? {
            guard count > 0 else { return nil }
            let entry = storage[head]
            storage[head] = nil
            head = (head + 1) % capacity
            count -= 1
            return entry
        }

        mutating func removeAll() -> [Entry] {
            var removed: [Entry] = []
            removed.reserveCapacity(count)
            while let entry = removeFirst() { removed.append(entry) }
            return removed
        }
    }

    private struct RuntimeIdentity: Equatable, Sendable {
        let entryIdentifier: UInt64
        let serviceGeneration: UInt64
        let residentGeneration: UInt64?
        let deadlineUptimeNanoseconds: UInt64

        var deadline: DispatchTime {
            DispatchTime(uptimeNanoseconds: deadlineUptimeNanoseconds)
        }
    }

    private struct ActiveRPC {
        let identity: RuntimeIdentity
        let pending: PendingRPC
        let causalEventBudget: CausalEventBudget
    }

    private enum EntryAdmission {
        case began
        case expired
        case revoked
    }

    private struct State {
        var acceptsEntries = true
        var serviceGeneration: UInt64 = 1
        var residentGeneration: UInt64 = 0
        var nextEntryIdentifier: UInt64 = 0
        var active: Entry?
        var manual = EntryFIFO(capacity: ScriptService.maximumQueuedManualEntries)
        var residentEdges = EntryFIFO(capacity: ScriptService.maximumQueuedResidentEdges)
        var tick: Entry?
        var listenedEvents: Set<Event> = []
        var activeRPC: ActiveRPC?
        var concurrentExecutions = 0
        var statistics = Statistics()
    }

    private final class PendingRPC: @unchecked Sendable {
        private enum Status {
            case waiting
            case claimed
            case finished(RPCReply)
            case cancelled
        }

        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var status: Status = .waiting

        func claim() -> Bool {
            lock.withLock {
                guard case .waiting = status else { return false }
                status = .claimed
                return true
            }
        }

        func finish(_ reply: RPCReply) {
            let signals = lock.withLock {
                guard case .claimed = status else { return false }
                status = .finished(reply)
                return true
            }
            if signals { ready.signal() }
        }

        func cancel() {
            let signals = lock.withLock {
                switch status {
                case .waiting, .claimed:
                    status = .cancelled
                    return true
                case .finished, .cancelled:
                    return false
                }
            }
            if signals { ready.signal() }
        }

        func wait(until deadline: DispatchTime) -> RPCReply? {
            guard ready.wait(timeout: deadline) == .success else {
                cancel()
                return nil
            }
            return lock.withLock {
                if case .finished(let reply) = status { return reply }
                return nil
            }
        }
    }

    private final class DeadlineFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var reached = false

        func mark() { lock.withLock { reached = true } }
        var wasReached: Bool { lock.withLock { reached } }
    }

    /// Mutable execution state is confined to the JavaScript owner.
    private final class Execution {
        let identity: RuntimeIdentity
        let causalEventBudget: CausalEventBudget
        var output: [String] = []
        var outputBytes = 0
        var failure: String?
        var rpcCount = 0

        init(identity: RuntimeIdentity, causalEventBudget: CausalEventBudget) {
            self.identity = identity
            self.causalEventBudget = causalEventBudget
        }
    }

    /// Handler registration is kept with its context and never crosses the
    /// owner queue. Only its event-name snapshot is copied under the state lock.
    private final class ResidentRegistration: NSObject {
        var handlers: [Event: [JSManagedValue]] = [:]
        var count = 0
        var isInstalled = false
    }

    private final class WeakContextReference {
        weak var value: JSContext?

        init(_ value: JSContext) { self.value = value }
    }

    private let lock = NSLock()
    private var state = State()
    private let serviceIdentifier = UUID()
    private let ownerQueue: DispatchQueue
    private let ownerKey = DispatchSpecificKey<UInt8>()
    private let scheduleOnMainActor:
        @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let rpcHandler: RPCHandler
    private let executionTimeLimit: TimeInterval
    private let onEntryStart: (@Sendable (EntryKind, UInt64) -> Void)?

    // These values are created, read and released only on `ownerQueue`.
    private var residentContext: JSContext?
    private var residentRegistration: ResidentRegistration?
    private var workerResidentGeneration: UInt64?
    private var currentExecution: Execution?
    private var recentContextReferences: [WeakContextReference] = []

    /// - Parameter executionTimeLimit: How long one entry may run before the
    ///   service kills it. Injectable for the reason `ControlListener`'s total
    ///   is: a test that holds a script at a barrier on purpose is spending
    ///   this budget while it does, and on a loaded machine the script it is
    ///   observing dies of the timeout — so the test reports the machine and
    ///   not the barrier. Production uses the fixed public limit.
    init(
        label: String = "com.yuhuanstudio.yunaudio.javascript",
        executionTimeLimit: TimeInterval = ScriptService.executionTimeLimit,
        scheduleOnMainActor:
            @escaping @Sendable (
                @escaping @MainActor @Sendable () -> Void
            ) -> Void = { MainRunLoopDelivery.perform($0) },
        onEntryStart: (@Sendable (EntryKind, UInt64) -> Void)? = nil,
        rpcHandler: @escaping RPCHandler
    ) {
        self.executionTimeLimit = executionTimeLimit
        ownerQueue = DispatchQueue(label: label, qos: .userInitiated)
        self.scheduleOnMainActor = scheduleOnMainActor
        self.onEntryStart = onEntryStart
        self.rpcHandler = rpcHandler
        ownerQueue.setSpecific(key: ownerKey, value: 1)
    }

    var statistics: Statistics {
        lock.withLock {
            var snapshot = state.statistics
            snapshot.activeEntries = state.active == nil ? 0 : 1
            snapshot.queuedManualEntries = state.manual.count
            snapshot.queuedResidentEdges = state.residentEdges.count
            snapshot.pendingTicks = state.tick == nil ? 0 : 1
            snapshot.pendingRPCs = state.activeRPC == nil ? 0 : 1
            return snapshot
        }
    }

    func listens(for event: Event) -> Bool {
        lock.withLock { state.acceptsEntries && state.listenedEvents.contains(event) }
    }

    @discardableResult
    func submitManual(
        _ source: String, deadline: Deadline? = nil, completion: Completion? = nil
    ) -> Submission {
        guard source.utf8.count <= Self.maximumSourceBytes else {
            return .refused(.sourceTooLarge)
        }
        let decision: (Submission, Bool) = lock.withLock {
            guard state.acceptsEntries else { return (.refused(.stopped), false) }
            state.statistics.manualSubmissions &+= 1
            let entry = makeEntryLocked(
                kind: .manual, payload: .manual(source), residentGeneration: nil,
                externalDeadline: deadline, completion: completion)
            guard state.active != nil else {
                state.active = entry
                return (.accepted(entry.identifier), true)
            }
            guard state.manual.append(entry) else {
                state.statistics.refusedManualSubmissions &+= 1
                return (.refused(.manualQueueFull), false)
            }
            state.statistics.maximumQueuedManualEntries = max(
                state.statistics.maximumQueuedManualEntries, state.manual.count)
            return (.accepted(entry.identifier), false)
        }
        if decision.1 { scheduleDrain() }
        return decision.0
    }

    /// Replaces the resident generation synchronously. Any old RPC waiter is
    /// woken immediately, so reload never spends the rest of its deadline on a
    /// MainActor action which has already become invalid.
    @discardableResult
    func reload(_ source: String, completion: Completion? = nil) -> Submission {
        var revokedEntries: [Entry] = []
        var revokedRPC: PendingRPC?
        var revokedGeneration: UInt64?
        let decision: (Submission, Bool) = lock.withLock {
            guard state.acceptsEntries else { return (.refused(.stopped), false) }
            state.statistics.reloadSubmissions &+= 1
            state.residentGeneration &+= 1
            revokedGeneration = state.residentGeneration
            state.listenedEvents = []
            revokedEntries = state.residentEdges.removeAll()
            if let tick = state.tick {
                revokedEntries.append(tick)
                state.tick = nil
            }
            if state.active?.residentGeneration != nil {
                state.statistics.revokedEntries &+= 1
            }
            state.statistics.revokedEntries &+= UInt64(revokedEntries.count)
            if let activeRPC = state.activeRPC,
                activeRPC.identity.residentGeneration != nil
            {
                revokedRPC = activeRPC.pending
                state.activeRPC = nil
                state.statistics.revokedRPCs &+= 1
            }

            guard source.utf8.count <= Self.maximumSourceBytes else {
                return (.refused(.sourceTooLarge), false)
            }

            let generation = state.residentGeneration
            let entry = makeEntryLocked(
                kind: .reload, payload: source.isEmpty ? .unload : .reload(source),
                residentGeneration: generation,
                completion: completion)
            guard state.active != nil else {
                state.active = entry
                return (.accepted(entry.identifier), true)
            }
            precondition(state.residentEdges.append(entry))
            state.statistics.maximumQueuedResidentEdges = max(
                state.statistics.maximumQueuedResidentEdges, state.residentEdges.count)
            return (.accepted(entry.identifier), false)
        }
        revokedRPC?.cancel()
        for entry in revokedEntries { suppressCompletion(for: entry) }
        if decision.1 {
            scheduleDrain()
        } else if case .refused(.sourceTooLarge) = decision.0, let revokedGeneration {
            scheduleResidentDiscard(for: revokedGeneration)
        }
        return decision.0
    }

    /// Removes the resident program without constructing an empty context.
    @discardableResult
    func unload(completion: Completion? = nil) -> Submission {
        reload("", completion: completion)
    }

    @discardableResult
    func submit(
        _ event: Event, payload: JSONValue = .object([:]), causality: Causality? = nil,
        completion: Completion? = nil
    ) -> Submission {
        guard payload.text.utf8.count <= Self.maximumSourceBytes else {
            return .refused(.payloadTooLarge)
        }
        return event == .tick
            ? submitTick(payload: payload, causality: causality, completion: completion)
            : submitResidentEdge(
                event, payload: payload, causality: causality, completion: completion)
    }

    /// Revokes every generation without waiting for an entered interpreter.
    /// JavaScriptCore's group deadline remains the last-resort owner of an
    /// endless loop; all queued work and all late MainActor RPC jobs are inert.
    func stop() {
        var revokedEntries: [Entry] = []
        var revokedRPC: PendingRPC?
        let schedulesOwnerCleanup = lock.withLock {
            guard state.acceptsEntries else { return false }
            state.acceptsEntries = false
            state.serviceGeneration &+= 1
            state.residentGeneration &+= 1
            state.listenedEvents = []
            revokedEntries = state.manual.removeAll() + state.residentEdges.removeAll()
            if let tick = state.tick {
                revokedEntries.append(tick)
                state.tick = nil
            }
            state.statistics.revokedEntries &+= UInt64(revokedEntries.count)
            if let activeRPC = state.activeRPC {
                revokedRPC = activeRPC.pending
                state.activeRPC = nil
                state.statistics.revokedRPCs &+= 1
            }
            return true
        }
        revokedRPC?.cancel()
        for entry in revokedEntries { suppressCompletion(for: entry) }
        if schedulesOwnerCleanup {
            ownerQueue.async { [self] in releaseResidentOnOwner() }
        }
    }

    private func submitResidentEdge(
        _ event: Event, payload: JSONValue, causality: Causality?, completion: Completion?
    ) -> Submission {
        let decision: (Submission, Bool) = lock.withLock {
            guard state.acceptsEntries else { return (.refused(.stopped), false) }
            guard state.listenedEvents.contains(event) else { return (.ignored, false) }
            guard let causalEventBudget = causalEventBudgetLocked(causality) else {
                return (.ignored, false)
            }
            if causality != nil, !causalEventBudget.claim() {
                state.statistics.refusedCausalEvents &+= 1
                return (.refused(.causalEventLimit), false)
            }
            state.statistics.residentEdgeSubmissions &+= 1
            let generation = state.residentGeneration
            let entry = makeEntryLocked(
                kind: .residentEdge, payload: .residentEdge(event, payload),
                residentGeneration: generation, causalEventBudget: causalEventBudget,
                completion: completion)
            guard state.active != nil else {
                state.active = entry
                return (.accepted(entry.identifier), true)
            }
            guard state.residentEdges.append(entry) else {
                state.statistics.refusedResidentEdges &+= 1
                return (.refused(.residentEdgeQueueFull), false)
            }
            state.statistics.maximumQueuedResidentEdges = max(
                state.statistics.maximumQueuedResidentEdges, state.residentEdges.count)
            return (.accepted(entry.identifier), false)
        }
        if decision.1 { scheduleDrain() }
        return decision.0
    }

    private func submitTick(
        payload: JSONValue, causality: Causality?, completion: Completion?
    ) -> Submission {
        var superseded: Entry?
        let decision: (Submission, Bool) = lock.withLock {
            guard state.acceptsEntries else { return (.refused(.stopped), false) }
            guard state.listenedEvents.contains(.tick) else { return (.ignored, false) }
            guard let causalEventBudget = causalEventBudgetLocked(causality) else {
                return (.ignored, false)
            }
            if causality != nil, !causalEventBudget.claim() {
                state.statistics.refusedCausalEvents &+= 1
                return (.refused(.causalEventLimit), false)
            }
            state.statistics.tickSubmissions &+= 1
            let generation = state.residentGeneration
            let entry = makeEntryLocked(
                kind: .tick, payload: .tick(payload), residentGeneration: generation,
                causalEventBudget: causalEventBudget, completion: completion)
            guard state.active != nil else {
                state.active = entry
                return (.accepted(entry.identifier), true)
            }
            if let pending = state.tick {
                superseded = pending
                state.statistics.coalescedTicks &+= 1
            }
            state.tick = entry
            state.statistics.maximumPendingTicks = max(
                state.statistics.maximumPendingTicks, 1)
            let submission: Submission =
                superseded == nil ? .accepted(entry.identifier) : .coalesced(entry.identifier)
            return (submission, false)
        }
        if let superseded { suppressCompletion(for: superseded) }
        if decision.1 { scheduleDrain() }
        return decision.0
    }

    private func causalEventBudgetLocked(_ causality: Causality?) -> CausalEventBudget? {
        guard let causality else { return CausalEventBudget() }
        guard causality.serviceIdentifier == serviceIdentifier,
            causality.serviceGeneration == state.serviceGeneration,
            causality.residentGeneration == state.residentGeneration
        else { return nil }
        return causality.eventBudget
    }

    private func makeEntryLocked(
        kind: EntryKind, payload: Payload, residentGeneration: UInt64?,
        externalDeadline: Deadline? = nil, causalEventBudget: CausalEventBudget? = nil,
        completion: Completion?
    ) -> Entry {
        state.nextEntryIdentifier &+= 1
        let admitted = DispatchTime.now().uptimeNanoseconds
        let limit = UInt64(executionTimeLimit * 1_000_000_000)
        let localDeadline = admitted.addingReportingOverflow(limit)
        let boundedLocalDeadline =
            localDeadline.overflow ? UInt64.max : localDeadline.partialValue
        return Entry(
            identifier: state.nextEntryIdentifier,
            serviceGeneration: state.serviceGeneration,
            residentGeneration: residentGeneration,
            deadlineUptimeNanoseconds: min(
                boundedLocalDeadline, externalDeadline?.uptimeNanoseconds ?? UInt64.max),
            kind: kind,
            payload: payload,
            causalEventBudget: causalEventBudget ?? CausalEventBudget(),
            completion: CompletionGate(completion))
    }

    private func scheduleDrain() {
        ownerQueue.async { [self] in drain() }
    }

    private func drain() {
        assertJavaScriptOwner()
        while let entry = lock.withLock({ state.active }) {
            let result = autoreleasepool { execute(entry) }
            updateContextCensusOnOwner()
            publish(result, for: entry)
            finish(entry)
        }
        if !lock.withLock({ state.acceptsEntries }) { releaseResidentOnOwner() }
    }

    private func execute(_ entry: Entry) -> Result {
        assertJavaScriptOwner()
        // Queue residence spends the same budget as evaluation. Otherwise a
        // control client can time out, close its socket and still have its
        // script perform a side effect when older work finally releases the
        // owner. Generation, deadline and application admission are one locked
        // decision so stop cannot turn an obsolete entry into an expiry count.
        switch beginExecution(entry, now: DispatchTime.now().uptimeNanoseconds) {
        case .began:
            break
        case .expired:
            return failure(deadlineMessage())
        case .revoked:
            return revokedResult()
        }
        defer { endExecution() }
        onEntryStart?(entry.kind, entry.identifier)
        guard isEntryCurrent(entry) else { return revokedResult() }
        guard DispatchTime.now().uptimeNanoseconds < entry.deadlineUptimeNanoseconds else {
            return failure(deadlineMessage())
        }

        let identity = RuntimeIdentity(
            entryIdentifier: entry.identifier,
            serviceGeneration: entry.serviceGeneration,
            residentGeneration: entry.residentGeneration,
            deadlineUptimeNanoseconds: entry.deadlineUptimeNanoseconds)
        let execution = Execution(
            identity: identity, causalEventBudget: entry.causalEventBudget)
        precondition(currentExecution == nil)
        currentExecution = execution
        defer { currentExecution = nil }

        let result: Result
        switch entry.payload {
        case .manual(let source):
            result = executeManual(source, execution: execution)
        case .reload(let source):
            result = executeReload(
                source, generation: entry.residentGeneration!, execution: execution)
        case .unload:
            discardResidentOnOwner()
            result = Result(value: "", log: [], error: nil)
        case .residentEdge(let event, let payload):
            result = executeEvent(event, payload: payload, execution: execution)
        case .tick(let payload):
            result = executeEvent(.tick, payload: payload, execution: execution)
        }
        if DispatchTime.now().uptimeNanoseconds > identity.deadlineUptimeNanoseconds,
            result.error == nil
        {
            return failure(deadlineMessage())
        }
        return result
    }

    private func beginExecution(_ entry: Entry, now: UInt64) -> EntryAdmission {
        lock.withLock {
            guard state.active?.identifier == entry.identifier,
                entry.serviceGeneration == state.serviceGeneration,
                entry.residentGeneration == nil
                    || entry.residentGeneration == state.residentGeneration
            else { return .revoked }
            guard now < entry.deadlineUptimeNanoseconds else {
                state.statistics.expiredEntries &+= 1
                return .expired
            }
            state.concurrentExecutions += 1
            state.statistics.entryApplications &+= 1
            switch entry.kind {
            case .manual: state.statistics.manualApplications &+= 1
            case .reload: state.statistics.reloadApplications &+= 1
            case .residentEdge: state.statistics.residentEdgeApplications &+= 1
            case .tick: state.statistics.tickApplications &+= 1
            }
            state.statistics.maximumConcurrentExecutions = max(
                state.statistics.maximumConcurrentExecutions, state.concurrentExecutions)
            return .began
        }
    }

    private func endExecution() {
        lock.withLock {
            precondition(state.concurrentExecutions == 1)
            state.concurrentExecutions = 0
        }
    }

    private func finish(_ entry: Entry) {
        lock.withLock {
            guard state.active?.identifier == entry.identifier else { return }
            state.active = takeNextLocked()
        }
    }

    private func takeNextLocked() -> Entry? {
        let manual = state.manual.first
        let edge = state.residentEdges.first
        let tick = state.tick
        let candidates = [manual, edge, tick].compactMap { $0 }
        guard let next = candidates.min(by: { $0.identifier < $1.identifier }) else {
            return nil
        }
        if manual?.identifier == next.identifier { return state.manual.removeFirst() }
        if edge?.identifier == next.identifier { return state.residentEdges.removeFirst() }
        state.tick = nil
        return next
    }

    private func executeManual(_ source: String, execution: Execution) -> Result {
        guard let context = makeContextOnOwner() else {
            return failure(loc("The interpreter could not be started."))
        }
        installExceptionHandler(in: context)
        installAPI(in: context)
        var rendered = ""
        withTimeLimit(context, execution: execution) {
            let value = context.evaluateScript(source)
            if execution.failure == nil, !(value?.isUndefined ?? true),
                !(value?.isNull ?? true)
            {
                rendered = value?.toString() ?? ""
            }
        }
        if let problem = execution.failure {
            return failure(problem, log: execution.output)
        }
        guard rendered.utf8.count <= Self.maximumResultBytes else {
            return failure(
                loc("The script result is larger than 64 KiB."), log: execution.output)
        }
        return Result(value: rendered, log: execution.output, error: nil)
    }

    private func executeReload(
        _ source: String, generation: UInt64, execution: Execution
    ) -> Result {
        discardResidentOnOwner()
        guard let context = makeContextOnOwner() else {
            clearListeners(for: generation)
            return failure(loc("The interpreter could not be started."))
        }
        let registration = ResidentRegistration()
        installExceptionHandler(in: context)
        installAPI(in: context)
        installEvents(
            in: context, generation: generation, registration: registration)
        withTimeLimit(context, execution: execution) { _ = context.evaluateScript(source) }

        guard execution.failure == nil, isIdentityCurrent(execution.identity) else {
            clearListeners(for: generation)
            return execution.failure.map { failure($0, log: execution.output) }
                ?? revokedResult()
        }
        registration.isInstalled = true
        residentContext = context
        residentRegistration = registration
        workerResidentGeneration = generation
        lock.withLock {
            state.statistics.residentOwners = 1
            state.statistics.maximumResidentOwners = max(
                state.statistics.maximumResidentOwners, 1)
        }
        publishListeners(Set(registration.handlers.keys), for: generation)
        return Result(value: "", log: execution.output, error: nil)
    }

    private func executeEvent(
        _ event: Event, payload: JSONValue, execution: Execution
    ) -> Result {
        guard workerResidentGeneration == execution.identity.residentGeneration,
            let context = residentContext,
            let listeners = residentRegistration?.handlers[event], !listeners.isEmpty
        else { return Result(value: "", log: [], error: nil) }
        installExceptionHandler(in: context)
        let argument =
            JSValue(object: payload.any, in: context)
            ?? JSValue(undefinedIn: context)
        withTimeLimit(context, execution: execution) {
            for listener in listeners {
                context.exception = nil
                listener.value?.call(withArguments: [argument as Any])
                if let exception = context.exception {
                    if execution.failure == nil {
                        execution.failure =
                            exception.toString() ?? loc("Unknown script error.")
                    }
                    context.exception = nil
                }
            }
        }
        return Result(
            value: "", log: execution.output,
            error: execution.failure.map { Self.bounded($0, to: Self.maximumErrorBytes) })
    }

    private func installExceptionHandler(in context: JSContext) {
        context.exceptionHandler = { [weak self] _, exception in
            guard let execution = self?.currentExecution else { return }
            if execution.failure == nil {
                execution.failure = exception?.toString() ?? loc("Unknown script error.")
            }
        }
    }

    private func installEvents(
        in context: JSContext, generation: UInt64,
        registration: ResidentRegistration
    ) {
        let names = Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0.rawValue, $0) })
        let on: @convention(block) (String, JSValue?) -> Void = {
            [weak self, weak context, weak registration] name, handler in
            guard let self, let context, let registration,
                let execution = self.currentExecution
            else { return }
            guard let event = names[name] else {
                let available = Event.allCases.map(\.rawValue).sorted().joined(separator: ", ")
                let format = loc(
                    "There is no script event called “%@”. Available events: %@.")
                self.fail(
                    String(format: format, name, available),
                    in: context, execution: execution)
                return
            }
            guard let handler, handler.isObject,
                let managed = JSManagedValue(value: handler, andOwner: registration)
            else { return }
            guard registration.count < Self.maximumHandlers else {
                self.fail(
                    loc("The script registered too many event handlers."),
                    in: context, execution: execution)
                return
            }
            registration.handlers[event, default: []].append(managed)
            registration.count += 1
            if registration.isInstalled {
                self.publishListeners(Set(registration.handlers.keys), for: generation)
            }
        }
        context.objectForKeyedSubscript("yun")?
            .setObject(on, forKeyedSubscript: "on" as NSString)
    }

    private func installAPI(in context: JSContext) {
        let api = JSValue(newObjectIn: context)

        func command(
            _ make: @escaping (Bool?) -> RemoteCommand
        ) -> @convention(block) (JSValue?) -> String {
            { [weak self, weak context] argument in
                guard let self, let context, let execution = self.currentExecution else {
                    return ""
                }
                let wanted: Bool? =
                    (argument?.isUndefined ?? true) || (argument?.isNull ?? true)
                    ? nil : argument?.toBool()
                return self.commandResult(
                    self.performRPC(
                        .perform(make(wanted)), in: context, execution: execution),
                    in: context, execution: execution)
            }
        }
        api?.setObject(command { .routing($0) }, forKeyedSubscript: "routing" as NSString)
        api?.setObject(command { .mute($0) }, forKeyedSubscript: "mute" as NSString)
        api?.setObject(command { .record($0) }, forKeyedSubscript: "record" as NSString)
        api?.setObject(
            command { .transcribe($0) }, forKeyedSubscript: "transcribe" as NSString)

        func named(
            _ make: @escaping (String) -> RemoteCommand, _ missingKey: String
        ) -> @convention(block) (String) -> String {
            { [weak self, weak context] name in
                guard let self, let context, let execution = self.currentExecution else {
                    return ""
                }
                let reply = self.performRPC(
                    .perform(make(name)), in: context, execution: execution)
                guard case .performed(let message, let commandFailed) = reply else {
                    return ""
                }
                guard !commandFailed, let message else {
                    self.fail(
                        message
                            ?? String(format: loc(missingKey), name), in: context,
                        execution: execution)
                    return ""
                }
                return message
            }
        }
        api?.setObject(
            named({ .preset($0) }, "There is no scene called “%@”."),
            forKeyedSubscript: "preset" as NSString)
        api?.setObject(
            named({ .config($0) }, "There is no setup called “%@”."),
            forKeyedSubscript: "config" as NSString)

        let status: @convention(block) () -> Any = { [weak self, weak context] in
            guard let self, let context, let execution = self.currentExecution,
                case .status(let value) = self.performRPC(
                    .status, in: context, execution: execution)
            else { return NSNull() }
            return value.any
        }
        api?.setObject(status, forKeyedSubscript: "status" as NSString)

        let presets: @convention(block) () -> [String] = { [weak self, weak context] in
            guard let self, let context, let execution = self.currentExecution,
                case .names(let presets, _) = self.performRPC(
                    .names, in: context, execution: execution)
            else { return [] }
            return presets
        }
        api?.setObject(presets, forKeyedSubscript: "presets" as NSString)

        let configs: @convention(block) () -> [String] = { [weak self, weak context] in
            guard let self, let context, let execution = self.currentExecution,
                case .names(_, let configs) = self.performRPC(
                    .names, in: context, execution: execution)
            else { return [] }
            return configs
        }
        api?.setObject(configs, forKeyedSubscript: "configs" as NSString)

        let log: @convention(block) (JSValue?) -> Void = { [weak self, weak context] value in
            guard let self, let context, let execution = self.currentExecution else { return }
            let line = value?.toString() ?? ""
            let bytes = line.utf8.count
            guard execution.output.count < Self.maximumOutputLines,
                bytes <= Self.maximumOutputBytes,
                execution.outputBytes <= Self.maximumOutputBytes - bytes
            else {
                self.fail(
                    loc("The script produced too much output."), in: context,
                    execution: execution)
                return
            }
            execution.output.append(line)
            execution.outputBytes += bytes
        }
        api?.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(api, forKeyedSubscript: "yun" as NSString)

        let console = JSValue(newObjectIn: context)
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    private func commandResult(
        _ reply: RPCReply?, in context: JSContext, execution: Execution
    ) -> String {
        guard case .performed(let message, let commandFailed) = reply else { return "" }
        guard !commandFailed else {
            fail(
                message ?? loc("The application refused the script command."),
                in: context, execution: execution)
            return ""
        }
        return message ?? ""
    }

    private func performRPC(
        _ request: RPC, in context: JSContext, execution: Execution
    ) -> RPCReply? {
        assertJavaScriptOwner()
        execution.rpcCount += 1
        guard execution.rpcCount <= Self.maximumRPCsPerEntry else {
            lock.withLock { state.statistics.refusedRPCs &+= 1 }
            fail(
                loc("The script made too many application requests."), in: context,
                execution: execution)
            return nil
        }
        guard
            DispatchTime.now().uptimeNanoseconds
                < execution.identity.deadlineUptimeNanoseconds
        else {
            lock.withLock { state.statistics.deadlineRPCs &+= 1 }
            fail(deadlineMessage(), in: context, execution: execution)
            return nil
        }

        let pending = PendingRPC()
        guard register(pending, for: execution) else {
            lock.withLock { state.statistics.revokedRPCs &+= 1 }
            fail(revokedMessage(), in: context, execution: execution)
            return nil
        }
        let identity = execution.identity
        scheduleOnMainActor { [weak self, pending, identity] in
            self?.deliverRPC(request, pending: pending, identity: identity)
        }
        let reply = pending.wait(until: execution.identity.deadline)
        clear(pending, for: execution.identity)
        guard let reply else {
            let deadlinePassed =
                DispatchTime.now().uptimeNanoseconds
                >= execution.identity.deadlineUptimeNanoseconds
            lock.withLock {
                if deadlinePassed {
                    state.statistics.deadlineRPCs &+= 1
                } else {
                    state.statistics.revokedRPCs &+= 1
                }
            }
            fail(
                deadlinePassed ? deadlineMessage() : revokedMessage(), in: context,
                execution: execution)
            return nil
        }
        guard validate(reply) else {
            fail(
                loc("The script result is larger than 64 KiB."), in: context,
                execution: execution)
            return nil
        }
        if case .failure(let reason) = reply {
            fail(reason, in: context, execution: execution)
            return nil
        }
        return reply
    }

    private func register(_ pending: PendingRPC, for execution: Execution) -> Bool {
        lock.withLock {
            let identity = execution.identity
            guard isIdentityCurrentLocked(identity), state.activeRPC == nil else {
                return false
            }
            state.activeRPC = ActiveRPC(
                identity: identity, pending: pending,
                causalEventBudget: execution.causalEventBudget)
            state.statistics.rpcSubmissions &+= 1
            state.statistics.maximumPendingRPCs = max(
                state.statistics.maximumPendingRPCs, 1)
            return true
        }
    }

    private func clear(_ pending: PendingRPC, for identity: RuntimeIdentity) {
        lock.withLock {
            guard let active = state.activeRPC,
                active.identity == identity, active.pending === pending
            else { return }
            state.activeRPC = nil
        }
    }

    @MainActor
    private func deliverRPC(_ request: RPC, pending: PendingRPC, identity: RuntimeIdentity) {
        let reserve = UInt64(Self.maximumMainActorRPCSeconds * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        guard identity.deadlineUptimeNanoseconds > now,
            identity.deadlineUptimeNanoseconds - now > reserve
        else {
            lock.withLock {
                state.statistics.deadlineRPCs &+= 1
                state.statistics.lateRPCJobs &+= 1
            }
            pending.cancel()
            return
        }
        let causality: Causality? = lock.withLock {
            guard let active = state.activeRPC,
                active.identity == identity, active.pending === pending,
                isIdentityCurrentLocked(identity)
            else { return nil }
            return Causality(
                serviceIdentifier: serviceIdentifier,
                serviceGeneration: state.serviceGeneration,
                residentGeneration: state.residentGeneration,
                eventBudget: active.causalEventBudget)
        }
        guard let causality, pending.claim() else {
            lock.withLock { state.statistics.lateRPCJobs &+= 1 }
            pending.cancel()
            return
        }
        guard DispatchTime.now().uptimeNanoseconds < identity.deadlineUptimeNanoseconds,
            lock.withLock({ isIdentityCurrentLocked(identity) })
        else {
            lock.withLock {
                state.statistics.deadlineRPCs &+= 1
                state.statistics.lateRPCJobs &+= 1
            }
            pending.cancel()
            return
        }
        lock.withLock {
            state.statistics.rpcApplications &+= 1
        }
        let began = DispatchTime.now().uptimeNanoseconds
        let reply = rpcHandler(request, causality)
        let finished = DispatchTime.now().uptimeNanoseconds
        let elapsed = finished - began
        lock.withLock {
            state.statistics.maximumMainActorRPCNanoseconds = max(
                state.statistics.maximumMainActorRPCNanoseconds, elapsed)
            if Double(elapsed) / 1_000_000_000 > Self.maximumMainActorRPCSeconds {
                state.statistics.overBudgetMainActorRPCs &+= 1
            }
            if finished >= identity.deadlineUptimeNanoseconds {
                state.statistics.mainActorRPCDeadlineOverruns &+= 1
                state.statistics.deadlineRPCs &+= 1
            }
        }
        if finished >= identity.deadlineUptimeNanoseconds {
            pending.cancel()
        } else {
            pending.finish(reply)
        }
    }

    private func validate(_ reply: RPCReply) -> Bool {
        switch reply {
        case .performed(let message, _):
            return (message ?? "").utf8.count <= Self.maximumResultBytes
        case .status(let value):
            return value.text.utf8.count <= Self.maximumResultBytes
        case .names(let presets, let configs):
            return JSONValue.object([
                "presets": .array(presets.map(JSONValue.string)),
                "configs": .array(configs.map(JSONValue.string)),
            ]).text.utf8.count <= Self.maximumResultBytes
        case .failure(let reason):
            return reason.utf8.count <= Self.maximumErrorBytes
        }
    }

    private func withTimeLimit(
        _ context: JSContext, execution: Execution, body: () -> Void
    ) {
        guard let group = JSContextGetGroup(context.jsGlobalContextRef) else {
            fail(
                loc("The interpreter could not be started."), in: context,
                execution: execution)
            return
        }
        let flag = DeadlineFlag()
        let now = DispatchTime.now().uptimeNanoseconds
        guard execution.identity.deadlineUptimeNanoseconds > now else {
            fail(deadlineMessage(), in: context, execution: execution)
            return
        }
        let remaining = execution.identity.deadlineUptimeNanoseconds - now
        JSContextGroupSetExecutionTimeLimit(
            group, Double(remaining) / 1_000_000_000,
            { _, opaque in
                guard let opaque else { return true }
                Unmanaged<DeadlineFlag>.fromOpaque(opaque).takeUnretainedValue().mark()
                return true
            },
            Unmanaged.passUnretained(flag).toOpaque())
        defer {
            JSContextGroupClearExecutionTimeLimit(group)
            if flag.wasReached { execution.failure = deadlineMessage() }
            withExtendedLifetime(flag) {}
        }
        body()
    }

    private func fail(_ reason: String, in context: JSContext, execution: Execution) {
        let bounded = Self.bounded(reason, to: Self.maximumErrorBytes)
        if execution.failure == nil { execution.failure = bounded }
        context.exception = JSValue(object: bounded, in: context)
    }

    private func publish(_ result: Result, for entry: Entry) {
        guard entry.completion.isArmed else { return }
        scheduleOnMainActor { [weak self] in
            guard let self else { return }
            let isCurrent = self.isEntryGenerationCurrent(entry)
            guard isCurrent else {
                self.suppressCompletion(for: entry)
                return
            }
            let delivered = entry.completion.finish(result)
            guard delivered else { return }
            self.lock.withLock {
                self.state.statistics.resultPublications &+= 1
            }
        }
    }

    private func suppressCompletion(for entry: Entry) {
        if entry.completion.discard() {
            lock.withLock { state.statistics.revokedCompletions &+= 1 }
        }
    }

    private func publishListeners(_ events: Set<Event>, for generation: UInt64) {
        lock.withLock {
            guard state.acceptsEntries, state.residentGeneration == generation else { return }
            state.listenedEvents = events
        }
    }

    private func clearListeners(for generation: UInt64) {
        lock.withLock {
            guard state.residentGeneration == generation else { return }
            state.listenedEvents = []
        }
    }

    private func isEntryCurrent(_ entry: Entry) -> Bool {
        lock.withLock {
            state.acceptsEntries && entry.serviceGeneration == state.serviceGeneration
                && (entry.residentGeneration == nil
                    || entry.residentGeneration == state.residentGeneration)
        }
    }

    private func isEntryGenerationCurrent(_ entry: Entry) -> Bool {
        lock.withLock {
            state.acceptsEntries && entry.serviceGeneration == state.serviceGeneration
                && (entry.residentGeneration == nil
                    || entry.residentGeneration == state.residentGeneration)
        }
    }

    private func isIdentityCurrent(_ identity: RuntimeIdentity) -> Bool {
        lock.withLock { isIdentityCurrentLocked(identity) }
    }

    private func isIdentityCurrentLocked(_ identity: RuntimeIdentity) -> Bool {
        state.acceptsEntries && state.serviceGeneration == identity.serviceGeneration
            && state.active?.identifier == identity.entryIdentifier
            && (identity.residentGeneration == nil
                || state.residentGeneration == identity.residentGeneration)
    }

    private func failure(_ message: String, log: [String] = []) -> Result {
        Result(
            value: "", log: log,
            error: Self.bounded(message, to: Self.maximumErrorBytes))
    }

    private func revokedResult() -> Result { failure(revokedMessage()) }

    private func revokedMessage() -> String {
        loc("The script work was superseded or stopped before it could finish.")
    }

    private func deadlineMessage() -> String {
        String(
            format: loc("The script exceeded its %.0f ms execution limit."),
            executionTimeLimit * 1_000)
    }

    private static func bounded(_ text: String, to maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        let marker = "…"
        guard maximumBytes >= marker.utf8.count else { return "" }
        let budget = maximumBytes - marker.utf8.count
        var used = 0
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            let width = text[end..<next].utf8.count
            guard used + width <= budget else { break }
            used += width
            end = next
        }
        return String(text[..<end]) + marker
    }

    private func releaseResidentOnOwner() {
        assertJavaScriptOwner()
        guard !lock.withLock({ state.acceptsEntries }) else { return }
        discardResidentOnOwner()
    }

    private func scheduleResidentDiscard(for generation: UInt64) {
        ownerQueue.async { [weak self] in
            guard let self else { return }
            self.assertJavaScriptOwner()
            let isCurrent = self.lock.withLock {
                self.state.acceptsEntries
                    && self.state.residentGeneration == generation
            }
            guard isCurrent else { return }
            self.discardResidentOnOwner()
            self.updateContextCensusOnOwner()
        }
    }

    private func discardResidentOnOwner() {
        assertJavaScriptOwner()
        let released = residentContext != nil || residentRegistration != nil
        residentContext = nil
        residentRegistration = nil
        workerResidentGeneration = nil
        if released {
            lock.withLock {
                state.statistics.residentOwners = 0
                state.statistics.releasedResidentOwners &+= 1
            }
        }
    }

    private func makeContextOnOwner() -> JSContext? {
        assertJavaScriptOwner()
        guard let context = JSContext() else { return nil }
        recentContextReferences.removeAll { $0.value == nil }
        recentContextReferences.append(WeakContextReference(context))
        lock.withLock { state.statistics.createdJavaScriptContexts &+= 1 }
        return context
    }

    private func updateContextCensusOnOwner() {
        assertJavaScriptOwner()
        recentContextReferences.removeAll { $0.value == nil }
        let live = recentContextReferences.count
        lock.withLock {
            state.statistics.liveJavaScriptContexts = live
            state.statistics.maximumLiveJavaScriptContexts = max(
                state.statistics.maximumLiveJavaScriptContexts, live)
        }
    }

    private func assertJavaScriptOwner() {
        precondition(
            DispatchQueue.getSpecific(key: ownerKey) == 1,
            "JavaScriptCore escaped its serial owner")
    }
}
