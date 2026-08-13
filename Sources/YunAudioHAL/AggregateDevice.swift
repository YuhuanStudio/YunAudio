import CoreAudio
import Foundation

/// Builds one immutable snapshot at most once, including a failed optional one.
///
/// `lazy` properties do not promise thread-safe initialisation. Aggregate state
/// is read by the engine queue, recording controls and clock reporting, so two
/// first readers can legitimately arrive together. Holding the lock through
/// construction makes one of them pay for HAL and lets every other reader reuse
/// the same answer.
final class ExactlyOnceSnapshot<Value>: @unchecked Sendable {
    private enum State {
        case empty
        case value(Value)
    }

    private let lock = NSLock()
    private var state = State.empty

    func get(_ build: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .empty:
            let value = build()
            state = .value(value)
            return value
        case .value(let value):
            return value
        }
    }
}

/// Raw aggregate cleanup progress which survives bounded retry attempts.
///
/// Once a UID census proves the aggregate absent, its numeric object ID may be
/// reused by Core Audio. A retry must therefore continue only with retained tap
/// dependencies, never send another destroy or interpret that stale ID again.
final class RawAggregateCleanupState: @unchecked Sendable {
    let request: HALDestructionRequestCoordinator
    private let lock = NSLock()
    private var aggregateAbsenceConfirmed = false

    init(requestWasAccepted: Bool) {
        request = HALDestructionRequestCoordinator(
            requestWasAccepted: requestWasAccepted)
    }

    var hasConfirmedAbsence: Bool {
        lock.withLock { aggregateAbsenceConfirmed }
    }

    func confirmAbsence() {
        lock.withLock { aggregateAbsenceConfirmed = true }
    }
}

/// Separates a failed create status from ownership returned through its out parameter.
///
/// Core Audio follows the C ownership pattern where an out parameter can contain a
/// real object even when the status reports failure. The caller may publish only the
/// successful case; a nonzero value beside an error belongs to bounded cleanup.
struct AggregateDeviceCreationOwnership: Sendable, Equatable {
    let status: OSStatus
    let createdDeviceID: AudioObjectID?
    let orphanedDeviceID: AudioObjectID?

    init(status: OSStatus, returnedDeviceID: AudioObjectID) {
        let returned =
            returnedDeviceID == kAudioObjectUnknown ? nil : returnedDeviceID
        self.status = status
        if status == noErr {
            createdDeviceID = returned
            orphanedDeviceID = nil
        } else {
            createdDeviceID = nil
            orphanedDeviceID = returned
        }
    }
}

/// A private aggregate device assembled at runtime.
///
/// This is the whole reason the router works. `AVAudioEngine` drives a single
/// AUHAL, so its input and output are always the same device — verified by
/// object identity, not folklore. Binding several physical devices into one
/// aggregate gives a single IO cycle that reads the microphone and writes the
/// virtual device in the same callback: no ring buffer, no jitter headroom, no
/// user-space sample rate converter.
///
/// The aggregate is created *private*, so it never appears in Audio MIDI Setup
/// or in other applications' device lists, and the HAL tears it down when this
/// process exits — a crash cannot leave debris behind.
public final class AggregateDevice {
    public struct SubDevice: Sendable {
        public let uid: String
        /// When true the HAL resamples this device to track the clock master.
        /// Exactly one sub-device — the master — must have this off.
        public let driftCompensation: Bool
        /// How many of this device's input channels the aggregate should open.
        ///
        /// **Measured to have no effect.** The header reads like a restriction
        /// and it is a description: a device with three inputs asked for one
        /// still presents three, and one asked for none still presents one.
        /// Kept because saying so where somebody would reach for it is worth
        /// more than leaving the key to be rediscovered, and because the flow
        /// check asserts the current behaviour — if a macOS ever honours it,
        /// the obvious fix for the Bluetooth HFP problem becomes available and
        /// this project finds out.
        public let inputChannels: Int?
        /// The same for the output side, and the same caveat.
        public let outputChannels: Int?
        /// Extra frames of delay on this member's output, for lining up two
        /// paths that do not arrive together.
        ///
        /// Unlike the channel keys above, this one works: 480 frames asked for
        /// is 480 frames of extra output latency on the aggregate, measured.
        /// The HAL does the delaying, so a speaker and an interface fed from
        /// one IOProc can be aligned without the realtime path ever seeing it.
        public let extraOutputLatencyFrames: Int?

