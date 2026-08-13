import AppKit
import Foundation
import ServiceManagement
import YunAudioEngine
import YunAudioHAL
import YunDesign

/// Everything the app remembers between launches.
///
/// Devices are stored by UID, never by `AudioObjectID`: the numeric ID is
/// reassigned when a device is replugged or when the machine reboots, so a
/// persisted ID would silently start pointing at someone else's hardware.
struct Preferences: Codable, Equatable, Sendable {
    var sourceDeviceUID: String?
    var destinationDeviceUID: String?
    var channelMode: String
    var monoChannel: Int
    var bufferFrames: UInt32
    /// Start routing as soon as the app launches and the devices are present.
    var autoStart: Bool
    var voiceIsolationEnabled: Bool
    var voiceIsolationMix: Float
    var preferredSampleRate: Double
    /// Bundle identifiers of applications captured as routing sources.
    var capturedAppBundleIDs: [String]
    /// Applications this router will never tap, whatever is selected.
    var excludedAppBundleIDs: [String]?
    /// Raw values of the enabled processing stages.
    var enabledEffects: [String]
    /// Knob positions, keyed by "<stage>.<parameter>".
    var effectValues: [String: Float]
    /// Capture the microphone through the echo canceller. Optional so a
    /// preferences file written before this existed still decodes.
    var cancelsEcho: Bool?
    /// Use CoreAudio's device-global detector for the muted-speaking warning.
    /// Optional so existing files remain decodable; absence means fail closed.
    var warnsWhenSpeakingWhileMuted: Bool?
    /// The speaker the canceller listens for. Nil means the current default.
    var echoSpeakerUID: String?
    /// Which look the application wears. Optional so a file written before the
    /// setting existed still decodes.
    var style: String?
    /// Which of `YunIconBadge.styles` the application icon wears. Optional for
    /// the same reason.
    var iconStyle: String?
    /// The input trim and the master, in decibels. Optional for the same
    /// reason.
    /// What the microphone's light ring shows.
    var lightingMode: String?
    var lightingHue: Double?
    var lightingBrightness: Double?
    var inputDecibels: Float?
    var isInputMuted: Bool?
    var outputDecibels: Float?
    var isOutputMuted: Bool?
    /// Which platform the loudness readout is compared against.
    var loudnessTarget: String?
    /// Where the microphone is also sent so the user can hear themselves.
    var monitorDeviceUID: String?
    var monitorDecibels: Float?
    /// Hold the microphone at the target loudness automatically.
    var isAutoLevelling: Bool?
    /// Application audio steps out of the way while somebody is talking.
    var isDucking: Bool?
    var duckDecibels: Float?
    /// What each source is for, keyed by device UID or bundle identifier.
    var sourceRoles: [String: String]?
    /// Hold a key to talk rather than clicking to mute.
    var isPushToTalkEnabled: Bool?
    /// Third-party Audio Units in the chain, and their knob positions.
    var plugins: [AudioUnitPlugin]?
    var pluginValues: [String: Float]?
    /// A whole voice, rather than the two stages it is made of.
    var voicePreset: String?
    /// Write a separate file per source alongside the mix.
    var recordsStems: Bool?
    /// The container recordings are written in.
    ///
    /// Stored by raw value rather than as `Recorder.Format` for the reason
    /// `tapMuteBehavior` is: the type belongs to the engine, and a preferences
    /// file is a promise to a version that has not been built yet.
    var recordingFormat: String?
    /// How much of each source goes to the monitor, by source UID.
    var monitorSends: [String: Float]?
    /// Extra delay per output device UID, in milliseconds, for lining up two
    /// outputs that do not arrive together.
    var outputDelays: [String: Double]?
    /// The headphone correction in use, by file name.
    ///
    /// Superseded by `busHeadphoneProfiles`, and kept so that a file written
    /// before buses had their own still opens. Read once on the way in and
    /// folded into the bus it used to mean; never written again.
    var headphoneProfileName: String?
    /// Ten slider positions for the output tone control, in decibels.
    ///
    /// Superseded by `busGraphicEQ`, on the same terms.
    var graphicEQ: [Float]?
    /// Ten slider positions per bus, by output device UID.
    ///
    /// Keyed by device rather than by the bus's letter: the letters are
    /// positional — turning the monitor off promotes B to A — and a tone
    /// somebody dialled in for their headphones must not migrate to the stream
    /// mix because a picker changed.
    var busGraphicEQ: [String: [Float]]?
    /// The headphone correction per bus, by output device UID, by file name.
    var busHeadphoneProfiles: [String: String]?
    /// Devices chosen before, most recent first.
    ///
    /// Not a preference somebody sets — a record of what they have actually
    /// used, which is the only ranking that needs no interface and is right
    /// more often than one that does. It decides what to fall back to when the
    /// device in the route is unplugged.
    var recentSourceUIDs: [String]?
    var recentDestinationUIDs: [String]?
    /// Which physical control drives what, as flat strings — the target's own
    /// key against the message's. Flat rather than nested so that a file
    /// somebody has to read by hand stays readable, and so that a target this
    /// version has never heard of can be dropped on the way in without taking
    /// the rest of the decode down with it.
    var midiBindings: [String: String]?
    /// Whether a captured application is still heard while it is being tapped.
    ///
    /// Stored as a string rather than by giving `TapMuteBehavior` a raw value:
    /// that type lives in the HAL layer, where the shape of this application's
    /// preferences file has no business being.
    var tapMuteBehavior: String?

