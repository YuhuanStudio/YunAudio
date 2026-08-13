import Testing

@testable import YunAudioEngine

@Suite("Audio Unit disposable-process probation")
struct AudioUnitProbationTests {
    private static let deadline: UInt64 = 1_000_000
    private static let hostTail = AudioUnitProbationRenderTail(
        p999Nanoseconds: 40_000,
        p99999Nanoseconds: 80_000,
        maximumNanoseconds: 120_000)
    private static let candidateTail = AudioUnitProbationRenderTail(
        p999Nanoseconds: 20_000,
        p99999Nanoseconds: 100_000,
        maximumNanoseconds: 200_000)
    private static let liveCallbackTail = AudioUnitProbationRenderTail(
        p999Nanoseconds: 100_000,
        p99999Nanoseconds: 300_000,
        maximumNanoseconds: 500_000)
    private static let resourceBaseline = AudioUnitProbationResourceCensus(
        audioUnitInstances: 0,
        threads: 2,
        fileDescriptors: 3,
        machPorts: 4,
        residentBytes: 100_000_000,
        inFlightRenders: 0)

    private func digest(_ value: UInt64) -> AudioUnitProbationDigest {
        AudioUnitProbationDigest(
            word0: value,
            word1: value &+ 1,
            word2: value &+ 2,
            word3: value &+ 3)
    }

    private func key(_ value: UInt64, state: UInt64? = nil) -> AudioUnitProbationKey {
        AudioUnitProbationKey(
            binary: AudioUnitProbationBinaryIdentity(
                componentType: 1,
                componentSubType: UInt32(truncatingIfNeeded: value),
                componentManufacturer: 2,
                componentVersion: 3,
                codeIdentity: digest(value)),
            configuration: AudioUnitProbationConfigurationIdentity(
                serialisedState: digest(state ?? value &+ 100),
                sampleRateBitPattern: 48_000.0.bitPattern,
                maximumFramesPerSlice: 128,
                channelCount: 2))
    }

    private func evidence(
        requestedRenderCount: UInt64 = AudioUnitProbationSession.requiredRenderCount,
        completedRenderCount: UInt64? = nil,
        renderStatusFailures: UInt64 = 0,
        missedDeadlines: UInt64 = 0,
        allocationViolations: UInt64 = 0,
        nonFiniteOutputSamples: UInt64 = 0,
        maximumConcurrentRenders: UInt32 = 1,
        renderTail: AudioUnitProbationRenderTail = Self.candidateTail,
        resourceBaseline: AudioUnitProbationResourceCensus = Self.resourceBaseline,
        resourceFinal: AudioUnitProbationResourceCensus? = nil
    ) -> AudioUnitProbationEvidence {
        AudioUnitProbationEvidence(
            requestedRenderCount: requestedRenderCount,
            completedRenderCount: completedRenderCount ?? requestedRenderCount,
            renderStatusFailures: renderStatusFailures,
            missedDeadlines: missedDeadlines,
            allocationViolations: allocationViolations,
            nonFiniteOutputSamples: nonFiniteOutputSamples,
            maximumConcurrentRenders: maximumConcurrentRenders,
            renderTail: renderTail,
            resourceBaseline: resourceBaseline,
            resourceFinal: resourceFinal ?? resourceBaseline)
    }

    private func begin(
        _ session: inout AudioUnitProbationSession,
        key: AudioUnitProbationKey,
        hostTail: AudioUnitProbationRenderTail = Self.hostTail
    ) throws -> AudioUnitProbationRequest {
        let result = session.begin(
            key: key,
            callbackDeadlineNanoseconds: Self.deadline,
            hostBaselineTail: hostTail)
        if case .request(let request) = result { return request }
        Issue.record("a valid probation request was refused: \(result)")
        return try #require(nil as AudioUnitProbationRequest?)
    }

    private func observation(
        for request: AudioUnitProbationRequest,
        termination: AudioUnitProbationParentTermination
    ) -> AudioUnitProbationParentObservation {
        AudioUnitProbationParentObservation(
            sessionIdentifier: request.sessionIdentifier,
            probationGeneration: request.probationGeneration,
            key: request.key,
            termination: termination)
    }

