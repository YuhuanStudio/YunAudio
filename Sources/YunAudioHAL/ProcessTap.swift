import AppKit
import CoreAudio
import Foundation

extension AudioProperty {
    public static var processList: AudioProperty<AudioObjectID> {
        .init(kAudioHardwarePropertyProcessObjectList)
    }
    public static var processBundleID: AudioProperty<CFString> {
        .init(kAudioProcessPropertyBundleID)
    }
    public static var processPID: AudioProperty<pid_t> {
        .init(kAudioProcessPropertyPID)
    }
    public static var processIsRunningOutput: AudioProperty<UInt32> {
        .init(kAudioProcessPropertyIsRunningOutput)
    }
    /// Which process has the microphone open.
    ///
    /// The HAL has published this since macOS 14.4 and nothing here asked. It
    /// is the missing half of the oldest complaint about audio on this
    /// platform: a Bluetooth headset drops to telephone quality the moment
    /// *anything* opens its microphone, and the person wearing it is never told
    /// what. macOS shows an orange dot and no name.
    public static var processIsRunningInput: AudioProperty<UInt32> {
        .init(kAudioProcessPropertyIsRunningInput)
    }
    public static var processDevices: AudioProperty<AudioObjectID> {
        .init(kAudioProcessPropertyDevices)
    }
    public static var tapList: AudioProperty<AudioObjectID> {
        .init(kAudioHardwarePropertyTapList)
    }
    public static var tapUID: AudioProperty<CFString> { .init(kAudioTapPropertyUID) }
    public static var tapFormat: AudioProperty<AudioStreamBasicDescription> {
        .init(kAudioTapPropertyFormat)
    }
    /// The description the HAL is holding for a tap, as opposed to the one this
    /// process handed it.
    ///
    /// Reading it back is the only way to find out whether CoreAudio *accepted*
    /// a setting or quietly dropped it — and this project has already been
    /// caught by exactly that once, with `kAudioSubDeviceInputChannelsKey`,
    /// which reads like a constraint in the header and turns out to be a
    /// description the HAL ignores.
    public static var tapDescription: AudioProperty<CATapDescription> {
        .init(kAudioTapPropertyDescription)
    }
}

/// An application the HAL knows about, which can therefore be tapped.
public struct AudioProcess: Sendable, Identifiable, Hashable {
    public let id: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    /// True when the process is currently producing audio.
    public let isPlaying: Bool
    /// True when the process currently has an input open.
    public let isRecording: Bool
    /// Display name resolved from the running application list.
    public let name: String

    init?(id: AudioObjectID, names: [pid_t: String]) {
        self.id = id
        guard let pid = id.optionalValue(of: .processPID) else { return nil }
        self.pid = pid
        bundleID = id.optionalString(of: .processBundleID)
        isPlaying = (id.optionalValue(of: .processIsRunningOutput) ?? 0) != 0
        isRecording = (id.optionalValue(of: .processIsRunningInput) ?? 0) != 0
        name =
            names[pid]
            ?? bundleID?.split(separator: ".").last.map(String.init)
            ?? "PID \(pid)"
    }
}

/// What the HAL knew immediately around one process-tap creation call.
///
/// `AudioHardwareCreateProcessTap` has been measured returning `noErr` and an
/// unknown object ID. A status and an empty ID cannot distinguish a process
/// disappearing during the call from the HAL creating an object and failing to
/// return it, so both object lists are sampled on either side of the call.
public struct ProcessTapCreationSnapshot: Sendable, Equatable {
    public struct ObservedTap: Sendable, Equatable {
        public let id: AudioObjectID
        public let processIDs: [AudioObjectID]?
        public let bundleIDs: [String]?
        /// The identity from the description held by the HAL.
        ///
        /// Object-list differences alone are not ownership: another process
        /// may create a tap in the same interval. The UUID is the one value
        /// copied from the exact description we handed CoreAudio, so it lets a
        /// successful creation whose out parameter stayed empty be recovered
        /// without adopting somebody else's tap.
        public let uuid: UUID?

        public init(
            id: AudioObjectID,
            processIDs: [AudioObjectID]?,
            bundleIDs: [String]?,
            uuid: UUID? = nil
        ) {
            self.id = id
            self.processIDs = processIDs
            self.bundleIDs = bundleIDs
            self.uuid = uuid
        }
    }

