import CoreAudio
import Foundation
import YunAudioHAL
import YunAudioRT

/// One route lifetime's privacy-bounded diagnostic owner.
///
/// The callback sees only `callbackTelemetry`, a fixed C allocation. Everything
/// which can allocate, bridge a property list or inspect HAL remains on the
/// engine owner after the IOProc fence.
final class AudioIncidentRecorder: @unchecked Sendable {
    struct Resources: Sendable, Equatable {
        let processTapCallEntered: Bool
        let hadEchoCancellation: Bool
        let hadAudioUnits: Bool
        let hadAggregate: Bool
        let hadProcessTaps: Bool
        let changedSampleRates: Bool

        init(
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

        var incidentSnapshot: AudioIncidentResourceSnapshot {
            AudioIncidentResourceSnapshot(
                processTapCallEntered: processTapCallEntered,
                hadEchoCancellation: hadEchoCancellation,
                hadAudioUnits: hadAudioUnits,
                hadAggregate: hadAggregate,
                hadProcessTaps: hadProcessTaps,
                changedSampleRates: changedSampleRates)
        }
    }

    let runID: AudioIncidentRunID
    let startedUptimeNanoseconds: UInt64
    let callbackTelemetry: OpaquePointer
    private(set) var callbackDeadlineNanoseconds: UInt64
    let residueBaseline: AudioIncidentResidueSnapshot
    private let metadataLock = NSLock()
    private var driverDeviceIDStorage: AudioObjectID?
    private var driverWasRequiredStorage: Bool
    private var driverHealthBaselineStorage: AudioIncidentDriverHealth
    private var driverHealthWasConfigured = false
    private var resources: Resources

    private var pathReportedBitExact = false
    private var pathQualityWasRecorded = false
    private var fencedCallbacks: AudioIncidentCallbackSnapshot?
    private var teardownPublicationBegan = false
    private var failedAttempts: [FailedAttempt] = []
    private var droppedFailedAttempts: UInt64 = 0

    private struct FailedAttempt {
        let graphGeneration: UInt64
        let step: AudioIncidentTeardownStep
        let outcome: AudioIncidentTeardownOutcome
        let status: OSStatus
        let elapsedNanoseconds: UInt64
        let deadlineNanoseconds: UInt64
    }

    init?(
        sampleRate: Double,
        bufferFrames: Int,
        driverDeviceID: AudioObjectID?,
        driverWasRequired: Bool,
        driverHealthBaseline: AudioIncidentDriverHealth,
        residueBaseline: AudioResidueTelemetry,
        resources: Resources,
        runID: AudioIncidentRunID = .random()
    ) {
        guard sampleRate.isFinite, sampleRate > 0, bufferFrames > 0,
            let callbackTelemetry = yun_rt_incident_callback_create()
        else { return nil }
        let deadline = Double(bufferFrames) / sampleRate * 1_000_000_000
        guard deadline.isFinite, deadline >= 1, deadline < Double(UInt64.max) else {
            yun_rt_incident_callback_free(callbackTelemetry)
            return nil
        }
        self.runID = runID
        startedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        self.callbackTelemetry = callbackTelemetry
        callbackDeadlineNanoseconds = UInt64(deadline.rounded(.down))
        driverDeviceIDStorage = driverDeviceID
        driverWasRequiredStorage = driverWasRequired
        driverHealthBaselineStorage = driverHealthBaseline
        self.residueBaseline = AudioIncidentResidueSnapshot(residueBaseline)
        self.resources = resources

        // The first callback is part of the measured distribution, so Core
        // Audio's host-time conversion must not pay one-time runtime setup there.
        _ = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
    }

    deinit { yun_rt_incident_callback_free(callbackTelemetry) }

    var driverDeviceID: AudioObjectID? {
        metadataLock.withLock { driverDeviceIDStorage }
    }

    var driverWasRequired: Bool {
        metadataLock.withLock { driverWasRequiredStorage }
    }