    private func admittedTicket(
        _ session: inout AudioUnitProbationSession,
        key: AudioUnitProbationKey,
        evidence: AudioUnitProbationEvidence? = nil
    ) throws -> AudioUnitProbationTicket {
        let request = try begin(&session, key: key)
        let result = session.observeParentResult(
            observation(
                for: request,
                termination: .completedAndReaped(evidence ?? self.evidence())))
        if case .admitted(let ticket) = result { return ticket }
        Issue.record("clean probation evidence was refused: \(result)")
        return try #require(nil as AudioUnitProbationTicket?)
    }

    private func activate(
        _ session: inout AudioUnitProbationSession,
        key: AudioUnitProbationKey,
        candidateGraphGeneration: UInt64 = 42,
        lastKnownSafeGraphGeneration: UInt64 = 41
    ) throws -> AudioUnitLiveProbationCandidate {
        let ticket = try admittedTicket(&session, key: key)
        let result = session.activateLiveCandidate(
            ticket: ticket,
            candidateGraphGeneration: candidateGraphGeneration,
            lastKnownSafeGraphGeneration: lastKnownSafeGraphGeneration)
        if case .activated(let candidate) = result { return candidate }
        Issue.record("an exact admitted ticket was not activated: \(result)")
        return try #require(nil as AudioUnitLiveProbationCandidate?)
    }

    private func liveEvidence(
        for candidate: AudioUnitLiveProbationCandidate,
        key: AudioUnitProbationKey? = nil,
        probationGeneration: UInt64? = nil,
        graphGeneration: UInt64? = nil,
        returnedRenderCount: UInt64 = 1,
        renderStatusFailures: UInt64 = 0,
        missedDeadlines: UInt64 = 0,
        allocationViolations: UInt64 = 0,
        nonFiniteOutputSamples: UInt64 = 0,
        callbackTail: AudioUnitProbationRenderTail = Self.liveCallbackTail
    ) -> AudioUnitReturnedLiveCanaryEvidence {
        AudioUnitReturnedLiveCanaryEvidence(
            key: key ?? candidate.key,
            probationGeneration: probationGeneration ?? candidate.probationGeneration,
            graphGeneration: graphGeneration ?? candidate.candidateGraphGeneration,
            returnedRenderCount: returnedRenderCount,
            renderStatusFailures: renderStatusFailures,
            missedDeadlines: missedDeadlines,
            allocationViolations: allocationViolations,
            nonFiniteOutputSamples: nonFiniteOutputSamples,
            callbackTail: callbackTail)
    }