    public let requestedProcessIDs: [AudioObjectID]
    public let requestedBundleIDs: [String]
    public let ignoredBundleIDs: [String]
    public let processIDsBefore: [AudioObjectID]?
    public let processIDsAfter: [AudioObjectID]?
    public let tapIDsBefore: [AudioObjectID]?
    public let tapIDsAfter: [AudioObjectID]?
    public let newTaps: [ObservedTap]

    var diagnostic: String {
        func list(_ values: [AudioObjectID]?) -> String {
            guard let values else { return "unavailable" }
            return values.isEmpty ? "none" : values.map(String.init).joined(separator: ", ")
        }
        func presence(
            of requested: [AudioObjectID], in available: [AudioObjectID]?
        ) -> String {
            guard let available else { return "unavailable" }
            let present = Set(available)
            let missing = requested.filter { !present.contains($0) }
            return missing.isEmpty
                ? "all present"
                : "missing \(missing.map(String.init).joined(separator: ", "))"
        }
        let observed =
            newTaps.isEmpty
            ? "none"
            : newTaps.map { tap in
                let processes = list(tap.processIDs)
                let bundles =
                    tap.bundleIDs.map {
                        $0.isEmpty ? "none" : $0.joined(separator: ", ")
                    } ?? "unavailable"
                return "\(tap.id) [processes \(processes); bundles \(bundles)]"
            }.joined(separator: ", ")
        let bundles =
            requestedBundleIDs.isEmpty ? "none" : requestedBundleIDs.joined(separator: ", ")
        let ignored =
            ignoredBundleIDs.isEmpty
            ? ""
            : "; ignored non-bundle identity(s) \(ignoredBundleIDs.joined(separator: ", "))"
        return
            "process object(s) \(list(requestedProcessIDs)); "
            + "before: \(presence(of: requestedProcessIDs, in: processIDsBefore)); "
            + "after: \(presence(of: requestedProcessIDs, in: processIDsAfter)); "
            + "bundle(s) \(bundles)\(ignored); "
            + "new tap object(s) \(observed)"
    }
}

/// A live capture of one or more applications' audio.
///
/// Built on `AudioHardwareCreateProcessTap`, which lands the tapped audio on a
/// HAL object that an aggregate device can then include as a sub-device. That
/// is what makes this possible with no driver of our own: Loopback and its peers
/// ship a kernel-adjacent plug-in to intercept application audio, whereas this
/// is a documented API that has existed since macOS 14.2.
///
/// `@unchecked Sendable` covers immutable creation evidence plus one mutable
/// destruction state, and that state is serialised by `destructionLock`.
public final class ProcessTap: @unchecked Sendable {
    struct CensusIdentity: Sendable, Equatable {
        let id: AudioObjectID
        let uid: String
    }

    public let id: AudioObjectID
    public let uid: String
    /// Format the tap presents. Reported so the aggregate can be built to match.
    public let format: AudioStreamBasicDescription?
    /// The process and tap object lists immediately around creation.
    public let creationSnapshot: ProcessTapCreationSnapshot
    /// One normally; two when CoreAudio accepted a live process yet returned
    /// neither an object ID nor a matching object in the system tap list.
    public let creationAttempts: Int

    private let destructionLock = NSLock()
    private var destructionState = HALDestructionRequestState()
    private var removalWasConfirmed = false

    /// True when the tap was asked to remember its processes by bundle
    /// identifier and reattach to them when they come back.
    public let restoresProcesses: Bool
    /// The bundle identifiers this tap was told to hold on to. Empty when the
    /// tap is by process object alone.
    public let bundleIDs: [String]

    /// Triggers macOS's system-audio capture consent without starting IO.
    ///
    /// There is no standalone request API for this permission. CoreAudio asks
    /// when a process tap is created, so the least invasive request is a
    /// private global tap that is destroyed before it ever joins an aggregate.
    /// It neither mutes nor reads another application.
    public static func requestCaptureAccess() -> OSStatus {
        guard
            ProcessLifetimeAudioQuarantine.shared.refusalForNewAudioOwnership() == nil
        else {
            return kAudioHardwareNotReadyError
        }
        let description = capturePermissionDescription()
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapID != kAudioObjectUnknown else {
            // CoreAudio has returned `noErr` with no tap in production. That
            // proves neither permission nor capture, so the settings page must
            // not turn it into an Allowed badge.
            return status == noErr ? kAudioHardwareUnspecifiedError : status
        }
        let uid = (try? tapID.string(of: .tapUID)) ?? description.uuid.uuidString
        let destroyStatus = requestRawDestruction(
            id: tapID, uid: uid, reason: "capture-permission tap \(uid) requires census")
        return status == noErr ? destroyStatus : status
    }

