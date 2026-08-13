/// A fixed digest used to bind probation evidence to code and saved state.
///
/// The policy deliberately does not hash bytes itself. Code-signing and state
/// serialisation belong outside the audio engine; the engine only needs an
/// immutable value which cannot be confused with a display name.
struct AudioUnitProbationDigest: Sendable, Hashable {
    let word0: UInt64
    let word1: UInt64
    let word2: UInt64
    let word3: UInt64
}

/// The executable identity covered by one session quarantine.
struct AudioUnitProbationBinaryIdentity: Sendable, Hashable {
    let componentType: UInt32
    let componentSubType: UInt32
    let componentManufacturer: UInt32
    let componentVersion: UInt32
    let codeIdentity: AudioUnitProbationDigest
}

/// The render configuration which was actually measured.
struct AudioUnitProbationConfigurationIdentity: Sendable, Hashable {
    let serialisedState: AudioUnitProbationDigest
    let sampleRateBitPattern: UInt64
    let maximumFramesPerSlice: UInt32
    let channelCount: UInt32
}

/// Code and configuration are both part of admission, while quarantine is
/// deliberately wider and covers the complete binary for the session.
struct AudioUnitProbationKey: Sendable, Hashable {
    let binary: AudioUnitProbationBinaryIdentity
    let configuration: AudioUnitProbationConfigurationIdentity
}

/// The only execution boundary from which probation evidence is accepted.
enum AudioUnitProbationExecutionBoundary: Sendable, Equatable {
    case disposableProcess
}

/// A handle owned by the parent of one disposable probation worker.
struct AudioUnitProbationWorkerHandle: Sendable, Equatable {
    let sessionIdentifier: UInt64
    let probationGeneration: UInt64
}

/// Abstract launch boundary for the future probation worker implementation.
///
/// `launchWithoutWaiting` must enqueue work in a disposable child process and
/// return after launch. It must never invoke vendor render code in this process
/// and must never wait from an audio callback. A parent hard wall terminates and
/// reaps a child which does not return; cancellation of a Swift task or thread
/// is not evidence that `AudioUnitRender` was pre-empted.
protocol DisposableProcessAudioUnitProbationRenderer: Sendable {
    func launchWithoutWaiting(
        _ request: AudioUnitProbationRequest
    ) throws -> AudioUnitProbationWorkerHandle

    func terminateAndReapAtParentHardWall(
        _ handle: AudioUnitProbationWorkerHandle
    ) -> Bool
}

/// p99.9, p99.999 and worst-case cost from one fixed render census.
struct AudioUnitProbationRenderTail: Sendable, Equatable {
    let p999Nanoseconds: UInt64
    let p99999Nanoseconds: UInt64
    let maximumNanoseconds: UInt64

    var hasValidShape: Bool {
        p999Nanoseconds <= p99999Nanoseconds
            && p99999Nanoseconds <= maximumNanoseconds
    }
}

/// Resource ownership before construction and after ordered teardown in the
/// disposable worker. Every count has to return to or below its baseline.
struct AudioUnitProbationResourceCensus: Sendable, Equatable {
    let audioUnitInstances: UInt32
    let threads: UInt32
    let fileDescriptors: UInt32
    let machPorts: UInt32
    let residentBytes: UInt64
    let inFlightRenders: UInt32
}

/// Complete numeric evidence produced by a worker which rendered and exited.
struct AudioUnitProbationEvidence: Sendable, Equatable {
    let requestedRenderCount: UInt64
    let completedRenderCount: UInt64
    let renderStatusFailures: UInt64
    let missedDeadlines: UInt64
    let allocationViolations: UInt64
    let nonFiniteOutputSamples: UInt64
    let maximumConcurrentRenders: UInt32
    let renderTail: AudioUnitProbationRenderTail
    let resourceBaseline: AudioUnitProbationResourceCensus
    let resourceFinal: AudioUnitProbationResourceCensus
}

/// The worker outcome as observed by its parent process.
///
/// There is intentionally no `timedOutInProcess` case. A never-returning vendor
/// render becomes a timeout only after the parent hard wall has terminated and
/// reaped the disposable child, so probation cannot leave a replacement beside
/// a still-running call.
enum AudioUnitProbationParentTermination: Sendable, Equatable {
    case completedAndReaped(AudioUnitProbationEvidence)
    case parentHardWallTerminatedAndReaped
    case crashedAndReaped
    case invalidReplyAndReaped
}

