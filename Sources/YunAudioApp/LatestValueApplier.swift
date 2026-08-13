import Foundation

/// Runs expensive state publication off the main actor and keeps only the
/// newest value that arrived while one publication was in flight.
///
/// A slider can produce far more events than audio state can usefully install.
/// Queueing every intermediate value makes the sound chase the pointer after
/// the gesture has already ended; dropping the last one makes the control lie.
/// This shape runs the first value, coalesces the burst behind it, then runs the
/// latest value exactly once.
@MainActor
final class LatestValueApplier<Value: Sendable, Result: Sendable> {
    private let queue: DispatchQueue
    private let apply: @Sendable (Value) -> Result
    private let publish: @MainActor (Result) -> Void
    private var pending: Value?
    private var isApplying = false
    private var generation = 0

    init(
        queue: DispatchQueue,
        apply: @escaping @Sendable (Value) -> Result,
        publish: @escaping @MainActor (Result) -> Void
    ) {
        self.queue = queue
        self.apply = apply
        self.publish = publish
    }

    func submit(_ value: Value) {
        generation &+= 1
        pending = value
        guard !isApplying else { return }
        startPending()
    }

    /// Makes every queued or in-flight answer belong to an obsolete lifetime.
    ///
    /// A route graph can finish after Stop and deliver its MainActor callback
    /// after a new Start. Submission order alone cannot distinguish those two
    /// engine lifetimes, so stopping invalidates the publisher and clears work
    /// that has not reached the serial queue yet.
    func invalidate() {
        generation &+= 1
        pending = nil
    }

    /// Applies a value before returning, after any already-running work.
    ///
    /// Used by deterministic verification and route-start finalisation. The
    /// generation makes an older asynchronous result ineligible to publish
    /// after this newer synchronous answer.
    func flush(_ value: Value) -> Result {
        generation &+= 1
        pending = nil
        let result = queue.sync { apply(value) }
        publish(result)
        return result
    }

    private func startPending() {
        guard let value = pending else {
            isApplying = false
            return
        }
        pending = nil
        isApplying = true
        let workGeneration = generation
        let apply = apply
        queue.async { [weak self] in
            let result = apply(value)
            Task { @MainActor [weak self] in
                self?.finished(result, generation: workGeneration)
            }
        }
    }

    private func finished(_ result: Result, generation workGeneration: Int) {
        if workGeneration == generation { publish(result) }
        if pending == nil {
            isApplying = false
        } else {
            startPending()
        }
    }
}

/// Applies at most one newest value per fixed window, sampled when the worker
/// can actually run rather than when work is enqueued.
///
/// A Core Audio property write may sit behind a multi-second device start on
/// the shared serial queue. Capturing the value before that wait would replay
/// an obsolete slider position when the queue recovered, then chase every
/// intermediate position. This gate keeps one value behind a lock and takes it
/// only at execution time. Fifty milliseconds therefore means at most twenty
/// HAL write batches per second, with one final value guaranteed after a burst.
final class RateLimitedLatestValueApplier<Value: Sendable, Result: Sendable>:
    @unchecked Sendable
{
    struct Statistics: Sendable, Equatable {
        fileprivate(set) var submissions: UInt64 = 0
        fileprivate(set) var coalesced: UInt64 = 0
        fileprivate(set) var applications: UInt64 = 0
    }

    private struct State {
        var pending: Value?
        var hasScheduledWorker = false
        var generation: UInt64 = 0
        var statistics = Statistics()
    }

    private let lock = NSLock()
    private var state = State()
    private let queue: DispatchQueue
    private let interval: DispatchTimeInterval
    private let apply: @Sendable (Value) -> Result
    private let publish: @MainActor (Result) -> Void

    init(
        queue: DispatchQueue,
        interval: DispatchTimeInterval,
        apply: @escaping @Sendable (Value) -> Result,
        publish: @escaping @MainActor (Result) -> Void
    ) {
        self.queue = queue
        self.interval = interval
        self.apply = apply
        self.publish = publish
    }

    var statistics: Statistics {
        lock.withLock { state.statistics }
    }

    func submit(_ value: Value) {
        let shouldSchedule = lock.withLock {
            state.statistics.submissions &+= 1
            if state.pending != nil { state.statistics.coalesced &+= 1 }
            state.pending = value
            state.generation &+= 1
            guard !state.hasScheduledWorker else { return false }
            state.hasScheduledWorker = true
            return true
        }
        if shouldSchedule { scheduleWorker() }
    }

    /// Drops work which has not begun and makes an in-flight result obsolete.
    func invalidate() {
        lock.withLock {
            state.generation &+= 1
            state.pending = nil
        }
    }

    private func scheduleWorker() {
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.runNewest()
        }
    }

    private func runNewest() {
        let work: (value: Value, generation: UInt64)? = lock.withLock {
            guard let value = state.pending else {
                state.hasScheduledWorker = false
                return nil
            }
            state.pending = nil
            state.statistics.applications &+= 1
            return (value, state.generation)
        }
        guard let work else { return }

        let result = apply(work.value)
        let outcome: (publishes: Bool, schedulesAgain: Bool) = lock.withLock {
            let publishes = state.generation == work.generation
            if state.pending == nil {
                state.hasScheduledWorker = false
                return (publishes, false)
            }
            return (publishes, true)
        }
        if outcome.publishes {
            Task { @MainActor [publish] in publish(result) }
        }
        if outcome.schedulesAgain { scheduleWorker() }
    }
}