    static func capturePermissionDescription() -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "YunAudio Permission Check"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    /// - Parameters:
    ///   - processIDs: `AudioObjectID`s of the processes to capture.
    ///   - muteBehavior: Whether the tapped application keeps playing through
    ///     the speakers. `.mutedWhenTapped` is the useful one for streaming: the
    ///     audio reaches the mix without also reaching the room.
    ///   - bundleIDs: Bundle identifiers of the same applications. Supplying
    ///     them switches on `processRestoreEnabled`, so the tap survives the
    ///     application quitting and reattaches when it launches again.
    /// - Throws: `ProcessTapError.creationFailed` when CoreAudio refuses, which
    ///   happens when the process has gone away between listing and tapping.
    public convenience init(
        processIDs: [AudioObjectID],
        muteBehavior: TapMuteBehavior = .unmuted,
        bundleIDs: [String] = []
    ) throws {
        try self.init(
            processIDs: processIDs, muteBehavior: muteBehavior,
            bundleIDs: bundleIDs, retryAdmission: { true })
    }

    /// Package construction path whose retry shares the route's absolute
    /// admission boundary. The first creation and its ownership census are one
    /// indivisible stage; expiry suppresses the otherwise useful second call.
    package init(
        processIDs: [AudioObjectID],
        muteBehavior: TapMuteBehavior = .unmuted,
        bundleIDs: [String] = [],
        retryAdmission: @escaping @Sendable () -> Bool
    ) throws {
        try ProcessTapCapacityPolicy.validate(
            processIDs: processIDs, bundleIDs: bundleIDs)
        let quarantine = ProcessLifetimeAudioQuarantine.shared
        if let residue = quarantine.refusalForNewAudioOwnership() {
            throw ProcessTapError.audioResiduePresent(residue)
        }
        guard retryAdmission() else { throw CancellationError() }
        // NS_REFINED_FOR_SWIFT turns the NSNumber array in the header into a
        // plain [AudioObjectID] on this side.
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.name = "YunAudio Tap"
        // Private: the tap belongs to this process and disappears with it,
        // rather than lingering in every other application's device list.
        description.isPrivate = true
        description.muteBehavior = muteBehavior.coreAudioValue

        // A tap is bound to process *object ids*, and an object id belongs to
        // one launch of one process. So a captured application that quits and
        // comes back is, to the tap, gone: the audio stops and nothing says so.
        //
        // That is not a hypothetical defect somebody might one day hit. It is
        // OBS's issue #9144, open since June 2023, and OBS's own answer to it
        // is a button in the source's properties labelled "Restart capture" —
        // a defect with a button on it.
        //
        // macOS 26 added the two properties that fix it: `bundleIDs` says which
        // applications the tap is *about* rather than which processes it is
        // attached to, and `processRestoreEnabled` tells the HAL to remember
        // them across an exit.
        //
        // Measured, and it changes which line matters: **the flag defaults to
        // true**. Every tap this application has ever made already had restore
        // switched on and restored nothing, because `bundleIDs` defaults to
        // empty and there was nothing to remember. So the working line here is
        // the one above it, and setting the flag alone would have been a change
        // with no effect that read exactly like a fix. Both are set, because
        // the default is somebody else's and could move; the assertion for all
        // of this is in `ProcessTapRestoreTests`.
        // Only identifiers that are actually bundle identifiers.
        //
        // A process with no bundle — every command-line tool, and more Electron
        // helpers than one would like — is listed under a synthetic `pid:1234`
        // identity, because the application list needs *something* to key on.
        // The note where that identity is made says such a process "can be
        // captured perfectly well", and it was true right up until this
        // initialiser started forwarding the identity to the HAL as a bundle
        // identifier.
        //
        // What the HAL does with `pid:61380` is the worst of the options: it
        // returns `noErr` and no tap object, so the capture does not happen and
        // nothing anywhere is an error. Measured against `afplay`, which is why
        // the flow check's key detection heard the room instead of the music it
        // had just put on — intermittently, because whether the process had a
        // bundle depended on which process the list happened to offer.
        //
        // Dropped rather than refused. Restoring across a relaunch is the only
        // thing these identifiers buy, and a process with no bundle could never
        // have had it: there is nothing stable to remember it by.
        let realBundleIDs = bundleIDs.filter {
            !$0.hasPrefix(AudioApplications.pidIdentityPrefix) && !$0.isEmpty
        }
        let ignoredBundleIDs = bundleIDs.filter { !realBundleIDs.contains($0) }
        // Process restore is a macOS 26 property of the description, and it is
        // the one feature here that older systems simply do not have: a tap
        // that survives the tapped application quitting and reattaches when it
        // launches again. Everything else about the tap works without it.
        //
        // Below 26 the tap is still created, still captures, and still names
        // the applications it was asked for — it just stops when they stop, and
        // `restoresProcesses` says so rather than claiming otherwise.
        var restoring = false
        if #available(macOS 26.0, *), !realBundleIDs.isEmpty {
            description.bundleIDs = realBundleIDs
            description.isProcessRestoreEnabled = true
            restoring = true
        }
        restoresProcesses = restoring
        self.bundleIDs = realBundleIDs