    @Test("a 0.6-deadline candidate is refused before a live ticket exists")
    func sixtyPercentCandidateNeverReachesLive() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 7)
        let candidateKey = key(1)
        let request = try begin(&session, key: candidateKey)

        #expect(request.executionBoundary == .disposableProcess)
        #expect(request.renderCount == 100_000)
        #expect(request.parentHardWallNanoseconds == 300_000_000_000)
        let slow = evidence(
            renderTail: AudioUnitProbationRenderTail(
                p999Nanoseconds: 600_000,
                p99999Nanoseconds: 600_000,
                maximumNanoseconds: 600_000))
        let result = session.observeParentResult(
            observation(for: request, termination: .completedAndReaped(slow)))

        #expect(result == .rejected(.candidateP999ExceedsQuarterDeadline))
        #expect(!session.hasAdmittedTicket)
        #expect(session.activeCandidate == nil)
        #expect(session.isQuarantined(candidateKey.binary))
    }

    @Test("100000 completed renders are required before p99.999 can admit")
    func completeTailCensusIsRequired() throws {
        var shortSession = AudioUnitProbationSession(sessionIdentifier: 8)
        let shortKey = key(2)
        let shortRequest = try begin(&shortSession, key: shortKey)
        let shortResult = shortSession.observeParentResult(
            observation(
                for: shortRequest,
                termination: .completedAndReaped(
                    evidence(requestedRenderCount: 99_999))))
        #expect(shortResult == .rejected(.insufficientRenderCensus))

        var completeSession = AudioUnitProbationSession(sessionIdentifier: 9)
        let completeTicket = try admittedTicket(&completeSession, key: key(3))
        #expect(completeTicket.renderCount == 100_000)
        #expect(completeTicket.candidateTail.p99999Nanoseconds == 100_000)
    }

    @Test("admission retains exact p99.9 p99.999 allocation and resource census numbers")
    func cleanEvidenceRetainsNumericTelemetry() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 10)
        let final = AudioUnitProbationResourceCensus(
            audioUnitInstances: 0,
            threads: 2,
            fileDescriptors: 3,
            machPorts: 4,
            residentBytes: Self.resourceBaseline.residentBytes + 1_048_576,
            inFlightRenders: 0)
        let ticket = try admittedTicket(
            &session,
            key: key(4),
            evidence: evidence(resourceFinal: final))

        #expect(ticket.allocationViolations == 0)
        #expect(ticket.residentGrowthBytes == 1_048_576)
        #expect(ticket.resourceBaseline == Self.resourceBaseline)
        #expect(ticket.resourceFinal == final)
        #expect(ticket.projectedSteadyTail.p999Nanoseconds == 60_000)
        #expect(ticket.projectedSteadyTail.p99999Nanoseconds == 180_000)
        #expect(ticket.projectedSteadyTail.maximumNanoseconds == 320_000)
        #expect(ticket.projectedCrossfadeTail.p999Nanoseconds == 80_000)
        #expect(ticket.projectedCrossfadeTail.p99999Nanoseconds == 280_000)
        #expect(ticket.projectedCrossfadeTail.maximumNanoseconds == 520_000)
        #expect(ticket.deadlineFractions.candidate.p999.ratio == 0.02)
        #expect(ticket.deadlineFractions.candidate.p99999.ratio == 0.1)
        #expect(ticket.deadlineFractions.projectedSteady.maximum.ratio == 0.32)
        #expect(ticket.deadlineFractions.projectedCrossfade.maximum.ratio == 0.52)
    }

    @Test("crossfade admission accounts for two candidate renders")
    func crossfadeDoublesCandidateCost() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 11)
        let request = try begin(
            &session,
            key: key(5),
            hostTail: AudioUnitProbationRenderTail(
                p999Nanoseconds: 5_000,
                p99999Nanoseconds: 10_000,
                maximumNanoseconds: 100_000))
        let transitionHeavy = evidence(
            renderTail: AudioUnitProbationRenderTail(
                p999Nanoseconds: 10_000,
                p99999Nanoseconds: 20_000,
                maximumNanoseconds: 460_000))

        let result = session.observeParentResult(
            observation(
                for: request,
                termination: .completedAndReaped(transitionHeavy)))
        #expect(result == .rejected(.projectedCrossfadeMaximumExceedsDeadline))

        var p999Session = AudioUnitProbationSession(sessionIdentifier: 112)
        let p999Request = try begin(&p999Session, key: key(56))
        let p999TransitionHeavy = evidence(
            renderTail: AudioUnitProbationRenderTail(
                p999Nanoseconds: 105_001,
                p99999Nanoseconds: 105_001,
                maximumNanoseconds: 200_000))
        let p999Result = p999Session.observeParentResult(
            observation(
                for: p999Request,
                termination: .completedAndReaped(p999TransitionHeavy)))
        #expect(
            p999Result
                == .rejected(.projectedCrossfadeP999ExceedsQuarterDeadline))

        var p99999Session = AudioUnitProbationSession(sessionIdentifier: 113)
        let p99999Request = try begin(&p99999Session, key: key(57))
        let p99999TransitionHeavy = evidence(
            renderTail: AudioUnitProbationRenderTail(
                p999Nanoseconds: 20_000,
                p99999Nanoseconds: 210_001,
                maximumNanoseconds: 300_000))
        let p99999Result = p99999Session.observeParentResult(
            observation(
                for: p99999Request,
                termination: .completedAndReaped(p99999TransitionHeavy)))
        #expect(
            p99999Result
                == .rejected(.projectedCrossfadeP99999ExceedsHalfDeadline))

        var overflowSession = AudioUnitProbationSession(sessionIdentifier: 111)
        let overflowRequest = try begin(
            &overflowSession,
            key: key(55),
            hostTail: AudioUnitProbationRenderTail(
                p999Nanoseconds: 1,
                p99999Nanoseconds: 1,
                maximumNanoseconds: 1))
        let twiceWouldOverflow = evidence(
            renderTail: AudioUnitProbationRenderTail(
                p999Nanoseconds: UInt64.max / 2 + 1,
                p99999Nanoseconds: UInt64.max / 2 + 1,
                maximumNanoseconds: UInt64.max / 2 + 1))
        let overflowResult = overflowSession.observeParentResult(
            observation(
                for: overflowRequest,
                termination: .completedAndReaped(twiceWouldOverflow)))
        #expect(overflowResult == .rejected(.arithmeticOverflow))
    }

    @Test(
        "a parent-observed disposable hard wall quarantines without an in-process replacement"
    )
    func parentHardWallIsTheOnlyNeverReturnProbationOutcome() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 12)
        let candidateKey = key(6)
        let request = try begin(&session, key: candidateKey)

        // No blocking render is simulated here. A never-return is recognised
        // only through the disposable child's parent-enforced kill and reap.
        let result = session.observeParentResult(
            observation(for: request, termination: .parentHardWallTerminatedAndReaped))
        #expect(result == .rejected(.parentHardWall))
        #expect(session.telemetry.parentHardWallTimeouts == 1)
        #expect(session.telemetry.requestsStarted == 1)
        #expect(session.telemetry.candidatesAdmitted == 0)

        let lateSuccess = session.observeParentResult(
            observation(
                for: request,
                termination: .completedAndReaped(evidence())))
        #expect(lateSuccess == .ignoredStaleGeneration)
        #expect(!session.hasAdmittedTicket)

        let differentState = key(6, state: 999)
        let retry = session.begin(
            key: differentState,
            callbackDeadlineNanoseconds: Self.deadline,
            hostBaselineTail: Self.hostTail)
        #expect(retry == .refused(.binaryQuarantinedForSession))
        #expect(session.telemetry.requestsStarted == 1)
    }

    @Test("session quarantine never retries and closes at sixty-four binaries")
    func quarantineIsBoundedAndPermanentForTheSession() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 13)
        for index in 0..<AudioUnitProbationSession.maximumQuarantinedBinaries {
            let request = try begin(&session, key: key(UInt64(index + 100)))
            let result = session.observeParentResult(
                observation(for: request, termination: .crashedAndReaped))
            #expect(result == .rejected(.workerCrash))
        }

        #expect(session.quarantinedBinaryCount == 64)
        #expect(session.telemetry.quarantinedBinaryCount == 64)
        #expect(session.quarantineCapacityClosedSession)
        let sixtyFifth = session.begin(
            key: key(1_000),
            callbackDeadlineNanoseconds: Self.deadline,
            hostBaselineTail: Self.hostTail)
        #expect(sixtyFifth == .refused(.quarantineCapacityClosedSession))
    }

    @Test("stale probation evidence cannot publish or restore a revoked ticket")
    func probationGenerationRevocationIsExact() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 14)
        let firstKey = key(7)
        let firstTicket = try admittedTicket(&session, key: firstKey)
        let secondRequest = try begin(&session, key: key(8))

        #expect(session.telemetry.probationGenerationRevocations == 1)
        let revokedActivation = session.activateLiveCandidate(
            ticket: firstTicket,
            candidateGraphGeneration: 2,
            lastKnownSafeGraphGeneration: 1)
        #expect(revokedActivation == .refused(.ticketRevoked))

        let stale = AudioUnitProbationParentObservation(
            sessionIdentifier: session.sessionIdentifier,
            probationGeneration: firstTicket.probationGeneration,
            key: firstKey,
            termination: .completedAndReaped(evidence()))
        #expect(session.observeParentResult(stale) == .ignoredStaleGeneration)
        #expect(session.hasPendingCandidate)
        #expect(session.telemetry.staleObservations == 1)

        let current = session.observeParentResult(
            observation(
                for: secondRequest,
                termination: .completedAndReaped(evidence())))
        if case .admitted = current {
            #expect(true)
        } else {
            Issue.record("the current generation was not admitted")
        }
    }

    @Test("a returned live fault revokes its graph and requests rollback within two cycles")
    func returnedFaultHasTheOnlyBoundedRollbackContract() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 15)
        let candidateKey = key(9)
        _ = try activate(&session, key: candidateKey)

        let resolution = session.handleReturnedLiveFault(
            graphGeneration: 42,
            fault: .renderStatus(-50))
        let directive: AudioUnitReturnedFaultRollbackDirective
        if case .rollback(let value) = resolution {
            directive = value
        } else {
            Issue.record("a matching returned fault did not request rollback")
            return
        }

        #expect(directive.revokedCandidateGraphGeneration == 42)
        #expect(directive.lastKnownSafeGraphGeneration == 41)
        #expect(directive.maximumPublicationCycles == 2)
        #expect(directive.fault == .renderStatus(-50))
        #expect(session.activeCandidate == nil)
        #expect(session.isQuarantined(candidateKey.binary))
        #expect(session.telemetry.returningLiveFaults == 1)
        #expect(session.telemetry.liveGraphGenerationRevocations == 1)
        #expect(session.telemetry.boundedRollbackDirectives == 1)
        #expect(session.telemetry.inProcessRenderNonReturns == 0)
    }

    @Test("healthy returned canary evidence promotes safe generation and admits the next one")
    func returnedCanaryPromotionAdvancesLastKnownSafe() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 151)
        let first = try activate(&session, key: key(90))
        let evidence = liveEvidence(for: first, returnedRenderCount: 4_096)

        let result = session.confirmReturnedLiveCanary(evidence)
        let promoted: AudioUnitPromotedSafeGraph
        if case .promoted(let value) = result {
            promoted = value
        } else {
            Issue.record("clean returned canary evidence was not promoted")
            return
        }
        #expect(promoted.graphGeneration == 42)
        #expect(promoted.probationGeneration == first.probationGeneration)
        #expect(promoted.returnedRenderCount == 4_096)
        #expect(promoted.callbackTail == Self.liveCallbackTail)
        #expect(session.activeCandidate == nil)
        #expect(session.promotedSafeGraphGeneration == 42)
        #expect(session.telemetry.liveCanariesPromoted == 1)

        #expect(session.confirmReturnedLiveCanary(evidence) == .ignoredStaleIdentity)
        #expect(session.telemetry.liveCanariesPromoted == 1)
        #expect(session.telemetry.staleLiveCanaryConfirmations == 1)

        let secondTicket = try admittedTicket(&session, key: key(91))
        let staleSafe = session.activateLiveCandidate(
            ticket: secondTicket,
            candidateGraphGeneration: 43,
            lastKnownSafeGraphGeneration: 41)
        #expect(staleSafe == .refused(.lastKnownSafeMismatch))
        let inventedSafe = session.activateLiveCandidate(
            ticket: secondTicket,
            candidateGraphGeneration: 1_000,
            lastKnownSafeGraphGeneration: 999)
        #expect(inventedSafe == .refused(.lastKnownSafeMismatch))
        let olderCandidate = session.activateLiveCandidate(
            ticket: secondTicket,
            candidateGraphGeneration: 41,
            lastKnownSafeGraphGeneration: 42)
        #expect(olderCandidate == .refused(.candidateGenerationNotNewerThanSafe))
        let second = session.activateLiveCandidate(
            ticket: secondTicket,
            candidateGraphGeneration: 43,
            lastKnownSafeGraphGeneration: promoted.graphGeneration)
        if case .activated(let candidate) = second {
            #expect(candidate.candidateGraphGeneration == 43)
            #expect(candidate.lastKnownSafeGraphGeneration == 42)
        } else {
            Issue.record("a promoted canary did not release the next activation")
        }
        let returnedFault = session.handleReturnedLiveFault(
            graphGeneration: 43,
            fault: .renderStatus(-50))
        if case .rollback(let directive) = returnedFault {
            #expect(directive.lastKnownSafeGraphGeneration == 42)
        } else {
            Issue.record("a returned fault lost the promoted safe generation")
        }
        #expect(session.promotedSafeGraphGeneration == 42)
    }

    @Test("stale key probation and graph identities cannot clear the current live candidate")
    func staleCanaryPromotionCannotRevokeCurrent() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 152)
        let candidate = try activate(&session, key: key(92))
        let staleEvidence = [
            liveEvidence(for: candidate, key: key(93)),
            liveEvidence(
                for: candidate,
                probationGeneration: candidate.probationGeneration + 1),
            liveEvidence(
                for: candidate,
                graphGeneration: candidate.candidateGraphGeneration + 1),
        ]

        for evidence in staleEvidence {
            #expect(session.confirmReturnedLiveCanary(evidence) == .ignoredStaleIdentity)
            #expect(session.activeCandidate == candidate)
        }
        #expect(session.telemetry.liveCanariesPromoted == 0)
        #expect(session.telemetry.staleLiveCanaryConfirmations == 3)
    }

    @Test("live promotion requires returned clean callbacks within every tail budget")
    func canaryPromotionEvidenceFailsClosed() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 153)
        let candidate = try activate(&session, key: key(94))
        let rejected:
            [(AudioUnitReturnedLiveCanaryEvidence, AudioUnitReturnedLiveCanaryRejection)] = [
                (liveEvidence(for: candidate, returnedRenderCount: 0), .noReturnedRender),
                (liveEvidence(for: candidate, renderStatusFailures: 1), .renderStatusFailure),
                (liveEvidence(for: candidate, missedDeadlines: 1), .deadlineMiss),
                (liveEvidence(for: candidate, allocationViolations: 1), .allocationViolation),
                (liveEvidence(for: candidate, nonFiniteOutputSamples: 1), .nonFiniteOutput),
                (
                    liveEvidence(
                        for: candidate,
                        callbackTail: AudioUnitProbationRenderTail(
                            p999Nanoseconds: 3,
                            p99999Nanoseconds: 2,
                            maximumNanoseconds: 4)),
                    .invalidCallbackTail
                ),
                (
                    liveEvidence(
                        for: candidate,
                        callbackTail: AudioUnitProbationRenderTail(
                            p999Nanoseconds: 250_001,
                            p99999Nanoseconds: 300_000,
                            maximumNanoseconds: 500_000)),
                    .callbackP999ExceedsQuarterDeadline
                ),
                (
                    liveEvidence(
                        for: candidate,
                        callbackTail: AudioUnitProbationRenderTail(
                            p999Nanoseconds: 100_000,
                            p99999Nanoseconds: 500_001,
                            maximumNanoseconds: 600_000)),
                    .callbackP99999ExceedsHalfDeadline
                ),
                (
                    liveEvidence(
                        for: candidate,
                        callbackTail: AudioUnitProbationRenderTail(
                            p999Nanoseconds: 100_000,
                            p99999Nanoseconds: 300_000,
                            maximumNanoseconds: 1_000_001)),
                    .callbackMaximumExceedsDeadline
                ),
            ]

        for (evidence, reason) in rejected {
            #expect(session.confirmReturnedLiveCanary(evidence) == .rejected(reason))
            #expect(session.activeCandidate == candidate)
        }
        #expect(session.telemetry.liveCanaryConfirmationRejections == 9)
        #expect(session.telemetry.liveCanariesPromoted == 0)
    }

    @Test(
        "an in-process non-return makes no bounded rollback claim and closes the live host"
    )
    func inProcessNonReturnRequiresHostContainment() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 16)
        let first = try activate(&session, key: key(10))
        let promotion = session.confirmReturnedLiveCanary(liveEvidence(for: first))
        if case .promoted(let safe) = promotion {
            #expect(safe.graphGeneration == 42)
        } else {
            Issue.record("the setup canary did not promote")
        }
        let candidateKey = key(11)
        let ticket = try admittedTicket(&session, key: candidateKey)
        let activation = session.activateLiveCandidate(
            ticket: ticket,
            candidateGraphGeneration: 43,
            lastKnownSafeGraphGeneration: 42)
        if case .activated = activation {
            #expect(true)
        } else {
            Issue.record("the wedged test candidate did not activate")
        }

        let resolution = session.handleInProcessRenderDidNotReturn(graphGeneration: 43)
        let directive: AudioUnitInProcessRenderHangDirective
        if case .hostCompromised(let value) = resolution {
            directive = value
        } else {
            Issue.record("the matching wedged render did not close the live host")
            return
        }

        #expect(directive.wedgedGraphGeneration == 43)
        #expect(directive.lastKnownSafeGraphGeneration == 42)
        #expect(
            directive.containment
                == .restartAudioHostBeforeUsingLastKnownSafeGraph)
        #expect(session.liveAudioHostCompromised)
        #expect(session.promotedSafeGraphGeneration == 42)
        #expect(session.activeCandidate == nil)
        #expect(session.isQuarantined(candidateKey.binary))
        #expect(session.telemetry.inProcessRenderNonReturns == 1)
        #expect(session.telemetry.liveGraphGenerationRevocations == 1)
        #expect(session.telemetry.boundedRollbackDirectives == 0)

        let replacement = session.begin(
            key: key(12),
            callbackDeadlineNanoseconds: Self.deadline,
            hostBaselineTail: Self.hostTail)
        #expect(replacement == .refused(.liveAudioHostCompromised))
    }

    @Test("a stale live non-return cannot revoke the active graph generation")
    func staleLiveHangEvidenceIsIgnored() throws {
        var session = AudioUnitProbationSession(sessionIdentifier: 17)
        let candidate = try activate(&session, key: key(12))

        let result = session.handleInProcessRenderDidNotReturn(graphGeneration: 999)
        #expect(result == .ignoredStaleGraphGeneration)
        #expect(session.activeCandidate == candidate)
        #expect(!session.liveAudioHostCompromised)
        #expect(session.telemetry.liveGraphGenerationRevocations == 0)
    }

    @Test("resource census rejects every residual owner and one byte beyond the RSS gate")
    func resourceCensusHasClosedNumericBounds() throws {
        let rejectedFinals:
            [(
                AudioUnitProbationResourceCensus, AudioUnitProbationRejection
            )] = [
                (
                    AudioUnitProbationResourceCensus(
                        audioUnitInstances: 1,
                        threads: 2,
                        fileDescriptors: 3,
                        machPorts: 4,
                        residentBytes: Self.resourceBaseline.residentBytes,
                        inFlightRenders: 0),
                    .audioUnitLeak
                ),
                (
                    AudioUnitProbationResourceCensus(
                        audioUnitInstances: 0,
                        threads: 3,
                        fileDescriptors: 3,
                        machPorts: 4,
                        residentBytes: Self.resourceBaseline.residentBytes,
                        inFlightRenders: 0),
                    .threadLeak
                ),
                (
                    AudioUnitProbationResourceCensus(
                        audioUnitInstances: 0,
                        threads: 2,
                        fileDescriptors: 4,
                        machPorts: 4,
                        residentBytes: Self.resourceBaseline.residentBytes,
                        inFlightRenders: 0),
                    .fileDescriptorLeak
                ),
                (
                    AudioUnitProbationResourceCensus(
                        audioUnitInstances: 0,
                        threads: 2,
                        fileDescriptors: 3,
                        machPorts: 5,
                        residentBytes: Self.resourceBaseline.residentBytes,
                        inFlightRenders: 0),
                    .machPortLeak
                ),
                (
                    AudioUnitProbationResourceCensus(
                        audioUnitInstances: 0,
                        threads: 2,
                        fileDescriptors: 3,
                        machPorts: 4,
                        residentBytes: Self.resourceBaseline.residentBytes + 1_048_577,
                        inFlightRenders: 0),
                    .residentGrowthExceeded
                ),
                (
                    AudioUnitProbationResourceCensus(
                        audioUnitInstances: 0,
                        threads: 2,
                        fileDescriptors: 3,
                        machPorts: 4,
                        residentBytes: Self.resourceBaseline.residentBytes,
                        inFlightRenders: 1),
                    .nonQuiescentResourceCensus
                ),
            ]

        for (index, rejected) in rejectedFinals.enumerated() {
            var session = AudioUnitProbationSession(sessionIdentifier: UInt64(100 + index))
            let request = try begin(&session, key: key(UInt64(2_000 + index)))
            let result = session.observeParentResult(
                observation(
                    for: request,
                    termination: .completedAndReaped(
                        evidence(resourceFinal: rejected.0))))
            #expect(result == .rejected(rejected.1))
        }
    }

    @Test("render errors deadline misses allocations and overlap all fail closed")
    func renderFaultCensusFailsClosed() throws {
        let faults: [(AudioUnitProbationEvidence, AudioUnitProbationRejection)] = [
            (evidence(renderStatusFailures: 1), .renderStatusFailure),
            (evidence(missedDeadlines: 1), .deadlineMiss),
            (evidence(allocationViolations: 1), .allocationViolation),
            (evidence(nonFiniteOutputSamples: 1), .nonFiniteOutput),
            (evidence(maximumConcurrentRenders: 2), .concurrentRender),
        ]

        for (index, fault) in faults.enumerated() {
            var session = AudioUnitProbationSession(sessionIdentifier: UInt64(200 + index))
            let request = try begin(&session, key: key(UInt64(3_000 + index)))
            let result = session.observeParentResult(
                observation(for: request, termination: .completedAndReaped(fault.0)))
            #expect(result == .rejected(fault.1))
        }
    }
}