/// One parent-authenticated observation for the currently pending generation.
struct AudioUnitProbationParentObservation: Sendable, Equatable {
    let sessionIdentifier: UInt64
    let probationGeneration: UInt64
    let key: AudioUnitProbationKey
    let termination: AudioUnitProbationParentTermination
}

/// Immutable instructions for a disposable probation worker.
struct AudioUnitProbationRequest: Sendable, Equatable {
    let sessionIdentifier: UInt64
    let probationGeneration: UInt64
    let key: AudioUnitProbationKey
    let executionBoundary: AudioUnitProbationExecutionBoundary
    let renderCount: UInt64
    let parentHardWallNanoseconds: UInt64
    let callbackDeadlineNanoseconds: UInt64
    let hostBaselineTail: AudioUnitProbationRenderTail
}

/// An exact elapsed/deadline pair; `ratio` is presentation, not gate arithmetic.
struct AudioUnitProbationDeadlineFraction: Sendable, Equatable {
    let elapsedNanoseconds: UInt64
    let deadlineNanoseconds: UInt64

    var ratio: Double {
        Double(elapsedNanoseconds) / Double(deadlineNanoseconds)
    }
}

/// Deadline fractions retained for every measured tail rank.
struct AudioUnitProbationTailFractions: Sendable, Equatable {
    let p999: AudioUnitProbationDeadlineFraction
    let p99999: AudioUnitProbationDeadlineFraction
    let maximum: AudioUnitProbationDeadlineFraction

    init(tail: AudioUnitProbationRenderTail, deadlineNanoseconds: UInt64) {
        p999 = AudioUnitProbationDeadlineFraction(
            elapsedNanoseconds: tail.p999Nanoseconds,
            deadlineNanoseconds: deadlineNanoseconds)
        p99999 = AudioUnitProbationDeadlineFraction(
            elapsedNanoseconds: tail.p99999Nanoseconds,
            deadlineNanoseconds: deadlineNanoseconds)
        maximum = AudioUnitProbationDeadlineFraction(
            elapsedNanoseconds: tail.maximumNanoseconds,
            deadlineNanoseconds: deadlineNanoseconds)
    }
}

/// Candidate, steady-state and transition cost kept with an admitted ticket.
struct AudioUnitProbationDeadlineTelemetry: Sendable, Equatable {
    let candidate: AudioUnitProbationTailFractions
    let projectedSteady: AudioUnitProbationTailFractions
    let projectedCrossfade: AudioUnitProbationTailFractions
}

/// Proof that one exact binary and configuration may enter a live canary.
struct AudioUnitProbationTicket: Sendable, Equatable {
    let sessionIdentifier: UInt64
    let probationGeneration: UInt64
    let key: AudioUnitProbationKey
    let renderCount: UInt64
    let callbackDeadlineNanoseconds: UInt64
    let candidateTail: AudioUnitProbationRenderTail
    let projectedSteadyTail: AudioUnitProbationRenderTail
    let projectedCrossfadeTail: AudioUnitProbationRenderTail
    let deadlineFractions: AudioUnitProbationDeadlineTelemetry
    let allocationViolations: UInt64
    let resourceBaseline: AudioUnitProbationResourceCensus
    let resourceFinal: AudioUnitProbationResourceCensus
    let residentGrowthBytes: UInt64
}

enum AudioUnitProbationStartRefusal: Sendable, Equatable {
    case candidateAlreadyPending
    case binaryQuarantinedForSession
    case liveAudioHostCompromised
    case quarantineCapacityClosedSession
    case generationExhausted
    case invalidDeadline
    case invalidHostBaseline
}

enum AudioUnitProbationStartResult: Sendable, Equatable {
    case request(AudioUnitProbationRequest)
    case refused(AudioUnitProbationStartRefusal)
}