        public init(
            uid: String, driftCompensation: Bool,
            inputChannels: Int? = nil, outputChannels: Int? = nil,
            extraOutputLatencyFrames: Int? = nil
        ) {
            self.uid = uid
            self.driftCompensation = driftCompensation
            self.inputChannels = inputChannels
            self.outputChannels = outputChannels
            self.extraOutputLatencyFrames = extraOutputLatencyFrames
        }

        /// This member as the HAL wants to be told about it.
        var description: [String: Any] {
            var entry: [String: Any] = [kAudioSubDeviceUIDKey: uid]
            if driftCompensation {
                entry[kAudioSubDeviceDriftCompensationKey] = 1
                // Drift correction is the only resampling on the path, so it
                // runs at the highest quality the HAL offers rather than the
                // default.
                // Int rather than the constant's own UInt32: everything else
                // in this dictionary is an Int, and a mixed bag of numeric
                // types is a difference that shows up only when somebody reads
                // the dictionary back and one key does not match.
                entry[kAudioSubDeviceDriftCompensationQualityKey] =
                    Int(kAudioAggregateDriftCompensationMaxQuality)
            } else {
                entry[kAudioSubDeviceDriftCompensationKey] = 0
            }
            if let inputChannels { entry[kAudioSubDeviceInputChannelsKey] = inputChannels }
            if let outputChannels { entry[kAudioSubDeviceOutputChannelsKey] = outputChannels }
            if let extraOutputLatencyFrames {
                entry[kAudioSubDeviceExtraOutputLatencyKey] = extraOutputLatencyFrames
            }
            return entry
        }
    }

    public let id: AudioObjectID
    public let uid: String
    public let subDevices: [SubDevice]
    /// UID of the sub-device whose clock everything else follows.
    public let clockMasterUID: String
    /// Taps folded in as sub-devices. Retained so they outlive the aggregate
    /// that references them.
    public let taps: [ProcessTap]

    private let destructionLock = NSLock()
    private var destructionState = HALDestructionRequestState()
    private var removalWasConfirmed = false
    private let deviceSnapshot = ExactlyOnceSnapshot<AudioDevice?>()

    /// Builds the aggregate.
    ///
    /// - Parameters:
    ///   - name: Shown nowhere (the device is private) but useful in traces.
    ///   - subDevices: Members, in the order their channels should appear.
    ///   - clockMasterUID: Must name one of `subDevices`. Prefer the physical
    ///     device: virtual endpoints follow the host clock and adapt cheaply,
    ///     whereas resampling the microphone would touch the signal we are
    ///     trying to keep intact.
    ///   - taps: Process taps to fold in as members. Their channels appear
    ///     after the sub-devices' own, on the input side only.
    /// - Throws: `AggregateError` when the member list is empty, the named clock
    ///   master is not among them, or CoreAudio refuses to build the device.
    public init(
        name: String,
        subDevices: [SubDevice],
        clockMasterUID: String,
        taps: [ProcessTap] = []
    ) throws {
        try AggregateCapacityPolicy.validate(
            name: name, subDevices: subDevices, clockMasterUID: clockMasterUID,
            tapUIDs: taps.map(\.uid))
        let quarantine = ProcessLifetimeAudioQuarantine.shared
        if let residue = quarantine.refusalForNewAudioOwnership() {
            throw AggregateError.audioResiduePresent(residue)
        }

        let generatedUID = "com.yuhuanstudio.yunaudio.aggregate.\(UUID().uuidString)"
        self.uid = generatedUID
        self.subDevices = subDevices
        self.clockMasterUID = clockMasterUID
        self.taps = taps

        let subDeviceDicts = subDevices.map(\.description)

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: generatedUID,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceDicts,
            kAudioAggregateDeviceMainSubDeviceKey: clockMasterUID,
            // Invisible to every other process, and reaped with this one.
            kAudioAggregateDeviceIsPrivateKey: 1,
            // Not stacked: channels stay addressable per sub-device instead of
            // being summed together.
            kAudioAggregateDeviceIsStackedKey: 0,
        ]