    /// The script that stays loaded and reacts to things.
    ///
    /// Optional so a file written by a version that predates scripting still
    /// decodes — every field added here has been, and the one time one was
    /// not, every setting after it in the file was silently lost.
    var residentScript: String?

    /// Which channel of each source somebody chose, by device UID.
    ///
    /// Per device because it is a fact about that device: without it, every
    /// source change put the choice back to the default.
    var sourceChannelChoices: [String: String]?

    /// Further inputs and outputs beyond the primary pair.
    ///
    /// Stored separately from `sourceDeviceUID` and `destinationDeviceUID`
    /// rather than turning those into arrays, so that a preferences file
    /// written by a version that had one of each still opens — and because the
    /// first of each is the aggregate's clock master, which is a fact about the
    /// route rather than an ordering convenience.
    var additionalSourceUIDs: [String]?
    var additionalDestinationUIDs: [String]?

    /// A level for each additional output, in decibels, by device UID.
    ///
    /// Separate from `outputDelays` although both are per output: one is
    /// alignment and the other is loudness, and a single map would make a file
    /// somebody opens by hand ambiguous about which is which.
    var outputTrims: [String: Float]?

    /// Each source's fader position, in decibels, by source UID.
    ///
    /// A fader used to exist only as the gain of a route the engine had built,
    /// so every restart put the whole mixer back to unity and nothing said so.
    var sourceLevels: [String: Float]?

    /// Where OBS is, and which of its inputs reads this application.
    ///
    /// The password is deliberately absent. `UserDefaults` is a plain file in
    /// the user's home directory, and this application's own control socket is
    /// `chmod 600` because of what it can do; a websocket password in clear
    /// beside that would be inconsistent. See `OBSLink.password`.
    var obsHost: String?
    var obsPort: Int?
    var obsInputName: String?
    var obsMirrorsMute: Bool?

    // Things somebody switched on, which used to be forgotten every launch.
    //
    // All optional, like everything added since the first version: a
    // preferences file written before these existed still decodes.

    /// Whether the singing is being scored. The KTV switch — somebody who sings
    /// every evening had to find it again every evening.
    var isScoringSinging: Bool?
    /// 重唱. A property of the queue, and the queue outlives a launch.
    var repeatsOneSong: Bool?
    /// Which inspector tab was open. Coming back to the panel somebody was
    /// using is what every other application on this machine does.
    var inspectorTab: String?
    /// Whether the daemons are listed with the applications.
    var showsBackgroundApps: Bool?
    /// Whether Apple's sound classifier is running for the analysis card. It is
    /// opt-in because it costs, and opting in should stay opted in.
    var isSoundIdentificationEnabled: Bool?
    /// The songs that were put on, and which one was being sung. A KTV evening
    /// is a list somebody built up over an hour, and quitting threw it away.
    var queuedSongPaths: [String]?
    var queuedSongIndex: Int?

