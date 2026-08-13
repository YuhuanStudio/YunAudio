import CoreAudio
import Foundation
import YunAudioHAL

/// The sole lane allowed to ask `coreaudiod` for forensic driver state.
///
/// A diagnostic must never become a second cause of slow Stop. Core Audio does
/// not make a synchronous property read cancellable, so a timed-out read keeps
/// this worker occupied and later reads are refused until it actually returns.
/// No replacement queue or thread is created against the same congested server.
final class BoundedAudioIncidentDriverHealthLane: @unchecked Sendable {
    static let shared = BoundedAudioIncidentDriverHealthLane()

    struct Statistics: Sendable, Equatable {
        fileprivate(set) var reads: UInt64 = 0
        fileprivate(set) var refused: UInt64 = 0
        fileprivate(set) var timedOut: UInt64 = 0
        fileprivate(set) var expiredBeforeEntry: UInt64 = 0
        fileprivate(set) var maximumConcurrent = 0
    }

    typealias Read =
        @Sendable (
            AudioObjectID?, Bool, HALTeardownDeadline
        ) -> AudioIncidentDriverHealth

    private final class Transaction: @unchecked Sendable {
        private let lock = NSLock()
        private let completion = DispatchGroup()
        private var result: AudioIncidentDriverHealth?
        private var terminal = false

        init() { completion.enter() }

        func complete(_ value: AudioIncidentDriverHealth) {
            let signals = lock.withLock {
                guard !terminal else { return false }
                terminal = true
                result = value
                return true
            }
            if signals { completion.leave() }
        }

        func timeOut() {
            let signals = lock.withLock {
                guard !terminal else { return false }
                terminal = true
                return true
            }
            if signals { completion.leave() }
        }

        func wait(timeout: TimeInterval) -> AudioIncidentDriverHealth? {
            guard completion.wait(timeout: .now() + max(0, timeout)) == .success
            else { return nil }
            return lock.withLock { result }
        }
    }

    private let lock = NSLock()
    private let worker: DispatchQueue
    private let readOperation: Read
    private var active: Transaction?
    private var statisticsStorage = Statistics()

    init(
        label: String = "com.yuhuanstudio.yunaudio.incident-driver-health",
        workerQueue: DispatchQueue? = nil,
        read: @escaping Read = AudioIncidentDriverHealthReader.read
    ) {
        worker = workerQueue ?? DispatchQueue(label: label, qos: .utility)
        readOperation = read
    }

    var statistics: Statistics { lock.withLock { statisticsStorage } }

    func read(
        deviceID: AudioObjectID?,
        wasRequired: Bool,
        timeout: TimeInterval
    ) -> AudioIncidentDriverHealth {
        guard timeout.isFinite, timeout > 0 else {
            lock.withLock { statisticsStorage.refused &+= 1 }
            return Self.unavailable(wasRequired: wasRequired)
        }
        let transaction = Transaction()
        let admitted = lock.withLock {
            guard active == nil else {
                statisticsStorage.refused &+= 1
                return false
            }
            active = transaction
            statisticsStorage.reads &+= 1
            statisticsStorage.maximumConcurrent = max(
                statisticsStorage.maximumConcurrent, 1)
            return true
        }
        guard admitted else { return Self.unavailable(wasRequired: wasRequired) }

        let operation = readOperation
        // This is the caller's one budget, not a fresh allowance created when
        // a congested worker eventually dequeues the request. Starting a late
        // forensic HAL read after Stop already returned would make diagnostics
        // another source of pressure on the same system service being examined.
        let deadline = HALTeardownDeadline(timeout: timeout)
        worker.async { [self, transaction] in
            guard deadline.hasTimeRemaining else {
                lock.withLock {
                    if active === transaction {
                        active = nil
                        statisticsStorage.expiredBeforeEntry &+= 1
                    }
                }
                transaction.timeOut()
                return
            }
            let value = operation(deviceID, wasRequired, deadline)
            // The blocking call has returned before admission reopens. Clearing
            // the lane first avoids a harmless completed read looking busy to
            // the route which begins immediately after it.
            lock.withLock {
                if active === transaction { active = nil }
            }
            transaction.complete(value)
        }

        if let result = transaction.wait(timeout: timeout) { return result }
        transaction.timeOut()
        lock.withLock { statisticsStorage.timedOut &+= 1 }
        return Self.unavailable(wasRequired: wasRequired)
    }

    private static func unavailable(
        wasRequired: Bool
    ) -> AudioIncidentDriverHealth {
        AudioIncidentDriverHealth(
            state: .readFailed,
            wasRequired: wasRequired,
            readStatus: kAudioHardwareNotRunningError,
            unsafeReadOperations: 0,
            unsafeWriteOperations: 0)
    }
}
