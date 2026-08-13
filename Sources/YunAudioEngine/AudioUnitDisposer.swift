import AudioToolbox
import Dispatch
import Foundation
import YunAudioHAL

/// Outcome of disposing one callback-transitive Audio Unit owner.
public enum AudioUnitOwnerDisposalResult: Sendable, Equatable {
    case complete(disposedUnits: Int)
    case operationFailed(
        step: AudioUnitTeardownStep, status: OSStatus, disposedUnits: Int)
    case timedOut(step: AudioUnitTeardownStep?, disposedUnits: Int)
    /// The Audio Unit is fenced, but a callback-transitive owner which belongs
    /// to the same lifecycle transaction could not be proven safe to release.
    ///
    /// VoiceProcessingIO owns an aggregate and may consume a far-end IOProc.
    /// Reporting those boundaries as an Audio Unit error loses the actual
    /// failure, while treating them as complete would reopen graph admission
    /// before every transitive callback owner is gone.
    case ownerRetained(disposedUnits: Int)
    case blockedByRetainedTransaction(retainedUnits: Int)

    public var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}

/// Makes ownership explicit even when `AudioComponentInstanceNew` reports an error.
///
/// Core Foundation-style out parameters are allowed to contain a value on a
/// failing return. Treating status as the only source of truth loses that owner:
/// a successful instance belongs to the graph, while a value returned beside an
/// error belongs to the disposer.
struct AudioComponentCreationOwnership<Instance> {
    let status: OSStatus
    let createdInstance: Instance?
    let orphanedInstance: Instance?

    init(status: OSStatus, instance: Instance?) {
        self.status = status
        if status == noErr {
            createdInstance = instance
            orphanedInstance = nil
        } else {
            createdInstance = nil
            orphanedInstance = instance
        }
    }
}

/// An owner which keeps every callback context and buffer alive with its units.
///
/// Conformance is `Sendable` because ownership crosses to the sole disposer only
/// after the IOProc or RCU fence. Implementations must not be rendered or mutated
/// again after being handed over.
protocol AudioUnitTeardownOwner: AnyObject, Sendable {
    var audioUnitCount: Int { get }
    var hasTeardownWork: Bool { get }
    func tearDownAudioUnits(using gate: AudioUnitTeardownGate) -> AudioUnitOwnerDisposalResult
}

extension AudioUnitTeardownOwner {
    var hasTeardownWork: Bool { audioUnitCount > 0 }
}

/// A command which becomes unsafe to execute after its synchronous caller left.
///
/// Real teardown owners must stay queued until they fence their callbacks. A
/// Start, Stop or property command has the opposite contract: if it could not
/// enter the sole worker before its caller's deadline, running it later would
/// mutate an owner which has already failed closed.
protocol AudioUnitDeferredLifecycleCommand: AnyObject {
    func cancelBeforeStart()
}

/// Prevents a late synchronous operation from starting the next teardown step.
///
/// Core Audio calls cannot be cancelled. If an uninitialise overruns its route
/// deadline, cancellation is observed after it returns and dispose is skipped.
/// The owner therefore remains quarantined even when the late call happened to
/// succeed.
final class AudioUnitTeardownGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var currentStep: AudioUnitTeardownStep?

    func perform(
        _ step: AudioUnitTeardownStep,
        operation: () -> OSStatus
    ) -> OSStatus? {
        let admitted = lock.withLock {
            guard !isCancelled else { return false }
            currentStep = step
            return true
        }
        guard admitted else { return nil }

        let status = operation()
        return lock.withLock {
            if currentStep == step { currentStep = nil }
            return isCancelled ? nil : status
        }
    }

    @discardableResult
    func cancel() -> AudioUnitTeardownStep? {
        lock.withLock {
            isCancelled = true
            return currentStep
        }
    }

    var stepInFlight: AudioUnitTeardownStep? {
        lock.withLock { currentStep }
    }

    var admitsAnotherStep: Bool { lock.withLock { !isCancelled } }
}

