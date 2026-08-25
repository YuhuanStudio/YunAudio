import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine
@testable import YunAudioHAL

/// Waits for the process-wide quarantine to be empty before a test that needs
/// new audio ownership.
///
/// `ProcessLifetimeAudioQuarantine` is shared by every `RoutingEngine` in the
/// process, so a suite running beside these can be holding a cleanup owner when
/// one of them asks for ownership — and the refusal is correct, it is simply
/// about another test. The precondition was being assumed; it is waited for
/// now, which is what the quarantine's own API is for.
/// Reserves, retrying past a refusal that belongs to another suite.
///
/// `reserveAudioIncidentBeforeOwnership` consults the same process-wide
/// quarantine `beginAudioIncidentOwnership` does — the refusal can land on
/// either step, and wrapping only the second left the first exposed.
private func reserveIncident(
    _ engine: RoutingEngine,
    sourceDeviceUID: String = "input",
    destinationDeviceUID: String = "output",
    preferredSampleRate: Double? = 48_000,
    bufferFrames: UInt32 = 128,
    processTapOwnershipExpected: Bool = false
) throws -> RoutingEngine.AudioIncidentReservation {
    var lastError: Error?
    for _ in 0..<200 {
        _ = ProcessLifetimeAudioQuarantine.shared.waitForNewAudioOwnership(timeout: 1)
        do {
            return try engine.reserveAudioIncidentBeforeOwnership(
                sourceDeviceUID: sourceDeviceUID,
                destinationDeviceUID: destinationDeviceUID,
                preferredSampleRate: preferredSampleRate,
                bufferFrames: bufferFrames,
                processTapOwnershipExpected: processTapOwnershipExpected)
        } catch {
            lastError = error
        }
    }
    struct NeverReserved: Error, CustomStringConvertible {
        var description: String {
            "the process-wide quarantine never admitted a construction reservation"
        }
    }
    throw lastError ?? NeverReserved()
}

private func beginOwnership(
    _ engine: RoutingEngine, reservation: RoutingEngine.AudioIncidentReservation
) throws {
    // Retried, not merely waited for. Waiting until the quarantine is empty
    // leaves a gap in which another suite retains an owner again — the race is
    // inherent to a process-wide registry that every `RoutingEngine` shares,
    // and cannot be closed from outside it. Retrying closes it from this side:
    // the refusal is about somebody else's cleanup and stops being true as soon
    // as that cleanup finishes.
    var lastError: Error?
    for _ in 0..<200 {
        _ = ProcessLifetimeAudioQuarantine.shared.waitForNewAudioOwnership(timeout: 1)
        do {
            try engine.beginAudioIncidentOwnership(reservation: reservation)
            return
        } catch {
            lastError = error
        }
    }
    struct NeverAdmitted: Error, CustomStringConvertible {
        var description: String {
            "the process-wide quarantine never admitted new audio ownership"
        }
    }
    throw lastError ?? NeverAdmitted()
}

@Suite("Bounded audio incident bundle")
struct AudioIncidentBundleTests {
    @Test("the run identity accepts only its fixed hexadecimal representation")
    func runIDIsFixed() {
        let id = AudioIncidentRunID(high: 0x0123_4567_89AB_CDEF, low: 0x0FED_CBA9_8765_4321)
        #expect(id.text == "0123456789abcdef0fedcba987654321")
        #expect(AudioIncidentRunID(id.text) == id)
        #expect(AudioIncidentRunID(id.text.uppercased()) == nil)
        #expect(AudioIncidentRunID(id.text + "00") == nil)
        #expect(AudioIncidentRunID("lyrics are not an incident id") == nil)
    }

    @Test("ten thousand teardown submissions retain thirty-two numeric records")
    func teardownLogIsBounded() throws {
        var log = AudioIncidentTeardownLog()
        for ordinal in 0..<10_000 {
            log.append(
                AudioIncidentTeardownRecord(
                    ordinal: UInt8(truncatingIfNeeded: ordinal),
                    graphGeneration: 42,
                    step: .processTapDestroyed,
                    outcome: .requestFailed,
                    status: -1,
                    elapsedNanoseconds: 1,
                    deadlineNanoseconds: 2))
        }

        #expect(log.records.count == 32)
        #expect(log.droppedRecords == 9_968)
        let bundle = fixture(teardownLog: log, teardownStatus: .incomplete)
        let encoded = try AudioIncidentBundleCodec.encode(bundle)
        #expect(encoded.count <= AudioIncidentBundleCodec.maximumEncodedBytes)
        #expect(bundle.healthVerdict == .faulted)
        print(
            "10,000 teardown records: 32 retained, 9,968 dropped, "
                + "\(encoded.count) encoded bytes")
    }