        var attempt = Self.create(
            description: description,
            requestedProcessIDs: processIDs,
            requestedBundleIDs: realBundleIDs,
            ignoredBundleIDs: ignoredBundleIDs)
        var attempts = 1

        // Measured on a live `afplay`: all requested process objects remained
        // present, the HAL returned success, and both the returned ID and the
        // tap-list difference were empty. Retrying the entire route from the
        // interface works, but costs a teardown and leaves an intermittent
        // hole in application capture. One bounded retry at the narrow API
        // boundary is the same recovery without rebuilding unrelated audio.
        if attempt.status == noErr,
            Self.resolvedTapID(
                returned: attempt.tapID,
                descriptionUUID: description.uuid,
                snapshot: attempt.snapshot) == nil,
            Self.shouldRetryMissingTap(attempt.snapshot),
            retryAdmission()
        {
            Thread.sleep(forTimeInterval: 0.02)
            if retryAdmission() {
                attempt = Self.create(
                    description: description,
                    requestedProcessIDs: processIDs,
                    requestedBundleIDs: realBundleIDs,
                    ignoredBundleIDs: ignoredBundleIDs)
                attempts += 1
            }
        }

        guard attempt.status == noErr else {
            // A failed API is not allowed to leave a private tap duplicating
            // audio for the rest of this process. Prefer the returned object,
            // otherwise destroy only the object carrying our exact UUID.
            if let leaked = Self.resolvedTapID(
                returned: attempt.tapID,
                descriptionUUID: description.uuid,
                snapshot: attempt.snapshot)
            {
                let leakedUID =
                    (try? leaked.string(of: .tapUID)) ?? description.uuid.uuidString
                Self.requestRawDestruction(
                    id: leaked, uid: leakedUID,
                    reason: "failed process-tap creation \(leakedUID) requires census")
            }
            throw ProcessTapError.creationFailed(attempt.status)
        }
        // Succeeded, and handed back nothing.
        //
        // Reported until now as `creationFailed(0)`, which prints as "failed
        // with 0" — `noErr` — and reads as a contradiction. It is a distinct
        // outcome and it is the one seen on this machine: the HAL accepts the
        // description, returns success, and produces no object.
        //
        // Deliberately not given a cause here. The obvious guess — that the
        // process had gone — is wrong in the case it was measured in: the flow
        // check's player runs for twenty-four seconds and the tap is attempted
        // about three seconds in. What the two arguments were is recorded
        // instead, because that is what the next person needs and it is a fact
        // rather than a theory.
        guard
            let tapID = Self.resolvedTapID(
                returned: attempt.tapID,
                descriptionUUID: description.uuid,
                snapshot: attempt.snapshot)
        else {
            throw ProcessTapError.noTapReturned(attempt.snapshot)
        }
        creationSnapshot = attempt.snapshot
        creationAttempts = attempts
        id = tapID
        guard retryAdmission() else {
            // The create call and its before/after census are one ownership
            // transaction: stopping between them could lose a real tap whose
            // out parameter stayed empty. Once its exact ID is adopted, later
            // descriptive property reads are optional and are suppressed.
            uid = description.uuid.uuidString
            format = nil
            return
        }
        uid = (try? tapID.string(of: .tapUID)) ?? description.uuid.uuidString
        guard retryAdmission() else {
            format = nil
            return
        }
        format = tapID.optionalValue(of: .tapFormat)
    }

    /// What the HAL is actually holding for this tap, rather than what it was
    /// handed.
    ///
    /// Worth the extra call at every point that cares. CoreAudio has form for
    /// accepting a description field and then ignoring it, and the failure mode
    /// is invisible: the tap works, the audio flows, and the one behaviour that
    /// was asked for silently never happens.
    public func systemDescription() -> CATapDescription? {
        Self.description(of: id)
    }

    /// Reads `kAudioTapPropertyDescription` off any tap object.
    ///
    /// The header says the caller owns the returned object, which is why this
    /// goes through `Unmanaged` rather than letting ARC guess.
    public static func description(of tap: AudioObjectID) -> CATapDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
        var unmanaged: Unmanaged<CATapDescription>?
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let unmanaged else { return nil }
        return unmanaged.takeRetainedValue()
    }

    /// The bundle identifiers a tap description carries, where the system has
    /// them.
    ///
    /// `CATapDescription.bundleIDs` arrived in macOS 26. Below that a tap is
    /// identified by its process objects and its UUID, which is what the
    /// recovery path matches on anyway — the identifiers are extra evidence in
    /// a diagnostic, not the thing being decided.
    private static func heldBundleIDs(_ description: CATapDescription?) -> [String]? {
        guard #available(macOS 26.0, *) else { return nil }
        return description?.bundleIDs
    }

    private struct CreationAttempt {
        let status: OSStatus
        let tapID: AudioObjectID
        let snapshot: ProcessTapCreationSnapshot
    }

    private static func create(
        description: CATapDescription,
        requestedProcessIDs: [AudioObjectID],
        requestedBundleIDs: [String],
        ignoredBundleIDs: [String]
    ) -> CreationAttempt {
        let processIDsBefore = try? AudioObjectID.system.array(
            of: .processList, maximumCount: HALSemanticArrayPolicy.maximumProcesses)
        let tapIDsBefore = try? AudioObjectID.system.array(
            of: .tapList, maximumCount: HALSemanticArrayPolicy.maximumTaps)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        let snapshot = snapshot(
            requestedProcessIDs: requestedProcessIDs,
            requestedBundleIDs: requestedBundleIDs,
            ignoredBundleIDs: ignoredBundleIDs,
            processIDsBefore: processIDsBefore,
            tapIDsBefore: tapIDsBefore)
        return CreationAttempt(status: status, tapID: tapID, snapshot: snapshot)
    }

    /// Recovers a tap the HAL created but did not put in its out parameter.
    ///
    /// Internal for the branch tests. Matching process or bundle identifiers is
    /// insufficient because two applications may tap the same player.
    static func resolvedTapID(
        returned: AudioObjectID,
        descriptionUUID: UUID,
        snapshot: ProcessTapCreationSnapshot
    ) -> AudioObjectID? {
        if returned != kAudioObjectUnknown { return returned }
        return snapshot.newTaps.first { $0.uuid == descriptionUUID }?.id
    }

    /// A retry is useful only when its subject still exists and the first call
    /// did not create an object that needs adopting or destroying.
    static func shouldRetryMissingTap(_ snapshot: ProcessTapCreationSnapshot) -> Bool {
        // An unavailable list is not an empty list. If either read failed, the
        // first call may have left an object that cannot safely be distinguished
        // from a concurrent tap, so a second creation could duplicate audio.
        guard snapshot.tapIDsBefore != nil, snapshot.tapIDsAfter != nil else { return false }
        guard snapshot.newTaps.isEmpty else { return false }
        if snapshot.requestedProcessIDs.isEmpty {
            return !snapshot.requestedBundleIDs.isEmpty
        }
        guard let after = snapshot.processIDsAfter else { return false }
        return Set(snapshot.requestedProcessIDs).isSubset(of: after)
    }

    private static func snapshot(
        requestedProcessIDs: [AudioObjectID],
        requestedBundleIDs: [String],
        ignoredBundleIDs: [String],
        processIDsBefore: [AudioObjectID]?,
        tapIDsBefore: [AudioObjectID]?
    ) -> ProcessTapCreationSnapshot {
        let processIDsAfter = try? AudioObjectID.system.array(
            of: .processList, maximumCount: HALSemanticArrayPolicy.maximumProcesses)
        let tapIDsAfter = try? AudioObjectID.system.array(
            of: .tapList, maximumCount: HALSemanticArrayPolicy.maximumTaps)
        let oldTaps = Set(tapIDsBefore ?? [])
        let newTaps = (tapIDsAfter ?? []).filter { !oldTaps.contains($0) }.map { id in
            let held = description(of: id)
            return ProcessTapCreationSnapshot.ObservedTap(
                id: id, processIDs: held?.processes,
                bundleIDs: heldBundleIDs(held),
                uuid: held?.uuid)
        }
        return ProcessTapCreationSnapshot(
            requestedProcessIDs: requestedProcessIDs,
            requestedBundleIDs: requestedBundleIDs,
            ignoredBundleIDs: ignoredBundleIDs,
            processIDsBefore: processIDsBefore,
            processIDsAfter: processIDsAfter,
            tapIDsBefore: tapIDsBefore,
            tapIDsAfter: tapIDsAfter,
            newTaps: newTaps)
    }

    deinit {
        let id = id
        let uid = uid
        let lifecycle = destructionLock.withLock {
            (destructionState.wasAccepted, removalWasConfirmed)
        }
        guard !lifecycle.1 else { return }
        Self.quarantineRawDestruction(
            id: id, uid: uid, requestWasAccepted: lifecycle.0,
            reason: "process tap \(uid) requires deinit census")
    }

    /// Requests destruction for a tap which has no `ProcessTap` owner.
    ///
    /// Permission probes and partially failed creation can both leave a real
    /// object behind without a wrapper to carry its lifecycle. The same
    /// fail-closed census used by `deinit` must own those objects too; a bare
    /// destroy call would turn an accepted asynchronous request into assumed
    /// absence.
    @discardableResult
    private static func requestRawDestruction(
        id: AudioObjectID,
        uid: String,
        reason: String
    ) -> OSStatus {
        let status = AudioHardwareDestroyProcessTap(id)
        quarantineRawDestruction(
            id: id, uid: uid, requestWasAccepted: status == noErr, reason: reason)
        return status
    }

    private static func quarantineRawDestruction(
        id: AudioObjectID,
        uid: String,
        requestWasAccepted: Bool,
        reason: String
    ) {
        let request = HALDestructionRequestCoordinator(
            requestWasAccepted: requestWasAccepted)
        BoundedHALDeinitCleanup.quarantine(
            reason: reason
        ) {
            let deadline = HALTeardownDeadline(timeout: 2)
            guard
                let status = deadline.perform({
                    request.request {
                        AudioHardwareDestroyProcessTap(id)
                    }
                }), status == noErr
            else { return false }

            return HALRemovalWaiter.wait(
                until: deadline,
                pollInterval: 0.01,
                betweenAttempts: { Thread.sleep(forTimeInterval: $0) },
                isPresent: {
                    do {
                        return try Self.censusContains(
                            id: id, uid: uid,
                            tapIDs: {
                                try AudioObjectID.system.array(
                                    of: .tapList,
                                    maximumCount: HALSemanticArrayPolicy.maximumTaps)
                            },
                            tapUID: { try $0.string(of: .tapUID) })
                    } catch {
                        return true
                    }
                })
        }
    }

    /// Requests removal once, retrying only when Core Audio refused it.
    @discardableResult
    public func destroy() -> OSStatus {
        destructionLock.lock()
        defer { destructionLock.unlock() }
        return destructionState.request {
            AudioHardwareDestroyProcessTap(id)
        }
    }

    private func destroy(until deadline: HALTeardownDeadline) -> OSStatus? {
        destructionLock.lock()
        defer { destructionLock.unlock() }
        return deadline.perform {
            destructionState.request {
                AudioHardwareDestroyProcessTap(id)
            }
        }
    }

    /// Waits until neither this object ID nor this tap UID remains in HAL.
    ///
    /// Reading only the original object ID is insufficient: HAL object IDs can
    /// be recycled while an asynchronous removal is in flight. Conversely,
    /// treating a census error as absence is exactly how an owner gets released
    /// while Core Audio can still call through it.
    public func destroyAndWait(timeout: TimeInterval = 2) -> HALDestructionResult {
        destroyAndWait(until: HALTeardownDeadline(timeout: timeout))
    }

    /// Uses the remaining portion of a route-wide teardown budget.
    public func destroyAndWait(until deadline: HALTeardownDeadline) -> HALDestructionResult {
        switch Self.destroyAllAndWait([self], until: deadline) {
        case .destroyed:
            return .destroyed
        case .failed(_, let result):
            return result
        }
    }

    /// Requests every removal first, then verifies all taps with one census per
    /// poll rather than giving every tap its own full timeout.
    ///
    /// The caller continues retaining the complete array until this returns
    /// `.destroyed`. On timeout no wrapper is marked confirmed, including taps
    /// which happened to disappear earlier in the same batch, so a later Stop
    /// retries the proof without relying on stale partial evidence.
    public static func destroyAllAndWait(
        _ taps: [ProcessTap], until deadline: HALTeardownDeadline
    ) -> ProcessTapBatchDestructionResult {
        var seen = Set<ObjectIdentifier>()
        let uniqueTaps = taps.filter {
            seen.insert(ObjectIdentifier($0)).inserted
        }
        guard !uniqueTaps.isEmpty else { return .destroyed }

        var firstRequestFailure: (tap: ProcessTap, status: OSStatus)?
        for tap in uniqueTaps {
            guard let status = tap.destroy(until: deadline) else {
                return .failed(uid: tap.uid, result: .timedOut)
            }
            if status != noErr, firstRequestFailure == nil {
                firstRequestFailure = (tap, status)
            }
        }
        if let failure = firstRequestFailure {
            return .failed(
                uid: failure.tap.uid, result: .requestFailed(failure.status))
        }

        let interval = 0.01
        let identities = uniqueTaps.map { CensusIdentity(id: $0.id, uid: $0.uid) }
        var presentUIDs = Set(identities.map(\.uid))
        let absent = HALRemovalWaiter.wait(
            until: deadline,
            pollInterval: interval,
            betweenAttempts: { Thread.sleep(forTimeInterval: $0) },
            isPresent: {
                do {
                    presentUIDs = try Self.censusPresentUIDs(
                        identities: identities,
                        tapIDs: {
                            try AudioObjectID.system.array(
                                of: .tapList,
                                maximumCount: HALSemanticArrayPolicy.maximumTaps)
                        },
                        tapUID: { try $0.string(of: .tapUID) },
                        shouldContinue: { deadline.remainingTimeInterval > 0 })
                    return !presentUIDs.isEmpty
                } catch {
                    presentUIDs = Set(identities.map(\.uid))
                    return true
                }
            })
        if absent {
            for tap in uniqueTaps {
                tap.destructionLock.withLock { tap.removalWasConfirmed = true }
            }
            return .destroyed
        }
        let unresolved = identities.first { presentUIDs.contains($0.uid) } ?? identities[0]
        return .failed(uid: unresolved.uid, result: .timedOut)
    }

    /// Last status returned by the removal request, even when it failed.
    public var destructionStatus: OSStatus? {
        destructionLock.lock()
        defer { destructionLock.unlock() }
        return destructionState.lastStatus
    }

    static func censusContains(
        id: AudioObjectID,
        uid: String,
        tapIDs: () throws -> [AudioObjectID],
        tapUID: (AudioObjectID) throws -> String
    ) throws -> Bool {
        for candidate in try tapIDs() {
            let candidateUID = try tapUID(candidate)
            // A reused numeric object ID carrying another UID is another tap,
            // not evidence that this one survived asynchronous removal.
            if candidate == id {
                if candidateUID == uid { return true }
                continue
            }
            if candidateUID == uid { return true }
        }
        return false
    }

    /// UIDs from this ownership batch which are still present in one HAL tap
    /// list snapshot. Each candidate UID is read once regardless of how many
    /// taps YunAudio owns.
    static func censusPresentUIDs(
        identities: [CensusIdentity],
        tapIDs: () throws -> [AudioObjectID],
        tapUID: (AudioObjectID) throws -> String,
        shouldContinue: () -> Bool = { true }
    ) throws -> Set<String> {
        let wanted = Set(identities.map(\.uid))
        var present = Set<String>()
        guard shouldContinue() else { throw BatchCensusError.deadlineExpired }
        let candidates = try tapIDs()
        for candidate in candidates {
            guard shouldContinue() else { throw BatchCensusError.deadlineExpired }
            let uid = try tapUID(candidate)
            if wanted.contains(uid) { present.insert(uid) }
        }
        return present
    }

    private enum BatchCensusError: Error { case deadlineExpired }
}

