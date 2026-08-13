import CoreAudio
import Foundation
import YunAudioHAL
import YunAudioRT

/// A route-run identity which has exactly sixteen bytes and no user-supplied text.
///
/// The printable form is thirty-two lower-case hexadecimal characters. Keeping
/// it numeric prevents a filename, device name, transcript or token from being
/// smuggled into a field intended only to correlate bounded diagnostics.
public struct AudioIncidentRunID: Sendable, Hashable, Codable {
    public let high: UInt64
    public let low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    public init?(_ text: String) {
        guard text.utf8.count == 32,
            text.utf8.allSatisfy({ byte in
                (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
            }),
            let high = UInt64(text.prefix(16), radix: 16),
            let low = UInt64(text.suffix(16), radix: 16)
        else { return nil }
        self.init(high: high, low: low)
    }

    public var text: String {
        String(format: "%016llx%016llx", high, low)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = Self(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "run ID must be thirty-two lower-case hexadecimal bytes")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// Whether the driver's fixed health property was available for this run.
public enum AudioIncidentDriverHealthState: String, Sendable, Codable {
    case available
    case driverAbsent
    case propertyUnavailable
    case readFailed
}

/// Driver counters have no device identity and no content-bearing fields.
public struct AudioIncidentDriverHealth: Sendable, Equatable, Codable {
    public let state: AudioIncidentDriverHealthState
    public let wasRequired: Bool
    public let readStatus: Int32
    public let unsafeReadOperations: UInt64
    public let unsafeWriteOperations: UInt64
    public let unsafeReadStartFrame: UInt64?
    public let unsafeReadFrameCount: UInt64?
    public let unsafeReadUnavailableFrame: UInt64?
    public let lastPublishedStartFrame: UInt64?
    public let lastPublishedFrameCount: UInt64?

    public init(
        state: AudioIncidentDriverHealthState,
        wasRequired: Bool,
        readStatus: Int32,
        unsafeReadOperations: UInt64,
        unsafeWriteOperations: UInt64,
        unsafeReadStartFrame: UInt64? = nil,
        unsafeReadFrameCount: UInt64? = nil,
        unsafeReadUnavailableFrame: UInt64? = nil,
        lastPublishedStartFrame: UInt64? = nil,
        lastPublishedFrameCount: UInt64? = nil
    ) {
        self.state = state
        self.wasRequired = wasRequired
        self.readStatus = readStatus
        self.unsafeReadOperations = unsafeReadOperations
        self.unsafeWriteOperations = unsafeWriteOperations
        self.unsafeReadStartFrame = unsafeReadStartFrame
        self.unsafeReadFrameCount = unsafeReadFrameCount
        self.unsafeReadUnavailableFrame = unsafeReadUnavailableFrame
        self.lastPublishedStartFrame = lastPublishedStartFrame
        self.lastPublishedFrameCount = lastPublishedFrameCount
    }

    var hasFault: Bool {
        unsafeReadOperations > 0 || unsafeWriteOperations > 0
    }

    var isConclusive: Bool {
        state == .available || (state == .driverAbsent && !wasRequired)
    }

    var hasValidShape: Bool {
        switch state {
        case .available:
            readStatus == 0 && hasValidUnsafeReadEvidence
        case .driverAbsent:
            !wasRequired && readStatus == 0 && unsafeReadOperations == 0
                && unsafeWriteOperations == 0 && hasNoUnsafeReadEvidence
        case .propertyUnavailable:
            readStatus == 0 && unsafeReadOperations == 0 && unsafeWriteOperations == 0
                && hasNoUnsafeReadEvidence
        case .readFailed:
            readStatus != 0 && unsafeReadOperations == 0
                && unsafeWriteOperations == 0 && hasNoUnsafeReadEvidence
        }
    }

    private var hasNoUnsafeReadEvidence: Bool {
        unsafeReadStartFrame == nil && unsafeReadFrameCount == nil
            && unsafeReadUnavailableFrame == nil && lastPublishedStartFrame == nil
            && lastPublishedFrameCount == nil
    }

    private var hasValidUnsafeReadEvidence: Bool {
        if hasNoUnsafeReadEvidence { return true }
        guard unsafeReadOperations > 0,
            let start = unsafeReadStartFrame,
            let count = unsafeReadFrameCount,
            let unavailable = unsafeReadUnavailableFrame,
            let publishedStart = lastPublishedStartFrame,
            let publishedCount = lastPublishedFrameCount,
            count > 0,
            publishedCount > 0,
            start <= UInt64.max - count,
            publishedStart <= UInt64.max - publishedCount
        else { return false }
        return unavailable >= start && unavailable < start + count
    }

    /// Converts process-lifetime driver counters into one route's delta.
    ///
    /// A driver reload or a property changing shape makes attribution
    /// impossible. That is `readFailed`, never a convenient zero delta.
    static func routeDelta(
        from baseline: AudioIncidentDriverHealth,
        to final: AudioIncidentDriverHealth
    ) -> AudioIncidentDriverHealth {
        let wasRequired = baseline.wasRequired || final.wasRequired
        guard baseline.wasRequired == final.wasRequired else {
            return .unattributable(wasRequired: wasRequired)
        }
        switch (baseline.state, final.state) {
        case (.available, .available):
            guard final.unsafeReadOperations >= baseline.unsafeReadOperations,
                final.unsafeWriteOperations >= baseline.unsafeWriteOperations
            else { return .unattributable(wasRequired: wasRequired) }
            let unsafeReadDelta =
                final.unsafeReadOperations - baseline.unsafeReadOperations
            return AudioIncidentDriverHealth(
                state: .available,
                wasRequired: wasRequired,
                readStatus: 0,
                unsafeReadOperations: unsafeReadDelta,
                unsafeWriteOperations:
                    final.unsafeWriteOperations - baseline.unsafeWriteOperations,
                unsafeReadStartFrame:
                    unsafeReadDelta > 0 ? final.unsafeReadStartFrame : nil,
                unsafeReadFrameCount:
                    unsafeReadDelta > 0 ? final.unsafeReadFrameCount : nil,
                unsafeReadUnavailableFrame:
                    unsafeReadDelta > 0 ? final.unsafeReadUnavailableFrame : nil,
                lastPublishedStartFrame:
                    unsafeReadDelta > 0 ? final.lastPublishedStartFrame : nil,
                lastPublishedFrameCount:
                    unsafeReadDelta > 0 ? final.lastPublishedFrameCount : nil)
        case (.driverAbsent, .driverAbsent) where !wasRequired:
            return AudioIncidentDriverHealth(
                state: .driverAbsent, wasRequired: false, readStatus: 0,
                unsafeReadOperations: 0, unsafeWriteOperations: 0)
        case (.propertyUnavailable, .propertyUnavailable):
            return AudioIncidentDriverHealth(
                state: .propertyUnavailable, wasRequired: wasRequired, readStatus: 0,
                unsafeReadOperations: 0, unsafeWriteOperations: 0)
        case (.readFailed, _):
            return .unattributable(
                wasRequired: wasRequired, status: baseline.readStatus)
        case (_, .readFailed):
            return .unattributable(
                wasRequired: wasRequired, status: final.readStatus)
        default:
            return .unattributable(wasRequired: wasRequired)
        }
    }

    private static func unattributable(
        wasRequired: Bool,
        status: Int32 = kAudioHardwareUnspecifiedError
    ) -> AudioIncidentDriverHealth {
        AudioIncidentDriverHealth(
            state: .readFailed,
            wasRequired: wasRequired,
            readStatus: status == 0 ? kAudioHardwareUnspecifiedError : status,
            unsafeReadOperations: 0,
            unsafeWriteOperations: 0)
    }
}

/// The lifetime boundary under which callback counters were read.
public enum AudioIncidentCallbackCollection: String, Sendable, Codable {
    /// Atomics were read while callbacks could still advance them.
    case liveBestEffort
    /// IOProc or Audio Unit destruction proved every writer unreachable first.
    case postFenceCoherent
}

/// Fixed callback-tail evidence for one route run.
public struct AudioIncidentCallbackSnapshot: Sendable, Equatable, Codable {
    public let collection: AudioIncidentCallbackCollection
    public let samples: UInt64
    public let p50Nanoseconds: UInt64
    public let p999Nanoseconds: UInt64
    public let p99999Nanoseconds: UInt64
    public let maximumNanoseconds: UInt64
    public let deadlineNanoseconds: UInt64
    public let overflowSamples: UInt64
    public let missedDeadlines: UInt64
    public let callbackOverlaps: UInt64
    public let allocationViolations: UInt64
    public let maximumUpdateContentions: UInt64

    public init(
        collection: AudioIncidentCallbackCollection,
        samples: UInt64,
        p50Nanoseconds: UInt64,
        p999Nanoseconds: UInt64,
        p99999Nanoseconds: UInt64,
        maximumNanoseconds: UInt64,
        deadlineNanoseconds: UInt64,
        overflowSamples: UInt64,
        missedDeadlines: UInt64,
        callbackOverlaps: UInt64,
        allocationViolations: UInt64,
        maximumUpdateContentions: UInt64
    ) {
        self.collection = collection
        self.samples = samples
        self.p50Nanoseconds = p50Nanoseconds
        self.p999Nanoseconds = p999Nanoseconds
        self.p99999Nanoseconds = p99999Nanoseconds
        self.maximumNanoseconds = maximumNanoseconds
        self.deadlineNanoseconds = deadlineNanoseconds
        self.overflowSamples = overflowSamples
        self.missedDeadlines = missedDeadlines
        self.callbackOverlaps = callbackOverlaps
        self.allocationViolations = allocationViolations
        self.maximumUpdateContentions = maximumUpdateContentions
    }

    /// Converts the C collector without introducing a second interpretation of
    /// its coherence bit. The collector itself remains route-owned.
    public init(_ snapshot: YunRTIncidentCallbackSnapshot) {
        self.init(
            collection: snapshot.isCoherent ? .postFenceCoherent : .liveBestEffort,
            samples: snapshot.samples,
            p50Nanoseconds: snapshot.p50Nanoseconds,
            p999Nanoseconds: snapshot.p999Nanoseconds,
            p99999Nanoseconds: snapshot.p99999Nanoseconds,
            maximumNanoseconds: snapshot.maximumNanoseconds,
            deadlineNanoseconds: snapshot.deadlineNanoseconds,
            overflowSamples: snapshot.overflowSamples,
            missedDeadlines: snapshot.missedDeadlines,
            callbackOverlaps: snapshot.callbackOverlaps,
            allocationViolations: snapshot.allocationViolations,
            maximumUpdateContentions: snapshot.maximumUpdateContentions)
    }

    var hasFault: Bool {
        missedDeadlines > 0 || callbackOverlaps > 0 || allocationViolations > 0
            || maximumUpdateContentions > 0 || exceedsTailBudget
    }

    var hasValidShape: Bool {
        deadlineNanoseconds > 0 && deadlineNanoseconds < .max
            && (samples > 0
                || (p50Nanoseconds == 0 && p999Nanoseconds == 0
                    && p99999Nanoseconds == 0 && maximumNanoseconds == 0
                    && overflowSamples == 0 && missedDeadlines == 0))
            && p50Nanoseconds <= p999Nanoseconds
            && p999Nanoseconds <= p99999Nanoseconds
            && p99999Nanoseconds <= maximumNanoseconds
            && overflowSamples <= samples && missedDeadlines <= samples
            && ((maximumNanoseconds > deadlineNanoseconds) == (missedDeadlines > 0))
    }

    var exceedsTailBudget: Bool {
        guard deadlineNanoseconds > 0, deadlineNanoseconds < .max else { return false }
        return p999Nanoseconds > deadlineNanoseconds / 4
            || p99999Nanoseconds > deadlineNanoseconds / 2
    }
}

/// One fixed vocabulary for teardown progress. It intentionally carries no UID.
public enum AudioIncidentTeardownStep: String, Sendable, Codable {
    case routeTeardownStarted
    case admissionStopped
    case ioProcStopped
    case ioProcDestroyed
    case callbackFence
    case echoCancellationDisposed
    case audioUnitDisposed
    case aggregateDestroyed
    case processTapDestroyed
    case ownersReleased
    case sampleRatesRestored
    case driverHealthRead
    case halCensusComplete
}

public enum AudioIncidentTeardownOutcome: String, Sendable, Codable {
    case completed
    case requestFailed
    case timedOut
    case retained
    case skipped
}

/// One bounded lifecycle observation, tied to the graph generation it acted on.
public struct AudioIncidentTeardownRecord: Sendable, Equatable, Codable {
    public let ordinal: UInt8
    public let graphGeneration: UInt64
    public let step: AudioIncidentTeardownStep
    public let outcome: AudioIncidentTeardownOutcome
    public let status: Int32
    public let elapsedNanoseconds: UInt64
    public let deadlineNanoseconds: UInt64

    public init(
        ordinal: UInt8,
        graphGeneration: UInt64,
        step: AudioIncidentTeardownStep,
        outcome: AudioIncidentTeardownOutcome,
        status: Int32,
        elapsedNanoseconds: UInt64,
        deadlineNanoseconds: UInt64
    ) {
        self.ordinal = ordinal
        self.graphGeneration = graphGeneration
        self.step = step
        self.outcome = outcome
        self.status = status
        self.elapsedNanoseconds = elapsedNanoseconds
        self.deadlineNanoseconds = deadlineNanoseconds
    }
}

/// Fixed-capacity control-side storage for lifecycle steps.
///
/// Teardown has at most a few dozen semantic steps, but malformed tap state or
/// a retry loop must not turn diagnostics into an unbounded log. Submissions
/// after the thirty-second record increment one saturating counter and retain
/// no text or additional storage.
public struct AudioIncidentTeardownLog: Sendable, Equatable {
    public private(set) var records: [AudioIncidentTeardownRecord]
    public private(set) var droppedRecords: UInt64

    public init() {
        records = []
        records.reserveCapacity(AudioIncidentBundle.maximumTeardownRecords)
        droppedRecords = 0
    }

    @discardableResult
    public mutating func append(_ record: AudioIncidentTeardownRecord) -> Bool {
        guard records.count < AudioIncidentBundle.maximumTeardownRecords else {
            droppedRecords = droppedRecords.addingSaturated(1)
            return false
        }
        records.append(record)
        return true
    }

    mutating func noteDroppedRecords(_ count: UInt64) {
        droppedRecords = droppedRecords.addingSaturated(count)
    }
}

public enum AudioIncidentTeardownStatus: String, Sendable, Codable {
    case complete
    case incomplete
    case timedOut
    case notObserved
}

/// Fixed ownership milestones crossed during one route construction.
///
/// Booleans keep the representation closed and privacy-free while making a
/// pre-callback hang distinguishable from a run which never entered Core Audio.
public struct AudioIncidentResourceSnapshot: Sendable, Equatable, Codable {
    public let processTapCallEntered: Bool
    public let hadEchoCancellation: Bool
    public let hadAudioUnits: Bool
    public let hadAggregate: Bool
    public let hadProcessTaps: Bool
    public let changedSampleRates: Bool

    public init(
        processTapCallEntered: Bool = false,
        hadEchoCancellation: Bool,
        hadAudioUnits: Bool,
        hadAggregate: Bool,
        hadProcessTaps: Bool,
        changedSampleRates: Bool
    ) {
        self.processTapCallEntered = processTapCallEntered
        self.hadEchoCancellation = hadEchoCancellation
        self.hadAudioUnits = hadAudioUnits
        self.hadAggregate = hadAggregate
        self.hadProcessTaps = hadProcessTaps
        self.changedSampleRates = changedSampleRates
    }

    public static let none = AudioIncidentResourceSnapshot(
        processTapCallEntered: false,
        hadEchoCancellation: false,
        hadAudioUnits: false,
        hadAggregate: false,
        hadProcessTaps: false,
        changedSampleRates: false)
}

/// Numeric quarantine state only; owner references and reason strings never cross this boundary.
public struct AudioIncidentResidueSnapshot: Sendable, Equatable, Codable {
    public let retainedEntries: UInt32
    public let maximumRetainedEntries: UInt32
    public let cleanupAttempts: UInt64
    public let scheduledRetries: UInt32
    public let exhaustedEntries: UInt32
    public let completedEntries: UInt64
    public let deniedAdmissions: UInt64

    public init(
        retainedEntries: UInt32,
        maximumRetainedEntries: UInt32,
        cleanupAttempts: UInt64,
        scheduledRetries: UInt32,
        exhaustedEntries: UInt32,
        completedEntries: UInt64,
        deniedAdmissions: UInt64
    ) {
        self.retainedEntries = retainedEntries
        self.maximumRetainedEntries = maximumRetainedEntries
        self.cleanupAttempts = cleanupAttempts
        self.scheduledRetries = scheduledRetries
        self.exhaustedEntries = exhaustedEntries
        self.completedEntries = completedEntries
        self.deniedAdmissions = deniedAdmissions
    }

    public init(_ telemetry: AudioResidueTelemetry) {
        self.init(
            retainedEntries: UInt32(clamping: telemetry.retainedEntries),
            maximumRetainedEntries: UInt32(clamping: telemetry.maximumRetainedEntries),
            cleanupAttempts: telemetry.cleanupAttempts,
            scheduledRetries: UInt32(clamping: telemetry.scheduledRetries),
            exhaustedEntries: UInt32(clamping: telemetry.exhaustedEntries),
            completedEntries: telemetry.completedEntries,
            deniedAdmissions: telemetry.deniedAdmissions)
    }

    /// Whether this final snapshot contains an event attributable to the run.
    ///
    /// The quarantine counters are process-lifetime. Grading their absolute
    /// values made every clean route after one recovered incident look faulty.
    /// Keeping both exact snapshots avoids inventing a per-route maximum while
    /// still detecting a retained owner, cleanup, completion or refusal.
    func encounteredResidue(since baseline: Self) -> Bool {
        retainedEntries > baseline.retainedEntries
            || maximumRetainedEntries > baseline.maximumRetainedEntries
            || cleanupAttempts > baseline.cleanupAttempts
            || scheduledRetries > baseline.scheduledRetries
            || exhaustedEntries > baseline.exhaustedEntries
            || completedEntries > baseline.completedEntries
            || deniedAdmissions > baseline.deniedAdmissions
    }

    var hasValidShape: Bool {
        retainedEntries <= maximumRetainedEntries
            && UInt64(scheduledRetries) + UInt64(exhaustedEntries)
                <= UInt64(retainedEntries)
            && completedEntries <= cleanupAttempts
    }

    var isValidRouteBaseline: Bool {
        hasValidShape && retainedEntries == 0 && scheduledRetries == 0
            && exhaustedEntries == 0
    }

    func isMonotonic(after baseline: Self) -> Bool {
        retainedEntries >= baseline.retainedEntries
            && maximumRetainedEntries >= baseline.maximumRetainedEntries
            && cleanupAttempts >= baseline.cleanupAttempts
            && scheduledRetries >= baseline.scheduledRetries
            && exhaustedEntries >= baseline.exhaustedEntries
            && completedEntries >= baseline.completedEntries
            && deniedAdmissions >= baseline.deniedAdmissions
    }
}

public enum AudioIncidentHealthVerdict: String, Sendable, Codable {
    case healthy
    case faulted
    case indeterminate
}

/// One privacy-minimised, byte-bounded route incident.
///
/// The type has no text field beyond fixed enums and the sixteen-byte run ID.
/// It therefore cannot contain PCM, lyrics, transcription, device names, file
/// paths, tokens or arbitrary log messages by construction.
public struct AudioIncidentBundle: Sendable, Equatable, Codable {
    public static let schemaVersion: UInt8 = 3
    public static let maximumTeardownRecords = 32

    public let runID: AudioIncidentRunID
    public let startedUptimeNanoseconds: UInt64
    public let endedUptimeNanoseconds: UInt64
    public let firstGraphGeneration: UInt64
    public let finalGraphGeneration: UInt64
    public let pathReportedBitExact: Bool
    public let resources: AudioIncidentResourceSnapshot
    public let driverHealth: AudioIncidentDriverHealth
    public let callbacks: AudioIncidentCallbackSnapshot
    public let teardownStatus: AudioIncidentTeardownStatus
    public let teardownRecords: [AudioIncidentTeardownRecord]
    public let droppedTeardownRecords: UInt64
    public let residueBaseline: AudioIncidentResidueSnapshot
    public let residue: AudioIncidentResidueSnapshot

    public init(
        runID: AudioIncidentRunID,
        startedUptimeNanoseconds: UInt64,
        endedUptimeNanoseconds: UInt64,
        firstGraphGeneration: UInt64,
        finalGraphGeneration: UInt64,
        pathReportedBitExact: Bool,
        resources: AudioIncidentResourceSnapshot = .none,
        driverHealth: AudioIncidentDriverHealth,
        callbacks: AudioIncidentCallbackSnapshot,
        teardownStatus: AudioIncidentTeardownStatus,
        teardownRecords: [AudioIncidentTeardownRecord],
        droppedTeardownRecords: UInt64 = 0,
        residueBaseline: AudioIncidentResidueSnapshot,
        residue: AudioIncidentResidueSnapshot
    ) {
        let retainedRecords = teardownRecords.prefix(Self.maximumTeardownRecords)
        let newlyDropped = UInt64(teardownRecords.count - retainedRecords.count)
        self.runID = runID
        self.startedUptimeNanoseconds = startedUptimeNanoseconds
        self.endedUptimeNanoseconds = endedUptimeNanoseconds
        self.firstGraphGeneration = firstGraphGeneration
        self.finalGraphGeneration = finalGraphGeneration
        self.pathReportedBitExact = pathReportedBitExact
        self.resources = resources
        self.driverHealth = driverHealth
        self.callbacks = callbacks
        self.teardownStatus = teardownStatus
        self.teardownRecords = Array(retainedRecords)
        self.droppedTeardownRecords = droppedTeardownRecords.addingSaturated(newlyDropped)
        self.residueBaseline = residueBaseline
        self.residue = residue
    }

    public init(
        runID: AudioIncidentRunID,
        startedUptimeNanoseconds: UInt64,
        endedUptimeNanoseconds: UInt64,
        firstGraphGeneration: UInt64,
        finalGraphGeneration: UInt64,
        pathReportedBitExact: Bool,
        resources: AudioIncidentResourceSnapshot = .none,
        driverHealth: AudioIncidentDriverHealth,
        callbacks: AudioIncidentCallbackSnapshot,
        teardownStatus: AudioIncidentTeardownStatus,
        teardownLog: AudioIncidentTeardownLog,
        residueBaseline: AudioIncidentResidueSnapshot,
        residue: AudioIncidentResidueSnapshot
    ) {
        self.init(
            runID: runID,
            startedUptimeNanoseconds: startedUptimeNanoseconds,
            endedUptimeNanoseconds: endedUptimeNanoseconds,
            firstGraphGeneration: firstGraphGeneration,
            finalGraphGeneration: finalGraphGeneration,
            pathReportedBitExact: pathReportedBitExact,
            resources: resources,
            driverHealth: driverHealth,
            callbacks: callbacks,
            teardownStatus: teardownStatus,
            teardownRecords: teardownLog.records,
            droppedTeardownRecords: teardownLog.droppedRecords,
            residueBaseline: residueBaseline,
            residue: residue)
    }

    public var healthVerdict: AudioIncidentHealthVerdict {
        if driverHealth.hasFault || callbacks.hasFault
            || residue.encounteredResidue(since: residueBaseline)
            || teardownStatus == .incomplete || teardownStatus == .timedOut
            || teardownRecords.contains(where: { record in
                record.outcome == .requestFailed || record.outcome == .timedOut
                    || record.outcome == .retained
                    || record.elapsedNanoseconds > record.deadlineNanoseconds
            })
        {
            return .faulted
        }
        if !hasValidEvidence || callbacks.samples == 0 || !driverHealth.isConclusive
            || callbacks.collection != .postFenceCoherent
            || teardownStatus == .notObserved || droppedTeardownRecords > 0
        {
            return .indeterminate
        }
        return .healthy
    }

    /// A non-zero driver counter or any other trust-plane fault revokes this
    /// claim even if the path had reported bit-exactness while it was running.
    public var isBitExactEligible: Bool {
        pathReportedBitExact && healthVerdict == .healthy
    }

    /// Structural facts which must hold before numeric evidence can be graded.
    /// An invalid in-memory value remains indeterminate; the codec rejects it.
    var hasValidEvidence: Bool {
        guard firstGraphGeneration > 0,
            finalGraphGeneration >= firstGraphGeneration,
            endedUptimeNanoseconds >= startedUptimeNanoseconds,
            driverHealth.hasValidShape,
            callbacks.hasValidShape,
            residueBaseline.isValidRouteBaseline,
            residue.hasValidShape,
            residue.isMonotonic(after: residueBaseline),
            teardownRecords.count <= Self.maximumTeardownRecords
        else { return false }

        if teardownStatus == .complete {
            func endedSuccessfully(_ step: AudioIncidentTeardownStep) -> Bool {
                guard let record = teardownRecords.last(where: { $0.step == step }) else {
                    return false
                }
                return record.outcome == .completed || record.outcome == .skipped
            }
            guard !teardownRecords.isEmpty,
                endedSuccessfully(.callbackFence),
                endedSuccessfully(.driverHealthRead),
                endedSuccessfully(.halCensusComplete)
            else { return false }
        } else if teardownStatus == .notObserved, !teardownRecords.isEmpty {
            return false
        }

        for (index, record) in teardownRecords.enumerated() {
            guard record.ordinal == UInt8(index),
                record.graphGeneration >= firstGraphGeneration,
                record.graphGeneration <= finalGraphGeneration,
                record.deadlineNanoseconds > 0,
                record.outcome != .completed || record.status == 0,
                record.outcome != .requestFailed || record.status != 0
            else { return false }
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runID
        case startedUptimeNanoseconds
        case endedUptimeNanoseconds
        case firstGraphGeneration
        case finalGraphGeneration
        case pathReportedBitExact
        case resources
        case driverHealth
        case callbacks
        case teardown
        case residueBaseline
        case residue
        case verdict
    }

    private struct TeardownEnvelope: Codable {
        let status: AudioIncidentTeardownStatus
        let records: [AudioIncidentTeardownRecord]
        let droppedRecords: UInt64
    }

    private struct VerdictEnvelope: Codable, Equatable {
        let health: AudioIncidentHealthVerdict
        let bitExactEligible: Bool
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt8.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported incident schema")
        }
        let teardown = try container.decode(TeardownEnvelope.self, forKey: .teardown)
        guard teardown.records.count <= Self.maximumTeardownRecords else {
            throw DecodingError.dataCorruptedError(
                forKey: .teardown,
                in: container,
                debugDescription: "incident teardown record limit exceeded")
        }
        self.init(
            runID: try container.decode(AudioIncidentRunID.self, forKey: .runID),
            startedUptimeNanoseconds: try container.decode(
                UInt64.self, forKey: .startedUptimeNanoseconds),
            endedUptimeNanoseconds: try container.decode(
                UInt64.self, forKey: .endedUptimeNanoseconds),
            firstGraphGeneration: try container.decode(
                UInt64.self, forKey: .firstGraphGeneration),
            finalGraphGeneration: try container.decode(
                UInt64.self, forKey: .finalGraphGeneration),
            pathReportedBitExact: try container.decode(
                Bool.self, forKey: .pathReportedBitExact),
            resources: try container.decode(
                AudioIncidentResourceSnapshot.self, forKey: .resources),
            driverHealth: try container.decode(
                AudioIncidentDriverHealth.self, forKey: .driverHealth),
            callbacks: try container.decode(
                AudioIncidentCallbackSnapshot.self, forKey: .callbacks),
            teardownStatus: teardown.status,
            teardownRecords: teardown.records,
            droppedTeardownRecords: teardown.droppedRecords,
            residueBaseline: try container.decode(
                AudioIncidentResidueSnapshot.self, forKey: .residueBaseline),
            residue: try container.decode(
                AudioIncidentResidueSnapshot.self, forKey: .residue))
        guard hasValidEvidence else {
            throw DecodingError.dataCorruptedError(
                forKey: .teardown,
                in: container,
                debugDescription: "incident numeric evidence is inconsistent")
        }
        let declaredVerdict = try container.decode(VerdictEnvelope.self, forKey: .verdict)
        let actualVerdict = VerdictEnvelope(
            health: healthVerdict, bitExactEligible: isBitExactEligible)
        guard declaredVerdict == actualVerdict else {
            throw DecodingError.dataCorruptedError(
                forKey: .verdict,
                in: container,
                debugDescription: "incident verdict does not match its numeric evidence")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(runID, forKey: .runID)
        try container.encode(startedUptimeNanoseconds, forKey: .startedUptimeNanoseconds)
        try container.encode(endedUptimeNanoseconds, forKey: .endedUptimeNanoseconds)
        try container.encode(firstGraphGeneration, forKey: .firstGraphGeneration)
        try container.encode(finalGraphGeneration, forKey: .finalGraphGeneration)
        try container.encode(pathReportedBitExact, forKey: .pathReportedBitExact)
        try container.encode(resources, forKey: .resources)
        try container.encode(driverHealth, forKey: .driverHealth)
        try container.encode(callbacks, forKey: .callbacks)
        try container.encode(
            TeardownEnvelope(
                status: teardownStatus,
                records: teardownRecords,
                droppedRecords: droppedTeardownRecords),
            forKey: .teardown)
        try container.encode(residueBaseline, forKey: .residueBaseline)
        try container.encode(residue, forKey: .residue)
        try container.encode(
            VerdictEnvelope(
                health: healthVerdict,
                bitExactEligible: isBitExactEligible),
            forKey: .verdict)
    }
}

extension UInt64 {
    fileprivate func addingSaturated(_ value: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(value)
        return overflow ? .max : sum
    }
}

/// The only supported serialisation boundary for an incident bundle.
public enum AudioIncidentBundleCodec {
    public static let maximumEncodedBytes = 32 * 1_024

    public enum Error: Swift.Error, Sendable, Equatable {
        case inputTooLarge(Int)
        case outputTooLarge(Int)
        case invalidSchema
    }

    public static func encode(_ bundle: AudioIncidentBundle) throws -> Data {
        guard bundle.hasValidEvidence else { throw Error.invalidSchema }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(bundle)
        guard data.count <= maximumEncodedBytes else {
            throw Error.outputTooLarge(data.count)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> AudioIncidentBundle {
        guard data.count <= maximumEncodedBytes else {
            throw Error.inputTooLarge(data.count)
        }
        guard Self.hasExactSchema(data) else { throw Error.invalidSchema }
        do {
            return try JSONDecoder().decode(AudioIncidentBundle.self, from: data)
        } catch {
            throw Error.invalidSchema
        }
    }

    /// Rejects unknown keys before `JSONDecoder`, which otherwise ignores them.
    /// That makes the privacy claim structural: adding `pcm`, `transcript`, a
    /// path or a token cannot produce a bundle this codec accepts.
    private static func hasExactSchema(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data),
            let object = root as? [String: Any],
            object.hasExactly([
                "schemaVersion", "runID", "startedUptimeNanoseconds",
                "endedUptimeNanoseconds", "firstGraphGeneration",
                "finalGraphGeneration", "pathReportedBitExact", "resources",
                "driverHealth", "callbacks", "teardown", "residueBaseline",
                "residue", "verdict",
            ]),
            let resources = object["resources"] as? [String: Any],
            resources.hasExactly([
                "processTapCallEntered", "hadEchoCancellation", "hadAudioUnits",
                "hadAggregate", "hadProcessTaps", "changedSampleRates",
            ]),
            let driver = object["driverHealth"] as? [String: Any],
            driver.hasExactly([
                "state", "wasRequired", "readStatus", "unsafeReadOperations",
                "unsafeWriteOperations",
            ]),
            let callbacks = object["callbacks"] as? [String: Any],
            callbacks.hasExactly([
                "collection", "samples", "p50Nanoseconds", "p999Nanoseconds",
                "p99999Nanoseconds", "maximumNanoseconds", "overflowSamples",
                "deadlineNanoseconds", "missedDeadlines", "callbackOverlaps",
                "allocationViolations", "maximumUpdateContentions",
            ]),
            let teardown = object["teardown"] as? [String: Any],
            teardown.hasExactly(["status", "records", "droppedRecords"]),
            let records = teardown["records"] as? [[String: Any]],
            records.count <= AudioIncidentBundle.maximumTeardownRecords,
            records.allSatisfy({ record in
                record.hasExactly([
                    "ordinal", "graphGeneration", "step", "outcome", "status",
                    "elapsedNanoseconds", "deadlineNanoseconds",
                ])
            }),
            let residue = object["residue"] as? [String: Any],
            residue.hasExactly([
                "retainedEntries", "maximumRetainedEntries", "cleanupAttempts",
                "scheduledRetries", "exhaustedEntries", "completedEntries",
                "deniedAdmissions",
            ]),
            let residueBaseline = object["residueBaseline"] as? [String: Any],
            residueBaseline.hasExactly([
                "retainedEntries", "maximumRetainedEntries", "cleanupAttempts",
                "scheduledRetries", "exhaustedEntries", "completedEntries",
                "deniedAdmissions",
            ]),
            let verdict = object["verdict"] as? [String: Any],
            verdict.hasExactly(["health", "bitExactEligible"])
        else { return false }
        return true
    }
}

extension Dictionary where Key == String, Value == Any {
    fileprivate func hasExactly(_ expected: [String]) -> Bool {
        Set(keys) == Set(expected)
    }
}
