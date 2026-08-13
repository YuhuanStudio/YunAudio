import AudioToolbox
import Foundation
import YunAudioHAL

/// One fail-closed owner for every mutation made by an incomplete echo graph.
///
/// VoiceProcessingIO may retain the private aggregate it was bound to. Disposing
/// that unit, destroying the aggregate and restoring its physical members are
/// therefore one order-dependent transaction, not three independent defers.
/// A failure retains this whole owner and its graph admission; only a complete
/// sequence lets another Audio Unit graph enter the process.
final class EchoCancellationPartialConstructionOwner: @unchecked Sendable,
    AudioUnitTeardownOwner
{
    private let lock = NSLock()
    private let mutation: AggregateRateMutationOwner
    private var cleanupDeadline: HALTeardownDeadline?
    private var unitOwner: AudioUnitResourceCapsule?
    private var admission: BoundedAudioUnitDisposer.GraphAdmission?
    private var completed = false
    private var retainedAfterCancellation = false

    init(
        mutation: AggregateRateMutationOwner,
        admission: BoundedAudioUnitDisposer.GraphAdmission
    ) {
        self.mutation = mutation
        self.admission = admission
    }

    var audioUnitCount: Int { lock.withLock { unitOwner?.audioUnitCount ?? 0 } }

    var hasTeardownWork: Bool {
        lock.withLock { !completed && (unitOwner != nil || mutation.hasPendingOwnership) }
    }

    func adopt(_ unit: AudioComponentInstance) {
        lock.withLock {
            precondition(unitOwner == nil && !completed)
            unitOwner = AudioUnitResourceCapsule(
                units: [.init(instance: unit, initialised: false)])
        }
    }

    func retainOnce(afterCancellationIn context: AudioUnitConstructionContext?) {
        guard let context else { return }
        let shouldRetain = lock.withLock { () -> Bool in
            guard !retainedAfterCancellation else { return false }
            retainedAfterCancellation = true
            return true
        }
        if shouldRetain { context.retainAfterCancellation(self) }
    }

    /// Atomically replaces graph admission with this complete partial owner.
    func handOffForDisposal(
        until deadline: HALTeardownDeadline
    ) -> AudioUnitOwnerDisposalResult {
        let admission = lock.withLock { () -> BoundedAudioUnitDisposer.GraphAdmission? in
            guard !completed, cleanupDeadline == nil else { return nil }
            cleanupDeadline = deadline
            return self.admission
        }
        guard let admission else {
            return .blockedByRetainedTransaction(retainedUnits: audioUnitCount)
        }
        let result = admission.handOffForDisposal(self, until: deadline)
        lock.withLock { self.admission = nil }
        return result
    }

    /// A fully initialised capture has taken the mutation journal and admission.
    func commit() -> BoundedAudioUnitDisposer.GraphAdmission? {
        lock.withLock {
            precondition(!completed && cleanupDeadline == nil)
            unitOwner = nil
            completed = true
            defer { admission = nil }
            return admission
        }
    }

    func tearDownAudioUnits(
        using gate: AudioUnitTeardownGate
    ) -> AudioUnitOwnerDisposalResult {
        if lock.withLock({ completed }) { return .complete(disposedUnits: 0) }

        var disposed = 0
        if let owner = lock.withLock({ unitOwner }) {
            let result = owner.tearDownAudioUnits(using: gate)
            guard result.isComplete else { return result }
            if case .complete(let count) = result { disposed += count }
            lock.withLock { unitOwner = nil }
        }

        // The Audio Unit gate deliberately stops admitting calls after a timeout.
        // Do not begin HAL cleanup in that state: it would run beside a late AU
        // call whose ownership is still uncertain.
        guard gate.admitsAnotherStep else {
            return .timedOut(step: gate.stepInFlight, disposedUnits: disposed)
        }
        guard let deadline = lock.withLock({ cleanupDeadline }),
            mutation.cleanUp(until: deadline)
        else {
            return .ownerRetained(disposedUnits: disposed)
        }
        let admission = lock.withLock { () -> BoundedAudioUnitDisposer.GraphAdmission? in
            completed = true
            defer { self.admission = nil }
            return self.admission
        }
        admission?.release()
        return .complete(disposedUnits: disposed)
    }
}