    func recordPathReportedBitExact(_ value: Bool) {
        metadataLock.withLock {
            pathReportedBitExact =
                pathQualityWasRecorded ? (pathReportedBitExact && value) : value
            pathQualityWasRecorded = true
        }
    }

    /// Replaces provisional driver evidence before the first system mutation.
    func configureDriverHealth(
        deviceID: AudioObjectID?,
        wasRequired: Bool,
        baseline: AudioIncidentDriverHealth
    ) {
        metadataLock.withLock {
            guard !driverHealthWasConfigured else { return }
            driverDeviceIDStorage = deviceID
            driverWasRequiredStorage = wasRequired
            driverHealthBaselineStorage = baseline
            driverHealthWasConfigured = true
        }
    }

    /// Replaces the requested callback budget with the aggregate's settled one.
    /// No graph can name this recorder until after that timing is known.
    func configureCallbackTiming(sampleRate: Double, bufferFrames: Int) -> Bool {
        guard sampleRate.isFinite, sampleRate > 0, bufferFrames > 0 else { return false }
        let deadline = Double(bufferFrames) / sampleRate * 1_000_000_000
        guard deadline.isFinite, deadline >= 1, deadline < Double(UInt64.max) else {
            return false
        }
        callbackDeadlineNanoseconds = UInt64(deadline.rounded(.down))
        return true
    }

    /// Accumulates ownership as construction crosses each irreversible boundary.
    /// A failed start can then distinguish work which never began from work whose
    /// cleanup has to be proved despite there never having been an IO callback.
    func recordResources(_ observed: Resources) {
        metadataLock.withLock {
            resources = Resources(
                processTapCallEntered: resources.processTapCallEntered
                    || observed.processTapCallEntered,
                hadEchoCancellation: resources.hadEchoCancellation
                    || observed.hadEchoCancellation,
                hadAudioUnits: resources.hadAudioUnits || observed.hadAudioUnits,
                hadAggregate: resources.hadAggregate || observed.hadAggregate,
                hadProcessTaps: resources.hadProcessTaps || observed.hadProcessTaps,
                changedSampleRates: resources.changedSampleRates
                    || observed.changedSampleRates)
        }
    }

    func recordConstructionResource(_ resource: AudioUnitConstructionResource) {
        switch resource {
        case .changedSampleRate:
            recordResources(
                Resources(
                    processTapCallEntered: false,
                    hadEchoCancellation: false, hadAudioUnits: false,
                    hadAggregate: false, hadProcessTaps: false,
                    changedSampleRates: true))
        case .aggregate:
            recordResources(
                Resources(
                    processTapCallEntered: false,
                    hadEchoCancellation: false, hadAudioUnits: false,
                    hadAggregate: true, hadProcessTaps: false,
                    changedSampleRates: false))
        case .processTap:
            recordResources(
                Resources(
                    processTapCallEntered: false,
                    hadEchoCancellation: false, hadAudioUnits: false,
                    hadAggregate: false, hadProcessTaps: true,
                    changedSampleRates: false))
        case .audioUnit:
            recordResources(
                Resources(
                    processTapCallEntered: false,
                    hadEchoCancellation: false, hadAudioUnits: true,
                    hadAggregate: false, hadProcessTaps: false,
                    changedSampleRates: false))
        case .echoCancellation:
            recordResources(
                Resources(
                    processTapCallEntered: false,
                    hadEchoCancellation: true, hadAudioUnits: false,
                    hadAggregate: false, hadProcessTaps: false,
                    changedSampleRates: false))
        }
    }

    func recordProcessTapCallEntered() {
        recordResources(
            Resources(
                processTapCallEntered: true,
                hadEchoCancellation: false,
                hadAudioUnits: false,
                hadAggregate: false,
                hadProcessTaps: false,
                changedSampleRates: false))
    }

