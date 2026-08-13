import AudioToolbox
import Foundation
import YunAudioHAL

/// Operations owned by one detached VoiceProcessingIO capture.
///
/// The closures close over raw callback storage deliberately. The detached
/// owner is the only object allowed to release that storage, and only after the
/// Audio Unit, its private aggregate and every changed device rate reached the
/// terminal state in that exact order.
struct EchoCancellationCaptureTeardownOperations {
    let stop: () -> OSStatus
    let uninitialise: () -> OSStatus
    let dispose: () -> OSStatus
    let clearCallbackBindings: () -> Void
    let destroyAggregate: (HALTeardownDeadline) -> HALDestructionResult
    let restoreSampleRates: (HALTeardownDeadline) -> [String]
    let releaseStorage: () -> Void
}

/// A callback-transitive VoiceProcessingIO owner detached before teardown.
///
/// This owner is intentionally independent of `EchoCancellingCapture`. It can
/// cross the sole lifecycle worker from an ordinary Stop and from `deinit`
/// without attempting to resurrect an object whose reference count reached
/// zero. A failed or timed-out transaction retains this object for the rest of
/// the process, which also retains every pointer captured by its operations.
final class EchoCancellationCaptureTeardownOwner: @unchecked Sendable,
    AudioUnitTeardownOwner
{
    private let lock = NSLock()
    private var state: AudioUnitTeardownState
    private let deadline: HALTeardownDeadline
    private let operations: EchoCancellationCaptureTeardownOperations
    private var result: EchoCancellationTeardownResult?
    private var storageMayBeReleased = false

    init(
        state: AudioUnitTeardownState,
        deadline: HALTeardownDeadline,
        operations: EchoCancellationCaptureTeardownOperations
    ) {
        self.state = state
        self.deadline = deadline
        self.operations = operations
    }

    var audioUnitCount: Int {
        lock.withLock { state.phase == .disposed ? 0 : 1 }
    }

    var teardownResult: EchoCancellationTeardownResult? {
        lock.withLock { result }
    }

    func tearDownAudioUnits(
        using gate: AudioUnitTeardownGate
    ) -> AudioUnitOwnerDisposalResult {
        if let existing = lock.withLock({ result }) {
            return existing.isComplete
                ? .complete(disposedUnits: 0)
                : .ownerRetained(disposedUnits: 0)
        }
        let wasDisposed = lock.withLock { state.phase == .disposed }
        let unitResult = lock.withLock {
            state.tearDown(
                stop: {
                    gate.perform(.stop, operation: operations.stop)
                },
                uninitialise: {
                    gate.perform(.uninitialise, operation: operations.uninitialise)
                },
                dispose: {
                    gate.perform(.dispose, operation: operations.dispose)
                })
        }
        let disposedUnits =
            !wasDisposed && lock.withLock { state.phase == .disposed } ? 1 : 0

        guard unitResult.isComplete else {
            lock.withLock { result = unitResult }
            switch unitResult {
            case .audioUnit(let step, let status):
                return .operationFailed(
                    step: step, status: status, disposedUnits: disposedUnits)
            case .audioUnitTimedOut(let step):
                return .timedOut(step: step, disposedUnits: disposedUnits)
            case .complete, .aggregate, .sampleRatesNotRestored,
                .lifecycleTimedOut:
                preconditionFailure("the Audio Unit sequence returned a non-unit result")
            }
        }

        // Clearing the raw callback bindings before Stop has returned would
        // hand a possible late callback dangling closure/context pointers.
        operations.clearCallbackBindings()

        let aggregateResult = operations.destroyAggregate(deadline)
        guard aggregateResult == .destroyed else {
            let detailed = EchoCancellationTeardownResult.aggregate(aggregateResult)
            lock.withLock { result = detailed }
            return .ownerRetained(disposedUnits: disposedUnits)
        }

        let stubborn = operations.restoreSampleRates(deadline).sorted()
        guard stubborn.isEmpty else {
            let detailed = EchoCancellationTeardownResult.sampleRatesNotRestored(stubborn)
            lock.withLock { result = detailed }
            return .ownerRetained(disposedUnits: disposedUnits)
        }

        lock.withLock {
            result = .complete
            storageMayBeReleased = true
        }
        return .complete(disposedUnits: disposedUnits)
    }

    deinit {
        // A failed transaction is process-owned in production. Keeping this
        // guard makes an injected or future caller fail safe even if it drops
        // its final reference by mistake.
        guard lock.withLock({ storageMayBeReleased }) else { return }
        operations.releaseStorage()
    }
}

