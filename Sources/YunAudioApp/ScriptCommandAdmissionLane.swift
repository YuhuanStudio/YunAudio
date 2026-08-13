import Foundation

/// Admits model mutations which cannot safely run inside a JavaScript RPC turn.
///
/// Preset application writes many observed properties, while constructing the
/// KTV window enters AppKit. JavaScript waits for its native RPC reply, so doing
/// either inline couples the interpreter owner back to MainActor. This lane
/// returns a bounded queued answer and keeps only the newest intent per kind.
@MainActor
final class ScriptCommandAdmissionLane {
    enum Key: Hashable, Sendable {
        case preset
        case stage
    }

    enum Submission: Equatable, Sendable {
        case accepted
        case coalesced
        case refused
    }

    struct Statistics: Equatable, Sendable {
        var submissions: UInt64 = 0
        var applications: UInt64 = 0
        var coalesced: UInt64 = 0
        var refusals: UInt64 = 0
        var overBudgetApplications: UInt64 = 0
        var maximumApplicationNanoseconds: UInt64 = 0
        var pending = 0
        var maximumPending = 0
        var scheduledDeliveries: UInt64 = 0
    }

    typealias Operation = @MainActor @Sendable () -> Void
    typealias Scheduler = @MainActor @Sendable (@escaping Operation) -> Void

    static let maximumPendingCommands = 2
    static let maximumApplicationNanoseconds: UInt64 = 8_000_000

    private var pending: [Key: Operation] = [:]
    private var order: [Key] = []
    private var hasScheduledDelivery = false
    private let schedule: Scheduler
    private(set) var statistics = Statistics()

    init(schedule: @escaping Scheduler = { MainRunLoopDelivery.perform($0) }) {
        self.schedule = schedule
    }

    func submit(_ key: Key, operation: @escaping Operation) -> Submission {
        statistics.submissions &+= 1
        let submission: Submission
        if pending.updateValue(operation, forKey: key) != nil {
            statistics.coalesced &+= 1
            submission = .coalesced
        } else if order.count < Self.maximumPendingCommands {
            order.append(key)
            statistics.pending = order.count
            statistics.maximumPending = max(statistics.maximumPending, order.count)
            submission = .accepted
        } else {
            pending[key] = nil
            statistics.refusals &+= 1
            return .refused
        }
        scheduleIfNeeded()
        return submission
    }

    func invalidate() {
        pending = [:]
        order = []
        statistics.pending = 0
    }

    private func scheduleIfNeeded() {
        guard !hasScheduledDelivery else { return }
        hasScheduledDelivery = true
        statistics.scheduledDeliveries &+= 1
        schedule { [weak self] in self?.applyOne() }
    }

    private func applyOne() {
        guard !order.isEmpty else {
            hasScheduledDelivery = false
            return
        }
        let key = order.removeFirst()
        let operation = pending.removeValue(forKey: key)
        statistics.pending = order.count
        let began = DispatchTime.now().uptimeNanoseconds
        operation?()
        let elapsed = DispatchTime.now().uptimeNanoseconds - began
        statistics.applications &+= 1
        statistics.maximumApplicationNanoseconds = max(
            statistics.maximumApplicationNanoseconds, elapsed)
        if elapsed >= Self.maximumApplicationNanoseconds {
            statistics.overBudgetApplications &+= 1
        }
        if order.isEmpty {
            hasScheduledDelivery = false
        } else {
            statistics.scheduledDeliveries &+= 1
            schedule { [weak self] in self?.applyOne() }
        }
    }
}