    /// Takes the only snapshot allowed to claim callback coherence.
    func captureCallbackFence(cellOverlaps: UInt64) {
        guard fencedCallbacks == nil else { return }
        fencedCallbacks = callbackSnapshot(
            callbacksAreFenced: true, cellOverlaps: cellOverlaps)
    }

    /// Leaves a deliberately inconclusive checkpoint while the route is live.
    ///
    /// A crash or forced termination cannot run teardown. Persisting this
    /// bounded snapshot after the first proven callbacks preserves the run
    /// identity and its early realtime evidence without pretending that any
    /// owner was released or that the counters were read behind a fence.
    func makeLiveBundle(
        callbackCellOverlaps: UInt64,
        residue: AudioResidueTelemetry
    ) -> AudioIncidentBundle? {
        let metadata = metadataSnapshot()
        guard !metadata.teardownPublicationBegan else { return nil }
        let callbacks = callbackSnapshot(
            callbacksAreFenced: false, cellOverlaps: callbackCellOverlaps)
        guard callbacks.samples > 0 else { return nil }
        let finalGraphGeneration = max(
            1, yun_rt_incident_graph_generations(callbackTelemetry))
        let bundle = AudioIncidentBundle(
            runID: runID,
            startedUptimeNanoseconds: startedUptimeNanoseconds,
            endedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            firstGraphGeneration: 1,
            finalGraphGeneration: finalGraphGeneration,
            pathReportedBitExact: metadata.pathReportedBitExact,
            resources: metadata.resources.incidentSnapshot,
            driverHealth: AudioIncidentDriverHealth.routeDelta(
                from: metadata.driverHealthBaseline,
                to: metadata.driverHealthBaseline),
            callbacks: callbacks,
            teardownStatus: .notObserved,
            teardownLog: AudioIncidentTeardownLog(),
            residueBaseline: residueBaseline,
            residue: AudioIncidentResidueSnapshot(residue))
        return bundle.hasValidEvidence ? bundle : nil
    }

    /// Persists the run identity before aggregate, tap or Audio Unit work can block.
    func makeConstructionBundle(
        residue: AudioResidueTelemetry
    ) -> AudioIncidentBundle? {
        let metadata = metadataSnapshot()
        guard !metadata.teardownPublicationBegan else { return nil }
        let callbacks = callbackSnapshot(callbacksAreFenced: false, cellOverlaps: 0)
        let bundle = AudioIncidentBundle(
            runID: runID,
            startedUptimeNanoseconds: startedUptimeNanoseconds,
            endedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            firstGraphGeneration: 1,
            finalGraphGeneration: 1,
            pathReportedBitExact: metadata.pathReportedBitExact,
            resources: metadata.resources.incidentSnapshot,
            driverHealth: AudioIncidentDriverHealth.routeDelta(
                from: metadata.driverHealthBaseline,
                to: metadata.driverHealthBaseline),
            callbacks: callbacks,
            teardownStatus: .notObserved,
            teardownLog: AudioIncidentTeardownLog(),
            residueBaseline: residueBaseline,
            residue: AudioIncidentResidueSnapshot(residue))
        return bundle.hasValidEvidence ? bundle : nil
    }