    static let `default` = Preferences(
        sourceDeviceUID: nil,
        destinationDeviceUID: nil,
        channelMode: SourceChannelMode.mono.rawValue,
        monoChannel: 0,
        bufferFrames: 128,
        autoStart: false,
        voiceIsolationEnabled: false,
        voiceIsolationMix: 100,
        preferredSampleRate: 48000,
        capturedAppBundleIDs: [],
        excludedAppBundleIDs: [],
        enabledEffects: [],
        effectValues: [:],
        cancelsEcho: false,
        warnsWhenSpeakingWhileMuted: false,
        echoSpeakerUID: nil,
        style: YunStyle.flat.rawValue,
        lightingMode: LightingMode.off.rawValue,
        lightingHue: 0.55,
        lightingBrightness: 1,
        inputDecibels: 0,
        isInputMuted: false,
        outputDecibels: 0,
        isOutputMuted: false,
        loudnessTarget: LoudnessTarget.discord.rawValue,
        monitorDeviceUID: nil,
        monitorDecibels: -6,
        isAutoLevelling: false,
        isDucking: false,
        duckDecibels: -14,
        sourceRoles: [:],
        isPushToTalkEnabled: false,
        plugins: [],
        pluginValues: [:],
        voicePreset: VoicePreset.none.rawValue,
        recordsStems: false,
        recordingFormat: Recorder.Format.wav.rawValue,
        monitorSends: [:],
        outputDelays: [:],
        headphoneProfileName: nil,
        graphicEQ: [Float](repeating: 0, count: 10),
        busGraphicEQ: [:],
        busHeadphoneProfiles: [:],
        recentSourceUIDs: [],
        recentDestinationUIDs: [],
        midiBindings: [:],
        tapMuteBehavior: TapMuteBehavior.unmuted.storageKey,
        residentScript: nil,
        sourceChannelChoices: [:],
        additionalSourceUIDs: [],
        additionalDestinationUIDs: [],
        outputTrims: [:],
        sourceLevels: [:],
        obsHost: "127.0.0.1",
        obsPort: 4455,
        obsInputName: "",
        obsMirrorsMute: false,
        isScoringSinging: false,
        repeatsOneSong: false,
        inspectorTab: nil,
        showsBackgroundApps: false,
        isSoundIdentificationEnabled: false,
        queuedSongPaths: [],
        queuedSongIndex: nil)
}

/// A value-semantic preference snapshot whose derived collections are built
/// only if this is the last value in the coalescing window.
///
/// The source sets and dictionaries are copied here while `persist()` is
/// called. Their copy-on-write storage preserves the exact event-time state,
/// including when a later automatic adjustment deliberately suppresses
/// persistence. Turning them into the Codable shape is the allocating part and
/// can wait until the writer knows this snapshot will actually reach disk.
struct PendingPreferencesSnapshot: Sendable {
    private struct DeferredCollections {
        var capturedAppBundleIDs: Set<String>
        var excludedAppBundleIDs: Set<String>
        var enabledEffects: Set<EffectKind>
        var sourceRoles: [String: LevelCalibration.Role]
        var midiBindings: [MIDITarget: MIDIAddress]
    }

    private var preferences: Preferences
    private var deferredCollections: DeferredCollections?

    init(_ preferences: Preferences) {
        self.preferences = preferences
        deferredCollections = nil
    }

    init(
        _ preferences: Preferences,
        capturedAppBundleIDs: Set<String>,
        excludedAppBundleIDs: Set<String>,
        enabledEffects: Set<EffectKind>,
        sourceRoles: [String: LevelCalibration.Role],
        midiBindings: [MIDITarget: MIDIAddress]
    ) {
        self.preferences = preferences
        deferredCollections = DeferredCollections(
            capturedAppBundleIDs: capturedAppBundleIDs,
            excludedAppBundleIDs: excludedAppBundleIDs,
            enabledEffects: enabledEffects,
            sourceRoles: sourceRoles,
            midiBindings: midiBindings)
    }

    func materialised() -> Preferences {
        guard let deferredCollections else { return preferences }
        var materialised = preferences
        materialised.capturedAppBundleIDs = Array(deferredCollections.capturedAppBundleIDs)
        materialised.excludedAppBundleIDs = Array(deferredCollections.excludedAppBundleIDs)
        materialised.enabledEffects = deferredCollections.enabledEffects.map(\.rawValue)
        materialised.sourceRoles = deferredCollections.sourceRoles.mapValues(\.rawValue)
        materialised.midiBindings = MIDIController.storedBindings(
            for: deferredCollections.midiBindings)
        return materialised
    }
}