enum AudioUnitProbationRejection: Sendable, Equatable {
    case parentHardWall
    case workerCrash
    case invalidWorkerReply
    case insufficientRenderCensus
    case incompleteRenderCensus
    case renderStatusFailure
    case deadlineMiss
    case allocationViolation
    case nonFiniteOutput
    case concurrentRender
    case invalidRenderTail
    case candidateP999ExceedsQuarterDeadline
    case candidateP99999ExceedsHalfDeadline
    case candidateMaximumExceedsDeadline
    case projectedSteadyP999ExceedsQuarterDeadline
    case projectedSteadyP99999ExceedsHalfDeadline
    case projectedSteadyMaximumExceedsDeadline
    case projectedCrossfadeP999ExceedsQuarterDeadline
    case projectedCrossfadeP99999ExceedsHalfDeadline
    case projectedCrossfadeMaximumExceedsDeadline
    case nonQuiescentResourceCensus
    case audioUnitLeak
    case threadLeak
    case fileDescriptorLeak
    case machPortLeak
    case residentGrowthExceeded
    case arithmeticOverflow
}

enum AudioUnitProbationObservationResult: Sendable, Equatable {
    case admitted(AudioUnitProbationTicket)
    case rejected(AudioUnitProbationRejection)
    case ignoredStaleGeneration
}

/// A live graph carrying one candidate and its last known safe predecessor.
struct AudioUnitLiveProbationCandidate: Sendable, Equatable {
    let key: AudioUnitProbationKey
    let probationGeneration: UInt64
    let candidateGraphGeneration: UInt64
    let lastKnownSafeGraphGeneration: UInt64
    let callbackDeadlineNanoseconds: UInt64
}

enum AudioUnitLiveActivationRefusal: Sendable, Equatable {
    case ticketRevoked
    case liveCandidateAlreadyActive
    case invalidGraphGenerations
    case lastKnownSafeMismatch
    case candidateGenerationNotNewerThanSafe
    case liveAudioHostCompromised
}

enum AudioUnitLiveActivationResult: Sendable, Equatable {
    case activated(AudioUnitLiveProbationCandidate)
    case refused(AudioUnitLiveActivationRefusal)
}

/// Quantified evidence for a live canary whose vendor render calls returned.
struct AudioUnitReturnedLiveCanaryEvidence: Sendable, Equatable {
    let key: AudioUnitProbationKey
    let probationGeneration: UInt64
    let graphGeneration: UInt64
    let returnedRenderCount: UInt64
    let renderStatusFailures: UInt64
    let missedDeadlines: UInt64
    let allocationViolations: UInt64
    let nonFiniteOutputSamples: UInt64
    let callbackTail: AudioUnitProbationRenderTail
}

enum AudioUnitReturnedLiveCanaryRejection: Sendable, Equatable {
    case noReturnedRender
    case renderStatusFailure
    case deadlineMiss
    case allocationViolation
    case nonFiniteOutput
    case invalidCallbackTail
    case callbackP999ExceedsQuarterDeadline
    case callbackP99999ExceedsHalfDeadline
    case callbackMaximumExceedsDeadline
}

/// The candidate generation which clean returned evidence promoted to safe.
struct AudioUnitPromotedSafeGraph: Sendable, Equatable {
    let key: AudioUnitProbationKey
    let probationGeneration: UInt64
    let graphGeneration: UInt64
    let returnedRenderCount: UInt64
    let callbackTail: AudioUnitProbationRenderTail
}

enum AudioUnitReturnedLiveCanaryConfirmationResult: Sendable, Equatable {
    case promoted(AudioUnitPromotedSafeGraph)
    case rejected(AudioUnitReturnedLiveCanaryRejection)
    case ignoredStaleIdentity
}

/// Fault evidence which arrived only after the vendor render call returned.
enum AudioUnitReturnedLiveFault: Sendable, Equatable {
    case renderStatus(Int32)
    case deadlineMiss(elapsedNanoseconds: UInt64, deadlineNanoseconds: UInt64)
    case allocationViolation(count: UInt64)
    case nonFiniteOutput(count: UInt64)
    case tailBudgetExceeded(AudioUnitProbationRenderTail)
}

/// A rollback directive is bounded only because the vendor call has returned.
struct AudioUnitReturnedFaultRollbackDirective: Sendable, Equatable {
    let key: AudioUnitProbationKey
    let revokedCandidateGraphGeneration: UInt64
    let lastKnownSafeGraphGeneration: UInt64
    let maximumPublicationCycles: UInt8
    let fault: AudioUnitReturnedLiveFault
}

enum AudioUnitReturnedLiveFaultResolution: Sendable, Equatable {
    case rollback(AudioUnitReturnedFaultRollbackDirective)
    case ignoredStaleGraphGeneration
}