/// Applies the existing ordered Audio Unit lifecycle to one hosted instance.
enum AudioUnitOwnerTeardownSequence {
    static func tearDown(
        _ unit: AudioComponentInstance,
        state: inout AudioUnitTeardownState,
        using gate: AudioUnitTeardownGate
    ) -> AudioUnitOwnerDisposalResult {
        let wasDisposed = state.phase == .disposed
        let result = state.tearDown(
            stop: { noErr },
            uninitialise: {
                gate.perform(.uninitialise) { AudioUnitUninitialize(unit) }
            },
            dispose: {
                gate.perform(.dispose) { AudioComponentInstanceDispose(unit) }
            })
        let disposed = !wasDisposed && state.phase == .disposed ? 1 : 0
        switch result {
        case .complete:
            return .complete(disposedUnits: disposed)
        case .audioUnit(let step, let status):
            return .operationFailed(step: step, status: status, disposedUnits: disposed)
        case .audioUnitTimedOut(let step):
            return .timedOut(step: step, disposedUnits: disposed)
        case .lifecycleTimedOut(let step):
            return .timedOut(step: step, disposedUnits: disposed)
        case .aggregate, .sampleRatesNotRestored:
            preconditionFailure("a unit-only teardown cannot report a HAL owner result")
        }
    }
}

/// Detached units plus the storage their render callbacks can still reference.
///
/// The release closure runs only after every unit reached `.disposed`. On any
/// refusal or timeout this entire capsule stays in process-lifetime quarantine.
final class AudioUnitResourceCapsule: @unchecked Sendable, AudioUnitTeardownOwner {
    struct Unit {
        let instance: AudioComponentInstance
        var state: AudioUnitTeardownState

        init(instance: AudioComponentInstance, initialised: Bool) {
            self.instance = instance
            var state = AudioUnitTeardownState()
            if initialised { state.didInitialise() }
            self.state = state
        }

        init(instance: AudioComponentInstance, state: AudioUnitTeardownState) {
            self.instance = instance
            self.state = state
        }
    }

    private var units: [Unit]
    private var releaseStorage: (() -> Void)?

    init(units: [Unit], releaseStorage: @escaping () -> Void = {}) {
        self.units = units
        self.releaseStorage = releaseStorage
    }

    var audioUnitCount: Int { units.count }

    func tearDownAudioUnits(
        using gate: AudioUnitTeardownGate
    ) -> AudioUnitOwnerDisposalResult {
        var disposed = 0
        for index in units.indices {
            let result = AudioUnitOwnerTeardownSequence.tearDown(
                units[index].instance, state: &units[index].state, using: gate)
            switch result {
            case .complete(let count):
                disposed += count
            case .operationFailed(let step, let status, let count):
                return .operationFailed(
                    step: step, status: status, disposedUnits: disposed + count)
            case .timedOut(let step, let count):
                return .timedOut(step: step, disposedUnits: disposed + count)
            case .ownerRetained(let count):
                return .ownerRetained(disposedUnits: disposed + count)
            case .blockedByRetainedTransaction:
                preconditionFailure("a teardown sequence cannot submit another transaction")
            }
        }

        units.removeAll()
        let release = releaseStorage
        releaseStorage = nil
        release?()
        return .complete(disposedUnits: disposed)
    }
}

/// Groups all AU owners detached at one IOProc or RCU fence.
final class AudioUnitOwnerCapsule: @unchecked Sendable, AudioUnitTeardownOwner {
    private var owners: [any AudioUnitTeardownOwner]

    init(_ owners: [any AudioUnitTeardownOwner]) {
        var seen = Set<ObjectIdentifier>()
        self.owners = owners.filter {
            seen.insert(ObjectIdentifier($0)).inserted
        }
    }

    var audioUnitCount: Int { owners.reduce(0) { $0 + $1.audioUnitCount } }
    var hasTeardownWork: Bool { owners.contains(where: \.hasTeardownWork) }