extension TapMuteBehavior {
    /// A name that is safe to write down.
    ///
    /// Not `String(describing:)`: that is a debugging convenience the compiler
    /// is free to change, and a preferences file is a promise to a copy of the
    /// application that has not been built yet.
    var storageKey: String {
        switch self {
        case .unmuted: "unmuted"
        case .muted: "muted"
        case .mutedWhenTapped: "mutedWhenTapped"
        }
    }

    init?(storageKey: String) {
        guard let match = TapMuteBehavior.allCases.first(where: { $0.storageKey == storageKey })
        else { return nil }
        self = match
    }
}

/// The observable answer to a request for a preferences durability boundary.
enum PreferenceFlushResult: Equatable, Sendable {
    /// Every snapshot submitted before the request reached `UserDefaults`, and
    /// its preferences domain accepted an explicit synchronisation request.
    /// This is the strongest boundary that API reports; it is not a claim that
    /// bytes have reached physical storage.
    case synchronised
    /// This process has submitted no preference value that needs a barrier.
    case nothingToWrite
    /// Encoding, storing or synchronising the requested snapshot failed.
    case failed
    /// The writer may still finish, but did not prove synchronisation in time.
    case timedOut
    /// The bounded waiter set was full, so this request retained no waiter and
    /// completed immediately.
    case superseded

    var isAccepted: Bool {
        self == .synchronised || self == .nothingToWrite
    }
}

/// The complete preferences-domain durability boundary for accepted Quit.
struct ApplicationPersistenceFlushReport: Equatable, Sendable {
    let preferences: PreferenceFlushResult
    let quickConfigurations: PreferenceFlushResult
    let userPresets: PreferenceFlushResult

    var isAccepted: Bool {
        preferences.isAccepted && quickConfigurations.isAccepted && userPresets.isAccepted
    }
}

/// Joins the three independent preferences writers without serialising deadlines.
@MainActor
final class ApplicationPersistenceFlushJoin {
    private var preferences: PreferenceFlushResult?
    private var quickConfigurations: PreferenceFlushResult?
    private var userPresets: PreferenceFlushResult?
    private var didComplete = false
    private let completion: @MainActor (ApplicationPersistenceFlushReport) -> Void

    init(completion: @escaping @MainActor (ApplicationPersistenceFlushReport) -> Void) {
        self.completion = completion
    }

    func receivePreferences(_ result: PreferenceFlushResult) {
        guard preferences == nil else { return }
        preferences = result
        finishIfReady()
    }

    func receiveQuickConfigurations(_ result: PreferenceFlushResult) {
        guard quickConfigurations == nil else { return }
        quickConfigurations = result
        finishIfReady()
    }

    func receiveUserPresets(_ result: PreferenceFlushResult) {
        guard userPresets == nil else { return }
        userPresets = result
        finishIfReady()
    }

    private func finishIfReady() {
        guard !didComplete,
            let preferences,
            let quickConfigurations,
            let userPresets
        else { return }
        didComplete = true
        completion(
            ApplicationPersistenceFlushReport(
                preferences: preferences,
                quickConfigurations: quickConfigurations,
                userPresets: userPresets))
    }
}

/// The first value already being written and the latest value behind it.
///
/// This state is deliberately value-only. Its 10,000-request proof does not
/// need a queue or a scheduler, so the bound cannot pass because a test happened
/// not to give queued work time to run.
struct PreferenceWriteGate<Value: Sendable> {
    struct Entry: Sendable {
        let generation: UInt64
        let value: Value
    }

    private(set) var active: Entry?
    private(set) var pending: Entry?
    private(set) var latest: Entry?
    private var generation: UInt64 = 0

    /// The queue-retained values. `latest` is one additional read cache, so the
    /// complete memory bound is three value-semantic snapshots.
    var retainedRequestCount: Int {
        (active == nil ? 0 : 1) + (pending == nil ? 0 : 1)
    }

    @discardableResult
    mutating func submit(_ value: Value) -> Entry {
        generation &+= 1
        let entry = Entry(generation: generation, value: value)
        pending = entry
        latest = entry
        return entry
    }