/// The only honest recovery boundary after an in-process vendor render wedges.
enum AudioUnitInProcessRenderHangContainment: Sendable, Equatable {
    case restartAudioHostBeforeUsingLastKnownSafeGraph
}

/// A same-process non-return has no cycle deadline because the callback itself
/// cannot progress. This type deliberately has no `maximumPublicationCycles`.
struct AudioUnitInProcessRenderHangDirective: Sendable, Equatable {
    let key: AudioUnitProbationKey
    let wedgedGraphGeneration: UInt64
    let lastKnownSafeGraphGeneration: UInt64
    let containment: AudioUnitInProcessRenderHangContainment
}

enum AudioUnitInProcessRenderHangResolution: Sendable, Equatable {
    case hostCompromised(AudioUnitInProcessRenderHangDirective)
    case ignoredStaleGraphGeneration
}

/// Bounded counters which expose policy decisions without logging on the IO thread.
struct AudioUnitProbationTelemetry: Sendable, Equatable {
    fileprivate(set) var requestsStarted: UInt64 = 0
    fileprivate(set) var candidatesAdmitted: UInt64 = 0
    fileprivate(set) var candidatesRejected: UInt64 = 0
    fileprivate(set) var parentHardWallTimeouts: UInt64 = 0
    fileprivate(set) var workerCrashes: UInt64 = 0
    fileprivate(set) var staleObservations: UInt64 = 0
    fileprivate(set) var quarantinedBinaryCount: UInt64 = 0
    fileprivate(set) var probationGenerationRevocations: UInt64 = 0
    fileprivate(set) var liveGraphGenerationRevocations: UInt64 = 0
    fileprivate(set) var returningLiveFaults: UInt64 = 0
    fileprivate(set) var boundedRollbackDirectives: UInt64 = 0
    fileprivate(set) var inProcessRenderNonReturns: UInt64 = 0
    fileprivate(set) var liveCanariesPromoted: UInt64 = 0
    fileprivate(set) var liveCanaryConfirmationRejections: UInt64 = 0
    fileprivate(set) var staleLiveCanaryConfirmations: UInt64 = 0
}

/// Pure policy for disposable-process admission and live-canary revocation.
///
/// This value never executes an Audio Unit. A control-plane owner feeds it only
/// parent-observed worker outcomes and returned live telemetry. It therefore
/// cannot accidentally turn a probation render into work on the realtime path.
struct AudioUnitProbationSession: Sendable {
    static let requiredRenderCount: UInt64 = 100_000
    static let parentHardWallNanoseconds: UInt64 = 300_000_000_000
    static let maximumCallbackDeadlineNanoseconds: UInt64 = 1_000_000_000
    static let maximumResidentGrowthBytes: UInt64 = 1_048_576
    static let maximumQuarantinedBinaries = 64
    static let maximumReturningFaultRollbackCycles: UInt8 = 2

    private struct Pending: Sendable {
        let request: AudioUnitProbationRequest
    }

    let sessionIdentifier: UInt64
    private var latestProbationGeneration: UInt64 = 0
    private var pending: Pending?
    private var admittedTicket: AudioUnitProbationTicket?
    private var activeLiveCandidate: AudioUnitLiveProbationCandidate?
    private var quarantinedBinaries: Set<AudioUnitProbationBinaryIdentity> = []
    private(set) var promotedSafeGraphGeneration: UInt64?
    private(set) var liveAudioHostCompromised = false
    private(set) var quarantineCapacityClosedSession = false
    private(set) var telemetry = AudioUnitProbationTelemetry()

    init(sessionIdentifier: UInt64) {
        self.sessionIdentifier = sessionIdentifier
    }

    var quarantinedBinaryCount: Int { quarantinedBinaries.count }

    var hasPendingCandidate: Bool { pending != nil }

    var hasAdmittedTicket: Bool { admittedTicket != nil }

    var activeCandidate: AudioUnitLiveProbationCandidate? { activeLiveCandidate }

    func isQuarantined(_ binary: AudioUnitProbationBinaryIdentity) -> Bool {
        quarantinedBinaries.contains(binary)
    }