    @Test("the codec is deterministic, round-trips and has one exact schema")
    func codecIsFixed() throws {
        let log = validTeardownLog()
        let bundle = fixture(teardownLog: log)
        let first = try AudioIncidentBundleCodec.encode(bundle)
        let second = try AudioIncidentBundleCodec.encode(bundle)

        #expect(first == second)
        #expect(try AudioIncidentBundleCodec.decode(first) == bundle)
        #expect(first.count <= AudioIncidentBundleCodec.maximumEncodedBytes)
        let text = try #require(String(data: first, encoding: .utf8))
        for forbidden in ["pcm", "lyrics", "transcript", "secret", "token", "filepath"] {
            #expect(!text.lowercased().contains(forbidden))
        }

        let injected = try #require(
            text.replacingOccurrences(
                of: "{\"callbacks\":",
                with: "{\"pcm\":\"private audio\",\"callbacks\":"
            )
            .data(using: .utf8))
        #expect(throws: AudioIncidentBundleCodec.Error.invalidSchema) {
            try AudioIncidentBundleCodec.decode(injected)
        }

        let backwardsTime = try #require(
            text.replacingOccurrences(
                of: "\"endedUptimeNanoseconds\":200",
                with: "\"endedUptimeNanoseconds\":50"
            )
            .data(using: .utf8))
        #expect(throws: AudioIncidentBundleCodec.Error.invalidSchema) {
            try AudioIncidentBundleCodec.decode(backwardsTime)
        }

        let reversedTail = try #require(
            text.replacingOccurrences(
                of: "\"p99999Nanoseconds\":450000",
                with: "\"p99999Nanoseconds\":200000"
            )
            .data(using: .utf8))
        #expect(throws: AudioIncidentBundleCodec.Error.invalidSchema) {
            try AudioIncidentBundleCodec.decode(reversedTail)
        }
    }

    @Test("driver faults revoke both healthy and bit-exact claims")
    func healthRevokesClaims() throws {
        let healthy = fixture()
        #expect(healthy.healthVerdict == .healthy)
        #expect(healthy.isBitExactEligible)

        let faulted = fixture(
            driverHealth: AudioIncidentDriverHealth(
                state: .available,
                wasRequired: true,
                readStatus: 0,
                unsafeReadOperations: 1,
                unsafeWriteOperations: 0))
        #expect(faulted.healthVerdict == .faulted)
        #expect(!faulted.isBitExactEligible)

        let encoded = try AudioIncidentBundleCodec.encode(faulted)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("\"health\":\"faulted\""))
        #expect(text.contains("\"bitExactEligible\":false"))
    }

    @Test("driver evidence cannot disguise a failed read or a required absence")
    func driverEvidenceShapeIsExact() {
        let malformed = [
            AudioIncidentDriverHealth(
                state: .driverAbsent, wasRequired: false, readStatus: -1,
                unsafeReadOperations: 0, unsafeWriteOperations: 0),
            AudioIncidentDriverHealth(
                state: .driverAbsent, wasRequired: true, readStatus: 0,
                unsafeReadOperations: 0, unsafeWriteOperations: 0),
            AudioIncidentDriverHealth(
                state: .propertyUnavailable, wasRequired: false, readStatus: -1,
                unsafeReadOperations: 0, unsafeWriteOperations: 0),
            AudioIncidentDriverHealth(
                state: .readFailed, wasRequired: false, readStatus: 0,
                unsafeReadOperations: 0, unsafeWriteOperations: 0),
        ]
        let malformedFaults = [
            AudioIncidentDriverHealth(
                state: .available, wasRequired: true, readStatus: 0,
                unsafeReadOperations: 1, unsafeWriteOperations: 0,
                unsafeReadStartFrame: 10_000,
                unsafeReadFrameCount: 1_184),
            AudioIncidentDriverHealth(
                state: .available, wasRequired: true, readStatus: 0,
                unsafeReadOperations: 1, unsafeWriteOperations: 0,
                unsafeReadStartFrame: 10_000,
                unsafeReadFrameCount: 1_184,
                unsafeReadUnavailableFrame: 11_184,
                lastPublishedStartFrame: 9_600,
                lastPublishedFrameCount: 800),
        ]

        for evidence in malformed {
            let bundle = fixture(driverHealth: evidence)
            #expect(bundle.healthVerdict == .indeterminate)
            #expect(throws: AudioIncidentBundleCodec.Error.invalidSchema) {
                try AudioIncidentBundleCodec.encode(bundle)
            }
        }
        for evidence in malformedFaults {
            let bundle = fixture(driverHealth: evidence)
            #expect(bundle.healthVerdict == .faulted)
            #expect(throws: AudioIncidentBundleCodec.Error.invalidSchema) {
                try AudioIncidentBundleCodec.encode(bundle)
            }
        }
    }

    @Test("driver counters are attributed to one route rather than process lifetime")
    func driverHealthUsesRouteDelta() {
        let baseline = AudioIncidentDriverHealth(
            state: .available, wasRequired: true, readStatus: 0,
            unsafeReadOperations: 41, unsafeWriteOperations: 99)
        let final = AudioIncidentDriverHealth(
            state: .available, wasRequired: true, readStatus: 0,
            unsafeReadOperations: 43, unsafeWriteOperations: 104,
            unsafeReadStartFrame: 10_000,
            unsafeReadFrameCount: 1_184,
            unsafeReadUnavailableFrame: 10_769,
            lastPublishedStartFrame: 9_600,
            lastPublishedFrameCount: 800)
        #expect(
            AudioIncidentDriverHealth.routeDelta(from: baseline, to: final)
                == AudioIncidentDriverHealth(
                    state: .available, wasRequired: true, readStatus: 0,
                    unsafeReadOperations: 2, unsafeWriteOperations: 5,
                    unsafeReadStartFrame: 10_000,
                    unsafeReadFrameCount: 1_184,
                    unsafeReadUnavailableFrame: 10_769,
                    lastPublishedStartFrame: 9_600,
                    lastPublishedFrameCount: 800))

        let reset = AudioIncidentDriverHealth(
            state: .available, wasRequired: true, readStatus: 0,
            unsafeReadOperations: 0, unsafeWriteOperations: 0)
        let unattributable = AudioIncidentDriverHealth.routeDelta(
            from: baseline, to: reset)
        #expect(unattributable.state == .readFailed)
        #expect(unattributable.readStatus != 0)
    }

    @Test("historical quarantine counters do not fault a later clean route")
    func residueIsAttributedToOneRoute() throws {
        let historical = residueFixture(
            maximumRetainedEntries: 3,
            cleanupAttempts: 7,
            completedEntries: 3,
            deniedAdmissions: 2)
        let clean = fixture(
            residueBaseline: historical,
            residue: historical)
        #expect(clean.healthVerdict == .healthy)
        #expect(clean.isBitExactEligible)

        let routeFault = fixture(
            residueBaseline: historical,
            residue: residueFixture(
                retainedEntries: 1,
                maximumRetainedEntries: 3,
                cleanupAttempts: 8,
                scheduledRetries: 1,
                completedEntries: 3,
                deniedAdmissions: 2))
        #expect(routeFault.healthVerdict == .faulted)
        #expect(!routeFault.isBitExactEligible)

        let reset = fixture(
            residueBaseline: historical,
            residue: emptyResidue())
        #expect(reset.healthVerdict == .indeterminate)
        #expect(throws: AudioIncidentBundleCodec.Error.invalidSchema) {
            try AudioIncidentBundleCodec.encode(reset)
        }
    }

    @Test("live counters and truncated evidence are indeterminate")
    func incompleteEvidenceNeverClaimsHealth() {
        let live = fixture(
            callbacks: callbackFixture(collection: .liveBestEffort))
        #expect(live.healthVerdict == .indeterminate)
        #expect(!live.isBitExactEligible)

        var log = AudioIncidentTeardownLog()
        for ordinal in 0..<33 {
            log.append(
                AudioIncidentTeardownRecord(
                    ordinal: UInt8(ordinal), graphGeneration: 1,
                    step: .ownersReleased, outcome: .completed,
                    status: 0, elapsedNanoseconds: 1, deadlineNanoseconds: 2))
        }
        let truncated = fixture(teardownLog: log)
        #expect(truncated.droppedTeardownRecords == 1)
        #expect(truncated.healthVerdict == .indeterminate)
    }

    @Test("a pre-callback failure remains encodable but can never claim health")
    func zeroCallbackEvidenceNamesFailedConstruction() throws {
        let noCallbacks = AudioIncidentCallbackSnapshot(
            collection: .postFenceCoherent,
            samples: 0,
            p50Nanoseconds: 0,
            p999Nanoseconds: 0,
            p99999Nanoseconds: 0,
            maximumNanoseconds: 0,
            deadlineNanoseconds: 2_000_000,
            overflowSamples: 0,
            missedDeadlines: 0,
            callbackOverlaps: 0,
            allocationViolations: 0,
            maximumUpdateContentions: 0)
        let clean = fixture(callbacks: noCallbacks)
        #expect(clean.healthVerdict == .indeterminate)
        #expect(!clean.isBitExactEligible)
        #expect(
            try AudioIncidentBundleCodec.decode(AudioIncidentBundleCodec.encode(clean))
                == clean)

        var failedLog = AudioIncidentTeardownLog()
        failedLog.append(
            AudioIncidentTeardownRecord(
                ordinal: 0,
                graphGeneration: 41,
                step: .aggregateDestroyed,
                outcome: .timedOut,
                status: 0,
                elapsedNanoseconds: 2_000_000_001,
                deadlineNanoseconds: 2_000_000_000))
        let failed = fixture(
            callbacks: noCallbacks,
            teardownLog: failedLog,
            teardownStatus: .timedOut)
        #expect(failed.healthVerdict == .faulted)
        #expect(
            try AudioIncidentBundleCodec.decode(AudioIncidentBundleCodec.encode(failed))
                == failed)
    }

    @Test("tail budgets and impossible evidence cannot produce a healthy bundle")
    func numericEvidenceIsGraded() {
        let slowTail = callbackFixture(
            p999Nanoseconds: 500_001,
            p99999Nanoseconds: 900_000,
            maximumNanoseconds: 900_000,
            deadlineNanoseconds: 2_000_000)
        let slow = fixture(callbacks: slowTail)
        #expect(slow.healthVerdict == .faulted)
        #expect(!slow.isBitExactEligible)

        let impossibleTail = callbackFixture(
            p999Nanoseconds: 400_000,
            p99999Nanoseconds: 300_000,
            maximumNanoseconds: 500_000,
            deadlineNanoseconds: 2_000_000)
        let impossible = fixture(callbacks: impossibleTail)
        #expect(impossible.healthVerdict == .indeterminate)
        #expect(throws: AudioIncidentBundleCodec.Error.invalidSchema) {
            try AudioIncidentBundleCodec.encode(impossible)
        }

        let noTeardown = fixture(teardownLog: AudioIncidentTeardownLog())
        #expect(noTeardown.healthVerdict == .indeterminate)
        #expect(throws: AudioIncidentBundleCodec.Error.invalidSchema) {
            try AudioIncidentBundleCodec.encode(noTeardown)
        }

        let backwards = fixture(
            startedUptimeNanoseconds: 200,
            endedUptimeNanoseconds: 100,
            firstGraphGeneration: 42,
            finalGraphGeneration: 41)
        #expect(backwards.healthVerdict == .indeterminate)
    }

    @Test("a completed retry retains its earlier failure and actual deadline overrun")
    func recoveredFailureRemainsFaulted() throws {
        var log = AudioIncidentTeardownLog()
        log.append(
            AudioIncidentTeardownRecord(
                ordinal: 0,
                graphGeneration: 42,
                step: .ioProcStopped,
                outcome: .requestFailed,
                status: -1,
                elapsedNanoseconds: 3_000_000_000,
                deadlineNanoseconds: 2_000_000_000))
        for (offset, step) in [
            AudioIncidentTeardownStep.callbackFence,
            .driverHealthRead,
            .halCensusComplete,
        ].enumerated() {
            log.append(
                AudioIncidentTeardownRecord(
                    ordinal: UInt8(offset + 1),
                    graphGeneration: 42,
                    step: step,
                    outcome: .completed,
                    status: 0,
                    elapsedNanoseconds: 250_000,
                    deadlineNanoseconds: 2_000_000_000))
        }

        let recovered = fixture(teardownLog: log)
        #expect(recovered.healthVerdict == .faulted)
        #expect(
            try AudioIncidentBundleCodec.decode(AudioIncidentBundleCodec.encode(recovered))
                == recovered)
    }

    @Test("oversized input is rejected before JSON parsing")
    func byteLimitPrecedesParsing() {
        let oversized = Data(
            repeating: UInt8(ascii: " "),
            count: AudioIncidentBundleCodec.maximumEncodedBytes + 1)
        #expect(
            throws: AudioIncidentBundleCodec.Error.inputTooLarge(oversized.count)
        ) {
            try AudioIncidentBundleCodec.decode(oversized)
        }
    }

    private func fixture(
        driverHealth: AudioIncidentDriverHealth = AudioIncidentDriverHealth(
            state: .available,
            wasRequired: true,
            readStatus: 0,
            unsafeReadOperations: 0,
            unsafeWriteOperations: 0),
        callbacks: AudioIncidentCallbackSnapshot? = nil,
        teardownLog: AudioIncidentTeardownLog? = nil,
        teardownStatus: AudioIncidentTeardownStatus = .complete,
        startedUptimeNanoseconds: UInt64 = 100,
        endedUptimeNanoseconds: UInt64 = 200,
        firstGraphGeneration: UInt64 = 41,
        finalGraphGeneration: UInt64 = 42,
        residueBaseline: AudioIncidentResidueSnapshot? = nil,
        residue: AudioIncidentResidueSnapshot? = nil
    ) -> AudioIncidentBundle {
        AudioIncidentBundle(
            runID: AudioIncidentRunID(high: 0xA11D_0000_0000_0001, low: 42),
            startedUptimeNanoseconds: startedUptimeNanoseconds,
            endedUptimeNanoseconds: endedUptimeNanoseconds,
            firstGraphGeneration: firstGraphGeneration,
            finalGraphGeneration: finalGraphGeneration,
            pathReportedBitExact: true,
            driverHealth: driverHealth,
            callbacks: callbacks ?? callbackFixture(),
            teardownStatus: teardownStatus,
            teardownLog: teardownLog ?? validTeardownLog(),
            residueBaseline: residueBaseline ?? emptyResidue(),
            residue: residue ?? emptyResidue())
    }

    private func emptyResidue() -> AudioIncidentResidueSnapshot {
        residueFixture()
    }

    private func residueFixture(
        retainedEntries: UInt32 = 0,
        maximumRetainedEntries: UInt32 = 0,
        cleanupAttempts: UInt64 = 0,
        scheduledRetries: UInt32 = 0,
        exhaustedEntries: UInt32 = 0,
        completedEntries: UInt64 = 0,
        deniedAdmissions: UInt64 = 0
    ) -> AudioIncidentResidueSnapshot {
        AudioIncidentResidueSnapshot(
            retainedEntries: retainedEntries,
            maximumRetainedEntries: maximumRetainedEntries,
            cleanupAttempts: cleanupAttempts,
            scheduledRetries: scheduledRetries,
            exhaustedEntries: exhaustedEntries,
            completedEntries: completedEntries,
            deniedAdmissions: deniedAdmissions)
    }

    private func callbackFixture(
        collection: AudioIncidentCallbackCollection = .postFenceCoherent,
        p999Nanoseconds: UInt64 = 300_000,
        p99999Nanoseconds: UInt64 = 450_000,
        maximumNanoseconds: UInt64 = 500_000,
        deadlineNanoseconds: UInt64 = 2_000_000
    ) -> AudioIncidentCallbackSnapshot {
        AudioIncidentCallbackSnapshot(
            collection: collection,
            samples: 10_000,
            p50Nanoseconds: 120_000,
            p999Nanoseconds: p999Nanoseconds,
            p99999Nanoseconds: p99999Nanoseconds,
            maximumNanoseconds: maximumNanoseconds,
            deadlineNanoseconds: deadlineNanoseconds,
            overflowSamples: 0,
            missedDeadlines: 0,
            callbackOverlaps: 0,
            allocationViolations: 0,
            maximumUpdateContentions: 0)
    }

    private func validTeardownLog() -> AudioIncidentTeardownLog {
        var log = AudioIncidentTeardownLog()
        for (ordinal, step) in [
            AudioIncidentTeardownStep.callbackFence,
            .driverHealthRead,
            .halCensusComplete,
        ].enumerated() {
            log.append(
                AudioIncidentTeardownRecord(
                    ordinal: UInt8(ordinal),
                    graphGeneration: 42,
                    step: step,
                    outcome: .completed,
                    status: 0,
                    elapsedNanoseconds: 250_000,
                    deadlineNanoseconds: 2_000_000_000))
        }
        return log
    }

}

