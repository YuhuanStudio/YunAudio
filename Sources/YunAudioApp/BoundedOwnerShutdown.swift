import Foundation
import YunAudioHAL

/// What one bounded owner lane can prove after its only teardown operation.
enum OwnedResourceTeardownResult: Equatable, Sendable {
    case complete
    case operationFailed
    /// The caller's admission deadline expired before any framework call began.
    ///
    /// The same retained owner may be retried on its sole lane after AppKit
    /// refuses Quit. This is deliberately distinct from `timedOut`: once a
    /// synchronous framework call has begun, starting a peer beside it is not
    /// safe even if the original call later returns.
    case timedOutBeforeEntry
    case timedOut

    var isComplete: Bool { self == .complete }

    var permitsSameOwnerRetry: Bool { self == .timedOutBeforeEntry }
}

/// Process ownership for a non-HAL resource whose callback fence is uncertain.
///
/// Unlike `ProcessLifetimeAudioQuarantine`, this registry does not refuse a new
/// Core Audio graph merely because a light-ring report failed. It only makes
/// the lifetime claim literal when the controller which submitted teardown is
/// later released.
final class ProcessLifetimeResourceQuarantine: @unchecked Sendable {
    struct Token: Hashable, Sendable {
        fileprivate let value: UUID
    }

    static let shared = ProcessLifetimeResourceQuarantine()

    private let lock = NSLock()
    private var owners: [Token: AnyObject] = [:]

    @discardableResult
    func retain(_ owner: AnyObject) -> Token {
        let token = Token(value: UUID())
        lock.withLock { owners[token] = owner }
        return token
    }

    func release(_ token: Token) {
        let owner = lock.withLock { owners.removeValue(forKey: token) }
        withExtendedLifetime(owner) {}
    }

    var count: Int { lock.withLock { owners.count } }
}

/// Stops a late synchronous return from admitting another teardown call.
final class OwnedResourceShutdownGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func perform<Result>(_ operation: () -> Result) -> Result? {
        guard lock.withLock({ !isCancelled }) else { return nil }
        let result = operation()
        return lock.withLock { isCancelled ? nil : result }
    }

    func cancel() {
        lock.withLock { isCancelled = true }
    }
}

/// An exact-once result which can be observed without waiting on MainActor.
final class OwnedResourceTeardownFence: @unchecked Sendable {
    typealias Observer = @Sendable (OwnedResourceTeardownResult) -> Void

    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var resultStorage: OwnedResourceTeardownResult?
    private var observers: [Observer] = []
    private var completionCountStorage = 0

    init(completedWith result: OwnedResourceTeardownResult? = nil) {
        completion.enter()
        if let result { complete(result) }
    }

    @discardableResult
    func complete(_ result: OwnedResourceTeardownResult) -> Bool {
        let callbacks: [Observer]? = lock.withLock {
            guard resultStorage == nil else { return nil }
            resultStorage = result
            completionCountStorage += 1
            defer { observers.removeAll() }
            return observers
        }
        guard let callbacks else { return false }
        completion.leave()
        for callback in callbacks { callback(result) }
        return true
    }

    func observe(_ observer: @escaping Observer) {
        let result: OwnedResourceTeardownResult? = lock.withLock {
            guard let resultStorage else {
                observers.append(observer)
                return nil
            }
            return resultStorage
        }
        if let result { observer(result) }
    }

    func wait(timeout: TimeInterval) -> OwnedResourceTeardownResult {
        guard completion.wait(timeout: .now() + max(0, timeout)) == .success else {
            return .timedOut
        }
        return lock.withLock { resultStorage ?? .timedOut }
    }

    var completionCount: Int { lock.withLock { completionCountStorage } }

    var result: OwnedResourceTeardownResult? { lock.withLock { resultStorage } }
}