    func tearDownAudioUnits(
        using gate: AudioUnitTeardownGate
    ) -> AudioUnitOwnerDisposalResult {
        var disposed = 0
        for owner in owners {
            let result = owner.tearDownAudioUnits(using: gate)
            switch result {
            case .complete(let count):
                disposed += count
            case .operationFailed(let step, let status, let count):
                return .operationFailed(
                    step: step, status: status, disposedUnits: disposed + count)
            case .timedOut(let step, let count):
                return .timedOut(step: step, disposedUnits: disposed + count)
            case .ownerRetained(let count):
                return .ownerRetained(disposedUnits: disposed + count)
            case .blockedByRetainedTransaction:
                preconditionFailure("an owner cannot recursively submit disposal")
            }
        }
        owners.removeAll()
        return .complete(disposedUnits: disposed)
    }
}

/// The sole worker allowed to run Audio Unit lifecycle or graph teardown.
///
/// One blocked synchronous Core Audio call consumes this worker for the rest of
/// the process. Further owners are retained without starting another thread, and
/// every new AU graph is refused by the quarantine entry established before the
/// first operation began.
final class BoundedAudioUnitDisposer: @unchecked Sendable {
    static let shared = BoundedAudioUnitDisposer()

    /// Permission to execute one graph's AudioComponent construction calls.
    ///
    /// The lease closes the check/use race between observing no teardown and
    /// instantiating a unit. Owners fenced while construction is in progress are
    /// quarantined immediately, then submitted when the last lease is released.
    final class GraphAdmission: @unchecked Sendable {
        private let lock = NSLock()
        private var disposer: BoundedAudioUnitDisposer?

        fileprivate init(disposer: BoundedAudioUnitDisposer) {
            self.disposer = disposer
        }

        func release() {
            let disposer = lock.withLock { () -> BoundedAudioUnitDisposer? in
                defer { self.disposer = nil }
                return self.disposer
            }
            disposer?.releaseGraphAdmission()
        }

        func handOffForDisposal(
            _ owner: any AudioUnitTeardownOwner,
            until deadline: HALTeardownDeadline
        ) -> AudioUnitOwnerDisposalResult {
            let disposer = lock.withLock { () -> BoundedAudioUnitDisposer? in
                defer { self.disposer = nil }
                return self.disposer
            }
            return disposer?.replaceGraphAdmission(with: owner, until: deadline)
                ?? .blockedByRetainedTransaction(retainedUnits: owner.audioUnitCount)
        }

        deinit { release() }
    }

    private final class Transaction: @unchecked Sendable {
        let completion = DispatchGroup()
        let gate = AudioUnitTeardownGate()
        private let lock = NSLock()
        private var owner: (any AudioUnitTeardownOwner)?
        private var result: AudioUnitOwnerDisposalResult?
        private var didTimeOut = false
        var quarantineToken: ProcessLifetimeAudioQuarantine.Token?

        init(owner: any AudioUnitTeardownOwner) {
            self.owner = owner
            completion.enter()
        }

        var retainedOwner: (any AudioUnitTeardownOwner)? {
            lock.withLock { owner }
        }

        func releaseOwner() {
            lock.withLock { owner = nil }
        }

        func markTimedOut() -> AudioUnitTeardownStep? {
            lock.withLock { didTimeOut = true }
            return gate.cancel()
        }

        var timedOut: Bool { lock.withLock { didTimeOut } }

        func finish(_ result: AudioUnitOwnerDisposalResult) {
            lock.withLock { self.result = result }
            completion.leave()
        }

        var completedResult: AudioUnitOwnerDisposalResult? {
            lock.withLock { result }
        }
    }

    private struct PendingOwner {
        let owner: any AudioUnitTeardownOwner
        let quarantineToken: ProcessLifetimeAudioQuarantine.Token
    }