    mutating func takePending() -> Entry? {
        guard active == nil, let pending else { return nil }
        active = pending
        self.pending = nil
        return pending
    }

    @discardableResult
    mutating func finish(_ generation: UInt64) -> Bool {
        guard active?.generation == generation else { return false }
        active = nil
        return true
    }

    /// Gives an explicit flush one retry after an earlier write failed.
    ///
    /// The generation stays the same: this is the same requested state, not a
    /// new publication. It is restored only while idle, so a newer pending
    /// snapshot always wins and one failing encoder cannot create a retry loop.
    @discardableResult
    mutating func restoreLatestIfIdle() -> Bool {
        guard active == nil, pending == nil, let latest else { return false }
        pending = latest
        return true
    }
}

enum PreferenceWorkerWaitDecision: Equatable, Sendable {
    case waitForSignal
    case waitNanoseconds(UInt64)
    case runNow
}

/// Decides the worker's only idle transition without touching a condition.
///
/// An active-only flush once left an already-expired deadline behind after the
/// write finished. With no pending value to consume, the worker repeatedly
/// observed that deadline while retaining the condition mutex, spinning a core
/// and preventing its owner from ever closing. Keeping this decision pure makes
/// that exact state assertable without hanging a test process to observe it.
struct PreferenceWorkerWaitPolicy {
    static func decide(
        hasPending: Bool,
        deadline: UInt64?,
        now: UInt64
    ) -> PreferenceWorkerWaitDecision {
        guard hasPending else { return .waitForSignal }
        guard let deadline else { return .waitForSignal }
        guard deadline > now else { return .runNow }
        return .waitNanoseconds(deadline - now)
    }
}

/// One bounded, background preference writer.
///
/// A single condition-driven worker owns both encoding and the sink. Submitting
/// a value only replaces `pending`; it never appends a dispatch block or starts
/// a task. The first pending value fixes the coalescing deadline, so continuous
/// movement is persisted periodically rather than postponing forever.
final class CoalescedPreferenceWriter<Value: Sendable>: @unchecked Sendable {
    struct Metrics: Equatable, Sendable {
        var workerStarts: Int
        var maximumConcurrentWrites: Int
        var maximumRetainedSnapshots: Int
        var maximumFlushWaiters: Int
    }

    private struct Waiter: @unchecked Sendable {
        let id: UInt64
        let targetGeneration: UInt64
        let completion: @MainActor @Sendable (PreferenceFlushResult) -> Void
    }

    private final class Core: @unchecked Sendable {
        let condition = NSCondition()
        let delayNanoseconds: UInt64
        let now: @Sendable () -> UInt64
        let write: @Sendable (Value) -> Bool
        let synchronise: @Sendable () -> Bool
        let completionQueue: DispatchQueue

        var gate = PreferenceWriteGate<Value>()
        var pendingDeadline: UInt64?
        var acceptedGeneration: UInt64 = 0
        var synchronisedGeneration: UInt64 = 0
        var failedSynchronisationGeneration: UInt64?
        var nextWaiterID: UInt64 = 0
        var waiters: [UInt64: Waiter] = [:]
        var closesAfterDrain = false
        var workerHasExited = false
        var concurrentWrites = 0
        var metrics = Metrics(
            workerStarts: 0,
            maximumConcurrentWrites: 0,
            maximumRetainedSnapshots: 0,
            maximumFlushWaiters: 0)

        static var maximumWaiters: Int { 16 }

        init(
            delayNanoseconds: UInt64,
            now: @escaping @Sendable () -> UInt64,
            write: @escaping @Sendable (Value) -> Bool,
            synchronise: @escaping @Sendable () -> Bool,
            completionQueue: DispatchQueue
        ) {
            self.delayNanoseconds = delayNanoseconds
            self.now = now
            self.write = write
            self.synchronise = synchronise
            self.completionQueue = completionQueue
        }

        func submit(_ value: Value) {
            condition.lock()
            let hadPending = gate.pending != nil
            gate.submit(value)
            if !hadPending {
                pendingDeadline = Self.addingClamped(delayNanoseconds, to: now())
            }
            metrics.maximumRetainedSnapshots = max(
                metrics.maximumRetainedSnapshots, gate.retainedRequestCount + 1)
            condition.signal()
            condition.unlock()
        }