    func makeBundle(
        result: RoutingTeardownResult,
        elapsedNanoseconds: UInt64,
        deadlineNanoseconds: UInt64,
        driverHealth: AudioIncidentDriverHealth,
        callbackCellOverlaps: UInt64,
        residue: AudioResidueTelemetry
    ) -> AudioIncidentBundle? {
        metadataLock.withLock { teardownPublicationBegan = true }
        let metadata = metadataSnapshot()
        let callbacks =
            fencedCallbacks
            ?? callbackSnapshot(
                callbacksAreFenced: false, cellOverlaps: callbackCellOverlaps)
        let finalGraphGeneration = max(
            1, yun_rt_incident_graph_generations(callbackTelemetry))
        let status = Self.teardownStatus(for: result)
        rememberFailure(
            result: result,
            graphGeneration: finalGraphGeneration,
            elapsedNanoseconds: elapsedNanoseconds,
            deadlineNanoseconds: deadlineNanoseconds)
        let routeDriverHealth = AudioIncidentDriverHealth.routeDelta(
            from: metadata.driverHealthBaseline, to: driverHealth)
        let log = makeTeardownLog(
            status: status,
            driverHealth: routeDriverHealth,
            resources: metadata.resources,
            elapsedNanoseconds: elapsedNanoseconds,
            deadlineNanoseconds: max(1, deadlineNanoseconds))
        let bundle = AudioIncidentBundle(
            runID: runID,
            startedUptimeNanoseconds: startedUptimeNanoseconds,
            endedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            firstGraphGeneration: 1,
            finalGraphGeneration: finalGraphGeneration,
            pathReportedBitExact: metadata.pathReportedBitExact,
            resources: metadata.resources.incidentSnapshot,
            driverHealth: routeDriverHealth,
            callbacks: callbacks,
            teardownStatus: status,
            teardownLog: log,
            residueBaseline: residueBaseline,
            residue: AudioIncidentResidueSnapshot(residue))
        return bundle.hasValidEvidence ? bundle : nil
    }

    private func callbackSnapshot(
        callbacksAreFenced: Bool,
        cellOverlaps: UInt64
    ) -> AudioIncidentCallbackSnapshot {
        var raw = YunRTIncidentCallbackSnapshot()
        yun_rt_incident_callback_snapshot(
            callbackTelemetry, callbacksAreFenced, &raw)
        let snapshot = AudioIncidentCallbackSnapshot(raw)
        return AudioIncidentCallbackSnapshot(
            collection: snapshot.collection,
            samples: snapshot.samples,
            p50Nanoseconds: snapshot.p50Nanoseconds,
            p999Nanoseconds: snapshot.p999Nanoseconds,
            p99999Nanoseconds: snapshot.p99999Nanoseconds,
            maximumNanoseconds: snapshot.maximumNanoseconds,
            deadlineNanoseconds:
                snapshot.deadlineNanoseconds == 0
                ? callbackDeadlineNanoseconds : snapshot.deadlineNanoseconds,
            overflowSamples: snapshot.overflowSamples,
            missedDeadlines: snapshot.missedDeadlines,
            callbackOverlaps: snapshot.callbackOverlaps.addingSaturated(cellOverlaps),
            allocationViolations: snapshot.allocationViolations,
            maximumUpdateContentions: snapshot.maximumUpdateContentions)
    }

    private func makeTeardownLog(
        status: AudioIncidentTeardownStatus,
        driverHealth: AudioIncidentDriverHealth,
        resources: Resources,
        elapsedNanoseconds: UInt64,
        deadlineNanoseconds: UInt64
    ) -> AudioIncidentTeardownLog {
        let finalGraphGeneration = max(
            1, yun_rt_incident_graph_generations(callbackTelemetry))
        var log = AudioIncidentTeardownLog()
        func append(
            _ step: AudioIncidentTeardownStep,
            _ outcome: AudioIncidentTeardownOutcome,
            _ operationStatus: OSStatus = noErr
        ) {
            _ = log.append(
                AudioIncidentTeardownRecord(
                    ordinal: UInt8(clamping: log.records.count),
                    graphGeneration: finalGraphGeneration,
                    step: step,
                    outcome: outcome,
                    status: operationStatus,
                    elapsedNanoseconds: elapsedNanoseconds,
                    deadlineNanoseconds: deadlineNanoseconds))
        }

        append(.admissionStopped, .completed)
        for failure in failedAttempts {
            _ = log.append(
                AudioIncidentTeardownRecord(
                    ordinal: UInt8(clamping: log.records.count),
                    graphGeneration: failure.graphGeneration,
                    step: failure.step,
                    outcome: failure.outcome,
                    status: failure.status,
                    elapsedNanoseconds: failure.elapsedNanoseconds,
                    deadlineNanoseconds: failure.deadlineNanoseconds))
        }
        if status == .complete {
            for step in Self.completeSteps {
                let outcome: AudioIncidentTeardownOutcome
                if step == .driverHealthRead {
                    outcome = driverHealth.state == .available ? .completed : .skipped
                } else {
                    outcome = Self.outcome(for: step, resources: resources)
                }
                append(step, outcome)
            }
        }
        log.noteDroppedRecords(droppedFailedAttempts)
        return log
    }