    /// Creates evidence instructions; it neither launches nor renders a plugin.
    mutating func begin(
        key: AudioUnitProbationKey,
        callbackDeadlineNanoseconds: UInt64,
        hostBaselineTail: AudioUnitProbationRenderTail
    ) -> AudioUnitProbationStartResult {
        guard !liveAudioHostCompromised else {
            return .refused(.liveAudioHostCompromised)
        }
        guard !quarantineCapacityClosedSession else {
            return .refused(.quarantineCapacityClosedSession)
        }
        guard pending == nil else { return .refused(.candidateAlreadyPending) }
        guard !quarantinedBinaries.contains(key.binary) else {
            return .refused(.binaryQuarantinedForSession)
        }
        guard callbackDeadlineNanoseconds > 0,
            callbackDeadlineNanoseconds <= Self.maximumCallbackDeadlineNanoseconds
        else { return .refused(.invalidDeadline) }
        guard hostBaselineTail.hasValidShape,
            Self.meetsRealtimeTailBudget(
                hostBaselineTail, deadlineNanoseconds: callbackDeadlineNanoseconds)
        else { return .refused(.invalidHostBaseline) }

        let (nextGeneration, overflowed) = latestProbationGeneration.addingReportingOverflow(1)
        guard !overflowed else {
            quarantineCapacityClosedSession = true
            return .refused(.generationExhausted)
        }
        if admittedTicket != nil {
            admittedTicket = nil
            incrementSaturating(&telemetry.probationGenerationRevocations)
        }
        latestProbationGeneration = nextGeneration
        let request = AudioUnitProbationRequest(
            sessionIdentifier: sessionIdentifier,
            probationGeneration: nextGeneration,
            key: key,
            executionBoundary: .disposableProcess,
            renderCount: Self.requiredRenderCount,
            parentHardWallNanoseconds: Self.parentHardWallNanoseconds,
            callbackDeadlineNanoseconds: callbackDeadlineNanoseconds,
            hostBaselineTail: hostBaselineTail)
        pending = Pending(request: request)
        incrementSaturating(&telemetry.requestsStarted)
        return .request(request)
    }

    /// Consumes only an exact parent observation for the pending generation.
    mutating func observeParentResult(
        _ observation: AudioUnitProbationParentObservation
    ) -> AudioUnitProbationObservationResult {
        guard let pending,
            observation.sessionIdentifier == pending.request.sessionIdentifier,
            observation.probationGeneration == pending.request.probationGeneration
        else {
            incrementSaturating(&telemetry.staleObservations)
            return .ignoredStaleGeneration
        }
        guard observation.key == pending.request.key else {
            return rejectPending(.invalidWorkerReply)
        }

        switch observation.termination {
        case .parentHardWallTerminatedAndReaped:
            incrementSaturating(&telemetry.parentHardWallTimeouts)
            return rejectPending(.parentHardWall)
        case .crashedAndReaped:
            incrementSaturating(&telemetry.workerCrashes)
            return rejectPending(.workerCrash)
        case .invalidReplyAndReaped:
            return rejectPending(.invalidWorkerReply)
        case .completedAndReaped(let evidence):
            if let rejection = Self.rejection(request: pending.request, evidence: evidence) {
                return rejectPending(rejection)
            }
            guard
                let ticket = Self.admittedTicket(
                    request: pending.request, evidence: evidence)
            else {
                return rejectPending(.arithmeticOverflow)
            }
            self.pending = nil
            admittedTicket = ticket
            incrementSaturating(&telemetry.candidatesAdmitted)
            return .admitted(ticket)
        }
    }

    /// Consumes the exact probation ticket for one live canary graph.
    mutating func activateLiveCandidate(
        ticket: AudioUnitProbationTicket,
        candidateGraphGeneration: UInt64,
        lastKnownSafeGraphGeneration: UInt64
    ) -> AudioUnitLiveActivationResult {
        guard !liveAudioHostCompromised else {
            return .refused(.liveAudioHostCompromised)
        }
        guard activeLiveCandidate == nil else {
            return .refused(.liveCandidateAlreadyActive)
        }
        guard candidateGraphGeneration > 0, lastKnownSafeGraphGeneration > 0
        else { return .refused(.invalidGraphGenerations) }
        if let promotedSafeGraphGeneration,
            lastKnownSafeGraphGeneration != promotedSafeGraphGeneration
        {
            return .refused(.lastKnownSafeMismatch)
        }
        guard candidateGraphGeneration > lastKnownSafeGraphGeneration else {
            return .refused(.candidateGenerationNotNewerThanSafe)
        }
        guard admittedTicket == ticket else { return .refused(.ticketRevoked) }

        let candidate = AudioUnitLiveProbationCandidate(
            key: ticket.key,
            probationGeneration: ticket.probationGeneration,
            candidateGraphGeneration: candidateGraphGeneration,
            lastKnownSafeGraphGeneration: lastKnownSafeGraphGeneration,
            callbackDeadlineNanoseconds: ticket.callbackDeadlineNanoseconds)
        admittedTicket = nil
        activeLiveCandidate = candidate
        return .activated(candidate)
    }