    private let lock = NSLock()
    private let worker: DispatchQueue
    private let deadlineQueue: DispatchQueue
    private let graphAdmissionCompletion = DispatchGroup()
    private let quarantine: ProcessLifetimeAudioQuarantine
    private let asynchronousTimeout: TimeInterval
    private let beforeTimedOutWaitCancelsTransaction: @Sendable () -> Void
    private var active: Transaction?
    private var graphAdmissions = 0
    private var pendingOwners: [PendingOwner] = []
    private var startedTransactions = 0
    private var maximumConcurrentTransactions = 0

    init(
        quarantine: ProcessLifetimeAudioQuarantine = .shared,
        asynchronousTimeout: TimeInterval = 2,
        label: String = "com.yuhuanstudio.yunaudio.audio-unit-disposer",
        beforeTimedOutWaitCancelsTransaction: @escaping @Sendable () -> Void = {}
    ) {
        self.quarantine = quarantine
        self.asynchronousTimeout = max(0, asynchronousTimeout)
        self.beforeTimedOutWaitCancelsTransaction =
            beforeTimedOutWaitCancelsTransaction
        worker = DispatchQueue(label: label, qos: .utility)
        deadlineQueue = DispatchQueue(label: label + ".deadline", qos: .utility)
    }

    /// Atomically reserves the right to execute a graph's AudioComponent calls.
    ///
    /// Every AU-specific quarantine entry is created while `lock` is held, so
    /// active teardown cannot appear between this check and lease publication.
    /// The process-wide registry is checked inside the same critical section;
    /// route-level HAL ownership is additionally serialised by RoutingEngine.
    func acquireGraphAdmission(
        waitingUpTo timeout: TimeInterval = 2
    ) -> GraphAdmission? {
        acquireGraphAdmission(waitingUpTo: timeout, drainingSubmittedOwners: false)
    }

    /// Waits for already-submitted teardown before reserving the next graph.
    ///
    /// A structural route restart is ordered behind its predecessor's sole
    /// disposer transaction. This wait does not start a peer or extend any
    /// Audio Unit call's own deadline; it only spends the caller's route-level
    /// admission budget waiting for the existing transaction to finish.
    func acquireGraphAdmissionAfterDraining(
        waitingUpTo timeout: TimeInterval
    ) -> GraphAdmission? {
        acquireGraphAdmission(waitingUpTo: timeout, drainingSubmittedOwners: true)
    }

    private func acquireGraphAdmission(
        waitingUpTo timeout: TimeInterval,
        drainingSubmittedOwners: Bool
    ) -> GraphAdmission? {
        let deadline = DispatchTime.now() + max(0, timeout)
        while true {
            let selection:
                (
                    admission: GraphAdmission?, wait: DispatchGroup?, refused: Bool
                ) = lock.withLock {
                    if !drainingSubmittedOwners {
                        guard pendingOwners.isEmpty else { return (nil, nil, true) }
                    }
                    if let active {
                        if active.timedOut || active.completedResult != nil {
                            return (nil, nil, true)
                        }
                        return (nil, active.completion, false)
                    }
                    if graphAdmissions > 0 {
                        return (nil, graphAdmissionCompletion, false)
                    }
                    guard pendingOwners.isEmpty else { return (nil, nil, true) }
                    guard quarantine.refusalForNewAudioOwnership() == nil else {
                        return (nil, nil, true)
                    }
                    graphAdmissions = 1
                    graphAdmissionCompletion.enter()
                    return (GraphAdmission(disposer: self), nil, false)
                }
            if let admission = selection.admission { return admission }
            if selection.refused { return nil }
            guard let wait = selection.wait,
                wait.wait(timeout: deadline) == .success
            else { return nil }
        }
    }

    var admitsNewGraph: Bool {
        lock.withLock {
            active == nil && pendingOwners.isEmpty && graphAdmissions == 0
                && quarantine.count == 0
        }
    }