    private func metadataSnapshot() -> (
        driverHealthBaseline: AudioIncidentDriverHealth,
        resources: Resources,
        pathReportedBitExact: Bool,
        teardownPublicationBegan: Bool
    ) {
        metadataLock.withLock {
            (
                driverHealthBaselineStorage,
                resources,
                pathReportedBitExact,
                teardownPublicationBegan
            )
        }
    }

    private func rememberFailure(
        result: RoutingTeardownResult,
        graphGeneration: UInt64,
        elapsedNanoseconds: UInt64,
        deadlineNanoseconds: UInt64
    ) {
        guard let terminal = Self.terminalRecord(for: result) else { return }
        let maximumFailures =
            AudioIncidentBundle.maximumTeardownRecords - Self.completeSteps.count - 1
        guard failedAttempts.count < maximumFailures else {
            droppedFailedAttempts = droppedFailedAttempts.addingSaturated(1)
            return
        }
        failedAttempts.append(
            FailedAttempt(
                graphGeneration: graphGeneration,
                step: terminal.step,
                outcome: terminal.outcome,
                status: terminal.status,
                elapsedNanoseconds: elapsedNanoseconds,
                deadlineNanoseconds: max(1, deadlineNanoseconds)))
    }

    private static let completeSteps: [AudioIncidentTeardownStep] = [
        .ioProcStopped,
        .ioProcDestroyed,
        .callbackFence,
        .echoCancellationDisposed,
        .aggregateDestroyed,
        .processTapDestroyed,
        .audioUnitDisposed,
        .sampleRatesRestored,
        .ownersReleased,
        .driverHealthRead,
        .halCensusComplete,
    ]

    private static func outcome(
        for step: AudioIncidentTeardownStep,
        resources: Resources
    ) -> AudioIncidentTeardownOutcome {
        switch step {
        case .echoCancellationDisposed:
            resources.hadEchoCancellation ? .completed : .skipped
        case .audioUnitDisposed:
            resources.hadAudioUnits ? .completed : .skipped
        case .aggregateDestroyed:
            resources.hadAggregate ? .completed : .skipped
        case .processTapDestroyed:
            resources.hadProcessTaps ? .completed : .skipped
        case .sampleRatesRestored:
            resources.changedSampleRates ? .completed : .skipped
        default:
            .completed
        }
    }

    private static func teardownStatus(
        for result: RoutingTeardownResult
    ) -> AudioIncidentTeardownStatus {
        if result.isComplete { return .complete }
        return result.isTimeout ? .timedOut : .incomplete
    }

