import CoreAudio
import Dispatch
import Foundation

/// The observable outcome of asking Core Audio to remove an object.
///
/// A successful request is not the same as completed destruction. Core Audio
/// removes aggregate devices and taps asynchronously, and releasing their
/// owners before that boundary is one way an otherwise private object can keep
/// system audio work alive after the route has stopped.
public enum HALDestructionResult: Sendable, Equatable {
    /// The request succeeded and the object disappeared from its HAL census.
    case destroyed
    /// Core Audio refused the request. Retrying remains possible.
    case requestFailed(OSStatus)
    /// Core Audio accepted the request but the object remained at the deadline.
    case timedOut
}

/// One monotonic budget shared by every phase of a teardown transaction.
///
/// A relative timeout passed independently to an aggregate and then to every
/// tap turns a two-second Stop into `2 + tapCount * 2` seconds. The system audio
/// menu is another Core Audio client, so keeping HAL occupied that long makes
/// the whole machine look wedged. Passing this value down bounds deliberate
/// sleeps and repeated calls no matter how many objects the route owns. One
/// synchronous HAL call already in flight cannot be cancelled and may overrun;
/// expiry prevents another call from compounding it.
public struct HALTeardownDeadline: Sendable, Equatable {
    private let uptimeNanoseconds: UInt64