@Suite("Route incident recorder")
struct AudioIncidentRecorderTests {
    @Test(
        "a pre-ownership reservation is exact, inconclusive and replaceable only after release")
    func constructionReservationHasOneRunIdentity() throws {
        let engine = RoutingEngine()
        let first = try reserveIncident(engine)
        let firstBundle = first.constructionBundle

        #expect(firstBundle.callbacks.samples == 0)
        #expect(firstBundle.callbacks.collection == .liveBestEffort)
        #expect(firstBundle.teardownStatus == .notObserved)
        #expect(firstBundle.healthVerdict == .indeterminate)
        #expect(engine.lastAudioIncidentBundle?.runID == firstBundle.runID)
        #expect(engine.takePendingAudioIncidentBundle() == nil)
        #expect(throws: RoutingError.self) {
            try reserveIncident(engine)
        }

        #expect(engine.discardAudioIncidentReservation(first))
        let second = try reserveIncident(engine)
        #expect(second.constructionBundle.runID != firstBundle.runID)
        #expect(!engine.discardAudioIncidentReservation(first))
        #expect(engine.discardAudioIncidentReservation(second))
    }

    @Test("discarding a reservation removes its provisional latest evidence")
    func discardedReservationIsNotLatestEvidence() throws {
        let engine = RoutingEngine()
        let reservation = try reserveIncident(engine)

        #expect(engine.lastAudioIncidentBundle == reservation.constructionBundle)
        #expect(engine.discardAudioIncidentReservation(reservation))
        #expect(engine.lastAudioIncidentBundle == nil)
    }

    @Test("a prepared process-tap checkpoint cannot be discarded before begin")
    func preparedProcessTapCheckpointForbidsDiscard() throws {
        let engine = RoutingEngine()
        let reservation = try reserveIncident(engine, processTapOwnershipExpected: true)
        _ = try engine.makeProcessTapOwnershipCheckpoint(reservation: reservation)

        let discarded = engine.discardAudioIncidentReservation(reservation)
        #expect(!discarded)
        guard !discarded else { return }

        try beginOwnership(engine, reservation: reservation)
        #expect(engine.stop(timeout: 0.01).isComplete)
    }

    @Test("a process-tap boundary is serialised before ownership and forbids discard")
    func processTapBoundaryIsDurableEvidence() throws {
        let engine = RoutingEngine()
        let reservation = try reserveIncident(engine, processTapOwnershipExpected: true)
        #expect(throws: RoutingError.self) {
            try beginOwnership(engine, reservation: reservation)
        }
        let checkpoint = try engine.makeProcessTapOwnershipCheckpoint(
            reservation: reservation)

        #expect(checkpoint.runID == reservation.constructionBundle.runID)
        #expect(checkpoint.resources.processTapCallEntered)
        #expect(!checkpoint.resources.hadProcessTaps)
        #expect(!checkpoint.resources.hadAggregate)
        #expect(
            try AudioIncidentBundleCodec.decode(
                AudioIncidentBundleCodec.encode(checkpoint)) == checkpoint)
        try beginOwnership(engine, reservation: reservation)
        #expect(throws: RoutingError.self) {
            try beginOwnership(engine, reservation: reservation)
        }
        #expect(!engine.discardAudioIncidentReservation(reservation))

        let teardown = engine.stop(timeout: 0.01)
        #expect(teardown.isComplete)
        #expect(engine.lastAudioIncidentBundle?.runID == checkpoint.runID)
        #expect(
            engine.lastAudioIncidentBundle?.teardownRecords.last(where: {
                $0.step == .processTapDestroyed
            })?.outcome == .skipped)
    }

    @Test("reservation phases admit only their recorded ownership boundary")
    func reservationPhaseAdmissionIsExact() {
        #expect(
            RoutingEngine.reservationPhasePermitsStart(
                .beforeOwnership, processTapOwnershipExpected: false))
        #expect(
            !RoutingEngine.reservationPhasePermitsStart(
                .beforeOwnership, processTapOwnershipExpected: true))
        #expect(
            !RoutingEngine.reservationPhasePermitsStart(
                .checkpointPrepared, processTapOwnershipExpected: true))
        #expect(
            RoutingEngine.reservationPhasePermitsStart(
                .ownershipMayExist, processTapOwnershipExpected: true))
        #expect(
            !RoutingEngine.reservationPhasePermitsStart(
                .ownershipMayExist, processTapOwnershipExpected: false))
        #expect(
            RoutingEngine.reservationPhasePermitsStart(
                .consumed, processTapOwnershipExpected: false))
        #expect(
            RoutingEngine.reservationPhasePermitsStart(
                .consumed, processTapOwnershipExpected: true))
    }

    @Test("construction ownership is recorded before the first callback")
    func failedConstructionHasEvidence() throws {
        let recorder = try #require(
            AudioIncidentRecorder(
                sampleRate: 48_000,
                bufferFrames: 128,
                driverDeviceID: nil,
                driverWasRequired: false,
                driverHealthBaseline: .absent,
                residueBaseline: .empty,
                resources: AudioIncidentRecorder.Resources(
                    hadEchoCancellation: false,
                    hadAudioUnits: false,
                    hadAggregate: false,
                    hadProcessTaps: false,
                    changedSampleRates: false),
                runID: AudioIncidentRunID(high: 7, low: 8)))
        recorder.recordResources(
            AudioIncidentRecorder.Resources(
                hadEchoCancellation: true,
                hadAudioUnits: true,
                hadAggregate: true,
                hadProcessTaps: true,
                changedSampleRates: true))
        recorder.captureCallbackFence(cellOverlaps: 0)

        let bundle = try #require(
            recorder.makeBundle(
                result: .complete,
                elapsedNanoseconds: 200_000,
                deadlineNanoseconds: 2_000_000_000,
                driverHealth: .absent,
                callbackCellOverlaps: 0,
                residue: .empty))
        #expect(bundle.callbacks.samples == 0)
        #expect(bundle.healthVerdict == .indeterminate)
        for step in [
            AudioIncidentTeardownStep.echoCancellationDisposed,
            .audioUnitDisposed,
            .aggregateDestroyed,
            .processTapDestroyed,
            .sampleRatesRestored,
        ] {
            #expect(
                bundle.teardownRecords.last(where: { $0.step == step })?.outcome
                    == .completed)
        }
        #expect(
            try AudioIncidentBundleCodec.decode(AudioIncidentBundleCodec.encode(bundle))
                == bundle)
    }

    @Test("a live checkpoint names the run without claiming teardown or coherence")
    func liveCheckpointIsExplicitlyInconclusive() throws {
        let recorder = try #require(
            AudioIncidentRecorder(
                sampleRate: 48_000,
                bufferFrames: 128,
                driverDeviceID: nil,
                driverWasRequired: false,
                driverHealthBaseline: .absent,
                residueBaseline: .empty,
                resources: AudioIncidentRecorder.Resources(
                    hadEchoCancellation: false,
                    hadAudioUnits: false,
                    hadAggregate: true,
                    hadProcessTaps: false,
                    changedSampleRates: false),
                runID: AudioIncidentRunID(high: 9, low: 10)))
        yun_rt_incident_callback_observe(
            recorder.callbackTelemetry, 100_000,
            recorder.callbackDeadlineNanoseconds, 0)
        recorder.recordPathReportedBitExact(true)

        let checkpoint = try #require(
            recorder.makeLiveBundle(
                callbackCellOverlaps: 0, residue: .empty))
        #expect(checkpoint.runID == AudioIncidentRunID(high: 9, low: 10))
        #expect(checkpoint.teardownStatus == .notObserved)
        #expect(checkpoint.teardownRecords.isEmpty)
        #expect(checkpoint.callbacks.collection == .liveBestEffort)
        #expect(checkpoint.healthVerdict == .indeterminate)
        #expect(!checkpoint.isBitExactEligible)
        #expect(
            try AudioIncidentBundleCodec.decode(
                AudioIncidentBundleCodec.encode(checkpoint)) == checkpoint)
    }

    @Test("a route cannot regain a whole-run bit-exact claim after processing")
    func bitExactEvidenceLatchesFalse() throws {
        let recorder = try #require(
            AudioIncidentRecorder(
                sampleRate: 48_000,
                bufferFrames: 128,
                driverDeviceID: nil,
                driverWasRequired: false,
                driverHealthBaseline: .absent,
                residueBaseline: .empty,
                resources: AudioIncidentRecorder.Resources(
                    hadEchoCancellation: false,
                    hadAudioUnits: false,
                    hadAggregate: false,
                    hadProcessTaps: false,
                    changedSampleRates: false)))
        recorder.recordPathReportedBitExact(true)
        recorder.recordPathReportedBitExact(false)
        recorder.recordPathReportedBitExact(true)
        recorder.captureCallbackFence(cellOverlaps: 0)

        let bundle = try #require(
            recorder.makeBundle(
                result: .complete,
                elapsedNanoseconds: 1,
                deadlineNanoseconds: 1_000,
                driverHealth: .absent,
                callbackCellOverlaps: 0,
                residue: .empty))
        #expect(!bundle.pathReportedBitExact)
        #expect(!bundle.isBitExactEligible)
    }

    @Test("driver health freezes the first real baseline across internal retries")
    func driverBaselineDoesNotMoveOnRetry() throws {
        let recorder = try #require(
            AudioIncidentRecorder(
                sampleRate: 48_000,
                bufferFrames: 128,
                driverDeviceID: nil,
                driverWasRequired: false,
                driverHealthBaseline: .absent,
                residueBaseline: .empty,
                resources: AudioIncidentRecorder.Resources(
                    hadEchoCancellation: false,
                    hadAudioUnits: false,
                    hadAggregate: false,
                    hadProcessTaps: false,
                    changedSampleRates: false)))
        recorder.configureDriverHealth(
            deviceID: 7,
            wasRequired: true,
            baseline: .init(
                state: .available, wasRequired: true, readStatus: 0,
                unsafeReadOperations: 0, unsafeWriteOperations: 0))
        recorder.configureDriverHealth(
            deviceID: 7,
            wasRequired: true,
            baseline: .init(
                state: .available, wasRequired: true, readStatus: 0,
                unsafeReadOperations: 3, unsafeWriteOperations: 0))
        recorder.captureCallbackFence(cellOverlaps: 0)

        let bundle = try #require(
            recorder.makeBundle(
                result: .complete,
                elapsedNanoseconds: 1,
                deadlineNanoseconds: 1_000,
                driverHealth: .init(
                    state: .available, wasRequired: true, readStatus: 0,
                    unsafeReadOperations: 5, unsafeWriteOperations: 0),
                callbackCellOverlaps: 0,
                residue: .empty))
        #expect(bundle.driverHealth.unsafeReadOperations == 5)
    }

    @Test("a failed stop names only its terminal and a later clean retry keeps it")
    func retryEvidenceIsHistorical() throws {
        let recorder = try #require(
            AudioIncidentRecorder(
                sampleRate: 48_000,
                bufferFrames: 128,
                driverDeviceID: nil,
                driverWasRequired: false,
                driverHealthBaseline: .absent,
                residueBaseline: .empty,
                resources: AudioIncidentRecorder.Resources(
                    hadEchoCancellation: true,
                    hadAudioUnits: false,
                    hadAggregate: true,
                    hadProcessTaps: false,
                    changedSampleRates: true),
                runID: AudioIncidentRunID(high: 1, low: 2)))
        yun_rt_incident_callback_observe(
            recorder.callbackTelemetry, 100_000,
            recorder.callbackDeadlineNanoseconds, 0)
        yun_rt_incident_graph_published(recorder.callbackTelemetry)

        let failed = try #require(
            recorder.makeBundle(
                result: .ioProcStopFailed(-50),
                elapsedNanoseconds: 3_000_000_000,
                deadlineNanoseconds: 2_000_000_000,
                driverHealth: .absent,
                callbackCellOverlaps: 0,
                residue: .empty))
        #expect(failed.teardownStatus == .incomplete)
        #expect(failed.callbacks.collection == .liveBestEffort)
        #expect(failed.finalGraphGeneration == 2)
        #expect(failed.teardownRecords.map(\.step) == [.admissionStopped, .ioProcStopped])
        #expect(!failed.teardownRecords.contains { $0.step == .aggregateDestroyed })
        #expect(failed.healthVerdict == .faulted)

        recorder.captureCallbackFence(cellOverlaps: 0)
        let recovered = try #require(
            recorder.makeBundle(
                result: .complete,
                elapsedNanoseconds: 200_000,
                deadlineNanoseconds: 2_000_000_000,
                driverHealth: .absent,
                callbackCellOverlaps: 0,
                residue: .empty))
        #expect(recovered.teardownStatus == .complete)
        #expect(recovered.callbacks.collection == .postFenceCoherent)
        #expect(
            recovered.teardownRecords.contains { record in
                record.step == .ioProcStopped && record.outcome == .requestFailed
            })
        #expect(recovered.teardownRecords.last?.step == .halCensusComplete)
        #expect(recovered.healthVerdict == .faulted)
        #expect(
            try AudioIncidentBundleCodec.decode(
                AudioIncidentBundleCodec.encode(recovered)) == recovered)
    }
}