    var activeTransactionCount: Int { lock.withLock { active == nil ? 0 : 1 } }
    var pendingOwnerCount: Int { lock.withLock { pendingOwners.count } }
    var transactionCount: Int { lock.withLock { startedTransactions } }
    var maximumTransactionCount: Int { lock.withLock { maximumConcurrentTransactions } }

    /// Waits only for the route's remaining absolute budget.
    func dispose(
        _ owner: any AudioUnitTeardownOwner,
        until deadline: HALTeardownDeadline
    ) -> AudioUnitOwnerDisposalResult {
        guard owner.hasTeardownWork else { return drain(until: deadline) }

        while true {
            if !owner.hasTeardownWork { return drain(until: deadline) }
            if let graphWait = lock.withLock({
                graphAdmissions > 0 ? graphAdmissionCompletion : nil
            }) {
                let remaining = deadline.remainingTimeInterval
                guard remaining > 0,
                    graphWait.wait(timeout: .now() + remaining) == .success
                else {
                    retainForDeferredDisposal(
                        owner, reason: "AU owner blocked behind graph construction")
                    return .blockedByRetainedTransaction(
                        retainedUnits: owner.audioUnitCount)
                }
                continue
            }
            let selection: (transaction: Transaction?, started: Bool) = lock.withLock {
                guard graphAdmissions == 0 else { return (nil, false) }
                if let active { return (active, false) }
                let transaction = beginLocked(owner)
                return (transaction, true)
            }
            guard let transaction = selection.transaction else { continue }

            if !selection.started {
                guard wait(for: transaction, until: deadline) else {
                    retainForDeferredDisposal(
                        owner, reason: "AU owner blocked behind timed-out teardown")
                    return .blockedByRetainedTransaction(retainedUnits: owner.audioUnitCount)
                }
                let remainsActive = lock.withLock { active === transaction }
                if remainsActive {
                    retainForDeferredDisposal(
                        owner, reason: "AU owner blocked behind failed teardown")
                    return .blockedByRetainedTransaction(retainedUnits: owner.audioUnitCount)
                }
                continue
            }

            guard wait(for: transaction, until: deadline) else {
                let step = transaction.markTimedOut()
                return .timedOut(step: step, disposedUnits: 0)
            }
            return transaction.completedResult
                ?? .timedOut(step: nil, disposedUnits: 0)
        }
    }

    /// Waits for cleanup already submitted by a failed graph constructor.
    ///
    /// Failed initialisation may own no route property for Stop to collect, but
    /// its detached resource capsule is still part of that route transaction.
    private func drain(
        until deadline: HALTeardownDeadline
    ) -> AudioUnitOwnerDisposalResult {
        guard let transaction = lock.withLock({ active }) else {
            return .complete(disposedUnits: 0)
        }
        guard wait(for: transaction, until: deadline) else {
            return .timedOut(
                step: transaction.gate.stepInFlight, disposedUnits: 0)
        }
        if lock.withLock({ active === transaction }) {
            return transaction.completedResult
                ?? .blockedByRetainedTransaction(retainedUnits: 0)
        }
        return drain(until: deadline)
    }

    /// Hands an already-fenced owner to the same sole worker without waiting.
    func disposeAfterFence(_ owner: any AudioUnitTeardownOwner) {
        guard owner.hasTeardownWork else { return }
        let transaction: Transaction? = lock.withLock {
            guard active == nil, graphAdmissions == 0 else {
                enqueuePendingLocked(
                    owner, reason: "AU owner retained behind existing transaction")
                return nil
            }
            return beginLocked(owner)
        }
        guard let transaction else { return }
        scheduleAsynchronousTimeout(for: transaction)
    }

    private func releaseGraphAdmission() {
        let releaseTokens: [ProcessLifetimeAudioQuarantine.Token] = lock.withLock {
            precondition(graphAdmissions == 1)
            graphAdmissions = 0
            graphAdmissionCompletion.leave()
            guard active == nil else { return [] }
            return startPendingLocked()
        }
        for token in releaseTokens { quarantine.release(token) }
    }