    public init(timeout: TimeInterval) {
        self.init(
            timeout: timeout,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    init(timeout: TimeInterval, nowUptimeNanoseconds: UInt64) {
        let seconds = max(0, timeout)
        let requestedNanoseconds: UInt64
        if !seconds.isFinite || seconds >= Double(UInt64.max) / 1_000_000_000 {
            requestedNanoseconds = UInt64.max
        } else {
            requestedNanoseconds = UInt64(seconds * 1_000_000_000)
        }
        uptimeNanoseconds =
            requestedNanoseconds > UInt64.max - nowUptimeNanoseconds
            ? UInt64.max : nowUptimeNanoseconds + requestedNanoseconds
    }

    /// Time still available at the instant it is read.
    public var remainingTimeInterval: TimeInterval {
        remainingTimeInterval(nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    /// Whether another synchronous operation may begin now.
    ///
    /// This is an admission check, not cancellation: an operation admitted
    /// immediately before expiry can still return after it. Every caller must
    /// ask again before starting its next operation.
    public var hasTimeRemaining: Bool {
        remainingTimeInterval > 0
    }

    func remainingTimeInterval(nowUptimeNanoseconds: UInt64) -> TimeInterval {
        guard uptimeNanoseconds > nowUptimeNanoseconds else { return 0 }
        return Double(uptimeNanoseconds - nowUptimeNanoseconds) / 1_000_000_000
    }

    /// Starts one synchronous operation only while this transaction still has
    /// time. The operation itself cannot be interrupted after admission.
    public func perform<T>(_ operation: () -> T) -> T? {
        perform(
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            operation)
    }

    func perform<T>(
        nowUptimeNanoseconds: UInt64,
        _ operation: () -> T
    ) -> T? {
        guard remainingTimeInterval(nowUptimeNanoseconds: nowUptimeNanoseconds) > 0 else {
            return nil
        }
        return operation()
    }
}

/// Remembers whether Core Audio accepted an asynchronous destruction request.
///
/// A refusal is retryable; an accepted request is not sent twice. The latter
/// matters because a timeout means only that the census did not catch up before
/// its deadline. Reissuing a destructive request against an object which may
/// already be disappearing turns a useful timeout into an unrelated bad-object
/// error and loses the original state.
struct HALDestructionRequestState: Sendable, Equatable {
    private(set) var wasAccepted = false
    private(set) var lastStatus: OSStatus?

    mutating func request(using operation: () -> OSStatus) -> OSStatus {
        if wasAccepted { return lastStatus ?? noErr }

        let status = operation()
        lastStatus = status
        wasAccepted = status == noErr
        return status
    }
}

/// Carries accepted-request state across independently scheduled cleanup calls.
///
/// A refusal may be retried. Once Core Audio accepts one request, later calls
/// perform only the absence census rather than resubmitting an asynchronous
/// destroy merely because its first census timed out.
final class HALDestructionRequestCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: HALDestructionRequestState

    init(requestWasAccepted: Bool) {
        state = HALDestructionRequestState(
            wasAccepted: requestWasAccepted,
            lastStatus: requestWasAccepted ? noErr : nil)
    }

    func request(using operation: () -> OSStatus) -> OSStatus {
        lock.withLock { state.request(using: operation) }
    }
}

/// Process-lifetime ownership for a Core Audio object whose callback or HAL
/// dependency was not proven gone before its Swift owner deinitialised.
///
/// Entries are normally released by a bounded background cleanup. A callback
/// fence which keeps failing remains here deliberately: bounded leaked state is
/// preferable to a dangling realtime pointer. YunAudio has one routing engine,
/// so the callback-facing permanent case is one capsule rather than one entry
/// per graph generation or IO cycle.
public final class ProcessLifetimeAudioQuarantine: @unchecked Sendable {
    public struct Token: Hashable, Sendable {
        fileprivate let value: UUID
    }

    public static let shared = ProcessLifetimeAudioQuarantine()

    private struct Entry {
        let owner: AnyObject
        let reason: String
        var cleanupAttempts = 0
        var scheduledRetryDelay: TimeInterval?
        var isExhausted: Bool
    }

    private let lock = NSLock()
    private let admissionCondition = NSCondition()
    private let retryPolicy: AudioResidueRetryPolicy
    private var entries: [Token: Entry] = [:]
    private var maximumRetainedEntries = 0
    private var cleanupAttempts: UInt64 = 0
    private var completedEntries: UInt64 = 0
    private var deniedAdmissions: UInt64 = 0

    public init() {
        retryPolicy = .standard
    }

    init(retryPolicy: AudioResidueRetryPolicy) {
        self.retryPolicy = retryPolicy
    }

    @discardableResult
    public func retain(_ owner: AnyObject, reason: String) -> Token {
        retain(owner, reason: reason, hasAutomaticCleanup: false)
    }

    public func release(_ token: Token) {
        // Removing the last owner can run arbitrary deinitialisers. In
        // particular, a captured tap may install its own HAL fallback in this
        // same registry, so ARC must run only after this lock is released.
        admissionCondition.lock()
        let removed = lock.withLock { entries.removeValue(forKey: token)?.owner }
        admissionCondition.broadcast()
        admissionCondition.unlock()
        withExtendedLifetime(removed) {}
    }

    /// Numeric evidence for diagnostics and deterministic ownership tests.
    public var count: Int { lock.withLock { entries.count } }

    public var reasons: [String] {
        lock.withLock { entries.values.map(\.reason).sorted() }
    }

    /// Refuses every new Core Audio owner while even one uncertain owner remains.
    ///
    /// This is a control-plane lock acquisition. It must be called before any HAL
    /// creation API, never from an IO callback or while holding an audio graph lock.
    public func admitNewAudioOwnership() -> Bool {
        refusalForNewAudioOwnership() == nil
    }

    /// Atomically refuses admission and returns the residue state which caused it.
    ///
    /// Reading telemetry in a second lock acquisition could report zero owners if a
    /// cleanup completed between the refusal and the read. The error handed to a
    /// caller must describe the state which actually made its request fail.
    public func refusalForNewAudioOwnership() -> AudioResidueTelemetry? {
        lock.withLock {
            guard !entries.isEmpty else { return nil }
            deniedAdmissions &+= 1
            return telemetryLocked()
        }
    }

    /// Waits for an already-running cleanup without starting a replacement.
    ///
    /// Route rebuilds stop one graph and immediately start its successor. HAL
    /// can acknowledge destruction just after Stop returns, leaving a tiny
    /// interval in which the old owner is still retained. Waiting on that same
    /// owner's release avoids both a false refusal and the unsafe alternative
    /// of opening a peer beside it. Call only from the serial lifecycle owner,
    /// never MainActor or a realtime callback.
    public func waitForNewAudioOwnership(
        timeout: TimeInterval,
        while shouldContinue: @Sendable () -> Bool = { true }
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        admissionCondition.lock()
        defer { admissionCondition.unlock() }
        while lock.withLock({ !entries.isEmpty }) {
            guard shouldContinue() else { return false }
            let nextCheck = min(deadline, Date(timeIntervalSinceNow: 0.05))
            guard admissionCondition.wait(until: nextCheck) else {
                if nextCheck < deadline { continue }
                return lock.withLock { entries.isEmpty }
            }
        }
        return true
    }

    /// A coherent numeric snapshot for diagnostics and admission tests.
    public var telemetry: AudioResidueTelemetry {
        lock.withLock { telemetryLocked() }
    }

    fileprivate func retainForCleanup(_ owner: AnyObject, reason: String) -> Token {
        retain(owner, reason: reason, hasAutomaticCleanup: true)
    }

    fileprivate func beginCleanupAttempt(_ token: Token) -> Int? {
        lock.withLock {
            guard var entry = entries[token], !entry.isExhausted else { return nil }
            entry.scheduledRetryDelay = nil
            entry.cleanupAttempts += 1
            entries[token] = entry
            cleanupAttempts &+= 1
            return entry.cleanupAttempts
        }
    }

    fileprivate func retryDelay(afterFailureOf token: Token) -> TimeInterval? {
        lock.withLock {
            guard var entry = entries[token], !entry.isExhausted else { return nil }
            guard
                let delay = retryPolicy.delayAfterFailure(
                    completedAttempts: entry.cleanupAttempts)
            else {
                entry.isExhausted = true
                entries[token] = entry
                return nil
            }
            entry.scheduledRetryDelay = delay
            entries[token] = entry
            return delay
        }
    }

    fileprivate func completeCleanup(_ token: Token) {
        admissionCondition.lock()
        let removed: AnyObject? = lock.withLock {
            guard let owner = entries.removeValue(forKey: token)?.owner else { return nil }
            completedEntries &+= 1
            return owner
        }
        admissionCondition.broadcast()
        admissionCondition.unlock()
        withExtendedLifetime(removed) {}
    }

    private func retain(
        _ owner: AnyObject,
        reason: String,
        hasAutomaticCleanup: Bool
    ) -> Token {
        let token = Token(value: UUID())
        lock.withLock {
            entries[token] = Entry(
                owner: owner, reason: reason, cleanupAttempts: 0,
                scheduledRetryDelay: hasAutomaticCleanup ? 0 : nil,
                isExhausted: !hasAutomaticCleanup)
            maximumRetainedEntries = max(maximumRetainedEntries, entries.count)
        }
        return token
    }

    private func telemetryLocked() -> AudioResidueTelemetry {
        AudioResidueTelemetry(
            retainedEntries: entries.count,
            maximumRetainedEntries: maximumRetainedEntries,
            cleanupAttempts: cleanupAttempts,
            scheduledRetries: entries.values.count {
                $0.scheduledRetryDelay != nil
            },
            exhaustedEntries: entries.values.reduce(0) {
                $0 + ($1.isExhausted ? 1 : 0)
            },
            completedEntries: completedEntries,
            deniedAdmissions: deniedAdmissions,
            maximumRetryDelay: retryPolicy.maximumDelay,
            maximumAttemptsPerEntry: retryPolicy.maximumAttempts)
    }
}

/// Moves a bounded deinit fallback off the releasing thread while retaining
/// every dependency it captured. Successful work releases its quarantine;
/// failed work remains process-owned rather than guessing that HAL is done.
final class BoundedHALDeinitCleanup: @unchecked Sendable {
    typealias Scheduler =
        @Sendable (
            _ delay: TimeInterval,
            _ operation: @escaping @Sendable () -> Void
        ) -> Void

    private static let queue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.hal-deinit-cleanup",
        qos: .utility)

    private let work: @Sendable () -> Bool
    private let quarantine: ProcessLifetimeAudioQuarantine
    private let scheduler: Scheduler
    private var token: ProcessLifetimeAudioQuarantine.Token?

    private init(
        quarantine: ProcessLifetimeAudioQuarantine,
        scheduler: @escaping Scheduler,
        work: @escaping @Sendable () -> Bool
    ) {
        self.quarantine = quarantine
        self.scheduler = scheduler
        self.work = work
    }

    static func quarantine(
        reason: String,
        work: @escaping @Sendable () -> Bool
    ) {
        quarantine(
            in: .shared,
            scheduler: { delay, operation in
                queue.asyncAfter(deadline: .now() + delay, execute: operation)
            },
            reason: reason,
            work: work)
    }

    /// Injectable form for proving the retry count and delays without HAL or time.
    static func quarantine(
        in quarantine: ProcessLifetimeAudioQuarantine,
        scheduler: @escaping Scheduler,
        reason: String,
        work: @escaping @Sendable () -> Bool
    ) {
        let cleanup = BoundedHALDeinitCleanup(
            quarantine: quarantine, scheduler: scheduler, work: work)
        cleanup.token = quarantine.retainForCleanup(cleanup, reason: reason)
        cleanup.schedule(after: 0)
    }

    private func schedule(after delay: TimeInterval) {
        scheduler(delay) { [self] in
            guard let token, quarantine.beginCleanupAttempt(token) != nil else { return }
            if work() {
                quarantine.completeCleanup(token)
                return
            }
            guard let delay = quarantine.retryDelay(afterFailureOf: token) else { return }
            schedule(after: delay)
        }
    }
}

/// A deterministic polling primitive for asynchronous HAL removal.
enum HALRemovalWaiter {
    /// Polls against an absolute deadline rather than a count computed before
    /// the first HAL call. Census IPC consumes budget too; precomputing sleeps
    /// would let a slow audio server extend the transaction far past its bound.
    static func wait(
        until deadline: HALTeardownDeadline,
        pollInterval: TimeInterval,
        betweenAttempts: (TimeInterval) -> Void,
        isPresent: () -> Bool
    ) -> Bool {
        wait(
            pollInterval: pollInterval,
            remaining: { deadline.remainingTimeInterval },
            betweenAttempts: betweenAttempts,
            isPresent: isPresent)
    }

    /// Injectable clock form for proving that time spent inside the HAL census
    /// itself prevents another call after expiry.
    static func wait(
        pollInterval: TimeInterval,
        remaining: () -> TimeInterval,
        betweenAttempts: (TimeInterval) -> Void,
        isPresent: () -> Bool
    ) -> Bool {
        precondition(pollInterval > 0)
        // A census is synchronous HAL IPC too. An expired transaction cannot
        // buy an ostensibly free first read: that read was the call observed
        // wedging after the rest of teardown had consumed its budget.
        guard remaining() > 0 else { return false }
        if !isPresent() { return true }
        while true {
            let available = remaining()
            guard available > 0 else { return false }
            betweenAttempts(min(pollInterval, available))
            // Do not begin another synchronous HAL call after the sleep spent
            // the last of the budget. A call already in progress cannot be
            // cancelled, but an expired transaction never compounds it.
            guard remaining() > 0 else { return false }
            if !isPresent() { return true }
        }
    }

    /// - Parameters:
    ///   - maximumAttempts: Presence reads after the initial one.
    ///   - betweenAttempts: The production delay, injectable so tests do not
    ///     ask wall-clock scheduling to prove the loop.
    ///   - isPresent: One bounded census read.
    /// - Returns: True as soon as the object is absent.
    static func wait(
        maximumAttempts: Int,
        betweenAttempts: () -> Void,
        isPresent: () -> Bool
    ) -> Bool {
        let attempts = max(0, maximumAttempts)
        for attempt in 0...attempts {
            if !isPresent() { return true }
            if attempt < attempts { betweenAttempts() }
        }
        return false
    }
}