/// Coalesces independent controls by identity before they reach a serial owner.
///
/// A route start can occupy `coreaudiod` for seconds. Enqueuing one closure for
/// every pointer event behind that call makes Stop wait for thousands of stale
/// fader positions after the server finally replies. One pending value per key
/// preserves every independent control while replacing intermediate values of
/// the same control. The worker samples the whole bounded set only when its
/// queue can run, so an old gesture never becomes a delayed replay storm.
final class KeyedLatestValueApplier<Key: Hashable & Sendable, Value: Sendable>:
    @unchecked Sendable
{
    struct Statistics: Sendable, Equatable {
        fileprivate(set) var submissions: UInt64 = 0
        fileprivate(set) var coalesced: UInt64 = 0
        fileprivate(set) var batches: UInt64 = 0
        fileprivate(set) var applications: UInt64 = 0
        fileprivate(set) var maximumPending: Int = 0
    }

    private struct State {
        var pending: [Key: Value] = [:]
        var hasScheduledWorker = false
        var statistics = Statistics()
    }

    private let lock = NSLock()
    private var state = State()
    private let queue: DispatchQueue
    private let apply: @Sendable (Value) -> Void

    init(
        queue: DispatchQueue,
        apply: @escaping @Sendable (Value) -> Void
    ) {
        self.queue = queue
        self.apply = apply
    }

    var statistics: Statistics {
        lock.withLock { state.statistics }
    }

    func submit(_ value: Value, for key: Key) {
        let shouldSchedule = lock.withLock {
            state.statistics.submissions &+= 1
            if state.pending.updateValue(value, forKey: key) != nil {
                state.statistics.coalesced &+= 1
            }
            state.statistics.maximumPending = max(
                state.statistics.maximumPending, state.pending.count)
            guard !state.hasScheduledWorker else { return false }
            state.hasScheduledWorker = true
            return true
        }
        if shouldSchedule { scheduleWorker() }
    }

    /// Drops controls which have not begun. A batch already executing precedes
    /// the caller on the same serial queue and therefore completes before Stop.
    func invalidate() {
        lock.withLock { state.pending.removeAll(keepingCapacity: true) }
    }

    private func scheduleWorker() {
        queue.async { [weak self] in self?.runPending() }
    }

    private func runPending() {
        let batch: [Value] = lock.withLock {
            guard !state.pending.isEmpty else {
                state.hasScheduledWorker = false
                return []
            }
            let values = Array(state.pending.values)
            state.pending.removeAll(keepingCapacity: true)
            state.statistics.batches &+= 1
            state.statistics.applications &+= UInt64(values.count)
            return values
        }
        guard !batch.isEmpty else { return }
        for value in batch { apply(value) }

        let schedulesAgain = lock.withLock {
            guard !state.pending.isEmpty else {
                state.hasScheduledWorker = false
                return false
            }
            return true
        }
        if schedulesAgain { scheduleWorker() }
    }
}