public enum ProcessTapBatchDestructionResult: Sendable, Equatable {
    case destroyed
    case failed(uid: String, result: HALDestructionResult)
}

public enum TapMuteBehavior: Sendable, CaseIterable {
    /// The application is captured and still heard.
    case unmuted
    /// The application is captured and silenced.
    case muted
    /// The application is heard until something reads the tap, then silenced —
    /// so it goes quiet exactly while it is being routed somewhere else.
    case mutedWhenTapped

    var coreAudioValue: CATapMuteBehavior {
        switch self {
        case .unmuted: .unmuted
        case .muted: .muted
        case .mutedWhenTapped: .mutedWhenTapped
        }
    }

    public var title: String {
        switch self {
        case .unmuted: "Keep playing"
        case .muted: "Silence the app"
        case .mutedWhenTapped: "Silence while routed"
        }
    }
}

public enum ProcessTapError: Error, CustomStringConvertible {
    case creationFailed(OSStatus)
    case configurationExceedsLimit(resource: String, requested: Int, maximum: Int)
    case invalidConfiguration(String)
    case audioResiduePresent(AudioResidueTelemetry)
    /// The HAL accepted the description, returned `noErr`, and produced no tap
    /// object. The arguments it was given, because the cause is not known and
    /// they are what would identify it.
    case noTapReturned(ProcessTapCreationSnapshot)