extension AudioIncidentDriverHealth {
    fileprivate static let absent = AudioIncidentDriverHealth(
        state: .driverAbsent,
        wasRequired: false,
        readStatus: 0,
        unsafeReadOperations: 0,
        unsafeWriteOperations: 0)
}

extension AudioResidueTelemetry {
    fileprivate static let empty = AudioResidueTelemetry(
        retainedEntries: 0,
        maximumRetainedEntries: 0,
        cleanupAttempts: 0,
        scheduledRetries: 0,
        exhaustedEntries: 0,
        completedEntries: 0,
        deniedAdmissions: 0,
        maximumRetryDelay: 0,
        maximumAttemptsPerEntry: 1)
}

@Suite("Realtime incident callback telemetry", .serialized)
struct IncidentCallbackTelemetryTests {
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer

        init(_ pointer: OpaquePointer) {
            self.pointer = pointer
        }
    }

    @Test("overflow remains separate and a live snapshot never claims coherence")
    func tailDistributionIsConservative() throws {
        let pointer = try #require(yun_rt_incident_callback_create())
        defer { yun_rt_incident_callback_free(pointer) }

        for _ in 0..<998 {
            yun_rt_incident_callback_observe(pointer, 10_000, 2_000_000, 0)
        }
        yun_rt_incident_callback_observe(pointer, 800_000, 2_000_000, 3)
        yun_rt_incident_callback_observe(pointer, 5_000_000, 2_000_000, 0)
        yun_rt_incident_callback_refuse_overlap(pointer, 2)

        var live = YunRTIncidentCallbackSnapshot()
        yun_rt_incident_callback_snapshot(pointer, false, &live)
        #expect(!live.isCoherent)
        #expect(live.samples == 1_000)
        #expect(live.p50Nanoseconds == 11_999)
        #expect(live.p999Nanoseconds == 803_999)
        #expect(live.p99999Nanoseconds == 5_000_000)
        #expect(live.maximumNanoseconds == 5_000_000)
        #expect(live.overflowSamples == 1)
        #expect(live.deadlineNanoseconds == 2_000_000)
        #expect(live.missedDeadlines == 1)
        #expect(live.callbackOverlaps == 1)
        #expect(live.allocationViolations == 5)
        #expect(AudioIncidentCallbackSnapshot(live).collection == .liveBestEffort)

        var fenced = YunRTIncidentCallbackSnapshot()
        yun_rt_incident_callback_snapshot(pointer, true, &fenced)
        #expect(fenced.isCoherent)
        #expect(
            AudioIncidentCallbackSnapshot(fenced).collection == .postFenceCoherent)
    }

    @Test("four callback writers update one fixed histogram without losing samples")
    func multipleWritersAreAtomic() throws {
        let pointer = try #require(yun_rt_incident_callback_create())
        defer { yun_rt_incident_callback_free(pointer) }
        let handle = Handle(pointer)
        let group = DispatchGroup()

        for writer in 0..<4 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for sample in 0..<2_500 {
                    yun_rt_incident_callback_observe(
                        handle.pointer,
                        UInt64(40_000 + writer * 4_000 + sample % 4_000),
                        2_000_000,
                        0)
                }
                group.leave()
            }
        }
        #expect(group.wait(timeout: .now() + 2) == .success)

        var snapshot = YunRTIncidentCallbackSnapshot()
        yun_rt_incident_callback_snapshot(pointer, true, &snapshot)
        #expect(snapshot.isCoherent)
        #expect(snapshot.samples == 10_000)
        #expect(snapshot.overflowSamples == 0)
        #expect(snapshot.missedDeadlines == 0)
        #expect(snapshot.callbackOverlaps == 0)
        #expect(snapshot.maximumNanoseconds == 54_499)
        #expect(kYunRTIncidentHistogramBytes == 8_192)
    }

    #if DEBUG
        @Test(
            "callback collection allocates nothing",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("callback collection allocates nothing")
    #endif
    func callbackObservationAllocatesNothing() throws {
        let pointer = try #require(yun_rt_incident_callback_create())
        defer { yun_rt_incident_callback_free(pointer) }
        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }

        let before = RoutingEngine.allocationViolations
        yun_rt_tripwire_mark_realtime(true)
        for sample in 0..<100_000 {
            yun_rt_incident_callback_observe(
                pointer, UInt64(20_000 + sample % 4_000), 2_000_000, 0)
        }
        yun_rt_tripwire_mark_realtime(false)
        let allocations = RoutingEngine.allocationViolations - before

        var snapshot = YunRTIncidentCallbackSnapshot()
        yun_rt_incident_callback_snapshot(pointer, true, &snapshot)
        print(
            "100,000 incident observations: \(allocations) allocations, "
                + "\(snapshot.samples) samples")
        #expect(allocations == 0)
        #expect(snapshot.samples == 100_000)
        #expect(snapshot.isCoherent)
    }
}
