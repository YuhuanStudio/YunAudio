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