/// The sole lane allowed to release one callback-transitive resource owner.
///
/// Synchronous framework calls cannot be cancelled. The owner is retained in a
/// transaction before the call starts. A timeout or failure after framework
/// entry makes that transaction process-lifetime state, and every later request
/// shares its already-settled fence instead of starting a replacement thread.
/// A queue-admission timeout may transfer the same owner to one later generation
/// because no framework call began. An optional audio quarantine also closes
/// construction admission while an uncertain `AVAudioEngine` owner remains.
final class BoundedOwnerShutdownWorker<Owner: AnyObject & Sendable>:
    @unchecked Sendable
{
    struct Telemetry: Equatable, Sendable {
        let submittedRequests: UInt64
        let startedOperations: UInt64
        let sharedRequests: UInt64
        let timedOutOperations: UInt64
        let timedOutBeforeEntry: UInt64
        let timedOutAfterEntry: UInt64
        let retriedBeforeEntry: UInt64
        let failedOperations: UInt64
        let maximumConcurrentOperations: Int
        let retainedOwner: Bool
    }

    private final class Transaction: @unchecked Sendable {
        enum Phase {
            case queued
            case entered
            case settled(OwnedResourceTeardownResult)
        }

        var owner: Owner?
        let fence = OwnedResourceTeardownFence()
        let gate = OwnedResourceShutdownGate()
        var phase: Phase = .queued
        var resourceQuarantineToken: ProcessLifetimeResourceQuarantine.Token?
        var quarantineToken: ProcessLifetimeAudioQuarantine.Token?

        init(owner: Owner) { self.owner = owner }
    }

    static var defaultTimeout: TimeInterval { 0.5 }

    private let lock = NSLock()
    private let worker: DispatchQueue
    private let deadlineQueue: DispatchQueue
    private let operation: @Sendable (Owner, OwnedResourceShutdownGate) -> Bool
    private let operationTimeout: TimeInterval
    private let resourceQuarantine: ProcessLifetimeResourceQuarantine
    private let audioQuarantine: ProcessLifetimeAudioQuarantine?
    private let quarantineReason: String

    private var transaction: Transaction?
    private var submittedRequests: UInt64 = 0
    private var startedOperations: UInt64 = 0
    private var sharedRequests: UInt64 = 0
    private var timedOutOperations: UInt64 = 0
    private var timedOutBeforeEntry: UInt64 = 0
    private var timedOutAfterEntry: UInt64 = 0
    private var retriedBeforeEntry: UInt64 = 0
    private var failedOperations: UInt64 = 0
    private var concurrentOperations = 0
    private var maximumConcurrentOperations = 0

    init(
        operationTimeout: TimeInterval = BoundedOwnerShutdownWorker.defaultTimeout,
        label: String,
        resourceQuarantine: ProcessLifetimeResourceQuarantine = .shared,
        audioQuarantine: ProcessLifetimeAudioQuarantine? = nil,
        quarantineReason: String,
        workerQueue: DispatchQueue? = nil,
        deadlineQueue: DispatchQueue? = nil,
        operation: @escaping @Sendable (Owner, OwnedResourceShutdownGate) -> Bool
    ) {
        self.operationTimeout = max(0, operationTimeout)
        self.resourceQuarantine = resourceQuarantine
        self.audioQuarantine = audioQuarantine
        self.quarantineReason = quarantineReason
        self.operation = operation
        worker = workerQueue ?? DispatchQueue(label: label, qos: .utility)
        self.deadlineQueue =
            deadlineQueue ?? DispatchQueue(label: label + ".deadline", qos: .utility)
    }

    /// Admits exactly one owner. Repeated Quit requests share its one result.
    ///
    /// The first call has already retained the owner before it returns. This is
    /// stronger than a first/latest mailbox for teardown: there can be no
    /// legitimate newer owner after termination invalidated construction.
    func submit(_ owner: Owner) -> OwnedResourceTeardownFence {
        let decision: (transaction: Transaction, shouldStart: Bool) = lock.withLock {
            submittedRequests &+= 1
            if let transaction {
                sharedRequests &+= 1
                return (transaction, false)
            }
            let transaction = Transaction(owner: owner)
            transaction.resourceQuarantineToken = resourceQuarantine.retain(owner)
            if let audioQuarantine {
                transaction.quarantineToken = audioQuarantine.retain(
                    owner, reason: quarantineReason)
            }
            self.transaction = transaction
            return (transaction, true)
        }
        guard decision.shouldStart else { return decision.transaction.fence }

        schedule(decision.transaction)
        return decision.transaction.fence
    }

    /// Retries only an attempt whose deadline won before its framework call began.
    ///
    /// Ownership and both quarantine tokens move to a new generation under the
    /// same lock. The obsolete queued closure can therefore do no work, while
    /// an operation which actually entered remains permanently non-reentrant.
    func retryAfterTimeoutBeforeEntry() -> OwnedResourceTeardownFence? {
        let retry: Transaction? = lock.withLock {
            guard let previous = transaction,
                case .settled(.timedOutBeforeEntry) = previous.phase,
                let owner = previous.owner
            else { return nil }

            let retry = Transaction(owner: owner)
            previous.owner = nil
            retry.resourceQuarantineToken = previous.resourceQuarantineToken
            previous.resourceQuarantineToken = nil
            retry.quarantineToken = previous.quarantineToken
            previous.quarantineToken = nil
            transaction = retry
            submittedRequests &+= 1
            retriedBeforeEntry &+= 1
            return retry
        }
        guard let retry else { return nil }
        schedule(retry)
        return retry.fence
    }

    var telemetry: Telemetry {
        lock.withLock {
            Telemetry(
                submittedRequests: submittedRequests,
                startedOperations: startedOperations,
                sharedRequests: sharedRequests,
                timedOutOperations: timedOutOperations,
                timedOutBeforeEntry: timedOutBeforeEntry,
                timedOutAfterEntry: timedOutAfterEntry,
                retriedBeforeEntry: retriedBeforeEntry,
                failedOperations: failedOperations,
                maximumConcurrentOperations: maximumConcurrentOperations,
                retainedOwner: transaction?.owner != nil)
        }
    }

    private func schedule(_ transaction: Transaction) {
        deadlineQueue.asyncAfter(deadline: .now() + operationTimeout) { [self] in
            timeOut(transaction)
        }
        worker.async { [self] in run(transaction) }
    }

    private func run(_ transaction: Transaction) {
        let owner: Owner? = lock.withLock {
            guard self.transaction === transaction,
                case .queued = transaction.phase,
                let owner = transaction.owner
            else { return nil }
            transaction.phase = .entered
            startedOperations &+= 1
            concurrentOperations += 1
            maximumConcurrentOperations = max(
                maximumConcurrentOperations, concurrentOperations)
            return owner
        }
        guard let owner else { return }

        let succeeded = operation(owner, transaction.gate)
        var resourceTokenToRelease: ProcessLifetimeResourceQuarantine.Token?
        var tokenToRelease: ProcessLifetimeAudioQuarantine.Token?
        let result: OwnedResourceTeardownResult? = lock.withLock {
            concurrentOperations -= 1
            guard self.transaction === transaction,
                case .entered = transaction.phase
            else {
                // A late return cannot turn a timed-out owner into a clean one.
                return nil
            }
            if succeeded {
                transaction.phase = .settled(.complete)
                transaction.owner = nil
                resourceTokenToRelease = transaction.resourceQuarantineToken
                transaction.resourceQuarantineToken = nil
                tokenToRelease = transaction.quarantineToken
                transaction.quarantineToken = nil
                return .complete
            }
            failedOperations &+= 1
            transaction.phase = .settled(.operationFailed)
            return .operationFailed
        }
        if let resourceTokenToRelease { resourceQuarantine.release(resourceTokenToRelease) }
        if let tokenToRelease { audioQuarantine?.release(tokenToRelease) }
        if let result { transaction.fence.complete(result) }
    }

    private func timeOut(_ transaction: Transaction) {
        let result: OwnedResourceTeardownResult? = lock.withLock {
            guard self.transaction === transaction else { return nil }
            let result: OwnedResourceTeardownResult
            switch transaction.phase {
            case .queued:
                result = .timedOutBeforeEntry
                timedOutBeforeEntry &+= 1
            case .entered:
                result = .timedOut
                timedOutAfterEntry &+= 1
                transaction.gate.cancel()
            case .settled:
                return nil
            }
            transaction.phase = .settled(result)
            timedOutOperations &+= 1
            return result
        }
        if let result { transaction.fence.complete(result) }
    }
}

/// Carries a background fence back to the application's exact-once MainActor join.
enum OwnedResourceShutdownDispatcher {
    static func submit(
        _ fence: OwnedResourceTeardownFence,
        completion: @escaping @MainActor @Sendable (OwnedResourceTeardownResult) -> Void
    ) {
        fence.observe { result in
            MainRunLoopDelivery.perform { completion(result) }
        }
    }
}