    /// Promotes only exact, clean evidence from vendor calls which returned.
    ///
    /// The control plane chooses the canary census; this policy invents no live
    /// cycle count. Rejected evidence leaves the candidate active so its owner
    /// can classify the returned fault and use the separate rollback boundary.
    mutating func confirmReturnedLiveCanary(
        _ evidence: AudioUnitReturnedLiveCanaryEvidence
    ) -> AudioUnitReturnedLiveCanaryConfirmationResult {
        guard let candidate = activeLiveCandidate,
            candidate.key == evidence.key,
            candidate.probationGeneration == evidence.probationGeneration,
            candidate.candidateGraphGeneration == evidence.graphGeneration
        else {
            incrementSaturating(&telemetry.staleLiveCanaryConfirmations)
            return .ignoredStaleIdentity
        }

        let rejection: AudioUnitReturnedLiveCanaryRejection?
        if evidence.returnedRenderCount == 0 {
            rejection = .noReturnedRender
        } else if evidence.renderStatusFailures > 0 {
            rejection = .renderStatusFailure
        } else if evidence.missedDeadlines > 0 {
            rejection = .deadlineMiss
        } else if evidence.allocationViolations > 0 {
            rejection = .allocationViolation
        } else if evidence.nonFiniteOutputSamples > 0 {
            rejection = .nonFiniteOutput
        } else if !evidence.callbackTail.hasValidShape {
            rejection = .invalidCallbackTail
        } else if evidence.callbackTail.p999Nanoseconds
            > candidate.callbackDeadlineNanoseconds / 4
        {
            rejection = .callbackP999ExceedsQuarterDeadline
        } else if evidence.callbackTail.p99999Nanoseconds
            > candidate.callbackDeadlineNanoseconds / 2
        {
            rejection = .callbackP99999ExceedsHalfDeadline
        } else if evidence.callbackTail.maximumNanoseconds
            > candidate.callbackDeadlineNanoseconds
        {
            rejection = .callbackMaximumExceedsDeadline
        } else {
            rejection = nil
        }
        if let rejection {
            incrementSaturating(&telemetry.liveCanaryConfirmationRejections)
            return .rejected(rejection)
        }

        activeLiveCandidate = nil
        promotedSafeGraphGeneration = candidate.candidateGraphGeneration
        incrementSaturating(&telemetry.liveCanariesPromoted)
        return .promoted(
            AudioUnitPromotedSafeGraph(
                key: candidate.key,
                probationGeneration: candidate.probationGeneration,
                graphGeneration: candidate.candidateGraphGeneration,
                returnedRenderCount: evidence.returnedRenderCount,
                callbackTail: evidence.callbackTail))
    }

    /// Revokes a candidate within two publication cycles only after render returned.
    mutating func handleReturnedLiveFault(
        graphGeneration: UInt64,
        fault: AudioUnitReturnedLiveFault
    ) -> AudioUnitReturnedLiveFaultResolution {
        guard let candidate = activeLiveCandidate,
            candidate.candidateGraphGeneration == graphGeneration
        else {
            return .ignoredStaleGraphGeneration
        }

        activeLiveCandidate = nil
        quarantine(candidate.key.binary)
        incrementSaturating(&telemetry.returningLiveFaults)
        incrementSaturating(&telemetry.liveGraphGenerationRevocations)
        incrementSaturating(&telemetry.boundedRollbackDirectives)
        return .rollback(
            AudioUnitReturnedFaultRollbackDirective(
                key: candidate.key,
                revokedCandidateGraphGeneration: candidate.candidateGraphGeneration,
                lastKnownSafeGraphGeneration: candidate.lastKnownSafeGraphGeneration,
                maximumPublicationCycles: Self.maximumReturningFaultRollbackCycles,
                fault: fault))
    }