        // Process taps join the aggregate as sub-devices, which is what lets a
        // single IOProc read a microphone and an application's output in the
        // same cycle. Auto-start so the tap begins producing as soon as the
        // device runs, rather than on first read.
        if !taps.isEmpty {
            description[kAudioAggregateDeviceTapListKey] = taps.map { tap in
                [kAudioSubTapUIDKey: tap.uid, kAudioSubTapDriftCompensationKey: 1]
            }
            description[kAudioAggregateDeviceTapAutoStartKey] = 1
        }

        id = try Self.createAggregate(
            description: description, uid: generatedUID, taps: taps)
    }

    /// An aggregate whose only members are process taps.
    ///
    /// A tap is not readable on its own — it has to be a member of some
    /// aggregate before an IOProc can see it — but it does not need a physical
    /// device for company. That matters when the point is to read an
    /// application's output *without* touching any hardware: adding a speaker
    /// here to satisfy an invariant would put two owners on that speaker, which
    /// is precisely the fight this project exists to avoid.
    ///
    /// The clock comes from the tapped process's own timeline, so there is no
    /// main sub-device to name.
    ///
    /// - Throws: `AggregateError.noSubDevices` when no taps are given, or
    ///   `.creationFailed` when CoreAudio refuses.
    public convenience init(name: String, tapsOnly taps: [ProcessTap]) throws {
        guard !taps.isEmpty else { throw AggregateError.noSubDevices }
        try self.init(name: name, taps: taps, subDevices: [], clockMasterUID: nil)
    }

    private init(
        name: String, taps: [ProcessTap], subDevices: [SubDevice], clockMasterUID: String?
    ) throws {
        try AggregateCapacityPolicy.validate(
            name: name, subDevices: subDevices, clockMasterUID: clockMasterUID,
            tapUIDs: taps.map(\.uid))
        let quarantine = ProcessLifetimeAudioQuarantine.shared
        if let residue = quarantine.refusalForNewAudioOwnership() {
            throw AggregateError.audioResiduePresent(residue)
        }
        let generatedUID = "com.yuhuanstudio.yunaudio.aggregate.\(UUID().uuidString)"
        uid = generatedUID
        self.subDevices = subDevices
        self.clockMasterUID = clockMasterUID ?? ""
        self.taps = taps

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: generatedUID,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        description[kAudioAggregateDeviceTapListKey] = taps.map { tap in
            [kAudioSubTapUIDKey: tap.uid, kAudioSubTapDriftCompensationKey: 0]
        }

        id = try Self.createAggregate(
            description: description, uid: generatedUID, taps: taps)
    }

    private static func createAggregate(
        description: [String: Any], uid: String, taps: [ProcessTap]
    ) throws -> AudioObjectID {
        try resolveCreationAttempt(
            create: { deviceID in
                AudioHardwareCreateAggregateDevice(
                    description as CFDictionary, &deviceID)
            },
            handOffOrphan: { orphanedID in
                quarantineRawDestruction(
                    id: orphanedID, uid: uid, taps: taps,
                    requestWasAccepted: false,
                    reason: "failed aggregate creation \(uid) requires census")
            })
    }

    /// Injectable out-parameter boundary used without touching HAL in tests.
    static func resolveCreationAttempt(
        create: (_ deviceID: inout AudioObjectID) -> OSStatus,
        handOffOrphan: (AudioObjectID) -> Void
    ) throws -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = create(&deviceID)
        let ownership = AggregateDeviceCreationOwnership(
            status: status, returnedDeviceID: deviceID)
        return try resolveCreationOwnership(
            ownership, handOffOrphan: handOffOrphan)
    }

    /// Publishes a successful ID or transfers an error-side ID before throwing.
    private static func resolveCreationOwnership(
        _ ownership: AggregateDeviceCreationOwnership,
        handOffOrphan: (AudioObjectID) -> Void
    ) throws -> AudioObjectID {
        if let orphaned = ownership.orphanedDeviceID {
            handOffOrphan(orphaned)
        }
        guard let created = ownership.createdDeviceID else {
            throw AggregateError.creationFailed(ownership.status)
        }
        return created
    }

    deinit {
        let id = id
        let uid = uid
        let taps = taps
        let lifecycle = destructionLock.withLock {
            (destructionState.wasAccepted, removalWasConfirmed)
        }
        guard !lifecycle.1 else { return }
        Self.quarantineRawDestruction(
            id: id, uid: uid, taps: taps,
            requestWasAccepted: lifecycle.0,
            reason: "aggregate \(uid) requires deinit census")
    }

    /// Owns an aggregate ID which has no fully initialised Swift wrapper.
    ///
    /// The quarantine entry exists before this returns. Cleanup uses HAL's one
    /// bounded retry owner, so a wedged destroy cannot create another worker and
    /// no new audio owner is admitted while this raw identity remains uncertain.
    private static func quarantineRawDestruction(
        id: AudioObjectID,
        uid: String,
        taps: [ProcessTap],
        requestWasAccepted: Bool,
        reason: String
    ) {
        let cleanupState = RawAggregateCleanupState(
            requestWasAccepted: requestWasAccepted)
        BoundedHALDeinitCleanup.quarantine(reason: reason) {
            let deadline = HALTeardownDeadline(timeout: 2)
            return cleanUpRawAggregate(
                until: deadline,
                state: cleanupState,
                destroy: { AudioHardwareDestroyAggregateDevice(id) },
                isPresent: {
                    do {
                        return try censusContains(uid: uid) {
                            try AudioDevices.objectID(forUID: $0)
                        }
                    } catch {
                        return true
                    }
                },
                destroyDependencies: {
                    ProcessTap.destroyAllAndWait(taps, until: deadline) == .destroyed
                })
        }
    }

    /// One injected raw-owner attempt, shared by failed creation and `deinit`.
    static func cleanUpRawAggregate(
        until deadline: HALTeardownDeadline,
        state: RawAggregateCleanupState,
        destroy: () -> OSStatus,
        isPresent: () -> Bool,
        destroyDependencies: () -> Bool
    ) -> Bool {
        if !state.hasConfirmedAbsence {
            // A failed destroy status does not prove the error-side out owner is
            // still present. Conversely, it is never treated as success by
            // itself: only an exact UID census may close this ownership fact.
            guard
                deadline.perform({ state.request.request(using: destroy) }) != nil
            else { return false }
            let aggregateIsAbsent = HALRemovalWaiter.wait(
                until: deadline,
                pollInterval: 0.01,
                betweenAttempts: { Thread.sleep(forTimeInterval: $0) },
                isPresent: isPresent)
            guard aggregateIsAbsent else { return false }
            state.confirmAbsence()
        }

        // Only an absent aggregate has stopped referring to its taps. Their
        // wrappers stay captured until every dependency has disappeared too.
        // A later retry skips the stale aggregate ID and resumes here.
        guard deadline.hasTimeRemaining else { return false }
        return destroyDependencies()
    }

    /// Requests removal once and retains the returned status for diagnosis.
    ///
    /// A failed request does not mark the aggregate destroyed. A later teardown
    /// attempt may retry it; doing what the old implementation did — setting a
    /// Boolean first and discarding the status — made one transient refusal
    /// indistinguishable from successful cleanup for the rest of the process.
    @discardableResult
    public func destroy() -> OSStatus {
        destructionLock.lock()
        defer { destructionLock.unlock() }
        return destructionState.request {
            AudioHardwareDestroyAggregateDevice(id)
        }
    }

    private func destroy(until deadline: HALTeardownDeadline) -> OSStatus? {
        destructionLock.lock()
        defer { destructionLock.unlock() }
        return deadline.perform {
            destructionState.request {
                AudioHardwareDestroyAggregateDevice(id)
            }
        }
    }

    /// Requests removal and waits for UID translation to report absence.
    ///
    /// This belongs on a control queue, never an IO callback or the main actor.
    /// - Parameter timeout: Bounded time to wait after Core Audio accepts the
    ///   request. Zero starts no synchronous HAL operation.
    /// - Returns: The request and completion outcome separately.
    public func destroyAndWait(timeout: TimeInterval = 2) -> HALDestructionResult {
        destroyAndWait(until: HALTeardownDeadline(timeout: timeout))
    }

    /// Uses the remaining portion of a route-wide teardown budget.
    public func destroyAndWait(until deadline: HALTeardownDeadline) -> HALDestructionResult {
        guard let status = destroy(until: deadline) else { return .timedOut }
        guard status == noErr else { return .requestFailed(status) }

        let interval = 0.01
        let absent = HALRemovalWaiter.wait(
            until: deadline,
            pollInterval: interval,
            betweenAttempts: { Thread.sleep(forTimeInterval: $0) },
            isPresent: {
                do {
                    return try Self.censusContains(uid: self.uid) {
                        try AudioDevices.objectID(forUID: $0)
                    }
                } catch {
                    // A failed census is not evidence of absence. Treat it as
                    // present and let the bounded deadline report the problem.
                    return true
                }
            })
        if absent {
            destructionLock.withLock { removalWasConfirmed = true }
            return .destroyed
        }
        return .timedOut
    }

    static func censusContains(
        uid: String,
        translate: (String) throws -> AudioObjectID?
    ) throws -> Bool {
        try translate(uid) != nil
    }

    /// Last status returned by the removal request, even when it failed.
    public var destructionStatus: OSStatus? {
        destructionLock.lock()
        defer { destructionLock.unlock() }
        return destructionState.lastStatus
    }

    // MARK: Configuration

    /// The aggregate's immutable identity and channel topology.
    ///
    /// Constructing `AudioDevice` is not a struct copy: it asks HAL for the
    /// identity, transport, both stream configurations, available rates and
    /// clock domain. `pathQuality` used to reconstruct all of that twice a
    /// second. The aggregate cannot change members during its lifetime, so one
    /// snapshot is the honest answer. Live properties remain live:
    /// `currentSampleRate`, `currentBufferFrameSize` and `alters` still query
    /// their AudioObject every time they are read.
    public var device: AudioDevice? {
        deviceSnapshot.get { try? AudioDevice(id: id) }
    }

    /// Aligns every member to one rate before the aggregate starts, returning
    /// what each device was set to beforehand.
    ///
    /// Mixing rates inside an aggregate forces the HAL to convert on more paths
    /// than necessary, so the caller picks a rate all members share and applies
    /// it here. The change persists on the hardware after this process exits, so
    /// the previous values come back with the return value and the caller is
    /// expected to restore them — leaving someone's microphone at a rate they
    /// did not choose is a side effect, not a feature.
    @discardableResult
    public static func alignSampleRate(
        _ rate: Double, across devices: [AudioDevice],
        recordOriginal: (String, Double) -> Void = { _, _ in }
    ) throws -> [String: Double] {
        try alignSampleRate(
            rate, across: devices, deadline: nil,
            operationAdmission: { true }, recordOriginal: recordOriginal)
    }

    /// Package construction path whose per-device writes share one deadline.
    /// Restoration is still attempted after cancellation: undoing a rate
    /// already changed is cleanup, not a new graph-construction stage.
    @discardableResult
    package static func alignSampleRate(
        _ rate: Double, across devices: [AudioDevice],
        until deadline: HALTeardownDeadline,
        operationAdmission: () -> Bool,
        recordOriginal: (String, Double) -> Void = { _, _ in },
        callerOwnsPublishedOriginals: Bool = false
    ) throws -> [String: Double] {
        try alignSampleRate(
            rate, across: devices, deadline: deadline,
            operationAdmission: operationAdmission,
            recordOriginal: recordOriginal,
            callerOwnsPublishedOriginals: callerOwnsPublishedOriginals)
    }

    private static func alignSampleRate(
        _ rate: Double, across devices: [AudioDevice],
        deadline: HALTeardownDeadline?,
        operationAdmission: () -> Bool,
        recordOriginal: (String, Double) -> Void,
        callerOwnsPublishedOriginals: Bool = false
    ) throws -> [String: Double] {
        guard AudioHardwareValuePolicy.supports(sampleRate: rate) else {
            throw AudioHardwareValueError.unsupportedSampleRate(rate)
        }
        // Validate every restoration value before changing the first device.
        // Otherwise a legitimate but unsupported current format discovered
        // late in this loop could leave an earlier member changed with no safe
        // value this process is willing to write back.
        for device in devices {
            guard operationAdmission() else { throw CancellationError() }
            guard let current = device.currentSampleRate else {
                throw AggregateError.sampleRateUnavailable(device.uid)
            }
            if !AudioHardwareValuePolicy.supports(sampleRate: current) {
                throw AudioHardwareValueError.unsupportedSampleRate(current)
            }
        }
        var previous: [String: Double] = [:]
        do {
            for device in devices {
                guard operationAdmission() else { throw CancellationError() }
                guard let current = device.currentSampleRate else {
                    throw AggregateError.sampleRateUnavailable(device.uid)
                }
                guard current != rate else { continue }
                previous[device.uid] = current
                // Publish the undo value before the setter. A setter may change
                // the device and then time out waiting for notification, so a
                // success-only return value is too late to own that mutation.
                recordOriginal(device.uid, current)
                guard operationAdmission() else { throw CancellationError() }
                let operationTimeout = min(
                    1, max(0, deadline?.remainingTimeInterval ?? 1))
                guard operationTimeout > 0 else { throw CancellationError() }
                let arrived = try device.setNominalSampleRate(
                    rate, timeout: operationTimeout)
                guard operationAdmission() else { throw CancellationError() }
                try requireSampleRateArrival(arrived, uid: device.uid, rate: rate)
            }
        } catch {
            if callerOwnsPublishedOriginals { throw error }
            // This function has not returned the originals to its caller yet.
            // Put back every earlier member here, or a late failure leaves a
            // successfully changed microphone at a rate nobody chose and gives
            // the caller no record with which to restore it.
            for device in devices {
                guard let original = previous[device.uid] else { continue }
                _ = try? device.setNominalSampleRate(original)
            }
            throw error
        }
        return previous
    }

    /// Turns the asynchronous setter's timeout into an actionable start error.
    ///
    /// Separate so the decision can be asserted without changing real hardware.
    /// Continuing would configure every frequency- and time-dependent DSP stage
    /// for a rate the samples are not actually using.
    static func requireSampleRateArrival(
        _ arrived: Bool, uid: String, rate: Double
    ) throws {
        guard arrived else { throw AggregateError.sampleRateDidNotSet(uid, rate) }
    }

    /// Puts sample rates back the way `alignSampleRate` found them.
    ///
    /// Best effort: a device that has been unplugged in the meantime is skipped
    /// rather than treated as a failure, because there is nothing to restore.
    /// - Returns: The UIDs of devices that did not arrive back at their
    ///   original rate. Empty is the normal case; anything in it is hardware
    ///   left somewhere the user did not put it.
    @discardableResult
    public static func restoreSampleRates(_ rates: [String: Double]) -> [String] {
        restoreSampleRates(rates, deadline: nil)
    }

    /// Restores rates without extending an enclosing teardown transaction.
    @discardableResult
    public static func restoreSampleRates(
        _ rates: [String: Double], until deadline: HALTeardownDeadline
    ) -> [String] {
        restoreSampleRates(rates, deadline: deadline)
    }

    private static func restoreSampleRates(
        _ rates: [String: Double], deadline: HALTeardownDeadline?
    ) -> [String] {
        var stubborn: [String] = []
        for (uid, rate) in rates {
            guard deadline?.remainingTimeInterval ?? 1 > 0 else {
                stubborn.append(uid)
                continue
            }
            guard let device = try? AudioDevices.device(uid: uid) else { continue }
            let timeout = deadline?.remainingTimeInterval ?? 1
            guard timeout > 0 else {
                stubborn.append(uid)
                continue
            }
            if (try? device.setNominalSampleRate(rate, timeout: timeout)) != true {
                stubborn.append(uid)
            }
        }
        return stubborn
    }

    /// Highest sample rate every device in the list can present.
    public static func highestCommonSampleRate(among devices: [AudioDevice]) -> Double? {
        guard let first = devices.first else { return nil }
        let shared = devices.dropFirst().reduce(Set(first.availableSampleRates)) {
            common, device in
            common.intersection(device.availableSampleRates)
        }
        return shared.max()
    }

    public func setBufferFrameSize(_ frames: UInt32) throws {
        guard AudioHardwareValuePolicy.supports(framesPerSlice: frames) else {
            throw AudioHardwareValueError.unsupportedFramesPerSlice(frames)
        }
        try id.setValue(frames, for: .bufferFrameSize)
    }

    /// The sub-devices that are being resampled to follow the clock master.
    ///
    /// This — not `kAudioDevicePropertyClockDomain`, which consumer hardware
    /// almost never publishes — is the authoritative answer to "is this path
    /// bit-exact?". We built the aggregate, so we know exactly who is drifting.
    public var driftCorrectedUIDs: [String] {
        subDevices.filter(\.driftCompensation).map(\.uid)
    }
}