    /// Atomically turns a construction lease into the rejected unit's teardown.
    /// No new constructor can enter between the failure and quarantine.
    private func replaceGraphAdmission(
        with owner: any AudioUnitTeardownOwner,
        until deadline: HALTeardownDeadline
    ) -> AudioUnitOwnerDisposalResult {
        guard owner.hasTeardownWork else {
            releaseGraphAdmission()
            return .complete(disposedUnits: 0)
        }
        let submitted:
            (
                transaction: Transaction,
                tokens: [ProcessLifetimeAudioQuarantine.Token]
            ) = lock.withLock {
                precondition(graphAdmissions == 1 && active == nil)
                graphAdmissions = 0
                graphAdmissionCompletion.leave()
                enqueuePendingLocked(owner, reason: "rejected AU graph owner")
                let tokens = startPendingLocked()
                return (active!, tokens)
            }
        for token in submitted.tokens { quarantine.release(token) }
        guard wait(for: submitted.transaction, until: deadline) else {
            return .timedOut(
                step: submitted.transaction.gate.stepInFlight,
                disposedUnits: 0)
        }
        return submitted.transaction.completedResult
            ?? .blockedByRetainedTransaction(retainedUnits: owner.audioUnitCount)
    }

    private func scheduleAsynchronousTimeout(for transaction: Transaction) {
        deadlineQueue.asyncAfter(deadline: .now() + asynchronousTimeout) { [self] in
            let isStillActive = lock.withLock { active === transaction }
            if isStillActive { _ = transaction.markTimedOut() }
        }
    }

    private func beginLocked(_ owner: any AudioUnitTeardownOwner) -> Transaction {
        precondition(active == nil)
        let transaction = Transaction(owner: owner)
        transaction.quarantineToken = quarantine.retain(
            transaction, reason: "Audio Unit teardown transaction")
        active = transaction
        startedTransactions += 1
        maximumConcurrentTransactions = max(
            maximumConcurrentTransactions, active == nil ? 0 : 1)
        worker.async { [self, transaction] in run(transaction) }
        return transaction
    }

    private func run(_ transaction: Transaction) {
        guard transaction.retainedOwner != nil else {
            transaction.finish(.complete(disposedUnits: 0))
            return
        }
        var result = transaction.retainedOwner!.tearDownAudioUnits(using: transaction.gate)
        let succeededBeforeTimeout = result.isComplete && !transaction.timedOut

        if succeededBeforeTimeout {
            // Drop the callback-transitive owner before announcing completion.
            // A normal stop followed immediately by start must not race the old
            // owner's deinit or its process-quarantine token.
            transaction.releaseOwner()
            let tokensToRelease: [ProcessLifetimeAudioQuarantine.Token] = lock.withLock {
                if active === transaction { active = nil }
                var tokens: [ProcessLifetimeAudioQuarantine.Token] = []
                if let token = transaction.quarantineToken {
                    tokens.append(token)
                    transaction.quarantineToken = nil
                }
                if graphAdmissions == 0 { tokens += startPendingLocked() }
                return tokens
            }
            for token in tokensToRelease { quarantine.release(token) }
        } else if transaction.timedOut, result.isComplete {
            result = .timedOut(step: nil, disposedUnits: 0)
        }

        transaction.finish(result)
    }

    private func wait(
        for transaction: Transaction,
        until deadline: HALTeardownDeadline
    ) -> Bool {
        let remaining = deadline.remainingTimeInterval
        guard remaining > 0 else {
            _ = transaction.markTimedOut()
            return false
        }
        let result = transaction.completion.wait(timeout: .now() + remaining)
        if result == .success { return true }
        // Completion can win after DispatchGroup reports timeout but before the
        // cancellation bit is stored. Keep this boundary injectable so the
        // enqueue/completion missed-wakeup window remains deterministically tested.
        beforeTimedOutWaitCancelsTransaction()
        _ = transaction.markTimedOut()
        return false
    }