    /// Records a same-process render which has not returned.
    ///
    /// No replacement graph can run on that callback lane, so this closes live
    /// admission and reports process containment rather than a fictional cycle
    /// bound. The safe graph becomes usable only after the audio host restarts
    /// or the vendor call independently returns. A future out-of-process live
    /// Audio Unit host is the boundary which can make that restart selective.
    mutating func handleInProcessRenderDidNotReturn(
        graphGeneration: UInt64
    ) -> AudioUnitInProcessRenderHangResolution {
        guard let candidate = activeLiveCandidate,
            candidate.candidateGraphGeneration == graphGeneration
        else {
            return .ignoredStaleGraphGeneration
        }

        activeLiveCandidate = nil
        liveAudioHostCompromised = true
        quarantine(candidate.key.binary)
        incrementSaturating(&telemetry.inProcessRenderNonReturns)
        incrementSaturating(&telemetry.liveGraphGenerationRevocations)
        return .hostCompromised(
            AudioUnitInProcessRenderHangDirective(
                key: candidate.key,
                wedgedGraphGeneration: candidate.candidateGraphGeneration,
                lastKnownSafeGraphGeneration: candidate.lastKnownSafeGraphGeneration,
                containment: .restartAudioHostBeforeUsingLastKnownSafeGraph))
    }

    private mutating func rejectPending(
        _ reason: AudioUnitProbationRejection
    ) -> AudioUnitProbationObservationResult {
        guard let rejected = pending else { return .ignoredStaleGeneration }
        pending = nil
        admittedTicket = nil
        quarantine(rejected.request.key.binary)
        incrementSaturating(&telemetry.candidatesRejected)
        incrementSaturating(&telemetry.probationGenerationRevocations)
        return .rejected(reason)
    }

    private mutating func quarantine(_ binary: AudioUnitProbationBinaryIdentity) {
        guard quarantinedBinaries.insert(binary).inserted else { return }
        telemetry.quarantinedBinaryCount = UInt64(quarantinedBinaries.count)
        if quarantinedBinaries.count >= Self.maximumQuarantinedBinaries {
            quarantineCapacityClosedSession = true
        }
    }

    private static func admittedTicket(
        request: AudioUnitProbationRequest,
        evidence: AudioUnitProbationEvidence
    ) -> AudioUnitProbationTicket? {
        guard
            let steady = projectedTail(
                host: request.hostBaselineTail, candidate: evidence.renderTail,
                candidateMultiplicity: 1),
            let crossfade = projectedTail(
                host: request.hostBaselineTail, candidate: evidence.renderTail,
                candidateMultiplicity: 2)
        else { return nil }

        let growth =
            evidence.resourceFinal.residentBytes
                > evidence.resourceBaseline.residentBytes
            ? evidence.resourceFinal.residentBytes - evidence.resourceBaseline.residentBytes
            : 0
        let deadline = request.callbackDeadlineNanoseconds
        return AudioUnitProbationTicket(
            sessionIdentifier: request.sessionIdentifier,
            probationGeneration: request.probationGeneration,
            key: request.key,
            renderCount: evidence.completedRenderCount,
            callbackDeadlineNanoseconds: deadline,
            candidateTail: evidence.renderTail,
            projectedSteadyTail: steady,
            projectedCrossfadeTail: crossfade,
            deadlineFractions: AudioUnitProbationDeadlineTelemetry(
                candidate: AudioUnitProbationTailFractions(
                    tail: evidence.renderTail, deadlineNanoseconds: deadline),
                projectedSteady: AudioUnitProbationTailFractions(
                    tail: steady, deadlineNanoseconds: deadline),
                projectedCrossfade: AudioUnitProbationTailFractions(
                    tail: crossfade, deadlineNanoseconds: deadline)),
            allocationViolations: evidence.allocationViolations,
            resourceBaseline: evidence.resourceBaseline,
            resourceFinal: evidence.resourceFinal,
            residentGrowthBytes: growth)
    }