    private static func terminalRecord(
        for result: RoutingTeardownResult
    ) -> (
        step: AudioIncidentTeardownStep,
        outcome: AudioIncidentTeardownOutcome,
        status: OSStatus
    )? {
        switch result {
        case .complete:
            return nil
        case .lifecycleQueueTimedOut:
            return (.routeTeardownStarted, .timedOut, noErr)
        case .ioProcStopFailed(let status):
            return (.ioProcStopped, .requestFailed, status)
        case .ioProcDestroyFailed(let status):
            return (.ioProcDestroyed, .requestFailed, status)
        case .ioProcTimedOut(let step):
            return (
                step == .stop ? .ioProcStopped : .ioProcDestroyed,
                .timedOut,
                noErr
            )
        case .clockPublisherTimedOut:
            return (.ownersReleased, .timedOut, noErr)
        case .echoCancellation(let result, _):
            return (
                .echoCancellationDisposed,
                result.isTimeout ? .timedOut : .requestFailed,
                result.failureStatus
            )
        case .audioUnitOwner(let result):
            return (
                .audioUnitDisposed,
                result.isTimeout ? .timedOut : .requestFailed,
                result.failureStatus
            )
        case .aggregate(let result):
            return (
                .aggregateDestroyed,
                result == .timedOut ? .timedOut : .requestFailed,
                result.failureStatus
            )
        case .processTap(_, let result):
            return (
                .processTapDestroyed,
                result == .timedOut ? .timedOut : .requestFailed,
                result.failureStatus
            )
        case .sampleRatesNotRestored:
            return (
                .sampleRatesRestored,
                .requestFailed,
                kAudioHardwareUnspecifiedError
            )
        }
    }
}

package enum AudioIncidentDriverHealthReader {
    static let selector: AudioObjectPropertySelector = 0x79_69_6F_68  // 'yioh'

    package static func read(
        deviceID: AudioObjectID?,
        wasRequired: Bool,
        until deadline: HALTeardownDeadline
    ) -> AudioIncidentDriverHealth {
        guard let deviceID else {
            return AudioIncidentDriverHealth(
                state: wasRequired ? .readFailed : .driverAbsent,
                wasRequired: wasRequired,
                readStatus: wasRequired ? kAudioHardwareBadObjectError : noErr,
                unsafeReadOperations: 0,
                unsafeWriteOperations: 0)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard
            let hasProperty = deadline.perform({
                AudioObjectHasProperty(deviceID, &address)
            })
        else {
            return failure(wasRequired: wasRequired, status: kAudioHardwareNotRunningError)
        }
        guard hasProperty else {
            return AudioIncidentDriverHealth(
                state: .propertyUnavailable,
                wasRequired: wasRequired,
                readStatus: noErr,
                unsafeReadOperations: 0,
                unsafeWriteOperations: 0)
        }

        var size = UInt32(MemoryLayout<CFPropertyList?>.size)
        var unmanaged: Unmanaged<CFDictionary>?
        guard
            let status = deadline.perform({
                withUnsafeMutablePointer(to: &unmanaged) { pointer in
                    AudioObjectGetPropertyData(
                        deviceID, &address, 0, nil, &size, pointer)
                }
            })
        else {
            return failure(wasRequired: wasRequired, status: kAudioHardwareNotRunningError)
        }
        guard status == noErr,
            let dictionary = unmanaged?.takeRetainedValue() as? [String: Any],
            let unsafeReads = (dictionary["unsafeReadOperations"] as? NSNumber)?.uint64Value,
            let unsafeWrites = (dictionary["unsafeWriteOperations"] as? NSNumber)?.uint64Value
        else { return failure(wasRequired: wasRequired, status: status) }
        return AudioIncidentDriverHealth(
            state: .available,
            wasRequired: wasRequired,
            readStatus: noErr,
            unsafeReadOperations: unsafeReads,
            unsafeWriteOperations: unsafeWrites,
            unsafeReadStartFrame: (dictionary["unsafeReadStartFrame"] as? NSNumber)?
                .uint64Value,
            unsafeReadFrameCount: (dictionary["unsafeReadFrameCount"] as? NSNumber)?
                .uint64Value,
            unsafeReadUnavailableFrame: (dictionary["unsafeReadUnavailableFrame"] as? NSNumber)?
                .uint64Value,
            lastPublishedStartFrame: (dictionary["lastPublishedStartFrame"] as? NSNumber)?
                .uint64Value,
            lastPublishedFrameCount: (dictionary["lastPublishedFrameCount"] as? NSNumber)?
                .uint64Value)
    }

    private static func failure(
        wasRequired: Bool,
        status: OSStatus
    ) -> AudioIncidentDriverHealth {
        AudioIncidentDriverHealth(
            state: .readFailed,
            wasRequired: wasRequired,
            readStatus: status == noErr ? kAudioHardwareUnspecifiedError : status,
            unsafeReadOperations: 0,
            unsafeWriteOperations: 0)
    }
}

extension AudioIncidentRunID {
    static func random() -> Self {
        let bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        let high = bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let low = bytes.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Self(high: high, low: low)
    }
}

extension UInt64 {
    fileprivate func addingSaturated(_ value: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(value)
        return overflow ? .max : sum
    }
}

extension HALDestructionResult {
    fileprivate var failureStatus: OSStatus {
        if case .requestFailed(let status) = self { return status }
        return self == .timedOut ? noErr : kAudioHardwareUnspecifiedError
    }
}

extension AudioUnitOwnerDisposalResult {
    fileprivate var isTimeout: Bool {
        if case .timedOut = self { return true }
        return false
    }

    fileprivate var failureStatus: OSStatus {
        if case .operationFailed(_, let status, _) = self { return status }
        return isTimeout ? noErr : kAudioHardwareUnspecifiedError
    }
}

extension EchoCancellationBridgeTeardownResult {
    fileprivate var isTimeout: Bool {
        switch self {
        case .lifecycleTimedOut:
            true
        case .capture(let result):
            result.isTimeout
        case .farEnd(let result):
            result.isTimeout
        case .complete:
            false
        }
    }

    fileprivate var failureStatus: OSStatus {
        switch self {
        case .capture(let result):
            result.failureStatus
        case .farEnd(let result):
            result.failureStatus
        case .complete, .lifecycleTimedOut:
            isTimeout ? noErr : kAudioHardwareUnspecifiedError
        }
    }
}

extension EchoCancellationTeardownResult {
    fileprivate var isTimeout: Bool {
        switch self {
        case .audioUnitTimedOut, .lifecycleTimedOut:
            true
        case .aggregate(let result):
            result == .timedOut
        case .complete, .audioUnit, .sampleRatesNotRestored:
            false
        }
    }

    fileprivate var failureStatus: OSStatus {
        switch self {
        case .audioUnit(_, let status):
            status
        case .aggregate(let result):
            result.failureStatus
        case .complete, .audioUnitTimedOut, .lifecycleTimedOut:
            isTimeout ? noErr : kAudioHardwareUnspecifiedError
        case .sampleRatesNotRestored:
            kAudioHardwareUnspecifiedError
        }
    }
}

extension FarEndCaptureTeardownResult {
    fileprivate var isTimeout: Bool {
        switch self {
        case .ioProcTimedOut:
            true
        case .aggregate(let result), .processTap(_, let result):
            result == .timedOut
        case .complete, .ioProcStopFailed, .ioProcDestroyFailed:
            false
        }
    }

    fileprivate var failureStatus: OSStatus {
        switch self {
        case .ioProcStopFailed(let status), .ioProcDestroyFailed(let status):
            status
        case .aggregate(let result), .processTap(_, let result):
            result.failureStatus
        case .complete, .ioProcTimedOut:
            isTimeout ? noErr : kAudioHardwareUnspecifiedError
        }
    }
}

extension RoutingTeardownResult {
    fileprivate var isTimeout: Bool {
        switch self {
        case .lifecycleQueueTimedOut, .ioProcTimedOut, .clockPublisherTimedOut:
            true
        case .echoCancellation(let result, _):
            result.isTimeout
        case .audioUnitOwner(let result):
            result.isTimeout
        case .aggregate(let result), .processTap(_, let result):
            result == .timedOut
        case .complete, .ioProcStopFailed, .ioProcDestroyFailed,
            .sampleRatesNotRestored:
            false
        }
    }
}