        func requestFlush(
            timeoutNanoseconds: UInt64,
            completion: @escaping @MainActor @Sendable (PreferenceFlushResult) -> Void
        ) -> PreferenceFlushResult? {
            condition.lock()
            guard let target = gate.latest?.generation else {
                condition.unlock()
                return .nothingToWrite
            }
            if synchronisedGeneration >= target {
                condition.unlock()
                return .synchronised
            }
            guard waiters.count < Self.maximumWaiters else {
                condition.unlock()
                return .superseded
            }

            nextWaiterID &+= 1
            let id = nextWaiterID
            waiters[id] = Waiter(
                id: id, targetGeneration: target, completion: completion)
            metrics.maximumFlushWaiters = max(metrics.maximumFlushWaiters, waiters.count)
            if acceptedGeneration < target { gate.restoreLatestIfIdle() }
            if failedSynchronisationGeneration.map({ $0 >= target }) == true {
                failedSynchronisationGeneration = nil
            }
            if gate.pending != nil { pendingDeadline = now() }
            condition.signal()
            condition.unlock()

            completionQueue.asyncAfter(
                deadline: .now() + .nanoseconds(Int(clamping: timeoutNanoseconds))
            ) { [weak self] in
                self?.timeOutWaiter(id)
            }
            return nil
        }

        func closeAfterDrain() {
            condition.lock()
            closesAfterDrain = true
            if let latest = gate.latest, acceptedGeneration < latest.generation {
                gate.restoreLatestIfIdle()
            }
            pendingDeadline = now()
            condition.signal()
            condition.unlock()
        }

        func snapshot() -> (
            pending: Value?, latest: Value?, hasScheduledWrite: Bool,
            hasUncommittedValue: Bool, metrics: Metrics
        ) {
            condition.lock()
            defer { condition.unlock() }
            return (
                gate.pending?.value,
                gate.latest?.value,
                gate.pending != nil,
                gate.latest.map { synchronisedGeneration < $0.generation } ?? false,
                metrics
            )
        }

        func run() {
            condition.lock()
            metrics.workerStarts += 1
            while true {
                if shouldSynchronise {
                    let generation = acceptedGeneration
                    condition.unlock()
                    let succeeded = synchronise()
                    condition.lock()
                    if succeeded {
                        synchronisedGeneration = max(synchronisedGeneration, generation)
                        failedSynchronisationGeneration = nil
                        completeWaiters(upTo: synchronisedGeneration, with: .synchronised)
                    } else {
                        failedSynchronisationGeneration = generation
                        failWaiters(upTo: generation)
                    }
                    continue
                }

                if shouldTakePending, let entry = gate.takePending() {
                    pendingDeadline = nil
                    concurrentWrites += 1
                    metrics.maximumConcurrentWrites = max(
                        metrics.maximumConcurrentWrites, concurrentWrites)
                    metrics.maximumRetainedSnapshots = max(
                        metrics.maximumRetainedSnapshots, gate.retainedRequestCount + 1)
                    condition.unlock()
                    let succeeded = write(entry.value)
                    condition.lock()
                    concurrentWrites -= 1
                    precondition(gate.finish(entry.generation))
                    if succeeded {
                        acceptedGeneration = max(acceptedGeneration, entry.generation)
                    } else if gate.pending == nil {
                        failWaiters(upTo: entry.generation)
                    }
                    continue
                }

                if closesAfterDrain, gate.active == nil, gate.pending == nil,
                    waiters.isEmpty
                {
                    workerHasExited = true
                    condition.broadcast()
                    condition.unlock()
                    return
                }

                switch PreferenceWorkerWaitPolicy.decide(
                    hasPending: gate.pending != nil,
                    deadline: pendingDeadline,
                    now: now()
                ) {
                case .waitForSignal:
                    pendingDeadline = nil
                    condition.wait()
                case .waitNanoseconds(let nanoseconds):
                    let interval = Double(nanoseconds) / 1_000_000_000
                    condition.wait(until: Date(timeIntervalSinceNow: interval))
                case .runNow:
                    continue
                }
            }
        }

        private var highestFlushTarget: UInt64? {
            waiters.values.map(\.targetGeneration).max()
        }