    public var description: String {
        switch self {
        case let .creationFailed(status):
            "AudioHardwareCreateProcessTap failed with \(fourCharDescription(status))"
        case let .configurationExceedsLimit(resource, requested, maximum):
            "\(resource) requested \(requested), above the supported maximum of \(maximum)"
        case .invalidConfiguration(let reason):
            "invalid process-tap configuration: \(reason)"
        case .audioResiduePresent(let telemetry):
            "process tap refused while \(telemetry.retainedEntries) cleanup owner(s) remain"
        case let .noTapReturned(snapshot):
            "AudioHardwareCreateProcessTap returned noErr and no tap; "
                + snapshot.diagnostic
        }
    }
}

extension AudioProcess {
    /// Devices this process currently has open, per scope.
    public func devices(scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        let property = AudioProperty<AudioObjectID>.processDevices.scoped(to: scope)
        return
            (try? id.array(
                of: property,
                maximumCount: HALSemanticArrayPolicy.maximumProcessDevices)) ?? []
    }
}

public enum AudioProcesses {
    /// Every process tap currently alive on the system, ours or anyone's.
    ///
    /// A tap that outlives the process that made it keeps duplicating audio,
    /// so this is the first thing to check when something sounds doubled.
    public static func liveTaps() -> [(id: AudioObjectID, uid: String)] {
        let ids =
            (try? AudioObjectID.system.array(
                of: .tapList, maximumCount: HALSemanticArrayPolicy.maximumTaps)) ?? []
        return ids.map { ($0, (try? $0.string(of: .tapUID)) ?? "—") }
    }

    /// Every process the HAL is tracking, newest-looking first.
    ///
    /// Processes with no bundle identifier and no audio activity are dropped:
    /// the raw list includes a long tail of system helpers that no one wants to
    /// pick from a menu.
    public static func all(includingSilent: Bool = false) throws -> [AudioProcess] {
        let names = runningApplicationNames()
        let ids = try AudioObjectID.system.array(
            of: .processList, maximumCount: HALSemanticArrayPolicy.maximumProcesses)
        return
            ids
            .compactMap { AudioProcess(id: $0, names: names) }
            .filter { includingSilent || $0.isPlaying || $0.bundleID != nil }
            .sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Maps PIDs to the names a person would recognise.
    ///
    /// An earlier version reached `NSRunningApplication` through KVC to keep
    /// AppKit out of this module. That was wrong twice over:
    /// `runningApplications` is a class method, so the KVC lookup could never
    /// succeed — it failed silently in a command-line context and threw
    /// `NSUnknownKeyException` inside an app. Importing AppKit is the honest
    /// cost of showing "Discord" instead of "Renderer".
    private static func runningApplicationNames() -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard let name = application.localizedName else { continue }
            result[application.processIdentifier] = name
        }
        return result
    }
}