    private static func rejection(
        request: AudioUnitProbationRequest,
        evidence: AudioUnitProbationEvidence
    ) -> AudioUnitProbationRejection? {
        guard evidence.requestedRenderCount >= requiredRenderCount else {
            return .insufficientRenderCensus
        }
        guard evidence.requestedRenderCount == request.renderCount,
            evidence.completedRenderCount == evidence.requestedRenderCount
        else { return .incompleteRenderCensus }
        guard evidence.renderStatusFailures == 0 else { return .renderStatusFailure }
        guard evidence.missedDeadlines == 0 else { return .deadlineMiss }
        guard evidence.allocationViolations == 0 else { return .allocationViolation }
        guard evidence.nonFiniteOutputSamples == 0 else { return .nonFiniteOutput }
        guard evidence.maximumConcurrentRenders == 1 else { return .concurrentRender }
        guard evidence.renderTail.hasValidShape else { return .invalidRenderTail }

        let deadline = request.callbackDeadlineNanoseconds
        guard
            let steady = projectedTail(
                host: request.hostBaselineTail, candidate: evidence.renderTail,
                candidateMultiplicity: 1),
            let crossfade = projectedTail(
                host: request.hostBaselineTail, candidate: evidence.renderTail,
                candidateMultiplicity: 2)
        else { return .arithmeticOverflow }
        guard evidence.renderTail.p999Nanoseconds <= deadline / 4 else {
            return .candidateP999ExceedsQuarterDeadline
        }
        guard evidence.renderTail.p99999Nanoseconds <= deadline / 2 else {
            return .candidateP99999ExceedsHalfDeadline
        }
        guard evidence.renderTail.maximumNanoseconds <= deadline else {
            return .candidateMaximumExceedsDeadline
        }
        guard steady.p999Nanoseconds <= deadline / 4 else {
            return .projectedSteadyP999ExceedsQuarterDeadline
        }
        guard steady.p99999Nanoseconds <= deadline / 2 else {
            return .projectedSteadyP99999ExceedsHalfDeadline
        }
        guard steady.maximumNanoseconds <= deadline else {
            return .projectedSteadyMaximumExceedsDeadline
        }
        guard crossfade.p999Nanoseconds <= deadline / 4 else {
            return .projectedCrossfadeP999ExceedsQuarterDeadline
        }
        guard crossfade.p99999Nanoseconds <= deadline / 2 else {
            return .projectedCrossfadeP99999ExceedsHalfDeadline
        }
        guard crossfade.maximumNanoseconds <= deadline else {
            return .projectedCrossfadeMaximumExceedsDeadline
        }

        let baseline = evidence.resourceBaseline
        let final = evidence.resourceFinal
        guard baseline.inFlightRenders == 0, final.inFlightRenders == 0 else {
            return .nonQuiescentResourceCensus
        }
        guard final.audioUnitInstances <= baseline.audioUnitInstances else {
            return .audioUnitLeak
        }
        guard final.threads <= baseline.threads else { return .threadLeak }
        guard final.fileDescriptors <= baseline.fileDescriptors else {
            return .fileDescriptorLeak
        }
        guard final.machPorts <= baseline.machPorts else { return .machPortLeak }
        if final.residentBytes > baseline.residentBytes,
            final.residentBytes - baseline.residentBytes > maximumResidentGrowthBytes
        {
            return .residentGrowthExceeded
        }
        return nil
    }

    private static func projectedTail(
        host: AudioUnitProbationRenderTail,
        candidate: AudioUnitProbationRenderTail,
        candidateMultiplicity: UInt64
    ) -> AudioUnitProbationRenderTail? {
        func projected(_ hostValue: UInt64, _ candidateValue: UInt64) -> UInt64? {
            let (candidateCost, multiplied) = candidateValue.multipliedReportingOverflow(
                by: candidateMultiplicity)
            guard !multiplied else { return nil }
            let (total, added) = hostValue.addingReportingOverflow(candidateCost)
            return added ? nil : total
        }

        guard let p999 = projected(host.p999Nanoseconds, candidate.p999Nanoseconds),
            let p99999 = projected(host.p99999Nanoseconds, candidate.p99999Nanoseconds),
            let maximum = projected(host.maximumNanoseconds, candidate.maximumNanoseconds)
        else { return nil }
        return AudioUnitProbationRenderTail(
            p999Nanoseconds: p999,
            p99999Nanoseconds: p99999,
            maximumNanoseconds: maximum)
    }

    private static func meetsRealtimeTailBudget(
        _ tail: AudioUnitProbationRenderTail,
        deadlineNanoseconds: UInt64
    ) -> Bool {
        tail.p999Nanoseconds <= deadlineNanoseconds / 4
            && tail.p99999Nanoseconds <= deadlineNanoseconds / 2
            && tail.maximumNanoseconds <= deadlineNanoseconds
    }
}

private func incrementSaturating(_ value: inout UInt64) {
    if value < .max { value += 1 }
}
