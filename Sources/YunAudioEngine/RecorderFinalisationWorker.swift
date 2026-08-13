import Foundation

/// Process ownership for a writer whose storage call missed its deadline.
final class ProcessLifetimeRecorderQuarantine: @unchecked Sendable {
    static let shared = ProcessLifetimeRecorderQuarantine()

    private let lock = NSLock()
    private var owners: [RecorderRetirementOwner] = []

    func retain(_ owner: RecorderRetirementOwner) {
        lock.withLock { owners.append(owner) }
    }

    var count: Int { lock.withLock { owners.count } }
}

/// What one detached recording branch proved about its file writers.
public enum RecorderFinalisationResult: Equatable, Sendable {
    case complete
    case detachmentFailed
    case writerTimedOut
}

/// An exact-once result for recording finalisation.
///
/// Waiting belongs only on the recording lifecycle worker. MainActor, the
/// routing owner and the graph reclaimer observe or ignore this value; none of
/// them waits for storage to acknowledge a write.
public final class RecorderFinalisationFence: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var resultStorage: RecorderFinalisationResult?
    private var completionCountStorage = 0

    public init(completedWith result: RecorderFinalisationResult? = nil) {
        completion.enter()
        if let result { complete(result) }
    }

    @discardableResult
    func complete(_ result: RecorderFinalisationResult) -> Bool {
        let accepted = lock.withLock {
            guard resultStorage == nil else { return false }
            resultStorage = result
            completionCountStorage += 1
            return true
        }
        if accepted { completion.leave() }
        return accepted
    }

    public func wait(timeout: TimeInterval) -> RecorderFinalisationResult {
        guard completion.wait(timeout: .now() + max(0, timeout)) == .success else {
            return .writerTimedOut
        }
        return lock.withLock { resultStorage ?? .writerTimedOut }
    }

    var completionCount: Int { lock.withLock { completionCountStorage } }
}

/// Recorder owners detached from one graph publication.
///
/// The graph reclaimer signals safety and returns. It never joins a writer.
/// This owner wakes every writer before joining the first, so one stuck file
/// cannot leave the other stems running after their producer is already gone.
final class RecorderRetirementOwner: @unchecked Sendable {
    typealias Tail = @Sendable (Int) -> Void

    private let safetyLock = NSLock()
    private let safetyGate = DispatchSemaphore(value: 0)
    private var didBecomeSafe = false
    private var primingFrames = 0
    private let tail: Tail
    private let finishWriters: @Sendable (DispatchTime) -> Bool

    init(recorders: [Recorder], tail: @escaping Tail = { _ in }) {
        precondition(!recorders.isEmpty)
        self.tail = tail
        finishWriters = { deadline in
            for recorder in recorders { recorder.requestStop() }
            var everyWriterStopped = true
            for recorder in recorders {
                everyWriterStopped =
                    recorder.joinWriter(until: deadline) && everyWriterStopped
            }
            return everyWriterStopped
        }
    }

    /// Fault-injected writer boundary without opening an audio file.
    init(finaliseForTesting: @escaping @Sendable (DispatchTime) -> Bool) {
        tail = { _ in }
        finishWriters = finaliseForTesting
    }

    /// Crosses the callback fence exactly once.
    func makeSafe(primingFrames: Int = 0) {
        let shouldSignal = safetyLock.withLock {
            guard !didBecomeSafe else { return false }
            didBecomeSafe = true
            self.primingFrames = max(0, primingFrames)
            return true
        }
        if shouldSignal { safetyGate.signal() }
    }

    /// Runs only on the sole finalisation lane.
    func finalise(writerTimeout: TimeInterval) -> RecorderFinalisationResult {
        safetyGate.wait()
        let primingFrames = safetyLock.withLock { self.primingFrames }
        tail(primingFrames)

        let deadline = DispatchTime.now() + max(0, writerTimeout)
        return finishWriters(deadline) ? .complete : .writerTimedOut
    }
}

