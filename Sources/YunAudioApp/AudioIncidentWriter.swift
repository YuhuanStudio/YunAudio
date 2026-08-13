import Darwin
import Foundation
import YunAudioEngine

/// Persists the active value, one exact critical checkpoint and its terminal value.
///
/// Encoding, directory creation and atomic replacement stay on one utility
/// owner. `submit` is therefore safe to call while the engine lifecycle lock is
/// held: it performs bounded value assignments and never waits for storage. The
/// third slot exists only when a timed-out critical checkpoint is already pending;
/// its same-run final must not be lost merely because the exact checkpoint still
/// has to pass through the sole writer first.
final class LatestAudioIncidentWriter: @unchecked Sendable {
    static let shared = LatestAudioIncidentWriter()

    enum DurableWriteResult: Sendable, Equatable {
        case persisted
        case writeFailed
        case refused
        case timedOut
    }

    final class DurableWriteReceipt: @unchecked Sendable {
        fileprivate let id: UInt64
        private let lock = NSLock()
        private let completion = DispatchGroup()
        private var result: DurableWriteResult?

        fileprivate init(id: UInt64) {
            self.id = id
            completion.enter()
        }

        /// Waits for this exact write without starting another storage owner.
        ///
        /// A timeout is terminal for the receipt. The original serial writer
        /// may still return later, but that late answer cannot turn evidence
        /// which missed its admission deadline into `.persisted`.
        func wait(timeout: Duration) -> DurableWriteResult {
            if let result = lock.withLock({ result }) { return result }
            if completion.wait(
                timeout: .now() + LatestAudioIncidentWriter.dispatchInterval(timeout))
                == .timedOut
            {
                resolve(.timedOut)
            }
            return lock.withLock { result ?? .timedOut }
        }

        fileprivate func resolve(_ result: DurableWriteResult) {
            let signals = lock.withLock {
                guard self.result == nil else { return false }
                self.result = result
                return true
            }
            if signals { completion.leave() }
        }
    }

    enum FlushResult: Sendable, Equatable {
        case complete
        case writeFailed
        case timedOut
        case refused
    }

    struct Statistics: Sendable, Equatable {
        fileprivate(set) var submissions: UInt64 = 0
        fileprivate(set) var writes: UInt64 = 0
        fileprivate(set) var coalesced: UInt64 = 0
        fileprivate(set) var failures: UInt64 = 0
        fileprivate(set) var flushTimeouts: UInt64 = 0
        fileprivate(set) var maximumPending = 0
    }

    struct Operations: Sendable {
        let write: @Sendable (AudioIncidentBundle) -> Bool

        static let system = Operations { bundle in
            guard
                let root = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                ).first
            else { return false }
            let directory =
                root
                .appendingPathComponent("YunAudio", isDirectory: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
            let destination = directory.appendingPathComponent(
                "last-audio-incident.json", isDirectory: false)
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                guard chmod(directory.path, 0o700) == 0 else { return false }
                let data = try AudioIncidentBundleCodec.encode(bundle)
                return secureAtomicWrite(data, to: destination)
            } catch {
                return false
            }
        }

        /// Replaces one file without a window in which incident evidence has
        /// ordinary umask-derived permissions.
        static func secureAtomicWrite(_ data: Data, to destination: URL) -> Bool {
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".incident-\(UUID().uuidString).tmp")
            let temporaryPath = temporary.path
            let destinationPath = destination.path
            let descriptor = open(
                temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return false }
            var isOpen = true
            var wasRenamed = false
            defer {
                if isOpen { _ = close(descriptor) }
                if !wasRenamed { _ = unlink(temporaryPath) }
            }