        private var shouldSynchronise: Bool {
            guard let target = highestFlushTarget else {
                return closesAfterDrain && acceptedGeneration > synchronisedGeneration
                    && failedSynchronisationGeneration != acceptedGeneration
            }
            return acceptedGeneration >= target && synchronisedGeneration < target
                && failedSynchronisationGeneration != acceptedGeneration
        }

        private var shouldTakePending: Bool {
            guard let pending = gate.pending else { return false }
            if closesAfterDrain { return true }
            if let target = highestFlushTarget, target >= pending.generation { return true }
            return pendingDeadline.map { now() >= $0 } ?? false
        }

        private func timeOutWaiter(_ id: UInt64) {
            condition.lock()
            guard let waiter = waiters.removeValue(forKey: id) else {
                condition.unlock()
                return
            }
            condition.signal()
            condition.unlock()
            deliver(.timedOut, to: waiter.completion)
        }

        private func completeWaiters(
            upTo generation: UInt64,
            with result: PreferenceFlushResult
        ) {
            let completed = waiters.values.filter { $0.targetGeneration <= generation }
            for waiter in completed { waiters.removeValue(forKey: waiter.id) }
            for waiter in completed { deliver(result, to: waiter.completion) }
        }

        private func failWaiters(upTo generation: UInt64) {
            completeWaiters(upTo: generation, with: .failed)
        }

        private func deliver(
            _ result: PreferenceFlushResult,
            to completion: @escaping @MainActor @Sendable (PreferenceFlushResult) -> Void
        ) {
            MainRunLoopDelivery.perform { completion(result) }
        }

        private static func addingClamped(_ lhs: UInt64, to rhs: UInt64) -> UInt64 {
            let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
            return overflowed ? UInt64.max : sum
        }
    }

    private let core: Core

    /// A sink that cannot report failure, retained for small in-memory users.
    convenience init(
        delay: Duration,
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.preferences", qos: .utility),
        write: @escaping @Sendable (Value) -> Void
    ) {
        self.init(
            delay: delay, queue: queue,
            durableWrite: {
                write($0)
                return true
            },
            synchronise: { true })
    }

    /// Injectable encoder, sink, synchronisation barrier and clock.
    convenience init<Payload: Sendable>(
        delay: Duration,
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.preferences", qos: .utility),
        now: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        encode: @escaping @Sendable (Value) -> Payload?,
        sink: @escaping @Sendable (Payload) -> Bool,
        synchronise: @escaping @Sendable () -> Bool
    ) {
        self.init(
            delay: delay, queue: queue, now: now,
            durableWrite: { value in
                guard let payload = encode(value) else { return false }
                return sink(payload)
            },
            synchronise: synchronise)
    }

    init(
        delay: Duration,
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.preferences", qos: .utility),
        now: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        durableWrite: @escaping @Sendable (Value) -> Bool,
        synchronise: @escaping @Sendable () -> Bool
    ) {
        core = Core(
            delayNanoseconds: Self.nanoseconds(delay),
            now: now,
            write: durableWrite,
            synchronise: synchronise,
            completionQueue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.preferences.flush-timeout",
                qos: .utility))
        let core = core
        queue.async { core.run() }
    }

    deinit {
        core.closeAfterDrain()
    }

    var pendingValue: Value? { core.snapshot().pending }
    var latestValue: Value? { core.snapshot().latest }
    var hasScheduledWrite: Bool { core.snapshot().hasScheduledWrite }
    var hasUncommittedValue: Bool { core.snapshot().hasUncommittedValue }
    var metrics: Metrics { core.snapshot().metrics }

    func submit(_ value: Value) {
        core.submit(value)
    }

    @MainActor
    func flush(
        timeout: Duration = .seconds(1),
        completion: @escaping @MainActor @Sendable (PreferenceFlushResult) -> Void
    ) {
        if let immediate = core.requestFlush(
            timeoutNanoseconds: Self.nanoseconds(timeout), completion: completion)
        {
            completion(immediate)
        }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let (wholeSeconds, secondsOverflowed) = seconds.multipliedReportingOverflow(
            by: 1_000_000_000)
        guard !secondsOverflowed else { return UInt64.max }
        let (total, totalOverflowed) = wholeSeconds.addingReportingOverflow(nanoseconds)
        return totalOverflowed ? UInt64.max : total
    }
}

private let preferencesStoreKey = "com.yuhuanstudio.yunaudio.preferences"