/// The only lane allowed to join detached recording writers.
///
/// One transaction may execute and one may wait. That exact bound covers the
/// mix and stem branches which can coexist in a route. Admission closes as
/// soon as either is handed over, so ordinary API use cannot manufacture a
/// third transaction while storage is stalled. A defensive overflow remains
/// retained for process lifetime rather than releasing a possibly live ring.
final class RecorderFinalisationWorker: @unchecked Sendable {
    struct Telemetry: Equatable, Sendable {
        let submittedOwners: UInt64
        let completedOwners: UInt64
        let timedOutOwners: UInt64
        let retainedOwners: Int
        let maximumOutstandingOwners: Int
    }

    private struct Transaction {
        let owner: RecorderRetirementOwner
        let fence: RecorderFinalisationFence
    }

    static let defaultWriterTimeout: TimeInterval = 0.5
    private static let maximumTransactions = 2

    private let lock = NSLock()
    private let worker: DispatchQueue
    private let writerTimeout: TimeInterval
    private let processQuarantine: ProcessLifetimeRecorderQuarantine
    private var pending: [Transaction] = []
    private var hasWorker = false
    private var hasActiveOwner = false
    private var retained: [RecorderRetirementOwner] = []
    private var submittedOwners: UInt64 = 0
    private var completedOwners: UInt64 = 0
    private var timedOutOwners: UInt64 = 0
    private var maximumOutstandingOwners = 0

    init(
        writerTimeout: TimeInterval = RecorderFinalisationWorker.defaultWriterTimeout,
        label: String = "com.yuhuanstudio.yunaudio.recorder-finalisation",
        processQuarantine: ProcessLifetimeRecorderQuarantine = .shared
    ) {
        self.writerTimeout = max(0, writerTimeout)
        self.processQuarantine = processQuarantine
        worker = DispatchQueue(label: label, qos: .utility)
    }

    /// Transfers ownership before returning and closes new-recorder admission.
    func submit(_ owner: RecorderRetirementOwner) -> RecorderFinalisationFence {
        let fence = RecorderFinalisationFence()
        let transaction = Transaction(owner: owner, fence: fence)
        let shouldSchedule = lock.withLock {
            submittedOwners &+= 1
            let outstanding = pending.count + (hasActiveOwner ? 1 : 0) + retained.count
            maximumOutstandingOwners = max(maximumOutstandingOwners, outstanding + 1)
            guard outstanding < Self.maximumTransactions else {
                retained.append(owner)
                processQuarantine.retain(owner)
                timedOutOwners &+= 1
                _ = fence.complete(.writerTimedOut)
                return false
            }
            pending.append(transaction)
            guard !hasWorker else { return false }
            hasWorker = true
            return true
        }
        if shouldSchedule { worker.async { [self] in drain() } }
        return fence
    }

    var acceptsConstruction: Bool {
        lock.withLock { !hasWorker && pending.isEmpty && retained.isEmpty }
    }

    var telemetry: Telemetry {
        lock.withLock {
            Telemetry(
                submittedOwners: submittedOwners,
                completedOwners: completedOwners,
                timedOutOwners: timedOutOwners,
                retainedOwners: retained.count,
                maximumOutstandingOwners: maximumOutstandingOwners)
        }
    }

    private func drain() {
        while let transaction = takeNext() {
            let result = transaction.owner.finalise(writerTimeout: writerTimeout)
            lock.withLock {
                hasActiveOwner = false
                switch result {
                case .complete:
                    completedOwners &+= 1
                case .writerTimedOut, .detachmentFailed:
                    timedOutOwners &+= 1
                    retained.append(transaction.owner)
                    processQuarantine.retain(transaction.owner)
                }
            }
            _ = transaction.fence.complete(result)
        }
    }

    private func takeNext() -> Transaction? {
        lock.withLock {
            guard !pending.isEmpty else {
                hasWorker = false
                return nil
            }
            hasActiveOwner = true
            return pending.removeFirst()
        }
    }
}
