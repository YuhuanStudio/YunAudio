import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

private final class IncidentWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [UInt64] = []
    let began = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func write(_ bundle: AudioIncidentBundle) -> Bool {
        lock.withLock { written.append(bundle.runID.low) }
        if bundle.runID.low == 1 {
            began.signal()
            _ = release.wait(timeout: .now() + TestGate.deadlock)
        }
        return true
    }

    var values: [UInt64] { lock.withLock { written } }
}

private final class IncidentWriterResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LatestAudioIncidentWriter.FlushResult?

    func store(_ value: LatestAudioIncidentWriter.FlushResult) {
        lock.withLock { self.value = value }
    }

    var result: LatestAudioIncidentWriter.FlushResult? { lock.withLock { value } }
}

private final class IncidentPhaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let blockedRun: UInt64?
    private var written: [AudioIncidentBundle] = []
    let began = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    init(blockedRun: UInt64? = nil) { self.blockedRun = blockedRun }

    func write(_ bundle: AudioIncidentBundle) -> Bool {
        lock.withLock { written.append(bundle) }
        if bundle.runID.low == blockedRun {
            began.signal()
            _ = release.wait(timeout: .now() + TestGate.deadlock)
        }
        return true
    }

    var values: [AudioIncidentBundle] { lock.withLock { written } }
}

@Suite("Audio incident writer", .serialized)
struct AudioIncidentWriterTests {
    @Test("the live incident cadence is bounded and pauses during teardown")
    func checkpointCadenceIsFiveSeconds() {
        var cadence = AudioIncidentCheckpointCadence()
        for _ in 0..<(AudioIncidentCheckpointCadence.pollInterval - 1) {
            let fired = cadence.advance(isEligible: true)
            #expect(!fired)
        }
        #expect(cadence.polls == 99)
        let whileIneligible = cadence.advance(isEligible: false)
        #expect(!whileIneligible)
        #expect(cadence.polls == 99)
        let final = cadence.advance(isEligible: true)
        #expect(final)
        #expect(cadence.polls == 0)

        var checkpoints = 0
        for _ in 0..<10_000 where cadence.advance(isEligible: true) {
            checkpoints += 1
        }
        #expect(checkpoints == 100)
    }

    @Test("the first accepted incident cannot be replaced before its worker starts")
    func firstSubmissionIsReservedSynchronously() {
        let workerQueue = DispatchQueue(
            label: "yunaudio.test.incident.reserved-worker")
        workerQueue.suspend()
        let probe = IncidentWriterProbe()
        let writer = LatestAudioIncidentWriter(
            operations: .init(write: probe.write),
            label: "yunaudio.test.incident.reserved",
            workerQueue: workerQueue)
        #expect(writer.submit(fixture(1)))
        #expect(writer.submit(fixture(2)))
        workerQueue.resume()

        #expect(probe.began.wait(timeout: .now() + TestGate.deadlock) == .success)
        probe.release.signal()
        let result = IncidentWriterResultBox()
        let completed = DispatchSemaphore(value: 0)
        writer.flush(timeout: .seconds(1)) {
            result.store($0)
            completed.signal()
        }
        #expect(completed.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(result.result == .complete)
        #expect(probe.values == [1, 2])
    }

    @Test("shutdown drains evidence accepted before admission closed")
    func shutdownPreservesPendingEvidence() {
        let gate = DispatchSemaphore(value: 0)
        let writer = LatestAudioIncidentWriter(
            operations: .init { _ in
                gate.wait()
                return true
            },
            label: "yunaudio.test.incident-writer.shutdown")
        #expect(writer.submit(fixture(9)))
        writer.shutdown()
        gate.signal()

        let result = IncidentWriterResultBox()
        let completed = DispatchSemaphore(value: 0)
        writer.flush(timeout: .seconds(1)) {
            result.store($0)
            completed.signal()
        }
        #expect(completed.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(result.result == .complete)
        #expect(writer.statistics.writes == 1)
    }

    @Test("secure replacement is private from its first inode")
    func secureReplacementHasPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-incident-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("last.json")
        let first = try AudioIncidentBundleCodec.encode(fixture(11))
        let second = try AudioIncidentBundleCodec.encode(fixture(12))