@MainActor
enum PreferencesStore {
    private static let writer = CoalescedPreferenceWriter<PendingPreferencesSnapshot>(
        delay: .milliseconds(150),
        encode: { snapshot in
            try? JSONEncoder().encode(snapshot.materialised())
        },
        sink: { data in
            UserDefaults.standard.set(data, forKey: preferencesStoreKey)
            return UserDefaults.standard.data(forKey: preferencesStoreKey) == data
        },
        synchronise: { UserDefaults.standard.synchronize() })

    /// Whether anything has ever been saved.
    ///
    /// `load()` answers with defaults either way, which is right for reading a
    /// setting and wrong for deciding whether somebody has made a choice at
    /// all: a first launch and a launch where every value happens to equal its
    /// default are indistinguishable from the outside.
    static var hasStoredPreferences: Bool {
        writer.latestValue != nil
            || UserDefaults.standard.data(forKey: preferencesStoreKey) != nil
    }

    static func load() -> Preferences {
        // Runtime callers need the latest event-time snapshot even while its
        // background write is in flight. Materialising an explicit read is
        // intentionally synchronous; slider publication never calls `load`,
        // and the encoder and preferences-domain IO always stay on the worker.
        if let latest = writer.latestValue { return latest.materialised() }
        return loadPersisted()
    }

    /// Decodes only the preferences domain, for evidence across a durability
    /// boundary. Ordinary model code wants `load()`: using this without first
    /// awaiting `flush` would merely exchange one stale answer for another.
    static func loadPersisted() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: preferencesStoreKey),
            let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return .default }
        return decoded
    }

    static func save(_ preferences: Preferences) {
        writer.submit(PendingPreferencesSnapshot(preferences))
    }

    static func save(_ snapshot: PendingPreferencesSnapshot) {
        writer.submit(snapshot)
    }

    static func flush(timeout: Duration = .seconds(1)) async -> PreferenceFlushResult {
        await withCheckedContinuation { continuation in
            writer.flush(timeout: timeout) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// Registers the durability boundary before entering AppKit's nested Quit loop.
    static func flush(
        timeout: Duration = .seconds(1),
        completion: @escaping @MainActor @Sendable (PreferenceFlushResult) -> Void
    ) {
        writer.flush(timeout: timeout, completion: completion)
    }
}

/// Where the application puts itself.
///
/// Not in `Preferences`: that blob is decoded when the model is built, and the
/// activation policy has to be right before the first window is ordered in or
/// the Dock icon appears a beat late and then vanishes. `UserDefaults` answers
/// with nothing else having run.
@MainActor
enum InterfaceOptions {
    private static let dockKey = "com.yuhuanstudio.yunaudio.showsDockIcon"

    /// `LSUIElement` makes this an accessory by default: menu bar only, no Dock
    /// icon and no application menu. That is right for a router that is mostly
    /// left alone, and wrong for somebody who works in the window and wants to
    /// reach it with ⌘-tab like anything else.
    static var showsDockIcon: Bool {
        get { UserDefaults.standard.bool(forKey: dockKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: dockKey)
            apply()
        }
    }

    /// Puts the policy on the running application.
    ///
    /// Returns whether it took: `setActivationPolicy` reports failure, and a
    /// toggle that silently did nothing is the kind of defect this project
    /// keeps finding.
    @discardableResult
    static func apply() -> Bool {
        NSApp?.setActivationPolicy(showsDockIcon ? .regular : .accessory) ?? false
    }
}

/// Login item registration.
///
/// `SMAppService.mainApp` replaces the old login-item and helper-bundle dances;
/// the system owns the state, so it is read back rather than mirrored locally.
@MainActor
enum LoginItem {
    enum State: Equatable, Sendable {
        case enabled
        case requiresApproval
        case notRegistered
        case unavailable
    }

    static var state: State {
        readState()
    }

    /// Reads ServiceManagement without making MainActor wait for its daemon.
    nonisolated static func readState() -> State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    static var isEnabled: Bool {
        state == .enabled
    }

    /// Returns nil on success, or a message explaining why it did not take.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            // The most common cause is the app not being in /Applications, or
            // running unsigned from a build directory. Say so rather than
            // failing silently.
            return String(
                format: loc("Could not update the login item: %@"),
                error.localizedDescription)
        }
    }
}