            let wroteEverything = data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return data.isEmpty }
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(
                        descriptor, base.advanced(by: offset), raw.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            guard wroteEverything, fsync(descriptor) == 0 else { return false }
            let closeStatus = close(descriptor)
            isOpen = false
            guard closeStatus == 0 else { return false }
            guard rename(temporaryPath, destinationPath) == 0 else { return false }
            wasRenamed = true
            return true
        }
    }

    private struct Work {
        let generation: UInt64
        let bundle: AudioIncidentBundle
        let durableReceipt: DurableWriteReceipt?

        var isCritical: Bool { durableReceipt != nil }
    }

    private struct FlushWaiter {
        let id: UInt64
        let targetGeneration: UInt64
        let completion: @Sendable (FlushResult) -> Void
    }

    private struct State {
        var active: Work?
        var pending: Work?
        var terminalAfterCritical: Work?
        var hasWorker = false
        var acceptsSubmissions = true
        var generation: UInt64 = 0
        var completedGeneration: UInt64 = 0
        var persistedGeneration: UInt64 = 0
        var lastPersistedBundle: AudioIncidentBundle?
        var newestAdmittedStartedUptimeNanoseconds: UInt64 = 0
        var newestAdmittedRunID: AudioIncidentRunID?
        var newestAdmittedPhase: UInt8 = 0
        var newestAdmittedEndedUptimeNanoseconds: UInt64 = 0
        var nextWaiterID: UInt64 = 0
        var nextDurableReceiptID: UInt64 = 0
        var waiters: [FlushWaiter] = []
        var statistics = Statistics()
    }

    private static func phaseRank(_ bundle: AudioIncidentBundle) -> UInt8 {
        switch bundle.teardownStatus {
        case .notObserved: 0
        case .incomplete, .timedOut: 1
        case .complete: 2
        }
    }

    private static func wouldRegress(
        _ incoming: AudioIncidentBundle,
        behind work: Work?
    ) -> Bool {
        guard let work, work.bundle.runID == incoming.runID else { return false }
        return phaseRank(incoming) < phaseRank(work.bundle)
    }

    private static func wouldRegressFrontier(
        _ incoming: AudioIncidentBundle,
        state: State
    ) -> Bool {
        guard let runID = state.newestAdmittedRunID else { return false }
        if incoming.startedUptimeNanoseconds < state.newestAdmittedStartedUptimeNanoseconds {
            return true
        }
        if incoming.startedUptimeNanoseconds
            > state.newestAdmittedStartedUptimeNanoseconds
        {
            return false
        }
        guard incoming.runID == runID else { return true }
        let phase = phaseRank(incoming)
        if phase < state.newestAdmittedPhase { return true }
        // Equal observation time is either an exact duplicate or an ambiguous
        // snapshot whose evidence cannot be ordered. Neither may replace the
        // already admitted value.
        return phase == state.newestAdmittedPhase
            && incoming.endedUptimeNanoseconds
                <= state.newestAdmittedEndedUptimeNanoseconds
    }

    private static func advanceFrontier(
        with bundle: AudioIncidentBundle,
        state: inout State
    ) {
        state.newestAdmittedStartedUptimeNanoseconds = bundle.startedUptimeNanoseconds
        state.newestAdmittedRunID = bundle.runID
        state.newestAdmittedPhase = phaseRank(bundle)
        state.newestAdmittedEndedUptimeNanoseconds = bundle.endedUptimeNanoseconds
    }

    private static let maximumFlushWaiters = 4
    private let lock = NSLock()
    private var state = State()
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let operations: Operations

    init(
        operations: Operations = .system,
        label: String = "com.yuhuanstudio.yunaudio.incident-writer",
        workerQueue: DispatchQueue? = nil
    ) {
        self.operations = operations
        queue = workerQueue ?? DispatchQueue(label: label, qos: .utility)
        callbackQueue = DispatchQueue(label: label + ".flush", qos: .utility)
    }

    var statistics: Statistics { lock.withLock { state.statistics } }

    @discardableResult
    func submit(_ bundle: AudioIncidentBundle?) -> Bool {
        guard let bundle else { return false }
        let decision: (accepted: Bool, schedulesWorker: Bool) = lock.withLock {
            guard state.acceptsSubmissions else { return (false, false) }
            guard !Self.wouldRegressFrontier(bundle, state: state) else {
                return (false, false)
            }
            guard !Self.wouldRegress(bundle, behind: state.active),
                !Self.wouldRegress(bundle, behind: state.pending),
                !Self.wouldRegress(bundle, behind: state.terminalAfterCritical),
                !Self.wouldRegress(
                    bundle,
                    behind: state.lastPersistedBundle.map {
                        Work(generation: 0, bundle: $0, durableReceipt: nil)
                    })
            else { return (false, false) }
            // A critical checkpoint has already been admitted and must reach
            // the sole writer unchanged. Its own newer terminal bundle may sit
            // behind it: a receipt timeout ends only the wait, not the write,
            // and abandoning that final would leave `.notObserved` on disk.
            if let pending = state.pending, pending.isCritical {
                guard bundle.runID == pending.bundle.runID,
                    Self.phaseRank(bundle) > Self.phaseRank(pending.bundle)
                else { return (false, false) }
                state.generation &+= 1
                state.statistics.submissions &+= 1
                Self.advanceFrontier(with: bundle, state: &state)
                let work = Work(
                    generation: state.generation, bundle: bundle,
                    durableReceipt: nil)
                if state.terminalAfterCritical != nil {
                    state.statistics.coalesced &+= 1
                }
                state.terminalAfterCritical = work
                state.statistics.maximumPending = max(
                    state.statistics.maximumPending, 2)
                return (true, false)
            }
            state.generation &+= 1
            state.statistics.submissions &+= 1
            Self.advanceFrontier(with: bundle, state: &state)
            let work = Work(
                generation: state.generation, bundle: bundle,
                durableReceipt: nil)
            if state.active != nil {
                if state.pending != nil { state.statistics.coalesced &+= 1 }
                state.pending = work
                state.statistics.maximumPending = max(
                    state.statistics.maximumPending, 1)
                return (true, false)
            }
            state.active = work
            precondition(!state.hasWorker)
            state.hasWorker = true
            return (true, true)
        }
        if decision.schedulesWorker { queue.async { [self] in drain() } }
        return decision.accepted
    }

    /// Admits one non-coalescing write and reports that exact work's result.
    ///
    /// At most one pending value still exists. When that slot is occupied this
    /// critical submission is refused instead of displacing earlier evidence.
    /// Conversely, once admitted, later latest-only submissions cannot replace
    /// it. `.persisted` is emitted only after the production operation has
    /// encoded, fsynced and atomically renamed this bundle.
    @discardableResult
    func submitCritical(_ bundle: AudioIncidentBundle) -> DurableWriteReceipt {
        let decision:
            (
                receipt: DurableWriteReceipt,
                accepted: Bool,
                schedulesWorker: Bool
            ) = lock.withLock {
                state.nextDurableReceiptID &+= 1
                let receipt = DurableWriteReceipt(id: state.nextDurableReceiptID)
                guard state.acceptsSubmissions, state.pending == nil,
                    state.terminalAfterCritical == nil,
                    !Self.wouldRegressFrontier(bundle, state: state),
                    !Self.wouldRegress(bundle, behind: state.active),
                    !Self.wouldRegress(
                        bundle,
                        behind: state.lastPersistedBundle.map {
                            Work(generation: 0, bundle: $0, durableReceipt: nil)
                        })
                else {
                    return (receipt, false, false)
                }

                state.generation &+= 1
                state.statistics.submissions &+= 1
                Self.advanceFrontier(with: bundle, state: &state)
                let work = Work(
                    generation: state.generation, bundle: bundle,
                    durableReceipt: receipt)
                guard state.active != nil else {
                    state.active = work
                    precondition(!state.hasWorker)
                    state.hasWorker = true
                    return (receipt, true, true)
                }
                state.pending = work
                state.statistics.maximumPending = max(
                    state.statistics.maximumPending, 1)
                return (receipt, true, false)
            }

        guard decision.accepted else {
            decision.receipt.resolve(.refused)
            return decision.receipt
        }
        if decision.schedulesWorker { queue.async { [self] in drain() } }
        return decision.receipt
    }

    /// Resolves after the newest incident visible at entry has been replaced.
    ///
    /// A timeout abandons only this observer. The sole writer remains alive and
    /// no replacement thread is started against the same storage subsystem.
    func flush(
        timeout: Duration,
        completion: @escaping @Sendable (FlushResult) -> Void
    ) {
        let decision: (id: UInt64?, immediate: FlushResult?) = lock.withLock {
            let target = state.generation
            if target == 0 || state.persistedGeneration >= target {
                return (nil, .complete)
            }
            if state.completedGeneration >= target {
                return (nil, .writeFailed)
            }
            guard state.waiters.count < Self.maximumFlushWaiters else {
                return (nil, .refused)
            }
            state.nextWaiterID &+= 1
            let id = state.nextWaiterID
            state.waiters.append(
                FlushWaiter(
                    id: id,
                    targetGeneration: target,
                    completion: completion))
            return (id, nil)
        }
        if let immediate = decision.immediate {
            callbackQueue.async { completion(immediate) }
            return
        }
        guard let id = decision.id else { return }
        callbackQueue.asyncAfter(deadline: .now() + Self.dispatchInterval(timeout)) {
            [self] in
            let timedOut = lock.withLock { () -> FlushWaiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                state.statistics.flushTimeouts &+= 1
                return state.waiters.remove(at: index)
            }
            timedOut?.completion(.timedOut)
        }
    }

    func shutdown() {
        lock.withLock { state.acceptsSubmissions = false }
    }

    private func drain() {
        while let work = activeWork() {
            let succeeded = autoreleasepool { operations.write(work.bundle) }
            let resolved = finish(work, succeeded: succeeded)
            work.durableReceipt?.resolve(succeeded ? .persisted : .writeFailed)
            for (waiter, result) in resolved {
                callbackQueue.async { waiter.completion(result) }
            }
        }
    }

    private func activeWork() -> Work? { lock.withLock { state.active } }

    private func finish(
        _ work: Work,
        succeeded: Bool
    ) -> [(FlushWaiter, FlushResult)] {
        lock.withLock {
            precondition(state.active?.generation == work.generation)
            state.statistics.writes &+= 1
            state.completedGeneration = max(state.completedGeneration, work.generation)
            if succeeded {
                state.persistedGeneration = max(
                    state.persistedGeneration, work.generation)
                state.lastPersistedBundle = work.bundle
            } else {
                state.statistics.failures &+= 1
            }
            state.active = state.pending
            state.pending = state.terminalAfterCritical
            state.terminalAfterCritical = nil
            if state.active == nil { state.hasWorker = false }
            var resolved: [(FlushWaiter, FlushResult)] = []
            let waiters = state.waiters
            state.waiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                let result: FlushResult?
                if state.persistedGeneration >= waiter.targetGeneration {
                    result = .complete
                } else if state.completedGeneration >= waiter.targetGeneration {
                    result = .writeFailed
                } else {
                    result = nil
                }
                if let result {
                    resolved.append((waiter, result))
                } else {
                    state.waiters.append(waiter)
                }
            }
            return resolved
        }
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return .nanoseconds(0)
        }
        let seconds = UInt64(components.seconds)
        let subsecond = UInt64(components.attoseconds / 1_000_000_000)
        let whole = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !whole.overflow else { return .never }
        let total = whole.partialValue.addingReportingOverflow(subsecond)
        guard !total.overflow else { return .never }
        return .nanoseconds(Int(clamping: total.partialValue))
    }
}