        #expect(
            LatestAudioIncidentWriter.Operations.secureAtomicWrite(
                first, to: destination))
        #expect(
            LatestAudioIncidentWriter.Operations.secureAtomicWrite(
                second, to: destination))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
        #expect(try Data(contentsOf: destination) == second)
    }

    @Test("a blocked write retains only the newest pending incident")
    func firstAndLatestAreBounded() throws {
        let probe = IncidentWriterProbe()
        let writer = LatestAudioIncidentWriter(
            operations: .init(write: probe.write),
            label: "yunaudio.test.incident.first-latest")

        #expect(writer.submit(fixture(1)))
        #expect(probe.began.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(writer.submit(fixture(2)))
        #expect(writer.submit(fixture(3)))
        probe.release.signal()

        let result = IncidentWriterResultBox()
        let completed = DispatchSemaphore(value: 0)
        writer.flush(timeout: .seconds(1)) {
            result.store($0)
            completed.signal()
        }
        #expect(completed.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(result.result == .complete)
        #expect(probe.values == [1, 3])
        #expect(writer.statistics.submissions == 3)
        #expect(writer.statistics.coalesced == 1)
        #expect(writer.statistics.writes == 2)
        #expect(writer.statistics.maximumPending == 1)
    }

    @Test("a flush timeout does not start a replacement writer")
    func timeoutLeavesOneOwner() throws {
        let probe = IncidentWriterProbe()
        let writer = LatestAudioIncidentWriter(
            operations: .init(write: probe.write),
            label: "yunaudio.test.incident.timeout")
        #expect(writer.submit(fixture(1)))
        #expect(probe.began.wait(timeout: .now() + TestGate.deadlock) == .success)

        let result = IncidentWriterResultBox()
        let completed = DispatchSemaphore(value: 0)
        writer.flush(timeout: .milliseconds(20)) {
            result.store($0)
            completed.signal()
        }
        #expect(completed.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(result.result == .timedOut)
        #expect(writer.statistics.writes == 0)
        #expect(writer.statistics.flushTimeouts == 1)

        probe.release.signal()
        for _ in 0..<1_000 where writer.statistics.writes == 0 {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(writer.statistics.writes == 1)
        #expect(probe.values == [1])
    }

    @Test("an admitted critical write cannot be coalesced or replaced")
    func criticalWriteHasReservedPendingSlot() {
        let workerQueue = DispatchQueue(
            label: "yunaudio.test.incident.critical-reservation")
        workerQueue.suspend()
        let written = IncidentWriterProbe()
        let writer = LatestAudioIncidentWriter(
            operations: .init(write: written.write),
            label: "yunaudio.test.incident.critical-reservation",
            workerQueue: workerQueue)

        #expect(writer.submit(fixture(1)))
        let admitted = writer.submitCritical(fixture(2))
        #expect(!writer.submit(fixture(3)))
        let refused = writer.submitCritical(fixture(4))
        workerQueue.resume()

        #expect(written.began.wait(timeout: .now() + TestGate.deadlock) == .success)
        written.release.signal()

        #expect(refused.wait(timeout: .zero) == .refused)
        #expect(admitted.wait(timeout: .seconds(2)) == .persisted)
        #expect(written.values == [1, 2])
        #expect(writer.statistics.submissions == 2)
        #expect(writer.statistics.coalesced == 0)
        #expect(writer.statistics.writes == 2)
        #expect(writer.statistics.maximumPending == 1)
    }

    @Test("a critical receipt reports its own failure despite a newer success")
    func criticalFailureIsNotMaskedByGeneration() {
        let began = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let written = IncidentWriterProbe()
        let writer = LatestAudioIncidentWriter(
            operations: .init { bundle in
                if bundle.runID.low == 21 {
                    began.signal()
                    _ = release.wait(timeout: .now() + TestGate.deadlock)
                    return false
                }
                return written.write(bundle)
            },
            label: "yunaudio.test.incident.critical-failure")
        let receipt = writer.submitCritical(fixture(21))
        #expect(began.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(writer.submit(fixture(22)))
        release.signal()

        #expect(receipt.wait(timeout: .seconds(2)) == .writeFailed)
        let flush = IncidentWriterResultBox()
        let flushed = DispatchSemaphore(value: 0)
        writer.flush(timeout: .seconds(1)) {
            flush.store($0)
            flushed.signal()
        }
        #expect(flushed.wait(timeout: .now() + TestGate.deadlock) == .success)

        #expect(flush.result == .complete)
        #expect(written.values == [22])
        #expect(writer.statistics.writes == 2)
    }

    @Test("a timed-out critical receipt completes exactly once")
    func criticalTimeoutDoesNotBecomeLateSuccess() {
        let began = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = LatestAudioIncidentWriter(
            operations: .init { _ in
                began.signal()
                _ = release.wait(timeout: .now() + TestGate.deadlock)
                return true
            },
            label: "yunaudio.test.incident.critical-timeout")
        let receipt = writer.submitCritical(fixture(31))
        #expect(began.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(receipt.wait(timeout: .milliseconds(20)) == .timedOut)

        release.signal()
        let flush = IncidentWriterResultBox()
        let flushed = DispatchSemaphore(value: 0)
        writer.flush(timeout: .seconds(1)) {
            flush.store($0)
            flushed.signal()
        }
        #expect(flushed.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(flush.result == .complete)
        #expect(receipt.wait(timeout: .zero) == .timedOut)
        #expect(writer.statistics.writes == 1)
    }

    @Test("a pending timed-out checkpoint retains its same-run terminal evidence")
    func timedOutPendingCheckpointQueuesTerminalEvidence() {
        let probe = IncidentPhaseProbe(blockedRun: 1)
        let writer = LatestAudioIncidentWriter(
            operations: .init(write: probe.write),
            label: "yunaudio.test.incident.pending-critical-timeout")
        #expect(writer.submit(fixture(1, started: 10, ended: 11)))
        #expect(probe.began.wait(timeout: .now() + TestGate.deadlock) == .success)

        let checkpoint = writer.submitCritical(
            fixture(2, teardownStatus: .notObserved, started: 20, ended: 21))
        #expect(checkpoint.wait(timeout: .milliseconds(20)) == .timedOut)
        #expect(writer.submit(fixture(2, started: 20, ended: 30)))
        #expect(writer.statistics.maximumPending == 2)
        probe.release.signal()

        let flush = IncidentWriterResultBox()
        let flushed = DispatchSemaphore(value: 0)
        writer.flush(timeout: .seconds(1)) {
            flush.store($0)
            flushed.signal()
        }
        #expect(flushed.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(flush.result == .complete)
        #expect(checkpoint.wait(timeout: .zero) == .timedOut)
        #expect(probe.values.map(\.runID.low) == [1, 2, 2])
        #expect(probe.values.map(\.teardownStatus) == [.complete, .notObserved, .complete])
        #expect(writer.statistics.submissions == 3)
        #expect(writer.statistics.writes == 3)
    }

    @Test("persisted is delivered only after the atomic destination exists")
    func criticalPersistenceAcknowledgesRename() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-critical-incident-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("last.json")
        let writer = LatestAudioIncidentWriter(
            operations: .init { bundle in
                guard let data = try? AudioIncidentBundleCodec.encode(bundle) else {
                    return false
                }
                return LatestAudioIncidentWriter.Operations.secureAtomicWrite(
                    data, to: destination)
            },
            label: "yunaudio.test.incident.critical-persisted")
        let receipt = writer.submitCritical(fixture(41))

        #expect(receipt.wait(timeout: .seconds(2)) == .persisted)
        let data = try Data(contentsOf: destination)
        #expect(try AudioIncidentBundleCodec.decode(data).runID.low == 41)

        writer.shutdown()
        let refused = writer.submitCritical(fixture(42))
        #expect(refused.wait(timeout: .zero) == .refused)
        #expect(try Data(contentsOf: destination) == data)
    }

    @Test("a persisted final cannot be replaced by its run's late live checkpoint")
    func finalPhaseRemainsMonotonicAfterTheWriterDrains() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-incident-phase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("last.json")
        let writer = LatestAudioIncidentWriter(
            operations: .init { bundle in
                guard let data = try? AudioIncidentBundleCodec.encode(bundle) else {
                    return false
                }
                return LatestAudioIncidentWriter.Operations.secureAtomicWrite(
                    data, to: destination)
            },
            label: "yunaudio.test.incident.phase-monotonic")

        #expect(writer.submit(fixture(51)))
        let firstFlush = IncidentWriterResultBox()
        let firstCompleted = DispatchSemaphore(value: 0)
        writer.flush(timeout: .seconds(1)) {
            firstFlush.store($0)
            firstCompleted.signal()
        }
        #expect(firstCompleted.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(firstFlush.result == .complete)

        let finalData = try Data(contentsOf: destination)
        #expect(!writer.submit(fixture(51, teardownStatus: .notObserved)))
        let afterLateCheckpoint = try Data(contentsOf: destination)
        #expect(afterLateCheckpoint == finalData)
        let persisted = try AudioIncidentBundleCodec.decode(afterLateCheckpoint)
        #expect(persisted.runID == AudioIncidentRunID(high: 0, low: 51))
        #expect(persisted.teardownStatus == .complete)
        #expect(writer.statistics.submissions == 1)
        #expect(writer.statistics.writes == 1)
    }

    @Test("another run's critical checkpoint may queue behind an active final")
    func phaseGuardIsScopedToOneRun() {
        let probe = IncidentPhaseProbe(blockedRun: 61)
        let writer = LatestAudioIncidentWriter(
            operations: .init(write: probe.write),
            label: "yunaudio.test.incident.phase-run-scope")

        #expect(writer.submit(fixture(61, started: 10, ended: 11)))
        #expect(probe.began.wait(timeout: .now() + TestGate.deadlock) == .success)
        let nextRun = writer.submitCritical(
            fixture(
                62, teardownStatus: .notObserved,
                started: 20, ended: 21))
        probe.release.signal()

        #expect(nextRun.wait(timeout: .seconds(2)) == .persisted)
        let written = probe.values
        #expect(written.count == 2)
        #expect(written[0].runID == AudioIncidentRunID(high: 0, low: 61))
        #expect(written[0].teardownStatus == .complete)
        #expect(written[1].runID == AudioIncidentRunID(high: 0, low: 62))
        #expect(written[1].teardownStatus == .notObserved)
        #expect(writer.statistics.submissions == 2)
        #expect(writer.statistics.writes == 2)
        #expect(writer.statistics.maximumPending == 1)
    }

    @Test("a newer run frontier rejects every late phase of the previous run")
    func newerRunRemainsTheAcceptedFrontier() {
        let workerQueue = DispatchQueue(
            label: "yunaudio.test.incident.accepted-run-frontier")
        workerQueue.suspend()
        let probe = IncidentPhaseProbe()
        let writer = LatestAudioIncidentWriter(
            operations: .init(write: probe.write),
            label: "yunaudio.test.incident.accepted-run-frontier",
            workerQueue: workerQueue)

        #expect(writer.submit(fixture(71, started: 10, ended: 15)))
        let nextRun = writer.submitCritical(
            fixture(
                72, teardownStatus: .notObserved,
                started: 20, ended: 21))
        #expect(
            !writer.submit(
                fixture(
                    71, teardownStatus: .notObserved,
                    started: 10, ended: 16)))
        #expect(
            !writer.submit(
                fixture(
                    71, teardownStatus: .incomplete,
                    started: 10, ended: 17)))
        workerQueue.resume()

        #expect(nextRun.wait(timeout: .seconds(2)) == .persisted)
        let written = probe.values
        #expect(written.map(\.runID.low) == [71, 72])
        #expect(written.last?.runID == AudioIncidentRunID(high: 0, low: 72))
        #expect(written.last?.teardownStatus == .notObserved)
        #expect(writer.statistics.submissions == 2)
        #expect(writer.statistics.writes == 2)
    }

    @Test("one phase cannot move backwards in observation time")
    func samePhaseEndedTimeIsMonotonic() {
        let workerQueue = DispatchQueue(
            label: "yunaudio.test.incident.accepted-time-frontier")
        workerQueue.suspend()
        let probe = IncidentPhaseProbe()
        let writer = LatestAudioIncidentWriter(
            operations: .init(write: probe.write),
            label: "yunaudio.test.incident.accepted-time-frontier",
            workerQueue: workerQueue)

        let newest = writer.submitCritical(
            fixture(
                81, teardownStatus: .notObserved,
                started: 10, ended: 20))
        #expect(
            !writer.submit(
                fixture(
                    81, teardownStatus: .notObserved,
                    started: 10, ended: 10)))
        workerQueue.resume()

        #expect(newest.wait(timeout: .seconds(2)) == .persisted)
        #expect(probe.values.count == 1)
        #expect(probe.values.first?.endedUptimeNanoseconds == 20)
        #expect(writer.statistics.submissions == 1)
        #expect(writer.statistics.writes == 1)
    }

    @Test("an equal-time duplicate cannot replace accepted evidence")
    func equalObservationTimeIsNotRewritten() {
        let writer = LatestAudioIncidentWriter(
            operations: .init { _ in true },
            label: "yunaudio.test.incident.equal-observation")
        let bundle = fixture(
            82, teardownStatus: .notObserved, started: 10, ended: 20)

        #expect(writer.submit(bundle))
        #expect(!writer.submit(bundle))
        let flush = IncidentWriterResultBox()
        let flushed = DispatchSemaphore(value: 0)
        writer.flush(timeout: .seconds(1)) {
            flush.store($0)
            flushed.signal()
        }
        #expect(flushed.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(flush.result == .complete)
        #expect(writer.statistics.submissions == 1)
        #expect(writer.statistics.writes == 1)
    }

    @Test("a failed final write still advances the accepted phase frontier")
    func failedWriteCannotReopenAnOlderPhase() {
        let writer = LatestAudioIncidentWriter(
            operations: .init { _ in false },
            label: "yunaudio.test.incident.failed-write-frontier")

        let final = writer.submitCritical(
            fixture(91, started: 10, ended: 20))
        #expect(final.wait(timeout: .seconds(2)) == .writeFailed)
        #expect(
            !writer.submit(
                fixture(
                    91, teardownStatus: .notObserved,
                    started: 10, ended: 21)))
        #expect(writer.statistics.submissions == 1)
        #expect(writer.statistics.writes == 1)
        #expect(writer.statistics.failures == 1)
    }

    private func fixture(
        _ run: UInt64,
        teardownStatus: AudioIncidentTeardownStatus = .complete,
        started: UInt64? = nil,
        ended: UInt64? = nil
    ) -> AudioIncidentBundle {
        let started = started ?? run
        let ended = ended ?? started &+ 1
        var log = AudioIncidentTeardownLog()
        if teardownStatus == .complete {
            for (ordinal, step) in [
                AudioIncidentTeardownStep.callbackFence,
                .driverHealthRead,
                .halCensusComplete,
            ].enumerated() {
                log.append(
                    AudioIncidentTeardownRecord(
                        ordinal: UInt8(ordinal),
                        graphGeneration: 1,
                        step: step,
                        outcome: .completed,
                        status: 0,
                        elapsedNanoseconds: 10,
                        deadlineNanoseconds: 1_000))
            }
        }
        return AudioIncidentBundle(
            runID: AudioIncidentRunID(high: 0, low: run),
            startedUptimeNanoseconds: started,
            endedUptimeNanoseconds: ended,
            firstGraphGeneration: 1,
            finalGraphGeneration: 1,
            pathReportedBitExact: false,
            driverHealth: AudioIncidentDriverHealth(
                state: .driverAbsent,
                wasRequired: false,
                readStatus: 0,
                unsafeReadOperations: 0,
                unsafeWriteOperations: 0),
            callbacks: AudioIncidentCallbackSnapshot(
                collection:
                    teardownStatus == .notObserved
                    ? .liveBestEffort : .postFenceCoherent,
                samples: 1,
                p50Nanoseconds: 100,
                p999Nanoseconds: 100,
                p99999Nanoseconds: 100,
                maximumNanoseconds: 100,
                deadlineNanoseconds: 2_000_000,
                overflowSamples: 0,
                missedDeadlines: 0,
                callbackOverlaps: 0,
                allocationViolations: 0,
                maximumUpdateContentions: 0),
            teardownStatus: teardownStatus,
            teardownLog: log,
            residueBaseline: AudioIncidentResidueSnapshot(
                retainedEntries: 0,
                maximumRetainedEntries: 0,
                cleanupAttempts: 0,
                scheduledRetries: 0,
                exhaustedEntries: 0,
                completedEntries: 0,
                deniedAdmissions: 0),
            residue: AudioIncidentResidueSnapshot(
                retainedEntries: 0,
                maximumRetainedEntries: 0,
                cleanupAttempts: 0,
                scheduledRetries: 0,
                exhaustedEntries: 0,
                completedEntries: 0,
                deniedAdmissions: 0))
    }
}