/// The consumer and producer halves of one AEC route, as one lifecycle owner.
///
/// The VoiceProcessingIO consumer must be fenced before the far-end producer:
/// its render callback holds a raw pointer to the producer's ring. Both remain
/// in this owner when either boundary times out.
final class EchoCancellationBridgeTeardownOwner: @unchecked Sendable,
    AudioUnitTeardownOwner
{
    private let lock = NSLock()
    private let capture: EchoCancellationCaptureTeardownOwner
    private let deadline: HALTeardownDeadline
    private let stopFarEnd: (HALTeardownDeadline) -> FarEndCaptureTeardownResult?
    private let releaseStorage: () -> Void
    private var result: EchoCancellationBridgeTeardownResult?
    private var storageMayBeReleased = false

    init(
        capture: EchoCancellationCaptureTeardownOwner,
        deadline: HALTeardownDeadline,
        stopFarEnd: @escaping (HALTeardownDeadline) -> FarEndCaptureTeardownResult?,
        releaseStorage: @escaping () -> Void
    ) {
        self.capture = capture
        self.deadline = deadline
        self.stopFarEnd = stopFarEnd
        self.releaseStorage = releaseStorage
    }

    var audioUnitCount: Int {
        lock.withLock { storageMayBeReleased ? 0 : 1 }
    }

    var teardownResult: EchoCancellationBridgeTeardownResult? {
        lock.withLock { result }
    }

    func tearDownAudioUnits(
        using gate: AudioUnitTeardownGate
    ) -> AudioUnitOwnerDisposalResult {
        if let existing = lock.withLock({ result }) {
            return existing.isComplete
                ? .complete(disposedUnits: 0)
                : .ownerRetained(disposedUnits: 0)
        }
        let captureDisposal = capture.tearDownAudioUnits(using: gate)
        guard captureDisposal.isComplete else {
            let detailed = EchoCancellationBridgeTeardownResult.capture(
                capture.teardownResult ?? .lifecycleTimedOut(step: gate.stepInFlight))
            lock.withLock { result = detailed }
            return captureDisposal
        }

        if let farEndResult = stopFarEnd(deadline), !farEndResult.isComplete {
            lock.withLock { result = .farEnd(farEndResult) }
            return .ownerRetained(disposedUnits: 1)
        }

        lock.withLock {
            result = .complete
            storageMayBeReleased = true
        }
        return .complete(disposedUnits: 1)
    }

    deinit {
        guard lock.withLock({ storageMayBeReleased }) else { return }
        releaseStorage()
    }
}

/// One non-destructive Audio Unit call executed by the sole lifecycle worker.
///
/// A timeout keeps `retainedOwner` alive and consumes the worker permanently.
/// A returned OSStatus either completes normally or follows the caller's
/// explicit fail-closed policy.
final class BoundedAudioUnitLifecycleCommand: @unchecked Sendable,
    AudioUnitTeardownOwner, AudioUnitDeferredLifecycleCommand
{
    private let lock = NSLock()
    private let retainedOwner: AnyObject
    private let step: AudioUnitTeardownStep
    private let operation: () -> OSStatus
    private let quarantineOnError: Bool
    private var status: OSStatus?
    private var callerCancelled = false

    init(
        retaining owner: AnyObject,
        step: AudioUnitTeardownStep,
        quarantineOnError: Bool,
        operation: @escaping () -> OSStatus
    ) {
        retainedOwner = owner
        self.step = step
        self.quarantineOnError = quarantineOnError
        self.operation = operation
    }

    var audioUnitCount: Int { 1 }

    var completedStatus: OSStatus? { lock.withLock { status } }

    func cancelBeforeStart() {
        lock.withLock { callerCancelled = true }
    }

    func tearDownAudioUnits(
        using gate: AudioUnitTeardownGate
    ) -> AudioUnitOwnerDisposalResult {
        guard !lock.withLock({ callerCancelled }) else {
            return .timedOut(step: step, disposedUnits: 0)
        }
        let returned = gate.perform(step, operation: operation)
        lock.withLock { status = returned }
        withExtendedLifetime(retainedOwner) {}
        guard let returned else {
            return .timedOut(step: step, disposedUnits: 0)
        }
        if quarantineOnError, returned != noErr {
            // Start and Stop can change callback ownership before returning an
            // error. No public API proves that a failed status means "nothing
            // happened", so bindings remain live and the same transaction
            // stays quarantined rather than guessing and freeing them.
            return .operationFailed(step: step, status: returned, disposedUnits: 0)
        }
        // When the caller timed out, the disposer observes its transaction's
        // cancelled bit and converts this late completion back to `.timedOut`.
        return .complete(disposedUnits: 0)
    }
}

/// Starts VoiceProcessingIO and rolls an ambiguous returned error back without
/// releasing the sole worker or its quarantine between those operations.
final class EchoCancellationStartCommand: @unchecked Sendable,
    AudioUnitTeardownOwner, AudioUnitDeferredLifecycleCommand
{
    private let lock = NSLock()
    private let retainedOwner: AnyObject
    private let start: () -> OSStatus
    private let rollback: EchoCancellationCaptureTeardownOwner
    private let transferRollbackOwnership: () -> Void
    private var status: OSStatus?
    private var rollbackDisposal: AudioUnitOwnerDisposalResult?
    private var callerCancelled = false

    init(
        retaining owner: AnyObject,
        start: @escaping () -> OSStatus,
        rollback: EchoCancellationCaptureTeardownOwner,
        transferRollbackOwnership: @escaping () -> Void
    ) {
        retainedOwner = owner
        self.start = start
        self.rollback = rollback
        self.transferRollbackOwnership = transferRollbackOwnership
    }

    var audioUnitCount: Int { 1 }
    var startStatus: OSStatus? { lock.withLock { status } }
    var rollbackResult: AudioUnitOwnerDisposalResult? {
        lock.withLock { rollbackDisposal }
    }

    func cancelBeforeStart() {
        lock.withLock { callerCancelled = true }
    }

    func tearDownAudioUnits(
        using gate: AudioUnitTeardownGate
    ) -> AudioUnitOwnerDisposalResult {
        guard !lock.withLock({ callerCancelled }) else {
            return .timedOut(step: .start, disposedUnits: 0)
        }
        let returned = gate.perform(.start, operation: start)
        lock.withLock { status = returned }
        withExtendedLifetime(retainedOwner) {}
        guard let returned else {
            return .timedOut(step: .start, disposedUnits: 0)
        }
        guard returned != noErr else { return .complete(disposedUnits: 0) }

        // From this point the start status is not evidence that callbacks never
        // began. Move ownership before Stop, while this transaction still owns
        // the process quarantine and no graph admission can reopen.
        transferRollbackOwnership()
        let result = rollback.tearDownAudioUnits(using: gate)
        lock.withLock { rollbackDisposal = result }
        return result
    }
}