public enum AggregateError: Error, CustomStringConvertible {
    case noSubDevices
    case clockMasterNotAMember(String)
    case creationFailed(OSStatus)
    case sampleRateUnavailable(String)
    case sampleRateDidNotSet(String, Double)
    case configurationExceedsLimit(resource: String, requested: Int, maximum: Int)
    case invalidConfiguration(String)
    case audioResiduePresent(AudioResidueTelemetry)

    public var description: String {
        switch self {
        case .noSubDevices:
            "an aggregate device needs at least one sub-device"
        case let .clockMasterNotAMember(uid):
            "clock master \(uid) is not among the sub-devices"
        case let .creationFailed(status):
            "AudioHardwareCreateAggregateDevice failed with \(fourCharDescription(status))"
        case let .sampleRateUnavailable(uid):
            "\(uid) did not report a current sample rate"
        case let .sampleRateDidNotSet(uid, rate):
            "\(uid) did not reach \(rate) Hz before the sample-rate deadline"
        case let .configurationExceedsLimit(resource, requested, maximum):
            "\(resource) requested \(requested), above the supported maximum of \(maximum)"
        case .invalidConfiguration(let reason):
            "invalid aggregate configuration: \(reason)"
        case .audioResiduePresent(let telemetry):
            "aggregate refused while \(telemetry.retainedEntries) cleanup owner(s) remain"
        }
    }
}