    private func retainForDeferredDisposal(
        _ owner: any AudioUnitTeardownOwner,
        reason: String
    ) {
        let releaseTokens: [ProcessLifetimeAudioQuarantine.Token] = lock.withLock {
            // This happens while the disposer lock still excludes promotion of
            // the pending queue. The command therefore cannot pass its own
            // cancellation check between the caller giving up and this bit
            // becoming visible.
            (owner as? any AudioUnitDeferredLifecycleCommand)?.cancelBeforeStart()
            enqueuePendingLocked(owner, reason: reason)
            // The transaction or graph admission we waited behind can complete
            // immediately before this lock is acquired. Its completion then saw
            // an empty queue, so this enqueue is also responsible for promotion.
            return startPendingLocked()
        }
        // Releasing a token can deinitialise arbitrary callback-transitive owners
        // which re-enter this disposer. ARC must therefore run outside its lock.
        for token in releaseTokens { quarantine.release(token) }
    }

    private func enqueuePendingLocked(
        _ owner: any AudioUnitTeardownOwner,
        reason: String
    ) {
        let token = quarantine.retain(owner, reason: reason)
        pendingOwners.append(PendingOwner(owner: owner, quarantineToken: token))
    }

    /// Starts every owner accumulated behind one construction or transaction as
    /// one bounded serial transaction. Its own token is established before the
    /// individual pending tokens are released by the caller.
    private func startPendingLocked() -> [ProcessLifetimeAudioQuarantine.Token] {
        guard active == nil, graphAdmissions == 0, !pendingOwners.isEmpty else {
            return []
        }
        let pending = pendingOwners
        pendingOwners.removeAll(keepingCapacity: true)
        let capsule = AudioUnitOwnerCapsule(pending.map(\.owner))
        let transaction = beginLocked(capsule)
        scheduleAsynchronousTimeout(for: transaction)
        return pending.map(\.quarantineToken)
    }
}

/// One construction-to-publication lease which can survive rejected instances.
///
/// A constructor may have to hand an orphaned Audio Unit to the disposer and
/// reacquire admission before continuing. Keeping the replaceable lease in one
/// reference lets its caller hold the exact resulting admission until graph
/// publication instead of reopening a check/use race after construction.
final class AudioUnitGraphAdmissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var admission: BoundedAudioUnitDisposer.GraphAdmission?

    init?(
        waitingUpTo timeout: TimeInterval,
        disposer: BoundedAudioUnitDisposer = .shared
    ) {
        guard let admission = disposer.acquireGraphAdmission(waitingUpTo: timeout) else {
            return nil
        }
        self.admission = admission
    }

    func handOffRejectedOwner(
        _ owner: any AudioUnitTeardownOwner,
        until deadline: HALTeardownDeadline
    ) -> AudioUnitOwnerDisposalResult {
        let admission = lock.withLock { () -> BoundedAudioUnitDisposer.GraphAdmission? in
            defer { self.admission = nil }
            return self.admission
        }
        return admission?.handOffForDisposal(owner, until: deadline)
            ?? .blockedByRetainedTransaction(retainedUnits: owner.audioUnitCount)
    }

    func reacquire(
        waitingUpTo timeout: TimeInterval,
        disposer: BoundedAudioUnitDisposer = .shared
    ) -> Bool {
        guard let admission = disposer.acquireGraphAdmission(waitingUpTo: timeout) else {
            return false
        }
        return lock.withLock {
            guard self.admission == nil else {
                admission.release()
                return false
            }
            self.admission = admission
            return true
        }
    }

    func release() {
        let admission = lock.withLock { () -> BoundedAudioUnitDisposer.GraphAdmission? in
            defer { self.admission = nil }
            return self.admission
        }
        admission?.release()
    }

    deinit { release() }
}
