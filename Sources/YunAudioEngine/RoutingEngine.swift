import CoreAudio
import Foundation
import YunAudioHAL
import YunAudioRT

/// Carries the clock storage onto the publisher's queue.
///
/// It carries the atomic storage rather than the graph, and that distinction is
/// the whole point: a patchbay edit swaps in a new graph and frees the old one,
/// so a captured graph pointer is dangling the first time anybody moves a cable.
/// This storage belongs to the route and outlives every graph in it.
///
/// The `@unchecked` is claimed deliberately, not to quiet the compiler: it is
/// allocated before the device starts and freed only after both the IOProc has
/// been destroyed and the publisher's queue has been drained. `YunAudioRT`
/// publishes and reads the pair through a C11 atomic seqlock.
private struct GraphHandle: @unchecked Sendable {
    let clock: RTGraph.SharedClock
}

/// Result of advancing one device IOProc towards an unreachable callback.
enum AudioIOProcTeardownResult: Sendable, Equatable {
    case complete
    case stopFailed(OSStatus)
    case destroyFailed(OSStatus)
    case timedOut(step: AudioIOProcTeardownStep)
}

public enum AudioIOProcTeardownStep: String, Sendable, Equatable {
    case stop
    case destroy
}

/// Retryable lifecycle for the only object allowed to dereference an RT graph.
///
/// `AudioDeviceStop` and `AudioDeviceDestroyIOProcID` are requests with status
/// codes, not `Void` cleanup notifications. Advancing the phase only on
/// `noErr` makes the lifetime fence explicit and independently testable.
struct AudioIOProcTeardownState: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case absent
        case stopped
        case running
    }

    private(set) var phase: Phase = .absent

    mutating func didCreate() {
        precondition(phase == .absent)
        phase = .stopped
    }

    mutating func didStart() {
        precondition(phase == .stopped)
        phase = .running
    }

    mutating func tearDown(
        stop: () -> OSStatus?,
        destroy: () -> OSStatus?
    ) -> AudioIOProcTeardownResult {
        if phase == .running {
            guard let status = stop() else { return .timedOut(step: .stop) }
            guard status == noErr else { return .stopFailed(status) }
            phase = .stopped
        }
        if phase == .stopped {
            guard let status = destroy() else { return .timedOut(step: .destroy) }
            guard status == noErr else { return .destroyFailed(status) }
            phase = .absent
        }
        return .complete
    }
}

/// Pure ownership transition for process taps crossing an internal route retry.
///
/// An attempt teardown must remove the aggregate while leaving the taps named by
/// the next attempt alive. A final teardown does the opposite. Keeping that
/// distinction as an identity-based value transition makes duplicate references
/// harmless and keeps the decision independently testable without creating HAL
/// objects.
struct ProcessTapRetryOwnership<Resource: AnyObject> {
    private(set) var active: [Resource]
    private(set) var pending: [Resource]

    init(active: [Resource] = [], pending: [Resource] = []) {
        self.active = Self.unique(active)
        self.pending = Self.unique(pending)
    }

    /// Adds resources accepted from a caller but not yet attached to a route.
    func adopting(_ resources: [Resource]) -> Self {
        Self(active: active, pending: pending + resources)
    }

    /// Transfers a successful attempt's resources out of pending teardown.
    func activating(_ resources: [Resource]) -> Self {
        let identities = Set(resources.map(ObjectIdentifier.init))
        return Self(
            active: resources,
            pending: pending.filter { !identities.contains(ObjectIdentifier($0)) })
    }

    /// Plans one fenced teardown and the state which may be committed afterwards.
    ///
    /// The next state is not installed until every requested destruction has
    /// been confirmed. On failure the caller therefore retains the complete old
    /// state and can retry without trusting partial HAL evidence.
    func tearingDown(
        preserving resources: [Resource]
    ) -> (destroy: [Resource], next: Self) {
        let preserved = Self.unique(resources)
        let preservedIdentities = Set(preserved.map(ObjectIdentifier.init))
        let owned = Self.unique(active + pending)
        let destroy = owned.filter {
            !preservedIdentities.contains(ObjectIdentifier($0))
        }
        return (destroy, Self(active: [], pending: preserved))
    }

    var allLive: [Resource] { Self.unique(active + pending) }

    private static func unique(_ resources: [Resource]) -> [Resource] {
        var seen = Set<ObjectIdentifier>()
        return resources.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

/// Observable result of a route teardown.
///
/// Anything but `complete` means some old-route ownership is intentionally
/// retained. A caller may retry `stop()` where the owning subsystem permits;
/// new audio ownership remains refused while quarantine is non-empty.
public enum RoutingTeardownResult: Sendable, Equatable {
    case complete
    case lifecycleQueueTimedOut
    case ioProcStopFailed(OSStatus)
    case ioProcDestroyFailed(OSStatus)
    case ioProcTimedOut(step: AudioIOProcTeardownStep)
    case clockPublisherTimedOut
    /// `canRetry` false means the bridge has stored this as its last word, so
    /// `stop()` will return it again without tearing anything down. True means
    /// the teardown is only deferred and the next Stop picks up its result.
    case echoCancellation(EchoCancellationBridgeTeardownResult, canRetry: Bool)
    case audioUnitOwner(AudioUnitOwnerDisposalResult)
    case aggregate(HALDestructionResult)
    case processTap(uid: String, result: HALDestructionResult)
    case sampleRatesNotRestored([String])

    public var isComplete: Bool { self == .complete }

    /// Whether pressing Stop again can clear this, or only relaunching can.
    ///
    /// `EchoCancellationBridge.stop` stores its first non-complete verdict and
    /// returns it before tearing anything down; only `start()` clears the
    /// field, and its own `isRunning` guard makes that unreachable while the
    /// verdict stands. A second Stop therefore provably does nothing, and
    /// telling somebody to press it again costs them the session on top of the
    /// route. Every other case here is retryable where its owning subsystem
    /// permits, which is what this type's own contract already says.
    public var anotherStopCanClearIt: Bool {
        if case .echoCancellation(_, let canRetry) = self { return canRetry }
        return true
    }

    var requiresOwnerQuarantine: Bool {
        switch self {
        case .complete, .sampleRatesNotRestored, .audioUnitOwner:
            false
        case .lifecycleQueueTimedOut,
            .ioProcStopFailed, .ioProcDestroyFailed, .ioProcTimedOut,
            .clockPublisherTimedOut,
            .echoCancellation,
            .aggregate, .processTap:
            true
        }
    }
}

/// One bounded route lifetime retained after its engine owner has gone away.
///
/// Raw allocations have no automatic Swift destructor, but every object an
/// IOProc reaches through `Unmanaged.passUnretained` does. Keeping both in one
/// capsule records the whole abandoned generation and, crucially, prevents ARC
/// from releasing its transitive owners after a failed callback fence.
final class RoutingEngineQuarantineCapsule: @unchecked Sendable {
    struct RawContext: @unchecked Sendable {
        let ioProcID: AudioDeviceIOProcID?
        let graph: UnsafeMutablePointer<RTGraph>?
        let graphCell: OpaquePointer?
        let sharedClock: RTGraph.SharedClock?
        let sharedAnalysisRing: RTGraph.SharedAnalysisRing?
        let alignmentHistories: [RTGraph.SharedAlignmentHistory]
        let selftestBlock: UnsafeMutablePointer<RTSelftest>?
        let isolationBlock: UnsafeMutablePointer<RTVoiceIsolation>?
        let isolationFailures: OpaquePointer?
        let effectTransitionBlock: UnsafeMutablePointer<RTEffectTransition>?
        let transitionOldBlock: UnsafeMutablePointer<RTVoiceIsolation>?
        let transcriptRings: [OpaquePointer]
    }

    let owners: [AnyObject]
    let raw: RawContext

    init(owners: [AnyObject], raw: RawContext) {
        self.owners = owners
        self.raw = raw
    }
}

/// Reclaims published graph generations without making the control thread wait
/// for a callback that may be stalled inside CoreAudio or a third-party unit.
///
/// The serial queue is part of the safety argument, not merely a convenience:
/// `detachAndReclaimAll` drains every scheduled poll before the engine frees the
/// cell it reads. A bounded backlog fails a later live edit instead of trading
/// an audio-server stall for unbounded half-megabyte graph allocations.
final class RTGenerationRetirementQueue: @unchecked Sendable {
    private struct Entry: @unchecked Sendable {
        let safeAfterCycle: UInt64
        let reclaim: () -> Void
    }

    private let coordinationQueue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.graph-retirement",
        qos: .utility)
    private let reclaimerQueue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.graph-reclaimer",
        qos: .utility)
    private let maximumPending: Int
    private var cell: OpaquePointer?
    private var pending: [Entry] = []
    private var inFlightReclaims = 0
    private var scheduleToken: UInt64 = 0
    private var pollDelayMilliseconds = 5

    init(maximumPending: Int = RTGraph.maximumStateHandoverDepth) {
        precondition(maximumPending > 0)
        self.maximumPending = maximumPending
    }

    func attach(to cell: OpaquePointer) {
        coordinationQueue.sync {
            precondition(
                self.cell == nil && pending.isEmpty && inFlightReclaims == 0)
            self.cell = cell
            pollDelayMilliseconds = 5
        }
    }

    /// Adds one owner only while the bounded backlog has room for it.
    ///
    /// `prepareForPublication` is called before allocating a replacement. The
    /// caller's state lock makes it the sole publisher, so a refusal after that
    /// reservation would be a programming error rather than backpressure.
    @discardableResult
    func enqueue(safeAfterCycle: UInt64, reclaim: @escaping () -> Void) -> Bool {
        coordinationQueue.sync {
            _ = collectReadyLocked()
            guard cell != nil, pending.count + inFlightReclaims < maximumPending else {
                return false
            }
            pending.append(Entry(safeAfterCycle: safeAfterCycle, reclaim: reclaim))
            pollDelayMilliseconds = 5
            schedulePollLocked()
            return true
        }
    }

    /// Collects an already-safe prefix before the publisher decides whether it
    /// may allocate another generation.
    func prepareForPublication() -> Bool {
        coordinationQueue.sync {
            _ = collectReadyLocked()
            return cell != nil && pending.count + inFlightReclaims < maximumPending
        }
    }

    @discardableResult
    func collectReady() -> Int {
        coordinationQueue.sync { collectReadyLocked() }
    }

    var pendingCount: Int {
        coordinationQueue.sync { pending.count + inFlightReclaims }
    }

    /// Called only after the IOProc has been destroyed. At that boundary no
    /// callback can retain any generation, so fences are no longer needed.
    func detachAndReclaimAll() {
        coordinationQueue.sync {
            scheduleToken &+= 1
            cell = nil
            let detached = pending
            pending.removeAll(keepingCapacity: true)
            scheduleReclaimsLocked(detached)
            pollDelayMilliseconds = 5
        }
        // Destructors may wait on a file writer or Audio Unit, so ordinary
        // publications never execute them on the coordination queue. Stop is
        // the one boundary that must drain them before shared storage is freed.
        reclaimerQueue.sync {}
        coordinationQueue.sync {
            precondition(pending.isEmpty && inFlightReclaims == 0)
        }
    }

    private func collectReadyLocked() -> Int {
        guard let cell else { return 0 }
        var ready: [Entry] = []
        while let first = pending.first,
            yun_rt_cell_has_reached(cell, first.safeAfterCycle)
        {
            ready.append(pending.removeFirst())
        }
        scheduleReclaimsLocked(ready)
        return ready.count
    }

    private func scheduleReclaimsLocked(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        inFlightReclaims += entries.count
        for entry in entries {
            reclaimerQueue.async { [self] in
                entry.reclaim()
                coordinationQueue.async { [self] in
                    inFlightReclaims -= 1
                }
            }
        }
    }

    private func schedulePollLocked() {
        scheduleToken &+= 1
        let token = scheduleToken
        let delay = pollDelayMilliseconds
        coordinationQueue.asyncAfter(deadline: .now() + .milliseconds(delay)) {
            [weak self] in
            self?.poll(token: token)
        }
    }

    private func poll(token: UInt64) {
        guard token == scheduleToken, cell != nil, !pending.isEmpty else { return }
        let collected = collectReadyLocked()
        guard !pending.isEmpty else { return }
        pollDelayMilliseconds = collected > 0 ? 5 : min(pollDelayMilliseconds * 2, 250)
        schedulePollLocked()
    }
}

/// Where a signal comes from, in device terms rather than buffer terms.
public struct ChannelRef: Sendable, Hashable {
    /// UID of the sub-device inside the aggregate.
    public let deviceUID: String
    /// Zero-based channel within that device.
    public let channel: Int

    public init(deviceUID: String, channel: Int) {
        self.deviceUID = deviceUID
        self.channel = channel
    }
}

public struct Route: Sendable, Hashable {
    public let source: ChannelRef
    public let destination: ChannelRef
    public var gain: Float
    public var isMuted: Bool
    /// True when this route should step out of the way while somebody is
    /// talking. Set for application audio, never for the microphone.
    public var isDuckable: Bool

    public init(
        source: ChannelRef, destination: ChannelRef,
        gain: Float = 1.0, isMuted: Bool = false, isDuckable: Bool = false
    ) {
        self.source = source
        self.destination = destination
        self.gain = gain
        self.isMuted = isMuted
        self.isDuckable = isDuckable
    }
}

/// Voice isolation configuration.
public struct VoiceIsolationSettings: Sendable, Hashable {
    /// 0 = untouched, 100 = fully isolated.
    public var mixPercent: Float
    /// The higher quality model, available from macOS 15.
    public var isHighQuality: Bool

    public init(mixPercent: Float = 100, isHighQuality: Bool = true) {
        self.mixPercent = mixPercent
        self.isHighQuality = isHighQuality
    }
}

/// How faithful a configured path actually is.
public struct PathQuality: Sendable, Hashable {
    /// True when the signal reaches the destination unaltered: nothing
    /// resamples it and nothing processes it.
    public let isBitExact: Bool
    /// A DSP stage is inserted. Bit-exactness is impossible while this is true —
    /// processing the signal is the entire point of the stage.
    public let hasProcessing: Bool
    /// True when the destination is the YunAudio driver and it has confirmed it
    /// is tracking the master's measured rate.
    public let isClockLocked: Bool
    /// Measured master rate over its nominal rate. 1.00002 is twenty ppm fast.
    public let measuredRateRatio: Double
    /// Sub-devices the HAL is drift-correcting, and therefore resampling.
    public let driftCorrectedDeviceUIDs: [String]
    /// True when the two ends of the route share no sample rate at all, so a
    /// converter is running rather than merely a drift correction.
    ///
    /// Worth telling apart from ordinary resampling in the interface: this one
    /// is a property of the two devices somebody owns, not of how they set
    /// anything up, and there is nothing they can do about it.
    public let hasSampleRateMismatch: Bool
    public let bufferFrames: Int
    public let sampleRate: Double

    public var bufferLatencyMilliseconds: Double {
        sampleRate > 0 ? Double(bufferFrames) / sampleRate * 1000 : 0
    }

    /// The one word for what this path is doing to the signal.
    ///
    /// Three views were each deriving it from the same two flags with their own
    /// ternary, and they had already drifted once — the same string went
    /// through `loc()` in one place and not in the other two, so the readout
    /// was translated in the window and English in the panel.
    public var integrityKey: String {
        if isBitExact { return "bit-exact" }
        return hasProcessing ? "processed" : "resampled"
    }
}

/// Drives one private aggregate device through a single IOProc.
///
/// `@unchecked Sendable` is earned rather than asserted: every mutation of the
/// engine's own state goes through `stateLock`, and the realtime graph it hands
/// to the IOProc is freed only after that proc has been destroyed. The clock
/// publisher calls back from its own queue, so the type genuinely does cross
/// threads and the serialisation has to be real.
public final class RoutingEngine: @unchecked Sendable {
    /// Opaque proof that this engine reserved and checkpointed one route run.
    ///
    /// Only the construction bundle is public. The remaining fields bind the
    /// token to one engine, generation and immutable timing request so an old
    /// asynchronous completion cannot consume or discard a newer reservation.
    public struct AudioIncidentReservation: Sendable {
        public let constructionBundle: AudioIncidentBundle

        fileprivate let engineID: UUID
        fileprivate let generation: UInt64
        fileprivate let processTapOwnershipExpected: Bool
        fileprivate let sourceDeviceUID: String
        fileprivate let destinationDeviceUID: String
        fileprivate let preferredSampleRate: Double?
        fileprivate let bufferFrames: UInt32
    }

    enum AudioIncidentReservationPhase: Equatable {
        case beforeOwnership
        case checkpointPrepared
        case ownershipMayExist
        case consumed
    }

    private struct ActiveAudioIncidentReservation {
        let token: AudioIncidentReservation
        let previousStoredBundle: AudioIncidentBundle?
        let previousPendingBundle: AudioIncidentBundle?
        var phase: AudioIncidentReservationPhase
    }

    /// Whether a reserved run may enter its first engine start without crossing
    /// an unrecorded ownership boundary.
    ///
    /// A process tap is built by the application before `start`, so that route
    /// must have both persisted and committed its dedicated checkpoint. A route
    /// without taps has no such external owner and consumes the initial durable
    /// checkpoint directly. `.consumed` is reserved for bounded internal retries.
    static func reservationPhasePermitsStart(
        _ phase: AudioIncidentReservationPhase,
        processTapOwnershipExpected: Bool
    ) -> Bool {
        switch phase {
        case .beforeOwnership: !processTapOwnershipExpected
        case .ownershipMayExist: processTapOwnershipExpected
        case .consumed: true
        case .checkpointPrepared: false
        }
    }

    /// Driver clock telemetry from one status response.
    public struct ClockTelemetry: Sendable, Equatable {
        public let isLocked: Bool
        public let rateRatio: Double

        public init(isLocked: Bool, rateRatio: Double) {
            self.isLocked = isLocked
            self.rateRatio = rateRatio
        }

        static let unlocked = ClockTelemetry(isLocked: false, rateRatio: 1)
    }

    /// Recorder lifetime and progress from one engine observation.
    public struct RecordingSnapshot: Sendable, Equatable {
        public let isRecording: Bool
        public let url: URL?
        public let duration: TimeInterval
        public let error: String?
        public let producedSamples: UInt64
        public let droppedSamples: UInt64

        public init(
            isRecording: Bool, url: URL?, duration: TimeInterval, error: String?,
            producedSamples: UInt64 = 0, droppedSamples: UInt64 = 0
        ) {
            self.isRecording = isRecording
            self.url = url
            self.duration = duration
            self.error = error
            self.producedSamples = producedSamples
            self.droppedSamples = droppedSamples
        }

        static let stopped = RecordingSnapshot(
            isRecording: false, url: nil, duration: 0, error: nil)
    }

    /// One graph generation's complete value-only interface truth.
    ///
    /// The application must not compose these fields from separate engine
    /// getters: start, recovery and live swaps mutate them under one lifecycle
    /// lock, so separate reads can both block MainActor and describe different
    /// generations.
    public struct EngineUISnapshot: Sendable, Equatable {
        /// Monotonic identity of this complete value publication.
        ///
        /// This is separate from the two engine identities below because a
        /// failed effect edit can publish a new refusal without accepting a
        /// graph, and a fader edit can change route values inside one graph.
        public let generation: UInt64
        /// Route owner whose value state this snapshot describes.
        public let routeGeneration: UInt64
        /// Accepted realtime graph, or zero while no graph is owned.
        public let graphGeneration: UInt64
        public let routes: [Route]
        public let processingLatency: ProcessingLatency
        public let voiceIsolationLatencyFrames: Int
        public let alignmentFrames: Int
        public let failedPlugins: [AudioUnitLoadFailure]
        public let droppedMonitor: DroppedMonitor?
        public let droppedExtras: [DroppedMonitor]
        public let isolationError: String?
        public let activeEffectStages: [EffectKind]
        public let effectUpdateRefusal: EffectUpdateRefusal?
        /// Whether this route owns the driver's clock-lock contract.
        public let holdsClockLock: Bool
        /// Last complete canceller counters from this lifecycle generation.
        public let echoCancellationStatus: EchoCancellationStatus?
        public let echoCancellationError: String?
        public let echoCancellationDetail: String?
        /// Output identities and correction result from the same graph.
        public let outputDeviceUIDs: [String]
        public let correctionOutcome: CorrectionOutcome

        /// Complete DSP delay before the destination device's own latency.
        public var totalProcessingLatencyFrames: Int {
            processingLatency.totalFrames
        }

        public static let empty = EngineUISnapshot(
            generation: 0,
            routeGeneration: 0,
            graphGeneration: 0,
            routes: [],
            processingLatency: ProcessingLatency(sourceFrames: 0, outputFrames: 0),
            voiceIsolationLatencyFrames: 0,
            alignmentFrames: 0,
            failedPlugins: [],
            droppedMonitor: nil,
            droppedExtras: [],
            isolationError: nil,
            activeEffectStages: [],
            effectUpdateRefusal: nil,
            holdsClockLock: false,
            echoCancellationStatus: nil,
            echoCancellationError: nil,
            echoCancellationDetail: nil,
            outputDeviceUIDs: [],
            correctionOutcome: .nothingToInstall)
    }

    private let stateLock = NSRecursiveLock()
    /// Last complete low-cost observations for a UI read which loses the state
    /// lock to a graph change or teardown.
    ///
    /// Returning these is preferable to blocking MainActor behind CoreAudio,
    /// and unlike reading an Optional owner without its lock, retaining the
    /// previous values cannot race that owner's release.
    private let publishedSnapshotLock = NSLock()
    private var publishedClockTelemetry = ClockTelemetry.unlocked
    private var publishedRecordingSnapshot = RecordingSnapshot.stopped
    private var publishedCalibrationSnapshot: [(energy: Double, frames: UInt64)] = []
    private var publishedEngineUISnapshot = EngineUISnapshot.empty
    private var engineUISnapshotGeneration: UInt64 = 0
    private struct PluginParameterPublication {
        let owner: UUID
        let parameters: [EffectParameter]
    }
    private struct GainReductionPublication {
        let owner: UUID
        let value: Float
    }
    /// Vendor metadata finishes on the bounded control lane. SwiftUI only
    /// samples this value; it never waits for a plug-in getter on MainActor.
    private let publishedPluginParameterLock = NSLock()
    private var publishedPluginParameters: [String: PluginParameterPublication] = [:]
    private let publishedGainReductionLock = NSLock()
    private var publishedGainReduction: [EffectKind: GainReductionPublication] = [:]
    public private(set) var aggregate: AggregateDevice?
    public private(set) var isRunning = false
    /// Changes whenever a route becomes live or loses its callback owner.
    ///
    /// Recorder files are deliberately constructed without `stateLock`. This
    /// generation prevents a late file-system return from being installed into
    /// a different route which reused the same graph address.
    private var routeLifetimeGeneration: UInt64 = 0
    /// Monotonic identity of graphs accepted by the callback owner.
    ///
    /// Incident telemetry has its own count and exists only during an incident
    /// run. UI consistency must not depend on that optional recorder, so this
    /// value advances for every initial graph and every live publication.
    private var graphPublicationGeneration: UInt64 = 0

    private var ioProcID: AudioDeviceIOProcID?
    private var ioProcTeardownState = AudioIOProcTeardownState()
    private var storedTeardownResult: RoutingTeardownResult?
    /// Taps accepted for a start but not currently owned by `lastConfiguration`.
    ///
    /// A cancelled or structurally empty preparation still created real HAL
    /// objects. Keeping them here makes Stop their explicit retry path; relying
    /// on `ProcessTap.deinit` would move their census to a background queue and
    /// let the next route begin while the old taps can still mute applications.
    private var pendingTeardownTaps: [ProcessTap] = []
    private var graph: UnsafeMutablePointer<RTGraph>?
    /// What the IOProc actually reads. Holding the graph behind this is what
    /// makes a route change a swap rather than a restart.
    private var graphCell: OpaquePointer?
    /// Fixed route-lifetime evidence, borrowed by every published graph.
    ///
    /// The owner stays here until callback destruction is proved. A failed
    /// fence moves it into the same process-lifetime capsule as the graph, so
    /// the callback can never outlive its telemetry allocation.
    private var incidentRecorder: AudioIncidentRecorder?
    /// A recorder whose construction checkpoint has been handed to the caller,
    /// but whose route has not acquired its first Core Audio owner yet.
    ///
    /// The application persists that exact value before creating a process tap.
    /// `startAttempt` then consumes the same recorder instead of finalising it as
    /// a previous route, so every later checkpoint keeps one run identity.
    private let audioIncidentReservationEngineID = UUID()
    private var audioIncidentReservationGeneration: UInt64 = 0
    private var activeAudioIncidentReservation: ActiveAudioIncidentReservation?
    private var storedIncidentBundle: AudioIncidentBundle?
    /// The newest bundle not yet handed to an external bounded sink.
    ///
    /// `storedIncidentBundle` remains inspectable after this value is consumed;
    /// keeping the two roles separate prevents polling from erasing the last
    /// forensic fact a caller may need to display.
    private var pendingIncidentBundle: AudioIncidentBundle?
    private let retiredGenerations = RTGenerationRetirementQueue()
    /// File writers never run on the graph reclaimer or route lifecycle queue.
    private let recorderFinaliser = RecorderFinalisationWorker()
    private var activeRoutes: [Route] = []
    /// Processing semantics which outlive any one route topology.
    ///
    /// In particular, an empty RT graph owns a dummy route whose flags are all
    /// false. That storage cannot become the source of truth for the next real
    /// route without silently dropping microphone trim, AEC and isolation.
    private var routeProcessingPlan: RouteProcessingPlan?
    /// Stable identities and their live slots, rebuilt only with the topology.
    ///
    /// Commands arrive on the engine queue after the interface has emitted
    /// them. Resolving an array index there would let a graph publication move
    /// that index onto another cable before the command arrives.
    private var activeRouteKeys: [RouteOccurrenceKey] = []
    private var activeRouteIndex: [RouteOccurrenceKey: Int] = [:]
    /// Delay history belongs to a cable occurrence, not an array slot or graph.
    /// Retained routes therefore share exactly one fixed history through every
    /// publication; removed owners cross the same callback fence as the graph
    /// which last referenced them.
    private var alignmentHistories: [RouteOccurrenceKey: RTGraph.SharedAlignmentHistory] = [:]

    /// The routes currently carrying audio, including any built from taps.
    public var currentRoutes: [Route] {
        engineUISnapshot.routes
    }
    /// Maps a device channel onto the (buffer, channel) pair the IOProc sees.
    private var inputMap: [ChannelRef: (buffer: Int32, channel: Int32)] = [:]
    private var outputMap: [ChannelRef: (buffer: Int32, channel: Int32)] = [:]
    /// The exact format the current realtime graph was built to consume.
    ///
    /// Reading it back through HAL for every EQ pointer event took synchronous
    /// IPC while the state lock was held. Coefficients need to agree with the
    /// graph, not rediscover the device property, so the construction value is
    /// the stronger answer as well as the cheaper one.
    private var graphSampleRate: Double = 48000
    private var graphBufferFrames = 128
    /// Storage ceiling for processing stages, distinct from one IO cycle.
    ///
    /// CoreAudio tells a unit its maximum slice separately from the number of
    /// frames in this callback. Conflating the two made a later effect rebuild
    /// shrink its buffers back to the ordinary cycle size and truncate the next
    /// larger slice.
    private var graphMaximumFrames = AudioProcessingContract.maximumFramesPerSlice
    /// Channel layout of the aggregate's output buffer list.
    ///
    /// Captured from the same stream objects that build `outputMap`, so the
    /// final limiter is prepared for exactly the buffers the IOProc receives.
    private var outputChannelCounts: [Int] = []
    /// Control-thread truth for the limiter drive.
    ///
    /// The realtime copy changes only by a queue command at a cycle boundary.
    /// Reading or writing that ordinary Float directly from this thread would
    /// race the callback.
    private var outputLimiterPreGain: Float = 1
    private var clockPublisher: ClockAnchorPublisher?
    private var selftestOwner: RTSelftestOwner?
    private var selftestBlock: UnsafeMutablePointer<RTSelftest>?
    /// Retained here so the unit outlives the unmanaged pointer the IO thread
    /// holds; the IOProc must never touch a reference count.
    private var isolationUnit: VoiceIsolationUnit?
    private var isolationBlock: UnsafeMutablePointer<RTVoiceIsolation>?
    private var isolationFailureCounter: OpaquePointer?

    /// Latency the isolation model adds, in frames. Zero when it is off.
    private var storedVoiceIsolationLatencyFrames = 0
    /// Latency introduced before route summing, in frames.
    ///
    /// Paths that skip the source chain are held back by this number. A final
    /// output stage is intentionally not part of it: every route meets that
    /// stage and delaying the bypass path by it would count the same latency
    /// twice.
    private var storedSourceProcessingLatencyFrames = 0
    /// Latency introduced after the complete mix, in frames.
    ///
    /// Kept separate before a final output stage exists so no consumer can
    /// quietly reuse the source-alignment number when that stage arrives.
    private var storedOutputProcessingLatencyFrames = 0
    public var voiceIsolationLatencyFrames: Int {
        engineUISnapshot.voiceIsolationLatencyFrames
    }
    public var sourceProcessingLatencyFrames: Int {
        engineUISnapshot.processingLatency.sourceFrames
    }
    public var outputProcessingLatencyFrames: Int {
        engineUISnapshot.processingLatency.outputFrames
    }
    /// The latency facts consumers should choose between explicitly.
    public var processingLatency: ProcessingLatency {
        engineUISnapshot.processingLatency
    }
    /// Total DSP latency in the path, before the device's own latency.
    public var totalProcessingLatencyFrames: Int { processingLatency.totalFrames }
    /// The old ambiguous answer, retained while external callers migrate.
    @available(*, deprecated, renamed: "totalProcessingLatencyFrames")
    public var effectLatencyFrames: Int { totalProcessingLatencyFrames }

    /// Frames the graph is actually holding back the paths that skipped the
    /// chain, read off the graph rather than off the number above.
    ///
    /// The defect this exists to catch is precisely a latency that is measured,
    /// stored, shown in the interface and never handed to anything that moves a
    /// sample — which is what the old latency value was for the life of the
    /// effect chain.
    public var alignmentFrames: Int {
        engineUISnapshot.alignmentFrames
    }
    private var effectChain: EffectChain?
    /// Retained owner of the unretained final-stage pointer in every live graph.
    ///
    /// One bank survives route and effect graph swaps. Recreating it would
    /// reset the look-ahead line and insert 48 frames of silence into every
    /// patchbay edit.
    private var outputLimiterBank: OutputLimiterBank?
    /// Independent detector for the canonical recording branch.
    private var recordingLimiter: OutputLimiterBank?
    /// The currently installed handover and the old path it keeps alive.
    ///
    /// All references live here rather than in the graph, whose IO-facing
    /// records are unmanaged. A later graph swap crosses the cycle fence before
    /// releasing these, so a rapid second toggle cannot free the first
    /// transition underneath the callback.
    private var effectTransitionController: EffectTransition?
    private var effectTransitionBlock: UnsafeMutablePointer<RTEffectTransition>?
    private var transitionOldChain: EffectChain?
    private var transitionOldUnit: VoiceIsolationUnit?
    private var transitionOldBlock: UnsafeMutablePointer<RTVoiceIsolation>?
    /// Retires completed handovers without retaining third-party Audio Units
    /// until the next user edit. This queue never touches audio; it only asks
    /// the atomic completion flag, then publishes a steady graph under the
    /// ordinary state lock.
    private let effectTransitionFinalisationQueue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.effect-transition-finalisation",
        qos: .utility)
    private static let effectTransitionFinalisationRetryLimit = 40
    /// Renders the model refused. Non-zero means audio passed through
    /// unprocessed, which the UI should surface rather than hide.
    ///
    /// One counter survives every graph and effect handover in this route
    /// lifetime. Resetting it with a stage would let a failed old path vanish
    /// from diagnostics during the exact rapid toggle which needs explaining.
    public var voiceIsolationFailures: UInt64 {
        guard stateLock.try() else { return 0 }
        defer { stateLock.unlock() }
        return isolationFailureCounter.map(yun_rt_counter_load) ?? 0
    }
    /// True when drift correction was switched off on the strength of the
    /// driver's clock locking, so the path is only clean while the lock holds.
    private var requiresClockLock = false
    /// True when the two ends could not agree a rate and the HAL is reconciling
    /// them. Reported rather than hidden: it is the difference between a path
    /// that is merely not bit-exact and one where a converter is running.
    public private(set) var sampleRateMismatch = false
    /// Sample rates as they were before routing touched them.
    private var originalSampleRates: [String: Double] = [:]

    /// The members this route aligned to its common rate.
    ///
    /// Only the aligned ones: a device that could not present the target is
    /// running at its own rate by design, and comparing it against the target
    /// would report drift the instant the route came up.
    private var alignedMemberIDs: [AudioObjectID] = []

    /// Watches those members for a rate changed from outside the route.
    ///
    /// A Bluetooth headset is two Core Audio devices, and another application
    /// opening the input one negotiates hands-free mode, which takes the output
    /// down with it. The device list does not change, so `DeviceChangeWatcher`
    /// never fires, and the route keeps running against a destination whose
    /// format is no longer the one it was built for.
    private lazy var memberRateWatcher = DeviceSampleRateWatcher {
        [weak self] device, rate in
        self?.onRouteMemberRateChanged?(device, rate)
    }

    /// Called when a member's rate moves away from the route's common rate.
    ///
    /// The route has to be rebuilt: its central assumption has been revoked
    /// from outside, and a rebuild recomputes a rate every member can still
    /// present — 16 kHz while hands-free mode holds, and back up when it lets
    /// go.
    public var onRouteMemberRateChanged: (@Sendable (AudioObjectID, Double) -> Void)?

    /// Every device this route was built from, aligned or not.
    ///
    /// `alignedMemberIDs` is deliberately the subset that could present the
    /// common rate, because drift is only meaningful against a rate we set. A
    /// missed deadline is meaningful on any member, including the one running
    /// at its own rate — that one is the likeliest to miss.
    private var routeMemberIDs: [AudioObjectID] = []

    /// Watches those devices, and the aggregate, for missed IOProc deadlines.
    ///
    /// `kAudioDeviceProcessorOverload` is Core Audio's own name for the gap a
    /// listener hears. Before this, a dropout left no trace anywhere in the
    /// process: the report was somebody's memory of a click, and there was
    /// nothing to compare a fix against.
    private lazy var overloadWatcher = DeviceOverloadWatcher {
        [weak self] event in
        self?.onRouteOverload?(event)
    }

    /// Called on the notification thread when a device reports an overload.
    ///
    /// Not a route rebuild: an overload is a symptom with many causes, and
    /// restarting the route on one would turn a single click into a gap. It is
    /// for recording and for telling somebody.
    public var onRouteOverload: (@Sendable (DeviceOverloadWatcher.Event) -> Void)?

    /// Missed IOProc deadlines since the last `resetIOProcOverloads()`.
    ///
    /// Survives a route restart on purpose. A route that has to restart is
    /// itself the symptom, and a counter zeroed by the restart would erase the
    /// case worth looking at.
    public var ioProcOverloadCount: Int { overloadWatcher.overloadCount }

    /// The same tally split by device, so a member and the aggregate stay
    /// distinguishable — they are different diagnoses.
    public var ioProcOverloadsByDevice: [AudioObjectID: Int] {
        overloadWatcher.overloadsByDevice
    }

    /// The most recent overloads with their times, oldest first.
    public var recentIOProcOverloads: [DeviceOverloadWatcher.Event] {
        overloadWatcher.recentEvents
    }

    /// Begins a fresh count. For a deliberate measurement, not for teardown.
    public func resetIOProcOverloads() { overloadWatcher.reset() }
    /// Every argument the route was last brought up with.
    ///
    /// A whole snapshot rather than a few named fields, because the clock-lock
    /// recovery restarts the route from this and anything missing is silently
    /// dropped. It used to hold the two devices, the routes and the buffer size
    /// alone, so a lock that gave way took the entire processing chain with it —
    /// along with the monitor mix, the captured applications, the requested
    /// sample rate and the echo canceller — while the model went on holding all
    /// of them and the interface went on showing them. `activeEffectStages` came
    /// back empty and nothing anywhere said why.
    private var lastConfiguration: StartConfiguration?

    /// One start's worth of arguments, so that replaying a start cannot quietly
    /// replay less than one.
    struct StartConfiguration {
        var sourceDeviceUID: String
        var destinationDeviceUID: String
        var routes: [Route]
        var taps: [ProcessTap]
        /// Further hardware inputs, joining the aggregate alongside the
        /// microphone so their channels can be routed like any other.
        ///
        /// Separate from `sourceDeviceUID` rather than folded into a list with
        /// it because the two are not interchangeable: the primary source is
        /// the aggregate's clock master, and every other member is drift
        /// corrected against it. A flat list would hide that one of them is
        /// the one thing here that cannot be resampled.
        var additionalSourceUIDs: [String]
        var additionalDestinationUIDs: [String]
        var monitorDeviceUID: String?
        var effects: [EffectKind]
        var plugins: [AudioUnitPlugin]
        var preferredSampleRate: Double?
        var bufferFrames: UInt32
        var voiceIsolation: VoiceIsolationSettings?
        var echoCancellation: EchoCancellationSettings?
        var outputLatencyTrim: [String: Int]
        var analysisEnabled: Bool
        var selftest: Bool

        /// Keeps recovery pointed at the graph that is now live.
        ///
        /// A route edit does not restart the aggregate, so the start snapshot
        /// otherwise continues naming the graph that was replaced. The next
        /// clock-lock recovery would faithfully rebuild that stale patchbay.
        mutating func rememberLiveRoutes(_ routes: [Route]) {
            self.routes = routes
        }

        /// Keeps recovery pointed at the processing graph that is now live.
        ///
        /// These three values are one decision: plugins change whether voice
        /// isolation uses its dedicated unit or the full chain, and the
        /// settings belong to that decision. Remembering only the stage names
        /// would still rebuild a different graph after a clock-lock failure.
        mutating func rememberLiveEffects(
            _ effects: [EffectKind],
            plugins: [AudioUnitPlugin],
            voiceIsolation: VoiceIsolationSettings?
        ) {
            self.effects = effects
            self.plugins = plugins
            self.voiceIsolation = voiceIsolation
        }

        /// Keeps recovery from silently turning every analyser back off.
        mutating func rememberAnalysisEnabled(_ enabled: Bool) {
            analysisEnabled = enabled
        }

        /// The same start with the monitor given up on: the second mix and
        /// every route into it gone, the main mix untouched.
        ///
        /// - Returns: Nil when there is nothing to give up — no monitor, a
        ///   monitor nothing was being sent to, or one that is also an end of
        ///   the main route. In that last case the routes into it *are* the
        ///   mix, so dropping them would be giving up the thing the monitor is
        ///   supposed to be additional to, and the failure is not the
        ///   monitor's to answer for.
        func withoutMonitor() -> Self? {
            guard let monitor = monitorDeviceUID,
                monitor != destinationDeviceUID
            else { return nil }
            var reduced = self
            reduced.monitorDeviceUID = nil
            reduced.routes = routes.filter { $0.destination.deviceUID != monitor }
            reduced.additionalDestinationUIDs = additionalDestinationUIDs.filter {
                $0 != monitor
            }
            guard reduced.routes.count != routes.count, !reduced.routes.isEmpty else {
                return nil
            }
            return reduced
        }

        /// The same start with every additional device given up on, and every
        /// route into or out of one gone.
        ///
        /// The monitor is deliberately left alone: it has its own rung, because
        /// an extra input that will not join the aggregate and an output that
        /// takes twelve seconds to refuse are independent faults and a machine
        /// with both must still get its call.
        ///
        /// - Returns: Nil when there is nothing additional to give up, or when
        ///   giving it up would leave nothing to route — in which case the
        ///   extras were the route, and the failure is not theirs to answer
        ///   for.
        func withoutAdditionalDevices() -> Self? {
            let extras = Set(additionalSourceUIDs + additionalDestinationUIDs)
                .subtracting([sourceDeviceUID, destinationDeviceUID])
            guard !extras.isEmpty else { return nil }
            var reduced = self
            reduced.additionalSourceUIDs = []
            reduced.additionalDestinationUIDs = additionalDestinationUIDs.filter {
                !extras.contains($0)
            }
            reduced.routes = routes.filter {
                !extras.contains($0.source.deviceUID)
                    && !extras.contains($0.destination.deviceUID)
            }
            guard !reduced.routes.isEmpty else { return nil }
            return reduced
        }

        /// Which additional devices `withoutAdditionalDevices` would give up.
        var additionalDeviceUIDs: [String] {
            var seen = Set([sourceDeviceUID, destinationDeviceUID])
            var list: [String] = []
            for uid in additionalSourceUIDs + additionalDestinationUIDs
            where seen.insert(uid).inserted {
                list.append(uid)
            }
            return list
        }
    }

    /// The timing the graph actually runs at, read back after configuration.
    ///
    /// Requested values are intentions. Filter coefficients, pitch arithmetic,
    /// meter releases and buffer bounds all have to follow what the aggregate
    /// reports, or the graph processes a different clock from the samples it
    /// receives.
    struct GraphTiming: Sendable, Equatable {
        let sampleRate: Double
        let cycleFrames: Int
        let processingCapacity: Int
    }

    struct SampleRatePlan: Sendable, Equatable {
        let targetRate: Double
        let hasMismatch: Bool
    }

    /// Chooses the clock master's rate before the aggregate is built.
    ///
    /// A common rate avoids nominal conversion and therefore wins. When no
    /// common rate exists, the source remains the clock master and another
    /// member must be converted whatever rate it chooses. In that case using
    /// the source's highest advertised rate is not extra fidelity: a 48/96 kHz
    /// microphone feeding a 44.1 kHz Bluetooth output still ends at 44.1 kHz.
    /// Honour the preferred source rate, then preserve its current rate, before
    /// falling back to the highest value only when neither is usable.
    ///
    /// ## And the same argument applies where a common rate *does* exist
    ///
    /// That branch used to take `shared.max()`, so a 48/96 kHz microphone into
    /// a 48/96 kHz destination landed on 96 whenever nobody had asked for 48 —
    /// twice the rate for content a capsule does not produce.
    ///
    /// The reason given here for avoiding it was wrong, though, and it is worth
    /// replacing rather than repeating. Measured on the voice scene, two
    /// seconds of audio through equaliser, gate, compressor and limiter:
    ///
    ///     48 kHz  33.8 ms CPU   10.67 ms per 512-frame cycle
    ///     96 kHz  36.0 ms CPU    5.33 ms per 512-frame cycle
    ///
    /// Seven per cent more work, not double: these units are dominated by
    /// per-buffer overhead rather than per-sample arithmetic. What actually
    /// doubles is the pressure. A buffer is counted in frames, so at twice the
    /// rate the same buffer is half the wall clock — the work per cycle barely
    /// moves and the deadline it must fit inside halves, which is where crackle
    /// comes from.
    ///
    /// So: the shared rate nearest what was asked for, measured in octaves
    /// because rates are ratios. With nothing asked for that is 48 kHz, which
    /// is what this application prefers everywhere else.
    static func sampleRatePlan(
        sourceRates: [Double],
        destinationRates: [Double],
        preferredRate: Double?,
        sourceCurrentRate: Double?
    ) -> SampleRatePlan? {
        let source = Set(
            sourceRates.filter { AudioProcessingContract.supports(sampleRate: $0) })
        guard !source.isEmpty else { return nil }
        let destination = Set(
            destinationRates.filter { AudioProcessingContract.supports(sampleRate: $0) })
        let shared = source.intersection(destination)

        if let preferredRate, AudioProcessingContract.supports(sampleRate: preferredRate),
            shared.contains(preferredRate)
        {
            return SampleRatePlan(targetRate: preferredRate, hasMismatch: false)
        }
        if !shared.isEmpty {
            let wanted =
                preferredRate.flatMap {
                    AudioProcessingContract.supports(sampleRate: $0) ? $0 : nil
                } ?? 48_000
            let nearest = shared.min {
                abs(log2($0 / wanted)) < abs(log2($1 / wanted))
            }
            if let nearest {
                return SampleRatePlan(targetRate: nearest, hasMismatch: false)
            }
        }
        if let preferredRate, AudioProcessingContract.supports(sampleRate: preferredRate),
            source.contains(preferredRate)
        {
            return SampleRatePlan(targetRate: preferredRate, hasMismatch: true)
        }
        if let sourceCurrentRate,
            AudioProcessingContract.supports(sampleRate: sourceCurrentRate),
            source.contains(sourceCurrentRate)
        {
            return SampleRatePlan(targetRate: sourceCurrentRate, hasMismatch: true)
        }
        guard let highest = source.max() else { return nil }
        return SampleRatePlan(targetRate: highest, hasMismatch: true)
    }

    /// Builds one timing answer from live aggregate properties.
    ///
    /// Four thousand and ninety-six frames is both storage headroom and the hard
    /// admitted slice ceiling: the callback still takes the minimum of the
    /// slice's available frames and this capacity, while a larger HAL answer is
    /// refused before it becomes an allocation dimension.
    static func graphTiming(
        actualSampleRate: Double?,
        actualBufferFrames: UInt32?
    ) -> GraphTiming? {
        guard let sampleRate = actualSampleRate,
            AudioProcessingContract.supports(sampleRate: sampleRate),
            let reportedFrames = actualBufferFrames,
            AudioProcessingContract.supports(framesPerSlice: reportedFrames)
        else { return nil }
        let cycleFrames = Int(reportedFrames)
        return GraphTiming(
            sampleRate: sampleRate,
            cycleFrames: cycleFrames,
            processingCapacity: AudioProcessingContract.maximumFramesPerSlice)
    }

    /// Rejects an unsupported request before it asks Core Audio to reconfigure
    /// any device. The settled values are validated again by `graphTiming` because
    /// setting either property is asynchronous and may be refused.
    static func supportsRouteTimingRequest(
        preferredSampleRate: Double?, bufferFrames: UInt32
    ) -> Bool {
        AudioProcessingContract.supports(framesPerSlice: bufferFrames)
            && preferredSampleRate.map(AudioProcessingContract.supports(sampleRate:)) != false
    }

    /// Everything a route start can ask Core Audio or a hosted Audio Unit to
    /// own, expressed without live HAL objects so admission remains testable.
    struct StartResourceRequest {
        var sourceDeviceUID: String
        var destinationDeviceUID: String
        var routes: [Route]
        var tapUIDs: [String]
        var additionalSourceUIDs: [String]
        var additionalDestinationUIDs: [String]
        var monitorDeviceUID: String?
        var effects: [EffectKind]
        var plugins: [AudioUnitPlugin]
        var voiceIsolation: VoiceIsolationSettings?
        var echoCancellation: EchoCancellationSettings?
        var outputLatencyTrim: [String: Int]
    }

    /// One application identity after read-only process discovery and before a
    /// process tap exists.
    public struct ProcessTapPreflightIdentity: Sendable, Equatable {
        public let bundleID: String
        public let processIDs: [AudioObjectID]

        public init(bundleID: String, processIDs: [AudioObjectID]) {
            self.bundleID = bundleID
            self.processIDs = processIDs
        }
    }

    /// One destination reduced to the channel width used by route planning.
    public struct DestinationPreflight: Sendable, Equatable {
        public let uid: String
        public let outputChannels: Int

        public init(uid: String, outputChannels: Int) {
            self.uid = uid
            self.outputChannels = outputChannels
        }
    }

    /// A complete start request while every prospective tap is still an identity.
    ///
    /// Application enumeration is read-only HAL work. This value is built after
    /// that discovery, then admitted before the first `ProcessTap` constructor can
    /// issue `AudioHardwareCreateProcessTap`.
    public struct StartPreflightRequest: Sendable {
        public var sourceDeviceUID: String
        public var destinationDeviceUID: String
        public var baseRoutes: [Route]
        public var sources: [String]
        public var captures: [ProcessTapPreflightIdentity]
        public var destinations: [DestinationPreflight]
        public var additionalSourceUIDs: [String]
        public var additionalDestinationUIDs: [String]
        public var monitorDeviceUID: String?
        public var monitorOutputChannels: Int?
        public var effects: [EffectKind]
        public var plugins: [AudioUnitPlugin]
        public var preferredSampleRate: Double?
        public var bufferFrames: UInt32
        public var voiceIsolation: VoiceIsolationSettings?
        public var echoCancellation: EchoCancellationSettings?
        public var outputLatencyTrim: [String: Int]

        public init(
            sourceDeviceUID: String,
            destinationDeviceUID: String,
            baseRoutes: [Route],
            sources: [String],
            captures: [ProcessTapPreflightIdentity],
            destinations: [DestinationPreflight],
            additionalSourceUIDs: [String] = [],
            additionalDestinationUIDs: [String] = [],
            monitorDeviceUID: String? = nil,
            monitorOutputChannels: Int? = nil,
            effects: [EffectKind] = [],
            plugins: [AudioUnitPlugin] = [],
            preferredSampleRate: Double? = nil,
            bufferFrames: UInt32 = 128,
            voiceIsolation: VoiceIsolationSettings? = nil,
            echoCancellation: EchoCancellationSettings? = nil,
            outputLatencyTrim: [String: Int] = [:]
        ) {
            self.sourceDeviceUID = sourceDeviceUID
            self.destinationDeviceUID = destinationDeviceUID
            self.baseRoutes = baseRoutes
            self.sources = sources
            self.captures = captures
            self.destinations = destinations
            self.additionalSourceUIDs = additionalSourceUIDs
            self.additionalDestinationUIDs = additionalDestinationUIDs
            self.monitorDeviceUID = monitorDeviceUID
            self.monitorOutputChannels = monitorOutputChannels
            self.effects = effects
            self.plugins = plugins
            self.preferredSampleRate = preferredSampleRate
            self.bufferFrames = bufferFrames
            self.voiceIsolation = voiceIsolation
            self.echoCancellation = echoCancellation
            self.outputLatencyTrim = outputLatencyTrim
        }
    }

    public static let maximumAggregateEndpoints = 16
    public static let maximumProcessTaps = 16
    public static let maximumHostedPlugins = 16
    public static let maximumStartProcessIDs = 64
    static let maximumDeviceReferences = 32
    static let maximumIdentifierBytes = 1_024
    public static let maximumExtraOutputLatencyFrames = 48_000
    static let maximumFarEndProcesses = maximumStartProcessIDs
    static let maximumStartRetryElapsed: TimeInterval = 5

    /// A failed Core Audio attempt can itself take seconds. Retrying after the
    /// control plane has already consumed this budget compounds a system-audio
    /// stall and keeps the Sound menu queued behind work which is no longer
    /// useful. This cannot cancel one synchronous HAL call, but it prevents one
    /// slow refusal from becoming four more.
    static func permitsStartRetry(elapsed: TimeInterval) -> Bool {
        elapsed.isFinite && elapsed >= 0 && elapsed <= maximumStartRetryElapsed
    }

    /// Admits a complete route while process taps are still plain identities.
    ///
    /// The route count is deliberately conservative. A tap may publish fewer
    /// channels and a monitor send may be muted, but neither fact is available
    /// without constructing the tap or interpreting mutable UI state. Refusing
    /// that boundary is cheaper and safer than creating system audio objects and
    /// discovering afterwards that the realtime graph cannot hold their routes.
    public static func validateStartPreflight(_ request: StartPreflightRequest) throws {
        try validateRouteTimingRequest(
            preferredSampleRate: request.preferredSampleRate,
            bufferFrames: request.bufferFrames)

        let syntheticTapUIDs = request.captures.indices.map { "preflight-tap:\($0)" }
        try validateStartResources(
            StartResourceRequest(
                sourceDeviceUID: request.sourceDeviceUID,
                destinationDeviceUID: request.destinationDeviceUID,
                routes: request.baseRoutes,
                tapUIDs: syntheticTapUIDs,
                additionalSourceUIDs: request.additionalSourceUIDs,
                additionalDestinationUIDs: request.additionalDestinationUIDs,
                monitorDeviceUID: request.monitorDeviceUID,
                effects: request.effects,
                plugins: request.plugins,
                voiceIsolation: request.voiceIsolation,
                echoCancellation: request.echoCancellation,
                outputLatencyTrim: request.outputLatencyTrim))

        let hardwareSources = [request.sourceDeviceUID] + request.additionalSourceUIDs
        guard request.sources == hardwareSources,
            Set(hardwareSources).count == hardwareSources.count
        else {
            throw RoutingError.invalidStartConfiguration(
                "source descriptions must exactly match requested input hardware")
        }
        let expectedDestinations =
            [request.destinationDeviceUID] + request.additionalDestinationUIDs
        guard request.destinations.map(\.uid) == expectedDestinations,
            Set(expectedDestinations).count == expectedDestinations.count
        else {
            throw RoutingError.invalidStartConfiguration(
                "destination channel descriptions must exactly match requested outputs")
        }
        guard Set(hardwareSources).isDisjoint(with: Set(expectedDestinations)) else {
            throw RoutingError.invalidStartConfiguration(
                "a hardware endpoint cannot be both a source and a destination")
        }

        let monitorChannels: Int
        switch (request.monitorDeviceUID, request.monitorOutputChannels) {
        case (nil, nil):
            monitorChannels = 0
        case (.some(let uid), .some(let channels)):
            guard !expectedDestinations.contains(uid) else {
                throw RoutingError.invalidStartConfiguration(
                    "the monitor cannot also be a route destination")
            }
            try validateStartChannelCount(channels, resource: "monitor output channels")
            monitorChannels = min(2, channels)
        default:
            throw RoutingError.invalidStartConfiguration(
                "a monitor UID and its channel count must be provided together")
        }

        var destinationWidth = 0
        for destination in request.destinations {
            try validateStartChannelCount(
                destination.outputChannels, resource: "destination output channels")
            destinationWidth = try checkedStartAdd(
                destinationWidth, min(2, destination.outputChannels),
                resource: "destination route width", maximum: RTGraph.maximumRoutes)
        }

        let sourceSet = Set(hardwareSources)
        let destinationSet = Set(expectedDestinations)
        for route in request.baseRoutes {
            guard sourceSet.contains(route.source.deviceUID) else {
                throw RoutingError.invalidStartConfiguration(
                    "a base route source must name requested input hardware")
            }
            guard destinationSet.contains(route.destination.deviceUID) else {
                throw RoutingError.invalidStartConfiguration(
                    "a base route destination must name a requested output")
            }
        }

        var seenBundles = Set<String>()
        var totalProcessIDs = 0
        for capture in request.captures {
            try requireStartIdentifier(capture.bundleID, resource: "capture identity")
            guard seenBundles.insert(capture.bundleID).inserted else {
                throw RoutingError.invalidStartConfiguration(
                    "capture identities must be unique")
            }
            guard !capture.processIDs.isEmpty else {
                throw RoutingError.invalidStartConfiguration(
                    "a capture identity must contain at least one process")
            }
            guard capture.processIDs.allSatisfy({ $0 != kAudioObjectUnknown }) else {
                throw RoutingError.invalidStartConfiguration(
                    "capture process IDs must name live Core Audio objects")
            }
            guard Set(capture.processIDs).count == capture.processIDs.count else {
                throw RoutingError.invalidStartConfiguration(
                    "process IDs within one capture identity must be unique")
            }
            totalProcessIDs = try checkedStartAdd(
                totalProcessIDs, capture.processIDs.count,
                resource: "start process IDs", maximum: maximumStartProcessIDs)
        }
        if let echo = request.echoCancellation {
            totalProcessIDs = try checkedStartAdd(
                totalProcessIDs, echo.farEndProcessIDs.count,
                resource: "start process IDs", maximum: maximumStartProcessIDs)
        }

        let tapRouteCount = try checkedStartMultiply(
            request.captures.count, destinationWidth,
            resource: "projected routes", maximum: RTGraph.maximumRoutes)
        let monitorSourceCount = try checkedStartAdd(
            hardwareSources.count, request.captures.count,
            resource: "monitor sources", maximum: RTGraph.maximumRoutes)
        let monitorRouteCount = try checkedStartMultiply(
            monitorChannels, monitorSourceCount,
            resource: "projected routes", maximum: RTGraph.maximumRoutes)
        var projectedRoutes = try checkedStartAdd(
            request.baseRoutes.count, tapRouteCount,
            resource: "projected routes", maximum: RTGraph.maximumRoutes)
        projectedRoutes = try checkedStartAdd(
            projectedRoutes, monitorRouteCount,
            resource: "projected routes", maximum: RTGraph.maximumRoutes)
        try requireStartCount(
            projectedRoutes, resource: "projected routes", maximum: RTGraph.maximumRoutes)
    }

    /// Rejects expensive or malformed ownership requests before the first HAL
    /// call. Aggregate creation is synchronous in Core Audio; allowing an
    /// unbounded list through here can occupy the system audio service and make
    /// even macOS's Sound output menu appear frozen.
    static func validateStartResources(_ request: StartResourceRequest) throws {
        try requireStartCount(
            request.routes.count, resource: "routes",
            maximum: RTGraph.maximumRoutes)
        let farEndTapCount =
            request.echoCancellation?.farEndProcessIDs.isEmpty == false ? 1 : 0
        let totalTapCount = try checkedStartAdd(
            request.tapUIDs.count, farEndTapCount,
            resource: "process taps", maximum: maximumProcessTaps)
        try requireStartCount(
            totalTapCount, resource: "process taps", maximum: maximumProcessTaps)
        try validateProcessingResources(
            effects: request.effects,
            plugins: request.plugins,
            voiceIsolation: request.voiceIsolation)
        try requireStartCount(
            request.outputLatencyTrim.count, resource: "output latency trims",
            maximum: maximumAggregateEndpoints)

        let (additionalCount, additionalOverflowed) =
            request.additionalSourceUIDs.count.addingReportingOverflow(
                request.additionalDestinationUIDs.count)
        guard !additionalOverflowed else {
            throw RoutingError.startResourceExceedsLimit(
                resource: "additional device references", requested: Int.max,
                maximum: maximumDeviceReferences)
        }
        try requireStartCount(
            additionalCount, resource: "additional device references",
            maximum: maximumDeviceReferences)

        let deviceReferences =
            [request.sourceDeviceUID, request.destinationDeviceUID]
            + request.additionalSourceUIDs + request.additionalDestinationUIDs
            + (request.monitorDeviceUID.map { [$0] } ?? [])
        for uid in deviceReferences {
            try requireStartIdentifier(uid, resource: "device UID")
        }
        for uid in request.tapUIDs {
            try requireStartIdentifier(uid, resource: "process-tap UID")
        }
        guard Set(request.tapUIDs).count == request.tapUIDs.count else {
            throw RoutingError.invalidStartConfiguration(
                "process-tap UIDs must be unique")
        }

        let uniqueDeviceUIDs = Set(deviceReferences)
        let (endpointCount, endpointOverflowed) = uniqueDeviceUIDs.count
            .addingReportingOverflow(request.tapUIDs.count)
        guard !endpointOverflowed else {
            throw RoutingError.startResourceExceedsLimit(
                resource: "aggregate endpoints", requested: Int.max,
                maximum: maximumAggregateEndpoints)
        }
        try requireStartCount(
            endpointCount, resource: "aggregate endpoints",
            maximum: maximumAggregateEndpoints)

        for route in request.routes {
            try requireStartIdentifier(route.source.deviceUID, resource: "route source UID")
            try requireStartIdentifier(
                route.destination.deviceUID, resource: "route destination UID")
            guard route.source.channel >= 0,
                route.source.channel < AudioProcessingContract.maximumChannelTopology,
                route.destination.channel >= 0,
                route.destination.channel < AudioProcessingContract.maximumChannelTopology
            else {
                throw RoutingError.invalidStartConfiguration(
                    "route channels must be within 0…\(AudioProcessingContract.maximumChannelTopology - 1)"
                )
            }
            guard route.gain.isFinite else {
                throw RoutingError.invalidStartConfiguration("route gains must be finite")
            }
        }

        for (uid, frames) in request.outputLatencyTrim {
            try requireStartIdentifier(uid, resource: "output-latency UID")
            guard uniqueDeviceUIDs.contains(uid) else {
                throw RoutingError.invalidStartConfiguration(
                    "an output latency trim must name a requested device")
            }
            guard frames >= 0, frames <= maximumExtraOutputLatencyFrames else {
                if frames < 0 {
                    throw RoutingError.invalidStartConfiguration(
                        "extra output latency must not be negative")
                }
                throw RoutingError.startResourceExceedsLimit(
                    resource: "extra output-latency frames", requested: frames,
                    maximum: maximumExtraOutputLatencyFrames)
            }
        }

        if let settings = request.echoCancellation {
            try requireStartIdentifier(settings.speakerUID, resource: "echo speaker UID")
            try requireStartCount(
                settings.farEndProcessIDs.count, resource: "far-end processes",
                maximum: maximumFarEndProcesses)
            guard settings.farEndProcessIDs.allSatisfy({ $0 != kAudioObjectUnknown }) else {
                throw RoutingError.invalidStartConfiguration(
                    "far-end process IDs must name live Core Audio objects")
            }
            guard Set(settings.farEndProcessIDs).count == settings.farEndProcessIDs.count else {
                throw RoutingError.invalidStartConfiguration(
                    "far-end process IDs must be unique")
            }
        }
    }

    /// Shared admission for initial construction and every live chain swap.
    /// No Audio Component lookup or instantiation may precede this function.
    static func validateProcessingResources(
        effects: [EffectKind],
        plugins: [AudioUnitPlugin],
        voiceIsolation: VoiceIsolationSettings?
    ) throws {
        try requireStartCount(
            plugins.count, resource: "hosted plugins", maximum: maximumHostedPlugins)
        try requireStartCount(
            effects.count, resource: "built-in effects",
            maximum: EffectKind.allCases.count)
        guard Set(effects).count == effects.count else {
            throw RoutingError.invalidStartConfiguration(
                "a built-in effect may appear only once")
        }
        guard Set(plugins.map(\.id)).count == plugins.count else {
            throw RoutingError.invalidStartConfiguration(
                "an Audio Unit component may appear only once")
        }
        for plugin in plugins {
            guard !plugin.requiresAsyncInstantiation else {
                throw RoutingError.invalidStartConfiguration(
                    "Audio Units which require asynchronous instantiation are not supported by the realtime path"
                )
            }
            guard plugin.loadsInProcess else {
                throw RoutingError.invalidStartConfiguration(
                    "out-of-process Audio Units cannot meet the realtime callback deadline")
            }
            try requireStartText(plugin.name, resource: "plugin name")
            try requireStartText(
                plugin.manufacturerName, resource: "plugin manufacturer name")
        }
        if let settings = voiceIsolation {
            guard settings.mixPercent.isFinite,
                (0...100).contains(settings.mixPercent)
            else {
                throw RoutingError.invalidStartConfiguration(
                    "voice-isolation mix must be within 0…100 percent")
            }
        }
    }

    private static func validateRouteTimingRequest(
        preferredSampleRate: Double?, bufferFrames: UInt32
    ) throws {
        guard
            supportsRouteTimingRequest(
                preferredSampleRate: preferredSampleRate,
                bufferFrames: bufferFrames)
        else {
            if let preferredSampleRate,
                !AudioProcessingContract.supports(sampleRate: preferredSampleRate)
            {
                throw RoutingError.unsupportedSampleRate(
                    requested: preferredSampleRate,
                    minimum: AudioProcessingContract.minimumSampleRate,
                    maximum: AudioProcessingContract.maximumSampleRate)
            }
            throw RoutingError.bufferFrameSizeExceedsLimit(
                requested: bufferFrames,
                maximum: AudioProcessingContract.maximumFramesPerSlice)
        }
    }

    private static func validateStartChannelCount(_ count: Int, resource: String) throws {
        guard count > 0 else {
            throw RoutingError.invalidStartConfiguration(
                "\(resource) must be greater than zero")
        }
        try requireStartCount(
            count, resource: resource,
            maximum: AudioProcessingContract.maximumChannelTopology)
    }

    private static func checkedStartAdd(
        _ lhs: Int, _ rhs: Int, resource: String, maximum: Int
    ) throws -> Int {
        let (value, overflowed) = lhs.addingReportingOverflow(rhs)
        guard !overflowed, value <= maximum else {
            throw RoutingError.startResourceExceedsLimit(
                resource: resource,
                requested: overflowed ? Int.max : value,
                maximum: maximum)
        }
        return value
    }

    private static func checkedStartMultiply(
        _ lhs: Int, _ rhs: Int, resource: String, maximum: Int
    ) throws -> Int {
        let (value, overflowed) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflowed, value <= maximum else {
            throw RoutingError.startResourceExceedsLimit(
                resource: resource,
                requested: overflowed ? Int.max : value,
                maximum: maximum)
        }
        return value
    }

    private static func requireStartCount(
        _ count: Int, resource: String, maximum: Int
    ) throws {
        guard count <= maximum else {
            throw RoutingError.startResourceExceedsLimit(
                resource: resource, requested: count, maximum: maximum)
        }
    }

    private static func requireStartIdentifier(_ value: String, resource: String) throws {
        guard !value.isEmpty else {
            throw RoutingError.invalidStartConfiguration("\(resource) must not be empty")
        }
        try requireStartText(value, resource: resource)
    }

    private static func requireStartText(_ value: String, resource: String) throws {
        let count = value.utf8.count
        guard count <= maximumIdentifierBytes else {
            throw RoutingError.startResourceExceedsLimit(
                resource: "\(resource) bytes", requested: count,
                maximum: maximumIdentifierBytes)
        }
    }

    /// Maximum source-stage delay for which every bypass route has storage.
    ///
    /// The frame ceiling is the delay line's physical capacity. The time
    /// ceiling prevents an unusual low-rate device or hostile plug-in latency
    /// report from turning a bounded live handover into seconds of retained AU
    /// graphs. Latency above this is rejected before publication; clamping it
    /// would align the bypass and processed paths to different points in time.
    static func maximumSourceProcessingLatencyFrames(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let timeBound = sampleRate * 0.200
        guard timeBound < Double(Int.max) else {
            return RTGraph.maximumAlignmentFrames
        }
        return min(
            RTGraph.maximumAlignmentFrames,
            max(0, Int(timeBound.rounded(.down))))
    }

    static func supportsSourceProcessingLatency(_ frames: Int, sampleRate: Double) -> Bool {
        sampleRate.isFinite && sampleRate > 0 && frames >= 0
            && frames <= maximumSourceProcessingLatencyFrames(sampleRate: sampleRate)
    }
    /// Set once a lock failure has forced drift correction back on, so the
    /// recovery cannot loop.
    private var clockLockAbandoned = false
    private let recoveryQueue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.route-recovery")

    /// Reports a route that had to be rebuilt because the clock lock failed.
    public var onClockLockFailure: (@Sendable () -> Void)?

    /// Hands construction and teardown checkpoints to an external bounded sink.
    ///
    /// The engine never performs filesystem work. The application installs one
    /// lock-only first/latest writer here so a checkpoint can leave the engine
    /// before the next synchronous HAL or Audio Unit call begins.
    public var onAudioIncidentBundle: (@Sendable (AudioIncidentBundle) -> Void)?

    /// Why voice isolation is not running, when it was asked for.
    ///
    /// Named constants rather than sentences written out at each site: the
    /// application turns these into something a person can read, and matching
    /// on a phrase that somebody later rewords would silently put the raw
    /// English back in front of the user.
    public enum IsolationFailure {
        public static let chainNotBuilt = "the processing chain could not be built"
        public static let unitNotInstantiated = "AUSoundIsolation could not be instantiated"
        public static let latencyExceedsRealtimeLimit =
            "the processing chain exceeds the supported realtime latency"
        public static let all = [
            chainNotBuilt, unitNotInstantiated, latencyExceedsRealtimeLimit,
        ]
    }

    private var storedIsolationError: String?

    public var lastIsolationError: String? { engineUISnapshot.isolationError }

    /// Why a live processing edit left the audible graph unchanged.
    ///
    /// The Boolean `updateEffects` result predates live handovers and cannot
    /// distinguish temporary backpressure from a topology which needs a full
    /// rebuild. Keeping the detailed result lets the application retry the
    /// latest value after a fade instead of interpreting normal handover time
    /// as permission to tear Core Audio down.
    public enum EffectUpdateRefusal: Sendable, Equatable {
        case transitionInFlight
        case resourcesBusy
        case unsupportedLatency(requested: Int, maximum: Int)
        case invalidConfiguration(String)
        case unavailable
    }

    private var storedEffectUpdateRefusal: EffectUpdateRefusal?

    /// The detailed result of the most recent `updateEffects` call.
    ///
    /// Read on the same serial engine queue as the edit. The lock still makes
    /// the API defined for other callers and keeps the value paired with the
    /// completed request rather than a partially-built chain.
    public var lastEffectUpdateRefusal: EffectUpdateRefusal? {
        engineUISnapshot.effectUpdateRefusal
    }

    /// A monitor output that would not come up, and what it said.
    public struct DroppedMonitor: Sendable, Equatable {
        public let uid: String
        public let reason: String
    }

    /// The monitor the last start had to give up on, or nil when the route came
    /// up exactly as it was asked for.
    ///
    /// A monitor is an *additional* output. The mix going to the far end does
    /// not depend on it, so refusing to route at all because one output would
    /// not start gives up the call to save the sidetone. Measured: three
    /// consecutive flow-check runs where attaching one display's audio endpoint
    /// left `1 → 0 routes`, and every section after it ran against a dead route.
    ///
    /// Named rather than silently dropped, for the same reason the failed
    /// plugins are: a monitor that vanishes with nothing said about it is a
    /// person turning their headphones up and wondering why they are still
    /// deaf.
    private var storedDroppedMonitor: DroppedMonitor?

    public var droppedMonitor: DroppedMonitor? { engineUISnapshot.droppedMonitor }

    /// Additional inputs and outputs the last start had to give up on, with the
    /// failure that made it give up.
    ///
    /// The same argument as `droppedMonitor`, one level out: an extra
    /// microphone that will not join the aggregate must not cost somebody the
    /// route they already had, and it must not do so quietly either. Empty
    /// when the route came up exactly as asked.
    private var storedDroppedExtras: [DroppedMonitor] = []

    public var droppedExtras: [DroppedMonitor] { engineUISnapshot.droppedExtras }

    /// Third-party units that were asked for and would not load, each with the
    /// step that refused and the status it returned.
    private var storedFailedPlugins: [AudioUnitLoadFailure] = []

    public var failedPlugins: [AudioUnitLoadFailure] { engineUISnapshot.failedPlugins }
    /// The stages actually rendering, which is not the same as the stages that
    /// were asked for: one that will not instantiate is dropped.
    public var activeEffectStages: [EffectKind] {
        engineUISnapshot.activeEffectStages
    }

    /// The installed stages when they can be inspected without waiting for a
    /// replacement Audio Unit graph to finish building.
    public var activeEffectStagesIfAvailable: [EffectKind]? {
        // SwiftUI reads this while `updateEffects` is building Audio Units on
        // the engine queue. That build owns the same lock and takes tens of
        // milliseconds, so waiting here turns a background hot swap into a
        // frozen frame on the main thread. Nil lets the main-actor snapshot
        // retain the last answer until the publication has finished.
        guard stateLock.try() else { return nil }
        defer { stateLock.unlock() }
        var stages = effectChain?.stages ?? (isolationUnit != nil ? [.voiceIsolation] : [])
        if graph?.pointee.outputLimiterEnabled != 0 { stages.append(.limiter) }
        return stages.sorted { $0.chainOrder < $1.chainOrder }
    }

    /// Returns one coherent interface snapshot without waiting for lifecycle.
    ///
    /// A fresh read also publishes the fallback. Contention returns the last
    /// complete generation rather than parking MainActor or manufacturing
    /// empty arrays and zero latency between two real graph states.
    public var engineUISnapshot: EngineUISnapshot {
        guard stateLock.try() else {
            return publishedSnapshotLock.withLock { publishedEngineUISnapshot }
        }
        let snapshot = makeAndPublishEngineUISnapshotLocked()
        stateLock.unlock()
        return snapshot
    }

    private func makeAndPublishEngineUISnapshotLocked() -> EngineUISnapshot {
        engineUISnapshotGeneration &+= 1
        if engineUISnapshotGeneration == 0 { engineUISnapshotGeneration = 1 }
        let snapshot = makeEngineUISnapshotLocked()
        _ = publishEngineUISnapshot(snapshot)
        return snapshot
    }

    private func makeEngineUISnapshotLocked() -> EngineUISnapshot {
        var stages = effectChain?.stages ?? (isolationUnit != nil ? [.voiceIsolation] : [])
        if graph?.pointee.outputLimiterEnabled != 0 { stages.append(.limiter) }
        return EngineUISnapshot(
            generation: engineUISnapshotGeneration,
            routeGeneration: routeLifetimeGeneration,
            graphGeneration: graph == nil ? 0 : graphPublicationGeneration,
            routes: activeRoutes,
            processingLatency: ProcessingLatency(
                sourceFrames: storedSourceProcessingLatencyFrames,
                outputFrames: storedOutputProcessingLatencyFrames),
            voiceIsolationLatencyFrames: storedVoiceIsolationLatencyFrames,
            alignmentFrames: Int(graph?.pointee.alignmentFrames ?? 0),
            failedPlugins: storedFailedPlugins,
            droppedMonitor: storedDroppedMonitor,
            droppedExtras: storedDroppedExtras,
            isolationError: storedIsolationError,
            activeEffectStages: stages.sorted { $0.chainOrder < $1.chainOrder },
            effectUpdateRefusal: storedEffectUpdateRefusal,
            holdsClockLock:
                requiresClockLock && !clockLockAbandoned && lastConfiguration != nil,
            echoCancellationStatus: echoCancellationStatusLocked(),
            echoCancellationError: lastEchoCancellationError,
            echoCancellationDetail: lastEchoCancellationDetail,
            outputDeviceUIDs: Array(Set(outputMap.keys.map(\.deviceUID))).sorted(),
            correctionOutcome: lastCorrectionOutcome)
    }

    @discardableResult
    private func publishEngineUISnapshot(_ snapshot: EngineUISnapshot) -> Bool {
        publishedSnapshotLock.withLock {
            guard snapshot.generation > publishedEngineUISnapshot.generation else {
                return false
            }
            publishedEngineUISnapshot = snapshot
            return true
        }
    }

    @discardableResult
    func installEngineUISnapshotForTesting(_ snapshot: EngineUISnapshot) -> Bool {
        stateLock.lock()
        engineUISnapshotGeneration = max(
            engineUISnapshotGeneration, snapshot.generation)
        stateLock.unlock()
        return publishEngineUISnapshot(snapshot)
    }

    private func recordEngineGraphPublicationLocked() {
        graphPublicationGeneration &+= 1
        if graphPublicationGeneration == 0 { graphPublicationGeneration = 1 }
    }

    /// How much a dynamics stage is pulling the signal down right now, in
    /// decibels. Zero when the stage is not in the chain, and nil when a graph
    /// change owns the state long enough that reading it would block.
    public func gainReduction(of kind: EffectKind) -> Float? {
        // Polled by the interface at 20 Hz, including while the chain is being
        // swapped. Nil tells the main-actor snapshot to hold its last reading;
        // zero would make the meter visibly blink during every instantiation.
        guard stateLock.try() else { return nil }
        guard let chain = effectChain else {
            stateLock.unlock()
            return 0
        }
        let owner = chain.controlIdentity
        let published = publishedGainReductionLock.withLock {
            publishedGainReduction[kind]
        }
        guard let lease = chain.acquireControlLease() else {
            stateLock.unlock()
            return nil
        }
        stateLock.unlock()
        BoundedAudioUnitControlLane.shared.submit(
            key: "meter:\(kind.rawValue)", lease: lease
        ) { context in
            guard context.mayBeginOperation else { return }
            let value = chain.gainReduction(of: kind)
            guard context.mayBeginOperation else { return }
            self.publishedGainReductionLock.withLock {
                self.publishedGainReduction[kind] = GainReductionPublication(
                    owner: owner, value: value)
            }
        }
        if let published, published.owner == owner { return published.value }
        return nil
    }

    /// What the hosted plugins say their controls are, by plugin id.
    public func pluginParameters(_ id: String) -> [EffectParameter] {
        stateLock.lock()
        guard let chain = effectChain, let lease = chain.acquireControlLease() else {
            stateLock.unlock()
            return []
        }
        let owner = chain.controlIdentity
        stateLock.unlock()
        let result: AudioUnitLaneResult<[EffectParameter]> =
            BoundedAudioUnitControlLane.shared.perform(
                key: "metadata:\(id)", lease: lease
            ) { context in
                guard context.mayBeginOperation else { return [] }
                return chain.parameters(ofPlugin: id)
            }
        if case .completed(let parameters) = result {
            publishPluginParameters(parameters, id: id, owner: owner)
            return parameters
        }
        return []
    }

    /// The same metadata without making an interface redraw wait for a chain
    /// publication. A plugin's parameter list is structural, so the caller can
    /// keep the last successful answer while a replacement unit is built.
    public func pluginParametersIfAvailable(_ id: String) -> [EffectParameter]? {
        guard stateLock.try() else { return nil }
        guard let chain = effectChain else {
            stateLock.unlock()
            return []
        }
        let owner = chain.controlIdentity
        if let published = publishedPluginParameterLock.withLock({
            publishedPluginParameters[id]
        }), published.owner == owner {
            stateLock.unlock()
            return published.parameters
        }
        guard let lease = chain.acquireControlLease() else {
            stateLock.unlock()
            return nil
        }
        stateLock.unlock()
        BoundedAudioUnitControlLane.shared.submit(
            key: "metadata:\(id)", lease: lease
        ) { context in
            guard context.mayBeginOperation else { return }
            let parameters = chain.parameters(ofPlugin: id)
            guard context.mayBeginOperation else { return }
            self.publishPluginParameters(parameters, id: id, owner: owner)
        }
        return nil
    }

    private func publishPluginParameters(
        _ parameters: [EffectParameter], id: String, owner: UUID
    ) {
        publishedPluginParameterLock.withLock {
            // A person can swap through an arbitrary catalogue over a long
            // session. This cache is a redraw witness, not a history.
            if publishedPluginParameters[id] == nil,
                publishedPluginParameters.count >= Self.maximumHostedPlugins
            {
                publishedPluginParameters.removeAll(keepingCapacity: true)
            }
            publishedPluginParameters[id] = PluginParameterPublication(
                owner: owner, parameters: parameters)
        }
    }

    /// Sets a control on a hosted third-party unit.
    public func setPluginParameter(_ parameter: String, ofPlugin id: String, to value: Float) {
        stateLock.lock()
        guard let chain = effectChain, let lease = chain.acquireControlLease() else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        BoundedAudioUnitControlLane.shared.submit(
            key: "plugin:\(id):\(parameter)", lease: lease
        ) { context in
            guard context.mayBeginOperation else { return }
            chain.set(parameter, ofPlugin: id, to: value)
        }
    }
    /// Why the echo canceller is not running, when it was asked for. Named for
    /// the reason `IsolationFailure` is: the application turns these into
    /// something a person can read.
    public enum EchoFailure {
        public static let notBuilt = "the echo canceller could not be built"
        public static let wouldNotStart = "the echo canceller would not start"
        public static let microphoneMissing = "the microphone is no longer there"
        public static let speakerMissing = "the speaker to cancel against is no longer there"
        public static let microphoneCannotPresentRouterRate =
            "the microphone cannot run at the router's sample rate"
        public static let noSharedSampleRate =
            "the microphone and the speaker share no sample rate"
        public static let sampleRateNotApplied =
            "the devices would not take the sample rate the canceller needs"
        public static let aggregateNotCreated =
            "the canceller's aggregate device could not be created"
        public static let unitNotInstantiated =
            "AUVoiceProcessingIO could not be instantiated"
        public static let unitRefusedSetup =
            "AUVoiceProcessingIO refused the configuration it was given"
        public static let clockDiffersFromRouter =
            "the canceller's clock does not match the router's"
        public static let ringNotAllocated =
            "the ring carrying cancelled audio could not be allocated"

        /// Every reason the engine can record, so the application's mapping
        /// from reason to sentence can be checked exhaustively rather than
        /// against a list somebody has to remember to extend.
        public static let all: [String] = [
            notBuilt, wouldNotStart, microphoneMissing, speakerMissing,
            microphoneCannotPresentRouterRate, noSharedSampleRate,
            sampleRateNotApplied, aggregateNotCreated, unitNotInstantiated,
            unitRefusedSetup, clockDiffersFromRouter, ringNotAllocated,
        ]
    }

    public private(set) var lastEchoCancellationError: String?
    /// The same refusal with its numbers, for the command-line harness. The
    /// interface gets a sentence; a report gets the rates that decided it.
    public private(set) var lastEchoCancellationDetail: String?

    /// The canceller, while it is in the path. Retained here so it outlives the
    /// ring pointer the IO thread holds.
    private var echoBridge: EchoCancellationBridge?

    /// Which branch of the echo canceller stored its teardown verdict.
    ///
    /// Temporary, for the divergence hunt: five sites can write it and the
    /// enum cannot tell them apart. The last non-complete verdict outlives its
    /// bridge, so this keeps it rather than reading the current one.
    public private(set) var echoTeardownDecidedBy = "never"

    /// Last complete failure pair, retained across the very short interval in
    /// which the callback is publishing its next seqlock generation. Falling
    /// back to two separately-read counters there would put the torn snapshot
    /// back at the final UI boundary.
    private var lastEchoRenderDiagnostics: EchoCancellationRenderDiagnostics?

    /// The destination as a device, for reading controls back off it.
    private var destinationDevice: AudioDevice?

    /// Cycle counter and clock anchor, owned by the route rather than by any
    /// one graph, so a patchbay edit does not free storage the clock publisher
    /// is still reading from its own queue.
    private var sharedClock: RTGraph.SharedClock?
    /// One ring and one consumer cursor for the complete route lifetime.
    /// Graph generations borrow it and therefore never mutate a predecessor to
    /// transfer ownership during publication.
    private var sharedAnalysisRing: RTGraph.SharedAnalysisRing?

    /// Held here as well as in the graph, because the graph is replaced on
    /// every restart and would come back at unity otherwise.
    public private(set) var inputGain: Float = 1
    public private(set) var isInputMuted = false
    public private(set) var outputGain: Float = 1
    public private(set) var isOutputMuted = false
    /// Control-side truth for globals whose realtime copy changes only through
    /// the latest-value mailbox. Graph builders never read those live scalars.
    private var duckingEnabled = false
    private var duckingDepth: Float = 0.1
    private var duckingAllowed = false
    private var analysisIsEnabled = false
    private var recordingIsPaused = false
    private var calibrationIsActive = false
    private var calibrationEpoch: UInt32 = 0
    private var calibrationSnapshot: [(energy: Double, frames: UInt64)] = []
    private var outputClippingEpoch: UInt32 = 0
    private var outputLimiterIsEnabled = false
    private var mainOutputBuffer: Int32 = 0
    private var masterExemptBuffer: Int32 = -1
    private var recordingChannels = 0
    private var stemChannelCounts: [Int] = []
    private var stemAssignments: [RouteOccurrenceKey: (stem: Int32, channel: Int32)] = [:]
    private var transcriptAssignments: [RouteOccurrenceKey: Int32] = [:]
    /// Reused so a failed telemetry seqlock attempt cannot partially overwrite
    /// the caller's last complete meter frame.
    private var telemetryPeakScratch: [Float] = []

    /// True when the microphone is reaching the routes through the canceller
    /// rather than through this aggregate.
    public var cancelsEcho: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return echoBridge != nil
    }

    /// What the canceller is doing, for the diagnostics view. Nil when it is
    /// not in the path — and nil, rather than a wait, while the route is being
    /// built.
    ///
    /// `try` rather than `lock`, and it is not an optimisation. This is read
    /// from `StatusPills`, which is evaluated on every pass of the SwiftUI view
    /// graph, on the main thread. `startAttempt` holds this lock across
    /// `AudioDeviceCreateIOProcID`, which is a synchronous message to
    /// `coreaudiod` — normally a few milliseconds, and unbounded when
    /// `coreaudiod` is wedged, which it can be. Taking the lock the ordinary
    /// way therefore froze the entire interface for as long as the audio server
    /// took to answer: measured here with the whole main thread parked in
    /// `__psynch_mutexwait` under this getter while the engine queue sat in
    /// `mach_msg`, with nothing on screen redrawing and no menu responding.
    ///
    /// A diagnostic row that is briefly blank while the route comes up is not
    /// worth a frozen application.
    public var echoCancellationStatus: EchoCancellationStatus? {
        guard stateLock.try() else { return nil }
        defer { stateLock.unlock() }
        return echoCancellationStatusLocked()
    }

    private func echoCancellationStatusLocked() -> EchoCancellationStatus? {
        guard let bridge = echoBridge else { return nil }
        let render: EchoCancellationRenderDiagnostics
        if let fresh = bridge.renderDiagnostics {
            lastEchoRenderDiagnostics = fresh
            render = fresh
        } else {
            render =
                lastEchoRenderDiagnostics
                ?? EchoCancellationRenderDiagnostics(
                    failureCount: 0, lastStatus: noErr)
        }
        return EchoCancellationStatus(
            produced: bridge.producedFrames,
            buffered: bridge.bufferedFrames,
            dropped: bridge.droppedFrames,
            hasReference: bridge.hasFarEndReference && !bridge.farEndReferenceFailed,
            truncatedBlocks: bridge.truncatedBlocks,
            inputCallbacks: bridge.inputCallbacks,
            farEndCallbacks: bridge.farEndCallbacks,
            callbackOverlaps: bridge.callbackOverlaps,
            renderFailures: render.failureCount,
            lastRenderStatus: render.lastStatus)
    }

    public init() {}

    deinit {
        let result = stop()
        if result.requiresOwnerQuarantine {
            quarantineFailedTeardown(result)
        }
    }

    /// Transfers every callback-transitive owner into process lifetime.
    ///
    /// Retaining `self` from `deinit` would resurrect a partially destroyed
    /// object and is not valid Swift ownership. This capsule contains only the
    /// immutable owners and raw cleanup context a live callback can still
    /// reach. There is one routing engine in the application, so a permanently
    /// failed Core Audio fence costs one bounded route generation.
    private func quarantineFailedTeardown(_ result: RoutingTeardownResult) {
        var owners: [AnyObject] = []
        var seen = Set<ObjectIdentifier>()
        func retain(_ owner: AnyObject?) {
            guard let owner, seen.insert(ObjectIdentifier(owner)).inserted else { return }
            owners.append(owner)
        }

        retain(retiredGenerations)
        retain(recorderFinaliser)
        retain(aggregate)
        retain(clockPublisher)
        retain(echoBridge)
        retain(isolationUnit)
        retain(effectChain)
        retain(outputLimiterBank)
        retain(recordingLimiter)
        retain(selftestOwner)
        retain(effectTransitionController)
        retain(transitionOldChain)
        retain(transitionOldUnit)
        retain(recorder)
        retain(incidentRecorder)
        for recorder in stemRecorders { retain(recorder) }
        for tap in aggregate?.taps ?? [] { retain(tap) }
        for tap in lastConfiguration?.taps ?? [] { retain(tap) }
        for tap in pendingTeardownTaps { retain(tap) }

        let raw = RoutingEngineQuarantineCapsule.RawContext(
            ioProcID: ioProcID,
            graph: graph,
            graphCell: graphCell,
            sharedClock: sharedClock,
            sharedAnalysisRing: sharedAnalysisRing,
            alignmentHistories: Array(alignmentHistories.values),
            selftestBlock: selftestBlock,
            isolationBlock: isolationBlock,
            isolationFailures: isolationFailureCounter,
            effectTransitionBlock: effectTransitionBlock,
            transitionOldBlock: transitionOldBlock,
            transcriptRings: transcriptRings)
        let capsule = RoutingEngineQuarantineCapsule(owners: owners, raw: raw)
        ProcessLifetimeAudioQuarantine.shared.retain(
            capsule, reason: "RoutingEngine teardown retained: \(result)")
    }

    /// Most recent lifecycle result. A non-complete value is an intentional
    /// retained route, not a route which was silently declared gone.
    public var lastTeardownResult: RoutingTeardownResult? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedTeardownResult
    }

    /// Last bounded route incident assembled after a Stop attempt.
    public var lastAudioIncidentBundle: AudioIncidentBundle? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedIncidentBundle
    }

    /// Takes the newest incident which has not yet crossed the engine boundary.
    public func takePendingAudioIncidentBundle() -> AudioIncidentBundle? {
        stateLock.lock()
        defer { stateLock.unlock() }
        defer { pendingIncidentBundle = nil }
        return pendingIncidentBundle
    }

    /// Reserves one route-run identity before the caller creates any audio owner.
    ///
    /// The returned value is deliberately not sent through the ordinary
    /// first/latest callback: the application must obtain an exact durable-write
    /// receipt for it before constructing a process tap. A refused reservation
    /// therefore leaves Core Audio untouched and cannot be mistaken for an
    /// asynchronously queued checkpoint.
    public func reserveAudioIncidentBeforeOwnership(
        sourceDeviceUID: String,
        destinationDeviceUID: String,
        preferredSampleRate: Double?,
        bufferFrames: UInt32,
        processTapOwnershipExpected: Bool = false
    ) throws -> AudioIncidentReservation {
        stateLock.lock()
        defer { stateLock.unlock() }
        try Self.validateRouteTimingRequest(
            preferredSampleRate: preferredSampleRate,
            bufferFrames: bufferFrames)
        guard activeAudioIncidentReservation == nil, incidentRecorder == nil,
            !isRunning, aggregate == nil, ioProcID == nil, graph == nil,
            echoBridge == nil, lastConfiguration == nil,
            pendingTeardownTaps.isEmpty,
            storedTeardownResult?.isComplete ?? true
        else {
            throw RoutingError.invalidStartConfiguration(
                "an audio route or construction reservation is already owned")
        }
        if let residue = ProcessLifetimeAudioQuarantine.shared.refusalForNewAudioOwnership() {
            throw RoutingError.audioResiduePresent(residue)
        }
        guard
            let frames = Int(exactly: bufferFrames),
            let recorder = AudioIncidentRecorder(
                sampleRate: preferredSampleRate ?? 48_000,
                bufferFrames: frames,
                driverDeviceID: nil,
                driverWasRequired: false,
                driverHealthBaseline: AudioIncidentDriverHealth(
                    state: .driverAbsent, wasRequired: false, readStatus: noErr,
                    unsafeReadOperations: 0, unsafeWriteOperations: 0),
                residueBaseline: ProcessLifetimeAudioQuarantine.shared.telemetry,
                resources: AudioIncidentRecorder.Resources(
                    hadEchoCancellation: false,
                    hadAudioUnits: false,
                    hadAggregate: false,
                    hadProcessTaps: false,
                    changedSampleRates: false)),
            let bundle = recorder.makeConstructionBundle(
                residue: ProcessLifetimeAudioQuarantine.shared.telemetry)
        else { throw RoutingError.realtimeStorageUnavailable }
        incidentRecorder = recorder
        audioIncidentReservationGeneration &+= 1
        let token = AudioIncidentReservation(
            constructionBundle: bundle,
            engineID: audioIncidentReservationEngineID,
            generation: audioIncidentReservationGeneration,
            processTapOwnershipExpected: processTapOwnershipExpected,
            sourceDeviceUID: sourceDeviceUID,
            destinationDeviceUID: destinationDeviceUID,
            preferredSampleRate: preferredSampleRate,
            bufferFrames: bufferFrames)
        activeAudioIncidentReservation = ActiveAudioIncidentReservation(
            token: token,
            previousStoredBundle: storedIncidentBundle,
            previousPendingBundle: pendingIncidentBundle,
            phase: .beforeOwnership)
        storedIncidentBundle = bundle
        pendingIncidentBundle = nil
        return token
    }

    /// Marks the boundary immediately before a constructor can enter Core Audio.
    ///
    /// Repeating a mark for a bounded retry is harmless. A stale token throws
    /// before the system call, which is the important direction: an old start
    /// must never create an owner under a newer run's evidence.
    public func makeProcessTapOwnershipCheckpoint(
        reservation: AudioIncidentReservation
    ) throws -> AudioIncidentBundle {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard reservationMatchesLocked(reservation), let incidentRecorder else {
            throw RoutingError.invalidStartConfiguration(
                "the audio incident reservation is stale")
        }
        guard reservation.processTapOwnershipExpected,
            activeAudioIncidentReservation?.phase == .beforeOwnership
        else {
            throw RoutingError.invalidStartConfiguration(
                "the audio incident reservation was already consumed")
        }
        incidentRecorder.recordProcessTapCallEntered()
        guard
            let bundle = incidentRecorder.makeConstructionBundle(
                residue: ProcessLifetimeAudioQuarantine.shared.telemetry)
        else { throw RoutingError.realtimeStorageUnavailable }
        storedIncidentBundle = bundle
        pendingIncidentBundle = nil
        activeAudioIncidentReservation?.phase = .checkpointPrepared
        return bundle
    }

    /// Commits the exact persisted checkpoint immediately before a HAL owner call.
    public func beginAudioIncidentOwnership(
        reservation: AudioIncidentReservation
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard reservationMatchesLocked(reservation),
            reservation.processTapOwnershipExpected,
            activeAudioIncidentReservation?.phase == .checkpointPrepared
        else {
            throw RoutingError.invalidStartConfiguration(
                "the audio incident reservation is stale")
        }
        activeAudioIncidentReservation?.phase = .ownershipMayExist
    }

    /// Releases a reservation after durable storage refused the start.
    ///
    /// This is only valid before the first owner is created. It intentionally
    /// performs no HAL query or teardown call, which preserves the guarantee the
    /// caller needs when storage itself is unavailable or blocked.
    @discardableResult
    public func discardAudioIncidentReservation(
        _ reservation: AudioIncidentReservation
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard reservationMatchesLocked(reservation),
            activeAudioIncidentReservation?.phase == .beforeOwnership,
            pendingTeardownTaps.isEmpty,
            aggregate == nil, ioProcID == nil, graph == nil, echoBridge == nil
        else { return false }
        let previousStoredBundle = activeAudioIncidentReservation?.previousStoredBundle
        let previousPendingBundle = activeAudioIncidentReservation?.previousPendingBundle
        activeAudioIncidentReservation = nil
        incidentRecorder = nil
        storedIncidentBundle = previousStoredBundle
        pendingIncidentBundle = previousPendingBundle
        return true
    }

    private func reservationMatchesLocked(
        _ reservation: AudioIncidentReservation
    ) -> Bool {
        guard let active = activeAudioIncidentReservation?.token else { return false }
        return reservation.engineID == audioIncidentReservationEngineID
            && reservation.engineID == active.engineID
            && reservation.generation == active.generation
            && reservation.constructionBundle.runID == active.constructionBundle.runID
    }

    /// Captures the first live evidence after CoreAudio has proved callbacks.
    ///
    /// This is intentionally not a health verdict: callbacks have not been
    /// fenced and teardown has not happened. Its purpose is to leave a bounded
    /// run identity behind even when a crash or forced termination makes the
    /// ordinary Stop evidence impossible to produce.
    @discardableResult
    public func checkpointLiveAudioIncidentBundle() -> AudioIncidentBundle? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, let recorder = incidentRecorder else { return nil }
        guard
            let bundle = recorder.makeLiveBundle(
                callbackCellOverlaps: graphCell.map(yun_rt_cell_overlaps) ?? 0,
                residue: ProcessLifetimeAudioQuarantine.shared.telemetry)
        else { return nil }
        publishIncidentBundleLocked(bundle)
        return bundle
    }

    private func publishIncidentBundleLocked(_ bundle: AudioIncidentBundle) {
        storedIncidentBundle = bundle
        pendingIncidentBundle = bundle
        onAudioIncidentBundle?(bundle)
    }

    private func checkpointConstructionIncidentLocked(
        _ recorder: AudioIncidentRecorder
    ) {
        guard
            let bundle = recorder.makeConstructionBundle(
                residue: ProcessLifetimeAudioQuarantine.shared.telemetry)
        else { return }
        publishIncidentBundleLocked(bundle)
    }

    /// Takes ownership of prepared taps which must be proven absent by Stop.
    ///
    /// Callers use this after deciding a preparation will not be handed to
    /// `start`, or after a preflight refusal which happened before `start` took
    /// ownership. Once an attempt begins the engine adopts the taps itself and
    /// explicitly preserves them through its internal teardown.
    public func adoptTapsForTeardown(_ taps: [ProcessTap]) {
        guard !taps.isEmpty else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        adoptTapsForTeardownLocked(taps)
    }

    /// Process taps this engine has been handed, and how many of them the HAL
    /// only produced on a second ask.
    ///
    /// `AudioHardwareCreateProcessTap` returns `noErr` with an empty object ID
    /// intermittently, for the same process in the same run. `ProcessTap`
    /// already answers that with one guarded retry, and already counted the
    /// attempts it took into a property nothing read — a number computed and
    /// thrown away, which is the one thing this project does not allow. Kept
    /// here because whether the retry rescues those is the open half of that
    /// report, and it cannot be answered without counting.
    public private(set) var tapsCreated = 0
    public private(set) var tapsNeedingASecondAttempt = 0

    private func adoptTapsForTeardownLocked(_ taps: [ProcessTap]) {
        for tap in taps where !pendingTeardownTaps.contains(where: { $0 === tap }) {
            tapsCreated += 1
            if tap.creationAttempts > 1 { tapsNeedingASecondAttempt += 1 }
        }
        let ownership = ProcessTapRetryOwnership(pending: pendingTeardownTaps)
        pendingTeardownTaps = ownership.adopting(taps).pending
        guard let incidentRecorder else { return }
        incidentRecorder.recordResources(
            AudioIncidentRecorder.Resources(
                hadEchoCancellation: false,
                hadAudioUnits: false,
                hadAggregate: false,
                hadProcessTaps: true,
                changedSampleRates: false))
        checkpointConstructionIncidentLocked(incidentRecorder)
    }

    private func transferTapsToActiveRouteLocked(_ taps: [ProcessTap]) {
        let ownership = ProcessTapRetryOwnership(pending: pendingTeardownTaps)
        pendingTeardownTaps = ownership.activating(taps).pending
    }

    // MARK: Lifecycle

    /// Builds the aggregate, resolves channel mappings, installs the IOProc and
    /// starts the device.
    ///
    /// - Parameters:
    ///   - sourceDeviceUID: The physical input. It becomes the clock master, so
    ///     its samples are never resampled.
    ///   - destinationDeviceUID: The virtual output the routed signal lands in.
    ///   - routes: Channel-level connections between the two.
    ///   - taps: Application captures to fold in as extra source channels.
    ///   - additionalDestinationUIDs: Further outputs to bind, so a tapped
    ///     application can be sent somewhere other than the main destination.
    ///   - monitorDeviceUID: A second output the microphone is also sent to, so
    ///     the user can hear themselves. Exempt from the master fader, because
    ///     the master is the level going to the far end and pulling it down
    ///     must not stop somebody hearing their own voice.
    ///   - effects: Processing stages to insert ahead of the routes. More than
    ///     one supersedes `voiceIsolation`, which is the single-stage form.
    ///   - plugins: Third-party Audio Units, placed after everything this
    ///     application shapes and before the limiter.
    ///   - preferredSampleRate: Used when both devices support it, rather than
    ///     always taking the highest common rate — a voice chat gains nothing
    ///     above 48 kHz.
    ///   - bufferFrames: IO cycle size. 128 frames is 2.7 ms at 48 kHz.
    ///   - voiceIsolation: Single-stage isolation settings, or nil for none.
    ///   - echoCancellation: Speaker and far-end reference for the canceller,
    ///     or nil to leave the microphone in this aggregate.
    ///   - outputLatencyTrim: Extra frames of delay per output device UID, for
    ///     lining up two outputs that do not arrive together. The HAL applies
    ///     it, so nothing on the realtime path changes.
    ///   - selftest: Installs the loopback integrity check.
    /// - Throws: `RoutingError` when a device is missing, a channel cannot be
    ///   mapped, the devices share no sample rate, or CoreAudio refuses to
    ///   create or start the aggregate.
    /// Coarse timings for the start path, printed when YUNAUDIO_TIMING is set.
    ///
    /// Added because a route restart turned out to cost several seconds and
    /// nobody knew which part — and a restart is not a rare event: changing one
    /// effect, one channel mode or one device does it, so whatever it costs is
    /// what the application costs to use.
    private static let reportsTiming =
        ProcessInfo.processInfo.environment["YUNAUDIO_TIMING"] != nil

    private func timed<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        guard Self.reportsTiming else { return try work() }
        let began = Date()
        let result = try work()
        FileHandle.standardError.write(
            Data(
                String(
                    format: "  %6.0f ms  %@\n", Date().timeIntervalSince(began) * 1000, label
                )
                .utf8))
        return result
    }

    public func start(
        sourceDeviceUID: String,
        destinationDeviceUID: String,
        routes: [Route],
        taps: [ProcessTap] = [],
        additionalSourceUIDs: [String] = [],
        additionalDestinationUIDs: [String] = [],
        monitorDeviceUID: String? = nil,
        effects: [EffectKind] = [],
        plugins: [AudioUnitPlugin] = [],
        preferredSampleRate: Double? = nil,
        bufferFrames: UInt32 = 128,
        voiceIsolation: VoiceIsolationSettings? = nil,
        echoCancellation: EchoCancellationSettings? = nil,
        outputLatencyTrim: [String: Int] = [:],
        selftest: Bool = false,
        audioIncidentReservation: AudioIncidentReservation? = nil
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        try startLocked(
            StartConfiguration(
                sourceDeviceUID: sourceDeviceUID,
                destinationDeviceUID: destinationDeviceUID,
                routes: routes,
                taps: taps,
                additionalSourceUIDs: additionalSourceUIDs,
                additionalDestinationUIDs: additionalDestinationUIDs,
                monitorDeviceUID: monitorDeviceUID,
                effects: effects,
                plugins: plugins,
                preferredSampleRate: preferredSampleRate,
                bufferFrames: bufferFrames,
                voiceIsolation: voiceIsolation,
                echoCancellation: echoCancellation,
                outputLatencyTrim: outputLatencyTrim,
                analysisEnabled: false,
                selftest: selftest),
            audioIncidentReservation: audioIncidentReservation)
    }

    /// A start, and — when a monitor is attached — a second one without it.
    ///
    /// There is no asking an output whether it will work: a display's audio
    /// endpoint takes about twelve seconds to answer `AudioDeviceStart failed
    /// with 'stop'`, and an aggregate offered as a member of another aggregate
    /// simply never has its channels appear, so the route fails while resolving
    /// them. Building again without the monitor is therefore the test as well
    /// as the remedy — it is what tells the difference between a monitor that
    /// is unusable and a route that is.
    private func startLocked(
        _ configuration: StartConfiguration,
        audioIncidentReservation: AudioIncidentReservation? = nil
    ) throws {
        let retryBeganAt = ProcessInfo.processInfo.systemUptime
        func isWithinRetryBudget() -> Bool {
            Self.permitsStartRetry(
                elapsed: ProcessInfo.processInfo.systemUptime - retryBeganAt)
        }
        guard Self.acceptsRealtimeRouteCount(configuration.routes.count) else {
            throw RoutingError.routeTopologyExceedsLimit(
                requested: configuration.routes.count,
                maximum: RTGraph.maximumRoutes)
        }
        try Self.validateRouteTimingRequest(
            preferredSampleRate: configuration.preferredSampleRate,
            bufferFrames: configuration.bufferFrames)
        try Self.validateStartResources(
            StartResourceRequest(
                sourceDeviceUID: configuration.sourceDeviceUID,
                destinationDeviceUID: configuration.destinationDeviceUID,
                routes: configuration.routes,
                tapUIDs: configuration.taps.map(\.uid),
                additionalSourceUIDs: configuration.additionalSourceUIDs,
                additionalDestinationUIDs: configuration.additionalDestinationUIDs,
                monitorDeviceUID: configuration.monitorDeviceUID,
                effects: configuration.effects,
                plugins: configuration.plugins,
                voiceIsolation: configuration.voiceIsolation,
                echoCancellation: configuration.echoCancellation,
                outputLatencyTrim: configuration.outputLatencyTrim))
        let quarantine = ProcessLifetimeAudioQuarantine.shared
        if let residue = quarantine.refusalForNewAudioOwnership() {
            throw RoutingError.audioResiduePresent(residue)
        }
        if let reservation = audioIncidentReservation {
            guard reservationMatchesLocked(reservation),
                reservation.sourceDeviceUID == configuration.sourceDeviceUID,
                reservation.destinationDeviceUID == configuration.destinationDeviceUID,
                reservation.preferredSampleRate == configuration.preferredSampleRate,
                reservation.bufferFrames == configuration.bufferFrames,
                let phase = activeAudioIncidentReservation?.phase,
                Self.reservationPhasePermitsStart(
                    phase,
                    processTapOwnershipExpected: reservation.processTapOwnershipExpected)
            else {
                throw RoutingError.invalidStartConfiguration(
                    "the audio incident reservation does not match this route")
            }
        } else if activeAudioIncidentReservation != nil {
            throw RoutingError.invalidStartConfiguration(
                "the reserved audio route requires its exact incident token")
        }
        // From this boundary an attempt may fail before it has an aggregate or a
        // recovery snapshot. Keep those taps in the explicit Stop transaction so
        // the final failure still proves each one absent. Internal attempt
        // teardown names the same objects as preserved below.
        adoptTapsForTeardownLocked(configuration.taps)
        storedDroppedMonitor = nil
        storedDroppedExtras = []
        var failure: Error
        do {
            try startAttempt(
                configuration, audioIncidentReservation: audioIncidentReservation)
            return
        } catch let thrown {
            failure = thrown
        }

        if let routingFailure = failure as? RoutingError {
            switch routingFailure {
            case .teardownIncomplete:
                throw routingFailure
            case .sourceProcessingLatencyExceedsLimit, .audioResiduePresent,
                .audioServerHealthUnavailable:
                // Removing a monitor or extra device cannot change an Audio
                // Unit's latency or make an uncertain owner safe. Rebuilding
                // those aggregates only repeats synchronous HAL work and
                // extends the period in which the system Sound service is
                // occupied.
                let teardown = stopLocked()
                guard teardown.isComplete else {
                    throw RoutingError.teardownIncomplete(teardown)
                }
                throw routingFailure
            default:
                break
            }
        }

        // `AudioDeviceStart` can return `noErr` without the device ever calling
        // its IOProc. Measured after a preset rebuild: the model said Running,
        // while the cycle count, recorder, analyser and Spotify tap all stayed
        // at zero. The same configuration came up on the next attempt.
        //
        // Retry that exact request before the fallback ladder. Dropping a
        // monitor or an extra source would hide a stalled device as a feature
        // that "could not be used", when none of the main mix ran either.
        if case RoutingError.noIOCycles = failure, isWithinRetryBudget() {
            do {
                try startAttempt(
                    configuration, audioIncidentReservation: audioIncidentReservation)
                return
            } catch let retryFailure {
                failure = retryFailure
            }
            if let routingFailure = failure as? RoutingError,
                case .teardownIncomplete = routingFailure
            {
                throw routingFailure
            }
        }

        // What the route can afford to lose, in the order it can afford to lose
        // it, each rung cumulative with the last. The main mix is never on the
        // list: it is the thing all of this is additional to.
        //
        // Extras go first because they are the more numerous and the more
        // likely to be what somebody just changed. When there are none the
        // ladder is exactly the single monitor retry it has always been.
        var ladder: [(configuration: StartConfiguration, drops: [String])] = []
        let withoutExtras = configuration.withoutAdditionalDevices()
        let extraUIDs = configuration.additionalDeviceUIDs
        if let withoutExtras { ladder.append((withoutExtras, extraUIDs)) }
        if let monitor = configuration.monitorDeviceUID {
            if let withoutMonitor = configuration.withoutMonitor() {
                ladder.append((withoutMonitor, [monitor]))
                if let both = withoutExtras?.withoutMonitor() {
                    ladder.append((both, extraUIDs + [monitor]))
                }
            }
        }

        let reason = String(describing: failure)
        for rung in ladder {
            guard isWithinRetryBudget() else { break }
            do {
                try startAttempt(
                    rung.configuration, audioIncidentReservation: audioIncidentReservation)
            } catch let routingFailure as RoutingError {
                if case .teardownIncomplete = routingFailure { throw routingFailure }
                continue
            } catch {
                continue
            }
            for uid in rung.drops {
                let dropped = DroppedMonitor(uid: uid, reason: reason)
                if uid == configuration.monitorDeviceUID {
                    storedDroppedMonitor = dropped
                } else {
                    storedDroppedExtras.append(dropped)
                }
            }
            return
        }
        // Nothing additional was what was wrong. The first failure is the one
        // that describes the route the caller actually asked for, so that is
        // the one they are told about; the retries were this layer's own idea.
        let previousTeardown = stopLocked()
        guard previousTeardown.isComplete else {
            throw RoutingError.teardownIncomplete(previousTeardown)
        }
        throw failure
    }

    /// The whole of a start, from one snapshot.
    ///
    /// Taking the configuration as a value rather than as fourteen parameters is
    /// the point: the clock-lock recovery replays exactly what the caller gave,
    /// and a field it forgets is one it cannot forget silently — there is only
    /// one of it.
    private func startAttempt(
        _ configuration: StartConfiguration,
        audioIncidentReservation: AudioIncidentReservation?
    ) throws {
        let sourceDeviceUID = configuration.sourceDeviceUID
        let destinationDeviceUID = configuration.destinationDeviceUID
        let routes = configuration.routes
        let taps = configuration.taps
        let additionalSourceUIDs = configuration.additionalSourceUIDs
        let additionalDestinationUIDs = configuration.additionalDestinationUIDs
        let monitorDeviceUID = configuration.monitorDeviceUID
        let effects = configuration.effects
        let plugins = configuration.plugins
        let preferredSampleRate = configuration.preferredSampleRate
        let bufferFrames = configuration.bufferFrames
        let voiceIsolation = configuration.voiceIsolation
        let echoCancellation = configuration.echoCancellation
        let outputLatencyTrim = configuration.outputLatencyTrim
        let analysisEnabled = configuration.analysisEnabled
        let selftest = configuration.selftest

        func requireAudioUnitGraphAdmission() throws {
            guard BoundedAudioUnitConstructionLane.shared.admitsConstruction,
                BoundedAudioUnitDisposer.shared.admitsNewGraph
            else {
                throw RoutingError.audioResiduePresent(
                    ProcessLifetimeAudioQuarantine.shared.telemetry)
            }
        }

        guard let incidentBufferFrames = Int(exactly: bufferFrames) else {
            throw RoutingError.realtimeStorageUnavailable
        }
        let incident: AudioIncidentRecorder
        if let reservation = audioIncidentReservation,
            reservationMatchesLocked(reservation),
            let reserved = incidentRecorder
        {
            // The caller already proved this exact run identity durable before
            // its first process tap. The first attempt consumes it without a
            // Stop. Later internal attempts fence and clear only the prior graph,
            // preserving both this recorder and its taps until the transaction's
            // terminal Stop can describe their real outcome.
            let phase = activeAudioIncidentReservation?.phase
            guard let phase,
                Self.reservationPhasePermitsStart(
                    phase,
                    processTapOwnershipExpected: reservation.processTapOwnershipExpected)
            else {
                throw RoutingError.invalidStartConfiguration(
                    "the audio incident reservation has not crossed its ownership boundary")
            }
            if phase == .consumed {
                let previousTeardown = stopLocked(
                    preservingTaps: configuration.taps,
                    finalizesIncident: false)
                guard previousTeardown.isComplete else {
                    throw RoutingError.teardownIncomplete(previousTeardown)
                }
            }
            activeAudioIncidentReservation?.phase = .consumed
            incident = reserved
            incident.recordResources(
                AudioIncidentRecorder.Resources(
                    hadEchoCancellation: false,
                    hadAudioUnits: false,
                    hadAggregate: false,
                    hadProcessTaps: !taps.isEmpty,
                    changedSampleRates: false))
            checkpointConstructionIncidentLocked(incident)
        } else {
            let previousTeardown = stopLocked(preservingTaps: configuration.taps)
            guard previousTeardown.isComplete else {
                throw RoutingError.teardownIncomplete(previousTeardown)
            }
            let incidentResidueBaseline =
                ProcessLifetimeAudioQuarantine.shared.telemetry
            guard
                let fresh = AudioIncidentRecorder(
                    sampleRate: preferredSampleRate ?? 48_000,
                    bufferFrames: incidentBufferFrames,
                    driverDeviceID: nil,
                    driverWasRequired: false,
                    driverHealthBaseline: AudioIncidentDriverHealth(
                        state: .driverAbsent, wasRequired: false, readStatus: noErr,
                        unsafeReadOperations: 0, unsafeWriteOperations: 0),
                    residueBaseline: incidentResidueBaseline,
                    resources: AudioIncidentRecorder.Resources(
                        hadEchoCancellation: false,
                        hadAudioUnits: false,
                        hadAggregate: false,
                        hadProcessTaps: !taps.isEmpty,
                        changedSampleRates: false))
            else { throw RoutingError.realtimeStorageUnavailable }
            incident = fresh
            // Publish before the first device query. A server call can block before
            // this attempt owns an aggregate or has produced one callback; the sink
            // must still be able to distinguish this run from yesterday's file.
            incidentRecorder = incident
            checkpointConstructionIncidentLocked(incident)
        }

        guard let source = try AudioDevices.device(uid: sourceDeviceUID) else {
            throw RoutingError.deviceNotFound(sourceDeviceUID)
        }
        guard let destination = try AudioDevices.device(uid: destinationDeviceUID) else {
            throw RoutingError.deviceNotFound(destinationDeviceUID)
        }
        // Driver health is process-global evidence even when this route uses a
        // different destination. Resolve its numeric object once at admission;
        // a post-teardown census must not rediscover devices while Core Audio is
        // already returning from a fault.
        let incidentDriverDeviceID =
            destinationDeviceUID == ClockAnchorPublisher.driverDeviceUID
            ? destination.id
            : (try? AudioDevices.device(uid: ClockAnchorPublisher.driverDeviceUID))?.id
        let incidentDriverWasRequired =
            destinationDeviceUID == ClockAnchorPublisher.driverDeviceUID
        let incidentDriverHealthBaseline = BoundedAudioIncidentDriverHealthLane.shared.read(
            deviceID: incidentDriverDeviceID,
            wasRequired: incidentDriverWasRequired,
            timeout: 0.25)
        guard incidentDriverHealthBaseline.state != .readFailed else {
            // Do not follow an already blocked or failing server query with
            // sample-rate changes, aggregate creation and Audio Unit calls.
            // The sole health lane remains occupied until its original call
            // returns, making retry refusal bounded as well.
            throw RoutingError.audioServerHealthUnavailable
        }
        incident.configureDriverHealth(
            deviceID: incidentDriverDeviceID,
            wasRequired: incidentDriverWasRequired,
            baseline: incidentDriverHealthBaseline)
        checkpointConstructionIncidentLocked(incident)

        // Align rates before assembling: a mismatch inside the aggregate forces
        // conversion on paths that would otherwise be clean.
        //
        // The caller's preferred rate wins when both devices support it. Falling
        // back to the highest common rate would quietly put a voice chat at
        // 96 kHz, which only buys a resample back to 48 kHz at the far end.
        // Extra destinations let a tapped application be sent somewhere other
        // than the microphone's destination — one app to the headphones while
        // the rest of the mix goes to the virtual device. Extra sources are the
        // same idea on the other side: a second microphone, or a line input,
        // whose channels appear in the aggregate and are addressable exactly
        // like the first one's.
        //
        // Both kinds go in the same list because from the aggregate's point of
        // view they are the same thing — a member that is not the clock master
        // — and the distinction that matters is drawn by the routes, not here.
        // Deduplicated, because the same device can honestly be both: a
        // headset's two halves share nothing but a name, but an interface with
        // inputs and outputs is one device and must be added once.
        let extras =
            (additionalSourceUIDs + additionalDestinationUIDs
            + (monitorDeviceUID.map { [$0] } ?? []))
            .filter { $0 != sourceDeviceUID && $0 != destinationDeviceUID }
            .reduce(into: [String]()) { seen, uid in
                if !seen.contains(uid) { seen.append(uid) }
            }
            .compactMap { try? AudioDevices.device(uid: $0) }
        // Every device involved is aligned, including the microphone even when
        // it is about to belong to the canceller rather than to this aggregate:
        // a rate mismatch there would be resampled somewhere regardless.
        let alignedDevices = [source, destination] + extras
        guard
            let ratePlan = Self.sampleRatePlan(
                sourceRates: source.availableSampleRates,
                destinationRates: destination.availableSampleRates,
                preferredRate: preferredSampleRate,
                sourceCurrentRate: source.nominalSampleRate)
        else {
            throw RoutingError.noCommonSampleRate
        }
        let targetRate = ratePlan.targetRate
        sampleRateMismatch = ratePlan.hasMismatch
        guard
            incident.configureCallbackTiming(
                sampleRate: targetRate, bufferFrames: incidentBufferFrames)
        else { throw RoutingError.realtimeStorageUnavailable }
        checkpointConstructionIncidentLocked(incident)
        // Remembered so the devices go back the way they were found. Merged
        // rather than replaced: a restart must not forget what the first start
        // changed.
        // Only devices that can actually present it. Asking a 44.1 kHz headset
        // for 48 throws, and the throw would be the whole route rather than the
        // one device that could not oblige.
        let membersAtTargetRate = alignedDevices.filter {
            $0.availableSampleRates.contains(targetRate)
        }
        alignedMemberIDs = membersAtTargetRate.map(\.id)
        routeMemberIDs = alignedDevices.map(\.id)
        _ = try timed("align sample rates") {
            try AggregateDevice.alignSampleRate(
                targetRate,
                across: membersAtTargetRate,
                recordOriginal: { uid, previous in
                    if self.originalSampleRates[uid] == nil {
                        self.originalSampleRates[uid] = previous
                    }
                    incident.recordResources(
                        AudioIncidentRecorder.Resources(
                            hadEchoCancellation: false,
                            hadAudioUnits: false,
                            hadAggregate: false,
                            hadProcessTaps: false,
                            changedSampleRates: true))
                    self.checkpointConstructionIncidentLocked(incident)
                })
        }

        // If the destination is our own driver and it implements clock anchors,
        // it will track the microphone's measured rate itself, so asking the
        // HAL to drift-correct it as well would resample a signal that does not
        // need it. Any other destination keeps drift correction on.
        //
        // Turning it off up front rather than after the lock converges is safe:
        // convergence takes about a second and a half, and a crystal tens of
        // parts per million out accumulates only microseconds in that window.
        let clockLockAvailable =
            !clockLockAbandoned
            && echoCancellation == nil
            && destinationDeviceUID == ClockAnchorPublisher.driverDeviceUID
            && (ClockAnchorPublisher(driverDeviceUID: destinationDeviceUID)?
                .driverSupportsClockLocking ?? false)
        requiresClockLock = clockLockAvailable
        lastConfiguration = configuration
        transferTapsToActiveRouteLocked(configuration.taps)

        // Echo cancellation takes the microphone away from this aggregate:
        // AUVoiceProcessingIO can only cancel a speaker it is itself driving, so
        // it needs the microphone and the speaker bound together in an aggregate
        // of its own. What arrives here instead is the cancelled signal, across
        // a ring, and the clock master becomes the destination.
        //
        // Everything that costs is given up honestly rather than quietly: no
        // clock lock, no bit-exactness, a buffer of latency each way. None of
        // that is a regression, because a cancelled signal is arithmetic on the
        // microphone by definition.
        var bridge: EchoCancellationBridge?
        if let settings = echoCancellation {
            // Cleared first. This is set on every refusal and was never put
            // back, so a route that succeeded after one failure kept showing
            // the reason for the failure — which is the same defect as saying
            // nothing, one step further on.
            lastEchoCancellationError = nil
            lastEchoCancellationDetail = nil
            guard let echoSliceFrames = Int(exactly: bufferFrames) else {
                throw RoutingError.realtimeStorageUnavailable
            }
            let incidentSink = onAudioIncidentBundle
            let construction:
                AudioUnitLaneResult<Result<EchoCancellationBridge, EchoCancellationSetupError>>
            if let graphAdmission = BoundedAudioUnitDisposer.shared
                .acquireGraphAdmissionAfterDraining(waitingUpTo: 2.25)
            {
                // Its own lane, so a wedge here costs the echo canceller and
                // not every route this process will ever build. See
                // `BoundedAudioUnitConstructionLane.echoCancellation`.
                construction = BoundedAudioUnitConstructionLane.echoCancellation.perform(
                    timeout: AudioUnitConstructionBudget.echoCancellation,
                    observing: { resource in
                        incident.recordConstructionResource(resource)
                        guard
                            let bundle = incident.makeConstructionBundle(
                                residue: ProcessLifetimeAudioQuarantine.shared.telemetry)
                        else { return }
                        incidentSink?(bundle)
                    }
                ) {
                    context -> Result<EchoCancellationBridge, EchoCancellationSetupError> in
                    do throws(EchoCancellationSetupError) {
                        return .success(
                            try EchoCancellationBridge(
                                microphoneUID: sourceDeviceUID, settings: settings,
                                routerSampleRate: targetRate,
                                maximumFrames: echoSliceFrames,
                                constructionContext: context,
                                graphAdmission: graphAdmission))
                    } catch {
                        return .failure(error)
                    }
                }
            } else {
                construction = .refused
            }
            switch construction {
            case .completed(.success(let built)):
                bridge = built
                incident.recordResources(
                    AudioIncidentRecorder.Resources(
                        hadEchoCancellation: true,
                        hadAudioUnits: false,
                        hadAggregate: false,
                        hadProcessTaps: false,
                        changedSampleRates: false))
                checkpointConstructionIncidentLocked(incident)
            case .completed(.failure(let error)):
                lastEchoCancellationError = error.reason
                lastEchoCancellationDetail = error.detail
            case .timedOut, .refused, .superseded:
                let error = EchoCancellationSetupError.audioOwnershipQuarantined
                lastEchoCancellationError = error.reason
                lastEchoCancellationDetail = error.detail
            }
            // A failed `AudioComponentInstanceNew` is allowed to leave a
            // non-null out instance. Its bounded cleanup must finish before
            // this fallback route creates any other Core Audio owner.
            //
            // The echo canceller's own lane is deliberately *not* consulted
            // here. That is the point of it: a construction wedged inside the
            // voice-processing unit quarantines that lane for the life of the
            // process, and treating it as a reason to refuse the route would
            // put the failure straight back where it was — a dead application
            // instead of a lost feature. What the route still will not proceed
            // past is the shared lane and the disposer, which are the two that
            // speak for the graph it is about to build.
            if !BoundedAudioUnitConstructionLane.shared.admitsConstruction
                || !BoundedAudioUnitDisposer.shared.admitsNewGraph
            {
                let drainedAdmission = BoundedAudioUnitDisposer.shared
                    .acquireGraphAdmissionAfterDraining(waitingUpTo: 2.25)
                drainedAdmission?.release()
                try requireAudioUnitGraphAdmission()
            }
        }
        let cancelsEcho = bridge != nil
        if cancelsEcho { requiresClockLock = false }

        let members = cancelsEcho ? [destination] + extras : [source, destination] + extras

        // Every member that is not the clock master, drift corrected against
        // the one that is. That covers both kinds of extra: an output the mix
        // is copied to, and a second input whose channels are read.
        //
        // A member the router only ever writes to would ideally not have its
        // input side opened at all — on Bluetooth that is a correctness matter
        // rather than a saving, because opening a headset's input negotiates
        // HFP and drags the *output* down to 16 kHz with it.
        //
        // `kAudioSubDeviceInputChannelsKey` looks like the way to say so and is
        // not: measured here, a device with three inputs asked for one still
        // presents three, and one asked for none still presents one. The key is
        // descriptive. The flow check asserts that, so a future macOS honouring
        // it will be noticed rather than never looked at again — and until then
        // the Bluetooth problem has no fix at this layer.
        //
        // That the key is descriptive is what makes extra *inputs* work at all:
        // their channels arrive in the aggregate's input map whether or not
        // anybody asked for them, so routing from them needs nothing here.
        func follower(_ device: AudioDevice) -> AggregateDevice.SubDevice {
            AggregateDevice.SubDevice(
                uid: device.uid, driftCompensation: true,
                extraOutputLatencyFrames: outputLatencyTrim[device.uid])
        }

        let routedSubDevices: [AggregateDevice.SubDevice] =
            cancelsEcho
            ? [follower(destination)] + extras.map(follower)
            : [
                .init(uid: sourceDeviceUID, driftCompensation: false),
                .init(
                    uid: destinationDeviceUID,
                    driftCompensation: !clockLockAvailable,
                    extraOutputLatencyFrames: outputLatencyTrim[destinationDeviceUID]),
            ] + extras.map(follower)

        // The microphone is the clock master; the virtual device follows it.
        // Doing it the other way round would resample the signal we are trying
        // to carry intact.
        let aggregate = try timed("create the aggregate") {
            try AggregateDevice(
                name: "YunAudio Route",
                subDevices: routedSubDevices,
                clockMasterUID: cancelsEcho ? destinationDeviceUID : sourceDeviceUID,
                taps: taps)
        }
        self.aggregate = aggregate
        destinationDevice = destination
        incident.recordResources(
            AudioIncidentRecorder.Resources(
                hadEchoCancellation: false,
                hadAudioUnits: false,
                hadAggregate: true,
                hadProcessTaps: false,
                changedSampleRates: false))
        checkpointConstructionIncidentLocked(incident)

        try? aggregate.setBufferFrameSize(bufferFrames)

        try buildChannelMaps(aggregate: aggregate, members: members, taps: taps)

        // Requests above are asynchronous and can also be refused. Every
        // frequency, time constant and processing buffer below follows what the
        // aggregate says it settled on, never what was asked for.
        guard
            let aggregateDevice = aggregate.device,
            let timing = Self.graphTiming(
                actualSampleRate: aggregateDevice.currentSampleRate,
                actualBufferFrames: aggregateDevice.currentBufferFrameSize)
        else {
            throw RoutingError.aggregateUnavailable
        }
        let rate = timing.sampleRate
        let cycleFrames = timing.cycleFrames
        let maximumFrames = timing.processingCapacity
        guard
            incident.configureCallbackTiming(
                sampleRate: rate, bufferFrames: cycleFrames)
        else { throw RoutingError.realtimeStorageUnavailable }
        guard let maximumFrames32 = Int32(exactly: maximumFrames) else {
            throw RoutingError.realtimeStorageUnavailable
        }
        graphSampleRate = rate
        graphBufferFrames = cycleFrames
        graphMaximumFrames = maximumFrames
        if abs(rate - targetRate) >= 0.5 { sampleRateMismatch = true }
        if let bridge,
            !EchoCancellationRateContract.ratesMatch(bridge.sampleRate, rate)
        {
            // Not the same fact as "it could not be built": it was built, and
            // then the aggregate settled on a rate other than the one asked
            // for. Saying so is the difference between "try another speaker"
            // and "something upstream changed the clock".
            lastEchoCancellationError = EchoFailure.clockDiffersFromRouter
            lastEchoCancellationDetail =
                "canceller \(Int(bridge.sampleRate)) Hz, aggregate \(Int(rate)) Hz"
            throw RoutingError.echoCancellerFailed
        }

        // Isolation is a mono stage fed from one source channel, so it is set
        // up before the routes are resolved: a route that reads the model's
        // output has a different stride and channel index from one that reads
        // the raw device buffer.
        // A chain is built for anything except the one case the dedicated
        // isolation unit exists for.
        //
        // The condition was `effects.count > 1`, which meant exactly one
        // enabled stage built no chain at all: switching on only the gate, or
        // only the compressor, or only the limiter did nothing whatsoever and
        // said nothing about it. Two stages worked, one did not. It went
        // unnoticed because every check that touched processing switched on
        // more than one thing at a time.
        //
        // The dedicated unit still handles isolation alone, because it carries
        // the mix and quality settings the chain has no way to express — and
        // only when nothing else is in the path, plugins included. A third-party
        // unit dropped onto an empty chain used to be the same defect one level
        // out: the plugin loaded, the interface listed it, and no chain was
        // built to run it in.
        // The limiter is an output stage. Building it in this mono source chain
        // limited only the first source before applications were summed, then
        // allowed the master, another source and output correction to clip
        // afterwards. Its UI state is preserved, but the stage itself is built
        // once on the complete output below.
        let sourceEffects = effects.filter { $0 != .limiter }
        let isolationOnly = sourceEffects == [.voiceIsolation] && plugins.isEmpty
        var isolatedSource: ChannelRef?
        var audioUnitPublicationAdmission: AudioUnitGraphAdmissionBox?
        defer { audioUnitPublicationAdmission?.release() }
        if !sourceEffects.isEmpty || !plugins.isEmpty, !isolationOnly,
            let first = routes.first
        {
            try requireAudioUnitGraphAdmission()
            guard let admission = AudioUnitGraphAdmissionBox(waitingUpTo: 2) else {
                throw RoutingError.audioResiduePresent(
                    ProcessLifetimeAudioQuarantine.shared.telemetry)
            }
            audioUnitPublicationAdmission = admission
            isolatedSource = first.source
            let buildResult = timed("build the effect chain") {
                BoundedAudioUnitConstructionLane.shared.perform { context in
                    guard context.mayBeginOperation else { return nil as EffectChain? }
                    return EffectChain(
                        kinds: sourceEffects, plugins: plugins, sampleRate: rate,
                        maximumFrames: maximumFrames,
                        teardownDeadline: context.deadline,
                        constructionContext: context,
                        suppliedGraphAdmission: admission)
                }
            }
            let built: EffectChain?
            if case .completed(let chain) = buildResult {
                built = chain
            } else {
                built = nil
            }
            if let chain = built {
                effectChain = chain
                // Named rather than silently dropped: a chain that quietly
                // lost a stage sounds different and says nothing about why.
                storedFailedPlugins = chain.pluginFailures
                storedVoiceIsolationLatencyFrames =
                    sourceEffects.contains(.voiceIsolation) ? chain.latencyFrames : 0
            } else {
                if !BoundedAudioUnitConstructionLane.shared.admitsConstruction
                    || !BoundedAudioUnitDisposer.shared.admitsNewGraph
                {
                    try requireAudioUnitGraphAdmission()
                }
                isolatedSource = nil
                storedIsolationError = IsolationFailure.chainNotBuilt
            }
        } else if let settings = voiceIsolation, let first = routes.first {
            try requireAudioUnitGraphAdmission()
            guard let admission = AudioUnitGraphAdmissionBox(waitingUpTo: 2) else {
                throw RoutingError.audioResiduePresent(
                    ProcessLifetimeAudioQuarantine.shared.telemetry)
            }
            audioUnitPublicationAdmission = admission
            isolatedSource = first.source
            let buildResult = timed("build voice isolation") {
                BoundedAudioUnitConstructionLane.shared.perform { context in
                    guard context.mayBeginOperation else {
                        return nil as VoiceIsolationUnit?
                    }
                    let unit = VoiceIsolationUnit(
                        sampleRate: rate, maximumFrames: maximumFrames,
                        teardownDeadline: context.deadline,
                        constructionContext: context,
                        suppliedGraphAdmission: admission)
                    guard let unit, context.mayBeginOperation,
                        unit.setMix(settings.mixPercent) == noErr,
                        context.mayBeginOperation,
                        unit.setHighQuality(settings.isHighQuality) == noErr,
                        context.mayBeginOperation
                    else { return nil }
                    return unit
                }
            }
            let unit: VoiceIsolationUnit?
            if case .completed(let built) = buildResult {
                unit = built
            } else {
                unit = nil
            }
            if let unit {
                isolationUnit = unit
                storedVoiceIsolationLatencyFrames = unit.latencyFrames
            } else {
                if !BoundedAudioUnitConstructionLane.shared.admitsConstruction
                    || !BoundedAudioUnitDisposer.shared.admitsNewGraph
                {
                    try requireAudioUnitGraphAdmission()
                }
                // Not fatal: the route still carries audio, just unprocessed.
                isolatedSource = nil
                storedIsolationError = IsolationFailure.unitNotInstantiated
            }
        }
        if (effectChain?.audioUnitCount ?? isolationUnit?.audioUnitCount ?? 0) > 0 {
            incident.recordResources(
                AudioIncidentRecorder.Resources(
                    hadEchoCancellation: false,
                    hadAudioUnits: true,
                    hadAggregate: false,
                    hadProcessTaps: false,
                    changedSampleRates: false))
        }
        storedSourceProcessingLatencyFrames = ProcessingLatency.sourceStageFrames(
            chainFrames: effectChain?.latencyFrames,
            isolationFrames: isolationUnit?.latencyFrames)
        let maximumSourceLatency = Self.maximumSourceProcessingLatencyFrames(
            sampleRate: rate)
        guard
            Self.supportsSourceProcessingLatency(
                storedSourceProcessingLatencyFrames, sampleRate: rate)
        else {
            storedIsolationError = IsolationFailure.latencyExceedsRealtimeLimit
            throw RoutingError.sourceProcessingLatencyExceedsLimit(
                requested: storedSourceProcessingLatencyFrames,
                maximum: maximumSourceLatency)
        }
        guard
            let outputLimiter = OutputLimiterBank(
                channelCounts: outputChannelCounts, sampleRate: rate)
        else {
            throw RoutingError.outputLimiterUnavailable
        }
        outputLimiterBank = outputLimiter
        storedOutputProcessingLatencyFrames = ProcessingLatency.outputStageFrames(
            limiterFrames: outputLimiter.latencyFrames)

        let processingPlan = RouteProcessingPlan(
            microphoneDeviceUID: sourceDeviceUID,
            processedSource: isolatedSource,
            echoCancellationActive: cancelsEcho)
        let rtRoutes = try routes.map { route -> RTRoute in
            // With the canceller in front, the microphone's channels are not in
            // this aggregate at all, so they have no entry in the input map and
            // must not be looked for in it.
            let fromMicrophone = cancelsEcho && route.source.deviceUID == sourceDeviceUID
            // An isolated route reads the model's output whether or not the
            // canceller fed it, so the two flags are exclusive: the cancelled
            // buffer is what the model consumed, not what this route wants.
            let provenance = processingPlan.provenance(for: route.source)

            var sourcePoint: (buffer: Int32, channel: Int32) = (0, 0)
            if !fromMicrophone {
                guard let point = inputMap[route.source] else {
                    throw RoutingError.channelNotFound(route.source, isInput: true)
                }
                sourcePoint = point
            }
            guard let destinationPoint = outputMap[route.destination] else {
                throw RoutingError.channelNotFound(route.destination, isInput: false)
            }
            return RTRoute(
                sourceBuffer: sourcePoint.buffer,
                sourceChannel: sourcePoint.channel,
                destinationBuffer: destinationPoint.buffer,
                destinationChannel: destinationPoint.channel,
                gain: route.gain,
                muted: route.isMuted,
                usesIsolatedSource: provenance.usesIsolatedSource,
                usesCancelledSource: provenance.usesCancelledSource,
                appliesInputTrim: provenance.appliesInputTrim,
                isDuckable: route.isDuckable)
        }

        let clock = RTGraph.SharedClock.allocate()
        sharedClock = clock
        let analysisRing = RTGraph.SharedAnalysisRing.allocate()
        sharedAnalysisRing = analysisRing
        let routeKeys = Route.occurrenceKeys(in: routes)
        let routeHistories = routeKeys.map { _ in
            RTGraph.SharedAlignmentHistory.allocate()
        }
        alignmentHistories = Dictionary(
            uniqueKeysWithValues: zip(routeKeys, routeHistories))
        guard
            let graph = RTGraph.allocateIfSupported(
                routes: rtRoutes, bufferFrames: cycleFrames, sampleRate: rate,
                sharedClock: clock, sharedAnalysisRing: analysisRing,
                sharedAlignmentHistories: routeHistories)
        else { throw RoutingError.realtimeStorageUnavailable }
        Self.initialisePersistedMixState(
            inputGain: inputGain, inputMuted: isInputMuted,
            outputGain: outputGain, outputMuted: isOutputMuted,
            on: graph)
        graph.pointee.incidentTelemetry = incident.callbackTelemetry
        graph.pointee.incidentDeadlineNanoseconds = incident.callbackDeadlineNanoseconds
        self.graph = graph
        routeProcessingPlan = processingPlan
        installActiveRoutes(routes)
        analysisIsEnabled = analysisEnabled
        outputLimiterIsEnabled = effects.contains(.limiter)
        graph.pointee.analysisEnabled = analysisIsEnabled ? 1 : 0
        graph.pointee.duckEnabled = duckingEnabled ? 1 : 0
        graph.pointee.duckDepth = duckingDepth
        graph.pointee.duckAllowed = duckingAllowed ? 1 : 0
        graph.pointee.calibrationEpoch = calibrationEpoch
        graph.pointee.outputClippingEpoch = outputClippingEpoch
        graph.pointee.outputLimiter = Unmanaged.passUnretained(outputLimiter).toOpaque()
        graph.pointee.outputLimiterEnabled = outputLimiterIsEnabled ? 1 : 0
        graph.pointee.outputLimiterPreGain = outputLimiterPreGain

        // When the canceller owns the microphone the reference has no entry in
        // the input map, so an absent point is expected rather than fatal.
        let isolationFromCancelled =
            cancelsEcho && isolatedSource?.deviceUID == sourceDeviceUID
        let isolationPoint =
            isolatedSource.flatMap { inputMap[$0] } ?? (buffer: Int32(0), channel: Int32(0))

        if let chain = effectChain, isolatedSource != nil,
            isolationFromCancelled || isolatedSource.flatMap({ inputMap[$0] }) != nil
        {
            let point = isolationPoint
            guard let failures = yun_rt_counter_create(0) else {
                throw RoutingError.realtimeStorageUnavailable
            }
            isolationFailureCounter = failures

            let block = UnsafeMutablePointer<RTVoiceIsolation>.allocate(capacity: 1)
            block.initialize(
                to: RTVoiceIsolation(
                    enabled: 1,
                    sourceBuffer: point.buffer,
                    sourceChannel: point.channel,
                    sourceIsCancelled: isolationFromCancelled ? 1 : 0,
                    unit: Unmanaged.passUnretained(chain).toOpaque(),
                    inputBuffer: chain.inputBuffer,
                    outputBuffer: chain.outputBuffer,
                    maximumFrames: maximumFrames32,
                    renderFailures: failures))
            isolationBlock = block
            graph.pointee.voiceIsolation = block
            graph.pointee.isolationIsChain = 1
        } else if let unit = isolationUnit, isolatedSource != nil,
            isolationFromCancelled || isolatedSource.flatMap({ inputMap[$0] }) != nil
        {
            let point = isolationPoint
            guard let failures = yun_rt_counter_create(0) else {
                throw RoutingError.realtimeStorageUnavailable
            }
            isolationFailureCounter = failures

            let block = UnsafeMutablePointer<RTVoiceIsolation>.allocate(capacity: 1)
            block.initialize(
                to: RTVoiceIsolation(
                    enabled: 1,
                    sourceBuffer: point.buffer,
                    sourceChannel: point.channel,
                    sourceIsCancelled: isolationFromCancelled ? 1 : 0,
                    unit: Unmanaged.passUnretained(unit).toOpaque(),
                    inputBuffer: unit.inputBuffer,
                    outputBuffer: unit.outputBuffer,
                    maximumFrames: maximumFrames32,
                    renderFailures: failures))
            isolationBlock = block
            graph.pointee.voiceIsolation = block
        }

        // Which buffer the recorder, the loudness meter and the spectrum read.
        // Not assumed to be zero: the aggregate lists its sub-devices in its own
        // order, so with a monitor attached buffer zero may well be the
        // headphones, and every one of those three would then be measuring or
        // recording the wrong device.
        // Everything that skipped the chain is held back by what the chain
        // costs, so the microphone and the tapped applications land on the same
        // frame. Set here rather than where the latency is first read, because
        // the graph does not exist until the routes are known.
        graph.pointee.alignmentFrames = Int32(
            min(storedSourceProcessingLatencyFrames, RTGraph.maximumAlignmentFrames))

        mainOutputBuffer =
            outputMap[ChannelRef(deviceUID: destinationDeviceUID, channel: 0)]?.buffer ?? 0
        masterExemptBuffer =
            monitorDeviceUID
            .flatMap { outputMap[ChannelRef(deviceUID: $0, channel: 0)]?.buffer } ?? -1
        graph.pointee.mainOutputBuffer = mainOutputBuffer
        graph.pointee.masterExemptBuffer = masterExemptBuffer

        // The integrity check writes its sequence to the destination's first
        // output channel and reads the same channel back off its input. Both
        // ends live inside this one aggregate, so a returned sample really did
        // travel the whole path.
        if selftest {
            let outRef = ChannelRef(deviceUID: destinationDeviceUID, channel: 0)
            let inRef = ChannelRef(deviceUID: destinationDeviceUID, channel: 0)
            guard let outPoint = outputMap[outRef] else {
                throw RoutingError.channelNotFound(outRef, isInput: false)
            }
            guard let inPoint = inputMap[inRef] else {
                throw RoutingError.channelNotFound(inRef, isInput: true)
            }
            let owner = RTSelftestOwner.allocate(
                outBuffer: outPoint.buffer, outChannel: outPoint.channel,
                inBuffer: inPoint.buffer, inChannel: inPoint.channel,
                captureFrames: 262_144)
            let block = owner.block
            selftestOwner = owner
            selftestBlock = block
            graph.pointee.selftest = block
        }

        // The canceller has to be producing before the router starts reading,
        // or the first cycles find an empty ring. Started here rather than in
        // the constructor so a failure to build the graph does not leave a unit
        // running with nothing to consume it.
        if let bridge {
            guard bridge.start() else {
                if bridge.lastTeardownResult?.isComplete == false {
                    // A failed start can also fail to close. Retain the bridge
                    // so the ordinary route teardown can resume that exact
                    // lifecycle rather than letting deinit quarantine it.
                    echoBridge = bridge
                }
                lastEchoCancellationError = EchoFailure.wouldNotStart
                throw RoutingError.echoCancellerFailed
            }
            echoBridge = bridge
            graph.pointee.cancelledRing = bridge.ring
        }

        // The first Swift entry into the callback performs process-wide lazy
        // allocation. Pay it against a disposable graph before Core Audio owns
        // the deadline; the real graph's audible state remains untouched.
        guard RTGraph.prewarmRealtimeRuntime() == noErr else {
            throw RoutingError.realtimeStorageUnavailable
        }
        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        graphCell = cell
        retiredGenerations.attach(to: cell)

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            aggregate.id, yunAudioIOProc, UnsafeMutableRawPointer(cell), &procID)
        if let procID {
            ioProcID = procID
            ioProcTeardownState.didCreate()
        }
        guard createStatus == noErr, let procID else {
            throw RoutingError.ioProcFailed(
                createStatus == noErr ? kAudioHardwareUnspecifiedError : createStatus)
        }

        let startStatus = timed("AudioDeviceStart") { AudioDeviceStart(aggregate.id, procID) }
        guard startStatus == noErr else {
            throw RoutingError.startFailed(startStatus)
        }
        isRunning = true
        routeLifetimeGeneration &+= 1
        ioProcTeardownState.didStart()
        // A success status only means CoreAudio accepted the request. It does
        // not mean an IOProc ran. Two completed cycles are the first numeric
        // proof that both the callback and its retirement path are alive.
        guard yun_rt_cell_wait_for_swap(cell, 750) else {
            throw RoutingError.noIOCycles
        }
        recordEngineGraphPublicationLocked()

        // Armed only now: two completed cycles are the first proof the route
        // exists, and a watch armed earlier could rebuild one that never did.
        memberRateWatcher.watch(alignedMemberIDs, expecting: graphSampleRate)
        // The aggregate as well as its members. The aggregate is what our
        // IOProc is attached to, so it is the one that reports our own
        // overruns; a member reports the endpoint failing to keep up with a
        // schedule it agreed to.
        overloadWatcher.watch(routeMemberIDs + [aggregate.id])

        // When the destination is our own driver, hand it the master's clock so
        // it can lock to the microphone. Any other destination — BlackHole, a
        // physical device — has no such channel, and the path stays honestly
        // marked as resampled.
        if clockLockAvailable,
            let publisher = ClockAnchorPublisher(driverDeviceUID: destinationDeviceUID)
        {
            // Captures the graph pointer, not self: the closure runs on the
            // publisher's own queue, and stop() drains that queue before the
            // graph is freed, so the pointer stays valid for every call.
            let handle = GraphHandle(clock: clock)
            let anchorRate = rate

            // Drift correction is off because the driver promised to track the
            // microphone. If that promise stops being kept — the application
            // was starved and missed its anchor deadline — nothing is
            // correcting a crystal that is parts per million out, and the error
            // accumulates into dropouts. Rebuild the route with the HAL back in
            // charge rather than let it rot silently.
            publisher.onLockChanged = { [weak self] locked in
                guard !locked, let self else { return }
                self.recoveryQueue.async { self.recoverFromClockLockLoss() }
            }
            guard
                publisher.start(anchorSource: {
                    RoutingEngine.anchor(from: handle.clock, sampleRate: anchorRate)
                })
            else {
                publisher.onLockChanged = nil
                throw RoutingError.clockPublisherFailedToStart
            }
            clockPublisher = publisher
        }
        _ = makeAndPublishEngineUISnapshotLocked()
    }

    @discardableResult
    public func stop() -> RoutingTeardownResult {
        stop(timeout: 2)
    }

    /// Stops every HAL owner against one route-wide polling budget.
    ///
    /// A synchronous HAL call already in flight cannot be cancelled and may
    /// return after the deadline. The shared deadline prevents that overrun
    /// from starting another wait or census against each remaining object.
    @discardableResult
    public func stop(timeout: TimeInterval) -> RoutingTeardownResult {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopLocked(until: HALTeardownDeadline(timeout: timeout))
    }

    @discardableResult
    private func stopLocked(
        until deadline: HALTeardownDeadline = HALTeardownDeadline(timeout: 2),
        preservingTaps: [ProcessTap] = [],
        finalizesIncident: Bool = true
    ) -> RoutingTeardownResult {
        defer { _ = makeAndPublishEngineUISnapshotLocked() }
        let recorder = incidentRecorder
        let cell = graphCell
        let began = DispatchTime.now().uptimeNanoseconds
        let available = max(0, deadline.remainingTimeInterval) * 1_000_000_000
        let budget =
            available >= Double(UInt64.max)
            ? UInt64.max : max(1, UInt64(available.rounded(.down)))
        let result = performStopLocked(
            until: deadline,
            preservingTaps: preservingTaps,
            capturesIncidentFence: finalizesIncident)
        guard finalizesIncident else { return result }
        let driverHealth: AudioIncidentDriverHealth
        if result.isComplete {
            driverHealth = BoundedAudioIncidentDriverHealthLane.shared.read(
                deviceID: recorder?.driverDeviceID,
                wasRequired: recorder?.driverWasRequired ?? false,
                timeout: min(0.25, max(0, deadline.remainingTimeInterval)))
        } else {
            let required = recorder?.driverWasRequired ?? false
            driverHealth = AudioIncidentDriverHealth(
                state: required ? .readFailed : .driverAbsent,
                wasRequired: required,
                readStatus: required ? kAudioHardwareNotRunningError : noErr,
                unsafeReadOperations: 0,
                unsafeWriteOperations: 0)
        }
        let ended = DispatchTime.now().uptimeNanoseconds
        let elapsed = ended >= began ? ended - began : UInt64.max
        let residue = ProcessLifetimeAudioQuarantine.shared.telemetry
        if let bundle = recorder?.makeBundle(
            result: result,
            elapsedNanoseconds: elapsed,
            deadlineNanoseconds: budget,
            driverHealth: driverHealth,
            // A complete teardown has already snapshotted this value and freed
            // the cell. Any failed teardown still owns its cell and can provide
            // a live best-effort count here.
            callbackCellOverlaps:
                result.isComplete ? 0 : cell.map(yun_rt_cell_overlaps) ?? 0,
            residue: residue)
        {
            publishIncidentBundleLocked(bundle)
        }
        if result.isComplete {
            activeAudioIncidentReservation = nil
            incidentRecorder = nil
        }
        return result
    }

    @discardableResult
    private func performStopLocked(
        until deadline: HALTeardownDeadline = HALTeardownDeadline(timeout: 2),
        preservingTaps: [ProcessTap] = [],
        capturesIncidentFence: Bool = true
    ) -> RoutingTeardownResult {
        if case .audioUnitOwner(let previous) = storedTeardownResult {
            // A genuinely failed sole-disposer transaction deliberately has no
            // retry: another synchronous Core Audio call could add a second
            // hung worker. A transaction merely queued behind construction may
            // since have completed; only that fully clean state may resume the
            // remaining non-AU stop work.
            guard BoundedAudioUnitDisposer.shared.admitsNewGraph else {
                return .audioUnitOwner(previous)
            }
            storedTeardownResult = nil
        }
        if let aggregate, let ioProcID {
            let ioResult = ioProcTeardownState.tearDown(
                stop: {
                    deadline.perform {
                        self.timed("AudioDeviceStop") {
                            AudioDeviceStop(aggregate.id, ioProcID)
                        }
                    }
                },
                destroy: {
                    deadline.perform {
                        self.timed("AudioDeviceDestroyIOProcID") {
                            AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
                        }
                    }
                })
            isRunning = ioProcTeardownState.phase == .running
            switch ioResult {
            case .complete:
                self.ioProcID = nil
            case .stopFailed(let status):
                let result = RoutingTeardownResult.ioProcStopFailed(status)
                storedTeardownResult = result
                return result
            case .destroyFailed(let status):
                // Stop succeeded, so no route is using the clock now. Disable
                // recovery before returning: a lock-loss callback must not
                // rebuild on top of the IOProc whose destroy just failed.
                guard stopClockPublisherLocked(until: deadline).isComplete else {
                    let result = RoutingTeardownResult.clockPublisherTimedOut
                    storedTeardownResult = result
                    return result
                }
                let result = RoutingTeardownResult.ioProcDestroyFailed(status)
                storedTeardownResult = result
                return result
            case .timedOut(let step):
                // A successful Stop has already fenced callbacks when the
                // destroy boundary times out. Disable recovery in that state;
                // a timed-out Stop leaves the live route untouched for retry.
                if ioProcTeardownState.phase == .stopped {
                    guard stopClockPublisherLocked(until: deadline).isComplete else {
                        let result = RoutingTeardownResult.clockPublisherTimedOut
                        storedTeardownResult = result
                        return result
                    }
                }
                let result = RoutingTeardownResult.ioProcTimedOut(step: step)
                storedTeardownResult = result
                return result
            }
        } else if ioProcID != nil || ioProcTeardownState.phase != .absent {
            // There is no device against which a callback can be destroyed.
            // Keep every owner rather than manufacture a successful fence.
            let result = RoutingTeardownResult.ioProcDestroyFailed(
                kAudioHardwareBadObjectError)
            storedTeardownResult = result
            return result
        }
        // Destroy is the callback lifetime fence. Snapshot while the cell still
        // exists; later owners may fail independently without weakening this
        // evidence.
        if capturesIncidentFence {
            incidentRecorder?.captureCallbackFence(
                cellOverlaps: graphCell.map(yun_rt_cell_overlaps) ?? 0)
        }
        // A refused AudioDeviceStop returns above with the publisher and its
        // recovery intact because that IOProc is still running. Only a stopped
        // callback path reaches this boundary.
        guard stopClockPublisherLocked(until: deadline).isComplete else {
            let result = RoutingTeardownResult.clockPublisherTimedOut
            storedTeardownResult = result
            return result
        }
        isRunning = false
        routeLifetimeGeneration &+= 1
        // Before any of it. Teardown restores the members' original rates, so a
        // watch left armed would report our own restoration as drift and ask
        // for a rebuild of the route being torn down.
        memberRateWatcher.stop()
        alignedMemberIDs = []
        overloadWatcher.stop()
        routeMemberIDs = []

        // Before the graph is freed, since the graph holds this object's ring.
        // Stopping the unit first also puts the microphone and the speaker back
        // in the hands of whatever wants them next.
        if let echoBridge {
            let echoResult = echoBridge.stop(until: deadline)
            guard echoResult.isComplete else {
                echoTeardownDecidedBy = echoBridge.teardownDecidedBy
                let result = RoutingTeardownResult.echoCancellation(
                    echoResult, canRetry: !echoBridge.teardownVerdictIsTerminal)
                storedTeardownResult = result
                return result
            }
            self.echoBridge = nil
            lastEchoRenderDiagnostics = nil
        }

        if let aggregate {
            let aggregateResult = timed("destroy the aggregate") {
                aggregate.destroyAndWait(until: deadline)
            }
            guard aggregateResult == .destroyed else {
                let result = RoutingTeardownResult.aggregate(aggregateResult)
                storedTeardownResult = result
                return result
            }
        }

        // Aggregate removal and tap removal are separate HAL lifecycles. The
        // configuration and aggregate both retain these taps until every one
        // is absent, because a live muted tap with no consumer silences an
        // application while making no sound of its own.
        var seenTaps = Set<ObjectIdentifier>()
        let routeTaps =
            (aggregate?.taps ?? []) + (lastConfiguration?.taps ?? [])
            + pendingTeardownTaps
        let ownership = ProcessTapRetryOwnership(active: routeTaps)
        let transition = ownership.tearingDown(preserving: preservingTaps)
        let uniqueTaps = transition.destroy.filter {
            seenTaps.insert(ObjectIdentifier($0)).inserted
        }
        switch ProcessTap.destroyAllAndWait(uniqueTaps, until: deadline) {
        case .destroyed:
            pendingTeardownTaps.removeAll()
            pendingTeardownTaps.append(contentsOf: transition.next.pending)
        case .failed(let uid, let tapResult):
            let result = RoutingTeardownResult.processTap(uid: uid, result: tapResult)
            storedTeardownResult = result
            return result
        }

        // Destroying the IOProc is the only unconditional reclamation fence.
        // Any graph whose callback grace period timed out stays owned by the
        // retirement queue until either its original cycle fence passes or this
        // boundary makes every outstanding generation unreachable at once.
        retiredGenerations.detachAndReclaimAll()

        // Capture every still-current callback-transitive owner before any
        // property is cleared. The IOProc and all RCU generations are fenced at
        // this point, so this one capsule is the route's complete AU ownership
        // transaction rather than four unrelated destructors.
        var audioUnitOwners: [any AudioUnitTeardownOwner] = []
        if let transitionOldChain { audioUnitOwners.append(transitionOldChain) }
        if let transitionOldUnit { audioUnitOwners.append(transitionOldUnit) }
        if let effectChain { audioUnitOwners.append(effectChain) }
        if let isolationUnit { audioUnitOwners.append(isolationUnit) }
        let audioUnitOwnerCapsule = AudioUnitOwnerCapsule(audioUnitOwners)

        self.aggregate = nil
        destinationDevice = nil

        // Dropped with the route it describes, and specifically because it now
        // holds the process taps: a tap kept alive past the stop goes on muting
        // the application it captured, with nothing routing its audio anywhere.
        // Nothing needs it once the route is down — the recovery it exists for
        // only runs against a route that is up.
        lastConfiguration = nil

        // The recording branch needs its graph scratch and priming count to
        // flush the look-ahead tail. The IOProc is already destroyed, so it is
        // safe to detach and finish that branch before the graph goes away.
        _ = stopRecordingLocked()

        // Safe now: the IOProc has been destroyed, so nothing can be reading
        // the graph any more.
        if let graph { RTGraph.deallocate(graph) }
        graph = nil
        for history in alignmentHistories.values { history.deallocate() }
        alignmentHistories.removeAll()
        // After the graph, and after the publisher was stopped and drained
        // above — this is the storage it reads.
        sharedClock?.deallocate()
        sharedClock = nil
        sharedAnalysisRing?.deallocate()
        sharedAnalysisRing = nil
        if let graphCell { yun_rt_cell_free(graphCell) }
        graphCell = nil
        _ = stopStemRecordingLocked()
        _ = stopTranscriptTapsLocked()
        selftestBlock = nil
        selftestOwner = nil

        if let effectTransitionBlock {
            RTEffectTransition.deallocate(effectTransitionBlock)
        }
        effectTransitionBlock = nil
        effectTransitionController = nil
        if let transitionOldBlock {
            transitionOldBlock.deinitialize(count: 1)
            transitionOldBlock.deallocate()
        }
        transitionOldBlock = nil
        transitionOldChain = nil
        transitionOldUnit = nil

        // Order matters: the block is freed first so nothing can dereference
        // the unmanaged unit pointer afterwards, then the unit is released.
        if let isolationBlock {
            isolationBlock.deinitialize(count: 1)
            isolationBlock.deallocate()
        }
        isolationBlock = nil
        if let isolationFailureCounter {
            yun_rt_counter_free(isolationFailureCounter)
        }
        isolationFailureCounter = nil
        isolationUnit = nil
        effectChain = nil
        outputLimiterBank = nil
        recordingLimiter = nil
        outputLimiterIsEnabled = false
        analysisIsEnabled = false
        recordingIsPaused = false
        calibrationIsActive = false
        calibrationSnapshot.removeAll()
        publishedSnapshotLock.withLock {
            publishedCalibrationSnapshot.removeAll()
        }
        mainOutputBuffer = 0
        masterExemptBuffer = -1
        storedVoiceIsolationLatencyFrames = 0
        storedSourceProcessingLatencyFrames = 0
        storedOutputProcessingLatencyFrames = 0
        graphSampleRate = 48000
        graphBufferFrames = 128
        graphMaximumFrames = AudioProcessingContract.maximumFramesPerSlice

        inputMap.removeAll()
        outputMap.removeAll()
        outputChannelCounts.removeAll()
        routeProcessingPlan = nil
        installActiveRoutes([])

        let audioUnitResult = BoundedAudioUnitDisposer.shared.dispose(
            audioUnitOwnerCapsule, until: deadline)
        guard audioUnitResult.isComplete else {
            let result = RoutingTeardownResult.audioUnitOwner(audioUnitResult)
            storedTeardownResult = result
            return result
        }

        // Restore last: the aggregate has to be gone first, or the HAL will
        // simply set the rate back to whatever the aggregate wanted.
        if !originalSampleRates.isEmpty {
            let stubborn = timed("restore sample rates") {
                AggregateDevice.restoreSampleRates(
                    originalSampleRates, until: deadline)
            }.sorted()
            if !stubborn.isEmpty {
                originalSampleRates = originalSampleRates.filter {
                    stubborn.contains($0.key)
                }
                let result = RoutingTeardownResult.sampleRatesNotRestored(stubborn)
                storedTeardownResult = result
                return result
            }
            originalSampleRates.removeAll()
        }
        storedTeardownResult = .complete
        return .complete
    }

    private func stopClockPublisherLocked(
        until deadline: HALTeardownDeadline
    ) -> ClockAnchorPublisherTeardownResult {
        // An in-flight status turn may already have copied the callback before
        // it is cleared. Close recovery admission first so that late delivery
        // cannot rebuild a route whose IOProc has already stopped.
        requiresClockLock = false
        guard let clockPublisher else {
            publishedSnapshotLock.withLock {
                publishedClockTelemetry = .unlocked
            }
            return .complete
        }
        clockPublisher.onLockChanged = nil
        let result = clockPublisher.stop(until: deadline)
        guard result.isComplete else { return result }
        self.clockPublisher = nil
        publishedSnapshotLock.withLock {
            publishedClockTelemetry = .unlocked
        }
        return .complete
    }

    /// Brings the route back up with drift correction enabled after the clock
    /// lock dropped. Runs on `recoveryQueue`, never on the publisher's queue —
    /// stopping there cannot pass a fence queued behind its own current turn.
    private func recoverFromClockLockLoss() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard requiresClockLock, !clockLockAbandoned,
            var configuration = lastConfiguration
        else { return }
        // Per-route controls are deliberately not copied into the recovery
        // snapshot on every pointer event. Doing so made each slider tick copy
        // the whole route array. The current engine truth is already protected
        // by this lock, so attach it once at the recovery boundary instead.
        configuration.routes = activeRoutes
        clockLockAbandoned = true

        // The whole configuration, not the devices alone. This used to name four
        // fields, and the other ten went to their defaults — so a lock that gave
        // way an hour into a call brought the route back with no processing
        // chain, no monitor mix, no captured applications and whatever sample
        // rate the two devices happened to share. Nothing said so: the model
        // still held every one of those settings, so the interface was still
        // showing them, and only `activeEffectStages` disagreed.
        //
        // `clockLockAbandoned` is already set, so the rebuild computes
        // `clockLockAvailable` as false and the HAL takes drift correction back.
        // That is the point of the rebuild and the one thing that must differ.
        try? startLocked(
            configuration,
            audioIncidentReservation: activeAudioIncidentReservation?.token)
        onClockLockFailure?()
    }

    /// Carries out the clock-lock recovery as though the driver had just
    /// reported the lock gone, and says whether there was one to carry out.
    ///
    /// Reachable only so that the flow check can assert what the route comes
    /// back as. The recovery is otherwise driven by the driver missing an anchor
    /// deadline, which nothing on this side can arrange, and its one interesting
    /// property — that the route returns carrying everything it was carrying —
    /// is exactly the property that was wrong and invisible for as long as it
    /// could not be provoked.
    ///
    /// - Returns: False when this route was never locked to begin with, so a
    ///   caller can say "not exercised" rather than "passed".
    @discardableResult
    public func forceClockLockRecovery() -> Bool {
        guard holdsClockLock else { return false }
        recoverFromClockLockLoss()
        return true
    }

    /// Whether this route has taken the driver's clock, and so has a lock it
    /// could lose.
    ///
    /// Not `isClockLocked`, which says whether the anchor has converged yet: a
    /// route can require the lock and not have reached it, and the recovery is
    /// about the first of those rather than the second.
    public var holdsClockLock: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requiresClockLock && !clockLockAbandoned && lastConfiguration != nil
    }

    /// Applies a processing parameter to whatever is actually rendering.
    ///
    /// Two things can be: the chain, and — when isolation is the only stage
    /// switched on — the dedicated isolation unit, which is built instead of a
    /// chain because it carries the model choice the chain cannot express.
    /// Writing only to the chain therefore meant the mix slider moved and the
    /// sound did not, in the one configuration where isolation is the whole
    /// point. Everything else the chain offers has no unit to reach in that
    /// case and is correctly a no-op.
    public func setEffectParameter(_ parameter: String, of kind: EffectKind, to value: Float) {
        stateLock.lock()
        if kind == .limiter, parameter == "gain", value.isFinite {
            let linear = powf(10, max(-20, min(20, value)) / 20)
            if graph == nil
                || pushGlobal(
                    kind: kYunRTCommandSetLimiterPreGain, value: linear)
            {
                outputLimiterPreGain = linear
            }
            stateLock.unlock()
            return
        }
        if let chain = effectChain, let lease = chain.acquireControlLease() {
            stateLock.unlock()
            BoundedAudioUnitControlLane.shared.submit(
                key: "stage:\(kind.rawValue):\(parameter)", lease: lease
            ) { context in
                guard context.mayBeginOperation else { return }
                chain.set(parameter, of: kind, to: value)
            }
            return
        }
        if kind == .voiceIsolation, parameter == "mix", let unit = isolationUnit,
            let lease = unit.acquireControlLease()
        {
            stateLock.unlock()
            BoundedAudioUnitControlLane.shared.submit(
                key: "isolation:mix", lease: lease
            ) { context in
                guard context.mayBeginOperation else { return }
                unit.setMix(value)
            }
            return
        }
        stateLock.unlock()
    }

    /// What the running unit is actually holding for that knob.
    ///
    /// The one thing that can tell a chain which came back tuned from one which
    /// came back at its defaults: the model's own copy of the value survives
    /// either way.
    ///
    /// - Returns: Nil when no chain is running, the stage is not in it, or the
    ///   knob is one that does not map to a single unit parameter.
    public func effectParameter(_ parameter: String, of kind: EffectKind) -> Float? {
        stateLock.lock()
        if kind == .limiter, parameter == "gain" {
            let value =
                20
                * log10f(
                    max(outputLimiterPreGain, Float.leastNonzeroMagnitude))
            stateLock.unlock()
            return value
        }
        if let chain = effectChain, let lease = chain.acquireControlLease() {
            stateLock.unlock()
            let result: AudioUnitLaneResult<Float?> =
                BoundedAudioUnitControlLane.shared.perform(
                    key: "read:\(kind.rawValue):\(parameter)", lease: lease
                ) { context in
                    guard context.mayBeginOperation else { return nil }
                    return chain.value(parameter, of: kind)
                }
            if case .completed(let value) = result { return value }
            return nil
        }
        if kind == .voiceIsolation, parameter == "mix", let unit = isolationUnit,
            let lease = unit.acquireControlLease()
        {
            stateLock.unlock()
            let result: AudioUnitLaneResult<Float> =
                BoundedAudioUnitControlLane.shared.perform(
                    key: "read:isolation:mix", lease: lease
                ) { context in
                    guard context.mayBeginOperation else { return 0 as Float }
                    return unit.mix
                }
            if case .completed(let value) = result { return value }
            return nil
        }
        stateLock.unlock()
        return nil
    }

    // MARK: Recording

    private var recorder: Recorder?
    /// Covers file allocation while `stateLock` is intentionally released.
    private var recordingConstructionIsInFlight = false

    /// One non-blocking, lifetime-safe observation of the recording branch.
    ///
    /// A route stop can own `stateLock` for the complete CoreAudio deadline.
    /// Polling must not wait behind it, but it also must not read `recorder`
    /// while that Optional is being cleared. A successful try-lock retains and
    /// reads the owner coherently; contention returns the last whole snapshot.
    public var recordingSnapshot: RecordingSnapshot {
        guard stateLock.try() else {
            return publishedSnapshotLock.withLock { publishedRecordingSnapshot }
        }
        defer { stateLock.unlock() }
        let snapshot: RecordingSnapshot
        if let recorder {
            let progress = recorder.progressSnapshot
            snapshot = RecordingSnapshot(
                isRecording: true, url: recorder.url,
                duration: progress.duration, error: progress.error,
                producedSamples: recorder.producedSamples,
                droppedSamples: recorder.droppedSamples)
        } else {
            snapshot = .stopped
        }
        publishedSnapshotLock.withLock {
            publishedRecordingSnapshot = snapshot
        }
        return snapshot
    }

    /// True while audio is being written to disk.
    public var isRecording: Bool { recordingSnapshot.isRecording }
    public var recordingURL: URL? { recordingSnapshot.url }
    public var recordingDuration: TimeInterval { recordingSnapshot.duration }

    /// Why the writer stopped, when it stopped itself.
    ///
    /// The recorder has recorded the file-system error since it was written and
    /// there was no way to ask for it from out here — so the application
    /// substituted "the file could not be written" for a message the engine
    /// already had, and disk-full, permission-denied and a codec refusing the
    /// format all read the same. Worse, the writer failing does not release the
    /// recorder, so `isRecording` stays true and the only symptom was a
    /// duration that stopped counting.
    public var recordingError: String? { recordingSnapshot.error }

    /// Control and realtime evidence for the live recording attachment.
    ///
    /// Used by the hardware flow check when a file is open but its transport
    /// has not advanced. Every structural field is read under `stateLock`; the
    /// limiter count comes from the graph's atomic telemetry snapshot.
    public struct RecordingAttachmentDiagnostics: Sendable, Equatable {
        public let hasRing: Bool
        public let channels: Int
        public let mainOutputBuffer: Int
        public let outputBufferCount: Int
        public let cycleFrames: Int
        public let maximumFrames: Int
        public let graphGeneration: UInt64
        public let limiterFailures: UInt64
    }

    public var recordingAttachmentDiagnostics: RecordingAttachmentDiagnostics {
        stateLock.lock()
        defer { stateLock.unlock() }
        var limiterFailures: UInt64 = 0
        if let graph {
            _ = yun_rt_telemetry_load(
                graph.pointee.telemetry, nil, nil, nil, nil, 0,
                nil, nil, &limiterFailures)
        }
        return RecordingAttachmentDiagnostics(
            hasRing: graph?.pointee.recordRing != nil,
            channels: Int(graph?.pointee.recordChannels ?? 0),
            mainOutputBuffer: Int(graph?.pointee.mainOutputBuffer ?? -1),
            outputBufferCount: outputChannelCounts.count,
            cycleFrames: graphBufferFrames,
            maximumFrames: graphMaximumFrames,
            graphGeneration: graphPublicationGeneration,
            limiterFailures: limiterFailures)
    }

    /// Builds route records from control-owned topology only.
    ///
    /// A published `RTRoute` is realtime-owned because its gain and mute can be
    /// changed by the mailbox. Copying that struct on this thread races even if
    /// the fields a caller cared about looked structural. Stable device maps,
    /// the processing plan and occurrence-key assignments contain the complete
    /// replacement without reading the live allocation.
    private func realtimeRoutesLocked(
        _ routes: [Route], processingPlan: RouteProcessingPlan
    ) -> [RTRoute]? {
        guard Self.acceptsRealtimeRouteCount(routes.count) else { return nil }
        let keys = Route.occurrenceKeys(in: routes)
        var result: [RTRoute] = []
        result.reserveCapacity(routes.count)
        for (index, route) in routes.enumerated() {
            let provenance = processingPlan.provenance(for: route.source)
            let comesFromCancelledMicrophone =
                processingPlan.echoCancellationActive
                && route.source.deviceUID == processingPlan.microphoneDeviceUID
            let source: (buffer: Int32, channel: Int32)
            if comesFromCancelledMicrophone {
                source = (0, 0)
            } else if let mapped = inputMap[route.source] {
                source = mapped
            } else {
                return nil
            }
            guard let destination = outputMap[route.destination] else { return nil }
            let stem = stemAssignments[keys[index]]
            result.append(
                RTRoute(
                    sourceBuffer: source.buffer,
                    sourceChannel: source.channel,
                    destinationBuffer: destination.buffer,
                    destinationChannel: destination.channel,
                    gain: route.gain,
                    muted: route.isMuted,
                    usesIsolatedSource: provenance.usesIsolatedSource,
                    usesCancelledSource: provenance.usesCancelledSource,
                    appliesInputTrim: provenance.appliesInputTrim,
                    isDuckable: route.isDuckable,
                    stemIndex: stem?.stem ?? -1,
                    stemChannel: stem?.channel ?? 0,
                    transcriptIndex: transcriptAssignments[keys[index]] ?? -1))
        }
        return result
    }

    /// Pure admission rule shared by starts, live edits and tests.
    /// Checking before any HAL work prevents an impossible topology from
    /// changing system devices merely to be rejected during graph allocation.
    static func acceptsRealtimeRouteCount(_ count: Int) -> Bool {
        RTGraph.supportsRouteCount(count)
    }

    /// Route-ordered history owners for a same-topology publication.
    private func activeAlignmentHistoriesLocked() -> [RTGraph.SharedAlignmentHistory] {
        let histories = activeRouteKeys.compactMap { alignmentHistories[$0] }
        precondition(
            histories.count == activeRouteKeys.count,
            "every active route must retain one alignment history")
        return histories
    }

    /// Installs route-lifetime owners into an unpublished graph.
    private func configurePersistentGraphLocked(
        _ next: UnsafeMutablePointer<RTGraph>, recordingPrimingFrames: Int32 = 0
    ) {
        next.pointee.voiceIsolation = isolationBlock
        next.pointee.isolationIsChain = effectChain != nil ? 1 : 0
        next.pointee.effectTransition = effectTransitionBlock
        next.pointee.selftest = selftestBlock
        if let outputLimiterBank {
            next.pointee.outputLimiter =
                Unmanaged.passUnretained(outputLimiterBank).toOpaque()
        }
        next.pointee.outputLimiterEnabled = outputLimiterIsEnabled ? 1 : 0
        next.pointee.outputLimiterPreGain = outputLimiterPreGain
        next.pointee.cancelledRing = echoBridge?.ring
        next.pointee.inputGain = inputGain
        next.pointee.inputMuted = isInputMuted ? 1 : 0
        next.pointee.outputGain = outputGain
        next.pointee.outputMuted = isOutputMuted ? 1 : 0
        next.pointee.mainOutputBuffer = mainOutputBuffer
        next.pointee.masterExemptBuffer = masterExemptBuffer
        next.pointee.analysisEnabled = analysisIsEnabled ? 1 : 0
        next.pointee.duckEnabled = duckingEnabled ? 1 : 0
        next.pointee.duckDepth = duckingDepth
        next.pointee.duckAllowed = duckingAllowed ? 1 : 0
        next.pointee.calibrating = calibrationIsActive ? 1 : 0
        next.pointee.calibrationEpoch = calibrationEpoch
        next.pointee.outputClippingEpoch = outputClippingEpoch
        next.pointee.alignmentFrames = Int32(
            min(storedSourceProcessingLatencyFrames, RTGraph.maximumAlignmentFrames))

        if let recorder, let recordingLimiter, recordingChannels > 0 {
            next.pointee.recordRing = recorder.ringHandle
            next.pointee.recordChannels = Int32(recordingChannels)
            next.pointee.recordPaused = recordingIsPaused ? 1 : 0
            next.pointee.recordLimiter =
                Unmanaged.passUnretained(recordingLimiter).toOpaque()
            next.pointee.recordLimiterPrimingFrames = recordingPrimingFrames
        }
        for index in 0..<min(stemRecorders.count, Int(next.pointee.stemCount)) {
            next.pointee.stemRings[index] = stemRecorders[index].ringHandle
            next.pointee.stemChannels[index] = Int32(stemChannelCounts[index])
        }
        for index in 0..<min(transcriptRings.count, Int(next.pointee.transcriptCount)) {
            next.pointee.transcriptRings[index] = transcriptRings[index]
        }
    }

    /// Publishes one same-topology structural change without mutating the graph
    /// a callback may already hold.
    @discardableResult
    private func publishStructuralGraphLocked(
        recordingPrimingFrames: Int32 = 0,
        reclaim: @escaping (UnsafeMutablePointer<RTGraph>) -> Void = { _ in },
        configure: (UnsafeMutablePointer<RTGraph>) -> Void = { _ in }
    ) -> Bool {
        guard isRunning, let cell = graphCell, let previous = graph,
            let processingPlan = routeProcessingPlan,
            let rtRoutes = realtimeRoutesLocked(activeRoutes, processingPlan: processingPlan)
        else { return false }
        guard retiredGenerations.prepareForPublication() else { return false }

        guard
            let next = RTGraph.allocateIfSupported(
                routes: rtRoutes, bufferFrames: graphBufferFrames,
                sampleRate: graphSampleRate, sharedClock: sharedClock,
                sharedAnalysisRing: sharedAnalysisRing,
                sharedAlignmentHistories: activeAlignmentHistoriesLocked())
        else { return false }
        configurePersistentGraphLocked(
            next, recordingPrimingFrames: recordingPrimingFrames)
        RTGraph.carryCorrections(from: previous, to: next)
        configure(next)
        RTGraph.installStateHandover(
            from: previous, to: next,
            routeSlots: activeRoutes.indices.map(Optional.some))

        _ = yun_rt_cell_publish(cell, UnsafeMutableRawPointer(next))
        RTGraph.recordPublication(of: UnsafePointer(next))
        recordEngineGraphPublicationLocked()
        let retirementFence = yun_rt_cell_retirement_fence(cell)
        graph = next
        _ = makeAndPublishEngineUISnapshotLocked()
        precondition(
            retiredGenerations.enqueue(safeAfterCycle: retirementFence) {
                reclaim(previous)
                RTGraph.deallocate(previous)
            })
        return true
    }

    /// Schedules the control-side half of an effect handover.
    ///
    /// The timer is only a wake-up estimate. A delayed callback, stopped
    /// device or plug-in which never returns cannot be converted into ownership
    /// proof by wall time, so `finaliseEffectTransitionLocked` still requires
    /// the callback's release-published completion flag and an RCU fence.
    private func scheduleEffectTransitionFinalisation(
        _ controller: EffectTransition,
        cycleFrames: Int,
        sampleRate: Double,
        attempt: Int = 0
    ) {
        let seconds: Double
        if attempt == 0 {
            seconds =
                controller.expectedCompletionSeconds
                + 2 * Double(max(1, cycleFrames)) / sampleRate
        } else {
            seconds = 0.005
        }
        let nanoseconds = Int(
            min(
                Double(Int.max),
                max(0, seconds * 1_000_000_000)))
        effectTransitionFinalisationQueue.asyncAfter(
            deadline: .now() + .nanoseconds(nanoseconds)
        ) { [weak self, weak controller] in
            guard let self, let controller else { return }
            var shouldRetry = false
            self.stateLock.lock()
            if self.isRunning,
                self.effectTransitionController === controller
            {
                if controller.isComplete {
                    shouldRetry = !self.finaliseEffectTransitionLocked(
                        expected: controller)
                } else {
                    shouldRetry = true
                }
            }
            self.stateLock.unlock()

            if shouldRetry,
                attempt < Self.effectTransitionFinalisationRetryLimit
            {
                self.scheduleEffectTransitionFinalisation(
                    controller,
                    cycleFrames: cycleFrames,
                    sampleRate: sampleRate,
                    attempt: attempt + 1)
            }
        }
    }

    /// Publishes the settled new path and retires every old handover owner.
    ///
    /// Called with `stateLock` held. A refusal leaves the complete transition
    /// installed and owned; a later retry or route stop remains safe.
    private func finaliseEffectTransitionLocked(
        expected controller: EffectTransition
    ) -> Bool {
        guard controller.isComplete,
            effectTransitionController === controller,
            let transitionBlock = effectTransitionBlock
        else { return false }

        let oldChain = transitionOldChain
        let oldUnit = transitionOldUnit
        let oldBlock = transitionOldBlock
        let installed = publishStructuralGraphLocked(
            reclaim: { _ in
                RTEffectTransition.deallocate(transitionBlock)
                if let oldBlock {
                    oldBlock.deinitialize(count: 1)
                    oldBlock.deallocate()
                }
                var owners: [any AudioUnitTeardownOwner] = []
                if let oldChain { owners.append(oldChain) }
                if let oldUnit { owners.append(oldUnit) }
                let capsule = AudioUnitOwnerCapsule(owners)
                if capsule.audioUnitCount > 0 {
                    BoundedAudioUnitDisposer.shared.disposeAfterFence(capsule)
                }
                withExtendedLifetime(controller) {}
            },
            configure: { next in
                next.pointee.effectTransition = nil
            })
        guard installed else { return false }

        effectTransitionController = nil
        effectTransitionBlock = nil
        transitionOldChain = nil
        transitionOldUnit = nil
        transitionOldBlock = nil
        return true
    }

    /// Starts writing the routed signal to a file.
    ///
    /// - Throws: Whatever creating the file throws — a directory that does not
    ///   exist, or is not writable.
    @discardableResult
    public func startRecording(
        to directory: URL, format: Recorder.Format = .wav, now: Date = Date()
    ) throws -> URL {
        return try startRecordingSession(
            to: directory, format: format, stemGroups: [], stemNames: [], now: now
        ).mix
    }

    /// Atomically admits and constructs every writer in one recording session.
    ///
    /// File creation remains off `stateLock`, but a single construction
    /// reservation prevents a second caller from building another batch in
    /// parallel. Mix-only and legacy stem entry points share this boundary.
    @discardableResult
    public func startRecordingSession(
        to directory: URL,
        format: Recorder.Format = .wav,
        stemGroups: [[Int]],
        stemNames: [String],
        now: Date = Date()
    ) throws -> (mix: URL, stems: [URL]) {
        stateLock.lock()
        guard isRunning, aggregate?.device != nil, recorder == nil,
            stemRecorders.isEmpty, !recordingConstructionIsInFlight,
            recorderFinaliser.acceptsConstruction
        else {
            stateLock.unlock()
            throw RecorderError.couldNotAllocate
        }
        let main = Int(mainOutputBuffer)
        guard main >= 0, main < outputChannelCounts.count else {
            stateLock.unlock()
            throw RecorderError.couldNotAllocate
        }
        let channels = min(2, outputChannelCounts[main])
        let sampleRate = graphSampleRate
        let lifetime = routeLifetimeGeneration
        let routeKeys = activeRouteKeys
        let stemCount = min(stemGroups.count, activeRoutes.count)
        let stemChannelCounts = stemGroups.prefix(stemCount).map {
            min(RTGraph.maxStemChannels, max(1, $0.count))
        }
        guard
            RecordingResourceAdmission.evaluate(
                sampleRate: sampleRate,
                channelCounts: [channels] + stemChannelCounts) != nil
        else {
            stateLock.unlock()
            throw RecorderError.couldNotAllocate
        }
        recordingConstructionIsInFlight = true
        stateLock.unlock()

        var constructed: [Recorder] = []
        func retireConstruction() {
            let owner =
                constructed.isEmpty
                ? nil : RecorderRetirementOwner(recorders: constructed)
            owner?.makeSafe()
            stateLock.lock()
            // The reservation opens only after the finaliser owns every file.
            // Reversing these lines lets a concurrent start enter the gap and
            // build another complete batch against unaccounted old writers.
            if let owner { _ = recorderFinaliser.submit(owner) }
            recordingConstructionIsInFlight = false
            stateLock.unlock()
        }

        guard channels > 0,
            let limiter = OutputLimiterBank(channelCounts: [channels], sampleRate: sampleRate)
        else {
            retireConstruction()
            throw RecorderError.couldNotAllocate
        }
        let mixRecorder: Recorder
        var stemReplacements: [Recorder] = []
        var stemURLs: [URL] = []
        var assignments: [RouteOccurrenceKey: (stem: Int32, channel: Int32)] = [:]
        do {
            mixRecorder = try Recorder(
                directory: directory, format: format, channels: channels,
                sampleRate: sampleRate, timestamp: now)
            constructed.append(mixRecorder)
            for (stem, routes) in stemGroups.prefix(stemCount).enumerated() {
                let recorder = try Recorder(
                    directory: directory, format: format,
                    channels: stemChannelCounts[stem], sampleRate: sampleRate,
                    timestamp: now,
                    name: stem < stemNames.count ? stemNames[stem] : "Source \(stem + 1)")
                constructed.append(recorder)
                stemReplacements.append(recorder)
                stemURLs.append(recorder.url)
                for (channel, route) in routes.enumerated()
                where routeKeys.indices.contains(route)
                    && channel < stemChannelCounts[stem]
                {
                    assignments[routeKeys[route]] =
                        (stem: Int32(stem), channel: Int32(channel))
                }
            }
        } catch {
            retireConstruction()
            throw error
        }

        stateLock.lock()
        guard isRunning, aggregate?.device != nil, self.recorder == nil,
            stemRecorders.isEmpty, recordingConstructionIsInFlight,
            routeLifetimeGeneration == lifetime, activeRouteKeys == routeKeys,
            recorderFinaliser.acceptsConstruction
        else {
            stateLock.unlock()
            retireConstruction()
            throw RecorderError.couldNotAllocate
        }
        let installed = publishStructuralGraphLocked(
            recordingPrimingFrames: Int32(limiter.latencyFrames),
            configure: { next in
                next.pointee.recordChannels = Int32(channels)
                next.pointee.recordLimiter = Unmanaged.passUnretained(limiter).toOpaque()
                next.pointee.recordLimiterPrimingFrames = Int32(limiter.latencyFrames)
                next.pointee.recordPaused = 0
                next.pointee.recordRing = mixRecorder.ringHandle
                for stem in 0..<min(stemReplacements.count, Int(next.pointee.stemCount)) {
                    next.pointee.stemChannels[stem] = Int32(stemChannelCounts[stem])
                    next.pointee.stemRings[stem] = stemReplacements[stem].ringHandle
                }
                for (route, key) in self.activeRouteKeys.enumerated() {
                    guard let assignment = assignments[key] else { continue }
                    next.pointee.routes[route].stemIndex = assignment.stem
                    next.pointee.routes[route].stemChannel = assignment.channel
                }
            })
        guard installed, graph?.pointee.recordRing == mixRecorder.ringHandle else {
            stateLock.unlock()
            retireConstruction()
            throw RecorderError.couldNotAllocate
        }
        self.recorder = mixRecorder
        recordingLimiter = limiter
        recordingChannels = channels
        recordingIsPaused = false
        stemRecorders = stemReplacements
        self.stemChannelCounts = stemChannelCounts
        stemAssignments = assignments
        recordingConstructionIsInFlight = false
        publishedSnapshotLock.withLock {
            publishedRecordingSnapshot = RecordingSnapshot(
                isRecording: true, url: mixRecorder.url, duration: 0, error: nil)
        }
        stateLock.unlock()
        return (mixRecorder.url, stemURLs)
    }

    /// Configures ducking. Takes effect on the next cycle without a rebuild.
    public func setDucking(enabled: Bool, depth: Float) {
        stateLock.lock()
        defer { stateLock.unlock() }
        duckingEnabled = enabled
        duckingDepth = depth.isFinite ? max(0, min(1, depth)) : duckingDepth
        _ = pushGlobal(kind: kYunRTCommandSetDuckingDepth, value: duckingDepth)
        _ = pushGlobal(
            kind: kYunRTCommandSetDuckingEnabled, value: duckingEnabled ? 1 : 0)
    }

    /// Tells the realtime side whether the classifier's recent verdict permits
    /// ducking at all. The envelope decides the instant; this decides whether
    /// that instant counts.
    public func setDuckingAllowed(_ allowed: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        duckingAllowed = allowed
        _ = pushGlobal(
            kind: kYunRTCommandSetDuckingAllowed, value: duckingAllowed ? 1 : 0)
    }

    /// Switches the mono fold that feeds the analysers on or off.
    ///
    /// Off by default. Nothing should be folding the output bus every cycle for
    /// a panel nobody has open.
    /// Puts a correction on each named output, and none on any other.
    ///
    /// The whole set at once rather than one output at a time, because this is
    /// a publish rather than a mutation: a bus whose curve was taken away has
    /// to stop running the old one, and a call naming a single device could
    /// never say so. Every output not named here is left running nothing, which
    /// is the only reading of the argument that cannot go stale.
    ///
    /// Why the last `setCorrections` installed nothing.
    ///
    /// Zero is three different failures wearing one number — no graph, no
    /// output matching the bus, or a graph replaced between the install and the
    /// check — and the caller reports the same "correction absent" for all
    /// three, so "the correction did not survive a restart" was three bugs to
    /// choose between with no way to choose. Now it says which.
    public enum CorrectionOutcome: String, Equatable, Sendable {
        case installed
        case noGraph
        case noOutputForTheBus
        case graphReplacedUnderIt
        case nothingToInstall
    }

    /// Which device UIDs the graph actually has an output buffer for.
    ///
    /// The other half of `noOutputForTheBus`: the model knows which bus it has
    /// a curve for, the engine knows which buses exist, and until both were
    /// printed together the answer was "one of them is wrong" with no way to
    /// say which.
    public var outputDeviceUIDs: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(Set(outputMap.keys.map(\.deviceUID))).sorted()
    }

    /// The last outcome, for diagnostics and acceptance checks.
    public private(set) var lastCorrectionOutcome: CorrectionOutcome = .nothingToInstall

    /// - Parameter curves: The curve for each output device UID.
    /// - Returns: How many of them reached an output. A curve for a device that
    ///   is not in this route is dropped rather than held — the ordinary case
    ///   of a profile left selected after the headphones were unplugged.
    @discardableResult
    public func setCorrections(_ curves: [String: ParametricEQ]) -> Int {
        stateLock.lock()
        guard let graph else {
            lastCorrectionOutcome = .noGraph
            stateLock.unlock()
            return 0
        }

        // Resolved to buffer indices first, on the control thread, so the loop
        // below can leave each slot in exactly one state. Two UIDs cannot claim
        // one slot: the map is by device.
        var wanted: [Int: ParametricEQ] = [:]
        for (uid, curve) in curves {
            guard let buffer = outputBufferIndex(forDeviceUID: uid) else { continue }
            wanted[buffer] = curve
        }
        let rate = graphSampleRate
        let owner = Unmanaged<OutputCorrectionBank>
            .fromOpaque(graph.pointee.outputCorrections)
        let correctionPointer = graph.pointee.outputCorrections
        _ = owner.retain()
        stateLock.unlock()
        defer { owner.release() }

        var configurations: [Int: OutputCorrectionBank.Configuration] = [:]
        configurations.reserveCapacity(wanted.count)
        for (slot, curve) in wanted {
            let packed = curve.coefficients(sampleRate: rate)
            let preamp = pow(10, curve.preampDecibels / 20)
            if let configuration = OutputCorrectionBank.Configuration(
                coefficients: packed, preampGain: preamp)
            {
                configurations[slot] = configuration
            }
        }
        let installed = owner.takeUnretainedValue().publish(configurations)
        stateLock.lock()
        let reachedCurrentGraph =
            self.graph?.pointee.outputCorrections == correctionPointer
        lastCorrectionOutcome =
            !reachedCurrentGraph
            ? .graphReplacedUnderIt
            : installed > 0
                ? .installed
                : curves.isEmpty ? .nothingToInstall : .noOutputForTheBus
        stateLock.unlock()
        return reachedCurrentGraph ? installed : 0
    }

    /// Which output buffer carries a device, if any of them do.
    private func outputBufferIndex(forDeviceUID uid: String) -> Int? {
        outputMap.first { key, _ in key.deviceUID == uid }.map { Int($0.value.buffer) }
    }

    public func setAnalysisEnabled(_ enabled: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        analysisIsEnabled = enabled
        _ = pushGlobal(
            kind: kYunRTCommandSetAnalysisEnabled, value: analysisIsEnabled ? 1 : 0)
        lastConfiguration?.rememberAnalysisEnabled(enabled)
    }

    /// A snapshot of the analyser hand-off, for diagnostics and acceptance checks.
    ///
    /// The fill level alone cannot distinguish an idle producer from a consumer
    /// that kept up. `written` makes that distinction, while `dropped` proves
    /// whether a reading silently contains holes.
    public struct AnalysisStatistics: Sendable {
        public let isEnabled: Bool
        public let written: UInt32
        public let available: UInt32
        public let dropped: UInt64
    }

    public var analysisStatistics: AnalysisStatistics {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ring = sharedAnalysisRing?.storage else {
            return AnalysisStatistics(
                isEnabled: false, written: 0, available: 0, dropped: 0)
        }
        return AnalysisStatistics(
            isEnabled: analysisIsEnabled,
            written: yun_rt_ring_written(ring),
            available: yun_rt_ring_available(ring),
            dropped: yun_rt_ring_dropped(ring))
    }

    /// Takes whatever the IO thread has folded to mono since the last call.
    ///
    /// Returns the number of samples written into `destination`. A short read
    /// is the normal case; an empty one means no cycle has run since the last
    /// drain, which the caller should treat as "nothing new" rather than
    /// "silence" — feeding zeroes to a loudness meter would drag the integrated
    /// reading down for time the signal was never absent.
    public func drainAnalysis(
        into destination: UnsafeMutablePointer<Float>, capacity: Int
    ) -> Int {
        // The ring keeps the unread samples. If a graph swap or clock recovery
        // owns the state lock, skipping one UI poll loses nothing and prevents
        // the twenty-hertz MainActor timer from waiting behind up to seconds of
        // CoreAudio work.
        guard stateLock.try() else { return 0 }
        defer { stateLock.unlock() }
        guard let ring = sharedAnalysisRing?.storage,
            let admittedCapacity = UInt32(exactly: capacity), admittedCapacity > 0
        else { return 0 }
        return Int(yun_rt_ring_read(ring, destination, admittedCapacity))
    }

    /// Pauses or resumes without closing the file.
    ///
    /// The recorder itself does not know: frames simply stop being put into its
    /// ring. That is what makes the result a clean splice rather than a gap —
    /// and it means the elapsed time stops too, because the duration is counted
    /// from what was written.
    public func setRecordingPaused(_ paused: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard recorder != nil, recordingLimiter != nil else { return }
        guard recordingIsPaused != paused else { return }
        recordingIsPaused = paused
        guard
            let publication = publishGlobal(
                kind: kYunRTCommandSetRecordingPaused, value: paused ? 1 : 0)
        else {
            recordingIsPaused.toggle()
            return
        }
        if paused {
            // Stop the producer first, then finish the delayed tail. Resetting
            // after the flush makes the resumed part a clean splice rather
            // than replaying the last millisecond from before the pause.
            guard waitForMailbox(publication, timeoutMilliseconds: 20) else { return }
            if let graphCell {
                let fence = yun_rt_cell_retirement_fence(graphCell)
                // A stalled callback keeps the limiter owner alive, so there is
                // no memory-safety deadline here. Leaving its look-ahead state
                // intact makes the eventual resume a continuous splice; it is
                // safer than resetting state a callback may still be using.
                guard yun_rt_cell_wait_until(graphCell, fence, 20) else { return }
            }
            guard let graph else { return }
            flushRecordingLimiterLocked(graph: graph)
            if let limiter = recordingLimiter {
                _ = limiter.reset(bus: 0)
                graph.pointee.recordLimiterPrimingFrames =
                    Int32(limiter.latencyFrames)
            }
        }
    }

    /// Under the lock like every other read of the graph, and non-blocking for
    /// the same reason: this dereferences memory the engine queue may free.
    /// Answering "not paused" for the frame a rebuild takes is the honest
    /// default — a recording that is not running is not paused either.
    public var isRecordingPaused: Bool {
        guard stateLock.try() else { return false }
        defer { stateLock.unlock() }
        return recorder != nil && recordingIsPaused
    }

    /// Starts a separate file per source alongside the mix.
    ///
    /// Recording the mix answers "what did the far end hear". Recording each
    /// source answers "what did each of us say", which is the question anybody
    /// editing afterwards actually has — and the one that cannot be recovered
    /// from a mix at any price.
    ///
    /// - Parameters:
    ///   - directory: Where the files go.
    ///   - groups: One entry per stem: the routes it is made of, in channel
    ///     order.
    ///   - names: What each stem is called, in the same order.
    ///   - format: Container and encoding, the same as the mix.
    ///   - now: Used in the file names.
    /// - Returns: The files created, in the same order.
    /// - Throws: `RecorderError.couldNotAllocate` when nothing is routing, or
    ///   whatever creating a file throws.
    @discardableResult
    public func startStemRecording(
        to directory: URL, groups: [[Int]], names: [String],
        format: Recorder.Format = .wav, now: Date = Date()
    ) throws -> [URL] {
        stateLock.lock()
        guard isRunning, aggregate?.device != nil, stemRecorders.isEmpty,
            !recordingConstructionIsInFlight, recorderFinaliser.acceptsConstruction
        else {
            stateLock.unlock()
            throw RecorderError.couldNotAllocate
        }
        let stemCount = min(groups.count, activeRoutes.count)
        let routeKeys = activeRouteKeys
        let sampleRate = graphSampleRate
        let lifetime = routeLifetimeGeneration
        let proposedChannelCounts = groups.prefix(stemCount).map {
            min(RTGraph.maxStemChannels, max(1, $0.count))
        }
        let existingMixChannels = recorder == nil ? [] : [recordingChannels]
        guard
            RecordingResourceAdmission.evaluate(
                sampleRate: sampleRate,
                channelCounts: existingMixChannels + proposedChannelCounts) != nil
        else {
            stateLock.unlock()
            throw RecorderError.couldNotAllocate
        }
        recordingConstructionIsInFlight = true
        stateLock.unlock()

        var urls: [URL] = []
        var replacements: [Recorder] = []
        var channelCounts: [Int] = []
        var assignments: [RouteOccurrenceKey: (stem: Int32, channel: Int32)] = [:]
        func retireConstruction() {
            let owner =
                replacements.isEmpty
                ? nil : RecorderRetirementOwner(recorders: replacements)
            owner?.makeSafe()
            stateLock.lock()
            // Keep the same ownership/admission ordering as the atomic
            // mix-and-stems entry point above.
            if let owner { _ = recorderFinaliser.submit(owner) }
            recordingConstructionIsInFlight = false
            stateLock.unlock()
        }
        do {
            for (stem, routes) in groups.prefix(stemCount).enumerated() {
                let channels = min(RTGraph.maxStemChannels, max(1, routes.count))
                let recorder = try Recorder(
                    directory: directory, format: format, channels: channels,
                    sampleRate: sampleRate, timestamp: now,
                    name: stem < names.count ? names[stem] : "Source \(stem + 1)")
                replacements.append(recorder)
                channelCounts.append(channels)
                urls.append(recorder.url)

                for (channel, route) in routes.enumerated()
                where routeKeys.indices.contains(route) && channel < channels {
                    assignments[routeKeys[route]] =
                        (stem: Int32(stem), channel: Int32(channel))
                }
            }
        } catch {
            retireConstruction()
            throw error
        }
        guard !replacements.isEmpty else {
            retireConstruction()
            return []
        }

        stateLock.lock()
        guard isRunning, aggregate?.device != nil, stemRecorders.isEmpty,
            recordingConstructionIsInFlight, routeLifetimeGeneration == lifetime,
            activeRouteKeys == routeKeys,
            recorderFinaliser.acceptsConstruction
        else {
            stateLock.unlock()
            retireConstruction()
            throw RecorderError.couldNotAllocate
        }
        let installed = publishStructuralGraphLocked(configure: { next in
            for stem in 0..<min(replacements.count, Int(next.pointee.stemCount)) {
                next.pointee.stemChannels[stem] = Int32(channelCounts[stem])
                next.pointee.stemRings[stem] = replacements[stem].ringHandle
            }
            for (route, key) in self.activeRouteKeys.enumerated() {
                guard let assignment = assignments[key] else { continue }
                next.pointee.routes[route].stemIndex = assignment.stem
                next.pointee.routes[route].stemChannel = assignment.channel
            }
        })
        guard installed else {
            stateLock.unlock()
            retireConstruction()
            throw RecorderError.couldNotAllocate
        }
        stemRecorders = replacements
        stemChannelCounts = channelCounts
        stemAssignments = assignments
        recordingConstructionIsInFlight = false
        stateLock.unlock()
        return urls
    }

    /// Where each route in a new list sat in the old one, or nil for a route
    /// that is new.
    ///
    /// The assignment of a route to a stem file or a transcript follows the
    /// route rather than its position: a rebuild reorders the array, and
    /// copying by index would hand one source's audio to another's file. What
    /// identifies a route is what it connects, so that is what is matched.
    ///
    /// Separated out because the alternative is a function only reachable with
    /// two audio devices and a running IOProc, and this is the part that can be
    /// wrong.
    static func carriedPositions(from old: [Route], to new: [Route]) -> [Int?] {
        // Each old route is claimed once. Two routes can connect the same pair
        // of channels — a duplicate cable is not an error — and letting both
        // new ones match the same old one would put two sources in one file.
        var available = Array(old.indices)
        return new.map { route in
            guard
                let position = available.firstIndex(where: {
                    old[$0].source == route.source && old[$0].destination == route.destination
                })
            else { return nil }
            return available.remove(at: position)
        }
    }

    /// Carries live fader and mute truth onto a proposed topology.
    ///
    /// A topology request is built on MainActor before earlier fader commands
    /// necessarily reach this queue. The engine's copy is therefore the newer
    /// truth. Reusing the route carry contract also keeps duplicate cables
    /// independent instead of collapsing identical endpoints into one entry.
    static func preservingRouteControls(from old: [Route], to new: [Route]) -> [Route] {
        var result = new
        for (newIndex, oldIndex) in carriedPositions(from: old, to: new).enumerated() {
            guard let oldIndex else { continue }
            result[newIndex].gain = old[oldIndex].gain
            result[newIndex].isMuted = old[oldIndex].isMuted
        }
        return result
    }

    /// Publishes control-side topology truth and its O(1) command lookup.
    private func installActiveRoutes(_ routes: [Route]) {
        activeRoutes = routes
        activeRouteKeys = Route.occurrenceKeys(in: routes)
        activeRouteIndex = Dictionary(
            uniqueKeysWithValues: activeRouteKeys.indices.map {
                (activeRouteKeys[$0], $0)
            })
    }

    @discardableResult
    public func stopStemRecording() -> RecorderFinalisationFence {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopStemRecordingLocked()
    }

    private func stopStemRecordingLocked() -> RecorderFinalisationFence {
        guard !stemRecorders.isEmpty else {
            return RecorderFinalisationFence(completedWith: .complete)
        }
        let detached = stemRecorders
        let owner = RecorderRetirementOwner(recorders: detached)
        if ioProcID != nil, graphCell != nil {
            guard
                publishStructuralGraphLocked(
                    reclaim: { _ in owner.makeSafe() },
                    configure: { next in
                        for stem in 0..<Int(next.pointee.stemCount) {
                            next.pointee.stemRings[stem] = nil
                            next.pointee.stemChannels[stem] = 0
                        }
                        for route in 0..<Int(next.pointee.routeCount) {
                            next.pointee.routes[route].stemIndex = -1
                        }
                    })
            else {
                return RecorderFinalisationFence(completedWith: .detachmentFailed)
            }
        } else {
            owner.makeSafe()
        }
        let fence = recorderFinaliser.submit(owner)
        stemRecorders.removeAll()
        stemChannelCounts.removeAll()
        stemAssignments.removeAll()
        return fence
    }

    private var stemRecorders: [Recorder] = []

    // MARK: Transcription taps

    /// Opens one ring per source so the app can transcribe each separately.
    ///
    /// This is the whole mechanism behind attributed transcripts. Every product
    /// in this space works out who is speaking from the sound and every one of
    /// them is sometimes wrong; here the sources were never mixed in the first
    /// place, so the speaker is the wiring and there is nothing to infer.
    ///
    /// - Parameter routes: One route index per source, in the order the caller
    ///   will ask for them back. The first channel of a source is enough — a
    ///   speech model gains nothing from a stereo fold.
    /// - Returns: The length of the exact request prefix which was opened.
    ///   Nothing after the first invalid, duplicate or unallocatable route is
    ///   installed, so a caller can safely prefix its labels by this count.
    @discardableResult
    public func startTranscriptTaps(routes: [Int]) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, graph != nil else { return 0 }
        guard stopTranscriptTapsLocked() else { return 0 }

        var replacements: [OpaquePointer] = []
        var assignments: [RouteOccurrenceKey: Int32] = [:]
        let admittedRoutes = Self.transcriptTapRoutePrefix(
            routes: routes, activeRouteKeys: activeRouteKeys,
            maximumCount: activeRoutes.count)
        for route in admittedRoutes {
            let key = activeRouteKeys[route]
            // A second at 48 kHz. The consumer polls on the interface's own
            // timer, so a ring that only held a buffer or two would drop audio
            // every time a window resize got in the way of a poll.
            guard let ring = yun_rt_ring_create(65_536) else { break }
            assignments[key] = Int32(replacements.count)
            replacements.append(ring)
        }
        let installed = publishStructuralGraphLocked(configure: { next in
            for slot in 0..<min(replacements.count, Int(next.pointee.transcriptCount)) {
                next.pointee.transcriptRings[slot] = replacements[slot]
            }
            for (route, key) in self.activeRouteKeys.enumerated() {
                guard let slot = assignments[key] else { continue }
                next.pointee.routes[route].transcriptIndex = slot
            }
        })
        guard installed else {
            for ring in replacements { yun_rt_ring_free(ring) }
            return 0
        }
        transcriptRings = replacements
        transcriptAssignments = assignments
        return replacements.count
    }

    /// The exact route prefix whose slots can retain positional identity.
    static func transcriptTapRoutePrefix(
        routes: [Int], activeRouteKeys: [RouteOccurrenceKey], maximumCount: Int
    ) -> [Int] {
        guard maximumCount > 0 else { return [] }
        var prefix: [Int] = []
        prefix.reserveCapacity(min(routes.count, maximumCount))
        var keys = Set<RouteOccurrenceKey>()
        for route in routes {
            guard prefix.count < maximumCount,
                activeRouteKeys.indices.contains(route),
                keys.insert(activeRouteKeys[route]).inserted
            else { break }
            prefix.append(route)
        }
        return prefix
    }

    /// Detaches every source ring, retaining ownership when publication fails.
    @discardableResult
    public func stopTranscriptTaps() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopTranscriptTapsLocked()
    }

    @discardableResult
    private func stopTranscriptTapsLocked() -> Bool {
        guard !transcriptRings.isEmpty else { return true }
        let detached = transcriptRings
        let reclaim = { (_: UnsafeMutablePointer<RTGraph>?) in
            for ring in detached { yun_rt_ring_free(ring) }
        }
        if ioProcID != nil, graphCell != nil {
            guard
                publishStructuralGraphLocked(
                    reclaim: { previous in reclaim(previous) },
                    configure: { next in
                        for slot in 0..<Int(next.pointee.transcriptCount) {
                            next.pointee.transcriptRings[slot] = nil
                        }
                        for route in 0..<Int(next.pointee.routeCount) {
                            next.pointee.routes[route].transcriptIndex = -1
                        }
                    })
            else { return false }
        } else {
            reclaim(nil)
        }
        transcriptRings.removeAll()
        transcriptAssignments.removeAll()
        return true
    }

    /// Takes whatever one source has produced since the last call.
    ///
    /// An empty read means no cycle has run, not silence — the same distinction
    /// the analysis drain makes, and it matters more here: handing a speech
    /// model zeroes for time the signal was never absent teaches it a pause
    /// that did not happen.
    public func drainTranscript(
        _ slot: Int, into destination: UnsafeMutablePointer<Float>, capacity: Int
    ) -> Int {
        guard let admittedCapacity = UInt32(exactly: capacity), admittedCapacity > 0 else {
            return 0
        }
        return Self.withTranscriptDrainLock(stateLock) {
            guard slot >= 0, slot < transcriptRings.count else { return 0 }
            return Int(
                yun_rt_ring_read(transcriptRings[slot], destination, admittedCapacity))
        }
    }

    /// Reads only when the graph owner is immediately available.
    ///
    /// The interface drains these rings on its meter tick. A graph replacement
    /// can own the state lock for its 200 ms retirement wait, while a start can
    /// own it across synchronous CoreAudio calls and a 750 ms cycle proof.
    /// Waiting for either would freeze the interface. Returning zero leaves the
    /// ring's read cursor untouched, so the next tick receives the same samples
    /// in the same order.
    @inline(__always)
    private static func withTranscriptDrainLock(
        _ lock: NSRecursiveLock, read: () -> Int
    ) -> Int {
        guard lock.try() else { return 0 }
        defer { lock.unlock() }
        return read()
    }

    /// How many sources are being tapped for transcription.
    public var transcriptTapCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return transcriptRings.count
    }

    /// A non-consuming snapshot of one source ring.
    ///
    /// Nil means the slot is invalid or graph ownership was busy. It must not
    /// become a zero-valued reading: an empty healthy ring, a saturated ring
    /// and a lock held across graph publication are three different facts.
    public struct TranscriptTapStatistics: Sendable, Equatable {
        public let available: UInt32
        public let dropped: UInt64
    }

    /// Samples one source ring without standing behind graph publication.
    ///
    /// The singing and transcription service polls this beside its nonblocking
    /// drain. Returning nil leaves the last complete telemetry untouched and
    /// prevents a 20 Hz interface read from joining a Core Audio lifecycle
    /// wait.
    public func transcriptTapStatistics(at slot: Int) -> TranscriptTapStatistics? {
        guard stateLock.try() else { return nil }
        defer { stateLock.unlock() }
        guard transcriptRings.indices.contains(slot) else { return nil }
        let ring = transcriptRings[slot]
        return TranscriptTapStatistics(
            available: yun_rt_ring_available(ring),
            dropped: yun_rt_ring_dropped(ring))
    }

    private var transcriptRings: [OpaquePointer] = []

    /// Installs an owned ring without constructing audio hardware.
    ///
    /// Test support for the lock boundary above. The ordinary installation path
    /// is `startTranscriptTaps`; using that in a unit test would turn a
    /// concurrency assertion into a CoreAudio integration test.
    func installTranscriptRingForTesting(_ ring: OpaquePointer) {
        stateLock.lock()
        defer { stateLock.unlock() }
        precondition(transcriptRings.isEmpty)
        transcriptRings.append(ring)
    }

    package func installSelftestForTesting(
        _ block: UnsafeMutablePointer<RTSelftest>?, generation: UInt64 = 1,
        graphGeneration: UInt64? = nil
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        selftestOwner = block.map(RTSelftestOwner.init(adopting:))
        selftestBlock = block
        routeLifetimeGeneration = generation
        graphPublicationGeneration = graphGeneration ?? generation
    }

    /// Holds the same lock as graph publication for a deterministic contention test.
    package func withStateLockForTesting(_ body: () -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        body()
    }

    /// Replaces the clock owner through the same lifetime lock as route Stop.
    func installClockPublisherForTesting(_ publisher: ClockAnchorPublisher?) {
        stateLock.lock()
        let previous = clockPublisher
        clockPublisher = publisher
        _ = clockTelemetryLocked()
        stateLock.unlock()
        if previous !== publisher { previous?.stop() }
    }

    /// Replaces and drains a recorder without constructing an audio route.
    func installRecorderForTesting(_ replacement: Recorder?) {
        stateLock.lock()
        let previous = recorder
        recorder = replacement
        let snapshot: RecordingSnapshot
        if let replacement {
            let progress = replacement.progressSnapshot
            snapshot = RecordingSnapshot(
                isRecording: true, url: replacement.url,
                duration: progress.duration, error: progress.error)
        } else {
            snapshot = .stopped
        }
        publishedSnapshotLock.withLock {
            publishedRecordingSnapshot = snapshot
        }
        stateLock.unlock()
        if previous !== replacement { previous?.stop() }
    }

    /// True while separate files are being written.
    public var isRecordingStems: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !stemRecorders.isEmpty
    }

    /// Samples any stem had to drop. Non-zero means a file has gaps.
    public var stemDroppedSamples: UInt64 {
        Self.withStemSnapshotLock(stateLock) {
            stemRecorders.reduce(0) { $0 + $1.droppedSamples }
        }
    }

    /// Keeps a SwiftUI telemetry read out of synchronous Core Audio work.
    ///
    /// Zero is an unavailable snapshot, not evidence that a prior drop healed;
    /// the view reads once per pass and the next pass retries. A dropped-sample
    /// warning is diagnostic, whereas blocking the system audio menu behind the
    /// same lock would be an outage.
    @inline(__always)
    static func withStemSnapshotLock(
        _ lock: NSRecursiveLock, read: () -> UInt64
    ) -> UInt64 {
        guard lock.try() else { return 0 }
        defer { lock.unlock() }
        return read()
    }

    @discardableResult
    public func stopRecording() -> RecorderFinalisationFence {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRecordingLocked()
    }

    /// Detaches the producer immediately and retires its owners after the same
    /// cycle fence as a graph publication.
    ///
    /// A timeout cannot distinguish an idle device from a callback stalled
    /// after loading the ring. The latter caused a measured `SIGSEGV` inside
    /// `yun_rt_ring_write`, so stalled owners stay in the bounded retirement
    /// queue instead of being freed on an assumption about why cycles stopped.
    private func stopRecordingLocked() -> RecorderFinalisationFence {
        guard let recorder else {
            return RecorderFinalisationFence(completedWith: .complete)
        }
        let limiter = recordingLimiter
        let channels = recordingChannels
        let limiting = outputLimiterIsEnabled
        let preGain = outputLimiterPreGain
        let owner = RecorderRetirementOwner(recorders: [recorder]) { primingFrames in
            if let limiter, channels > 0 {
                _ = Self.flushRecordingLimiter(
                    limiter, into: recorder.ringHandle,
                    channels: channels, primingFrames: primingFrames,
                    limiting: limiting, preGain: preGain)
            }
            withExtendedLifetime(limiter) {}
        }
        if ioProcID != nil, graphCell != nil {
            guard
                publishStructuralGraphLocked(
                    reclaim: { previous in
                        owner.makeSafe(
                            primingFrames: Int(
                                previous.pointee.recordLimiterPrimingFrames))
                    },
                    configure: { next in
                        next.pointee.recordRing = nil
                        next.pointee.recordLimiter = nil
                        next.pointee.recordChannels = 0
                        next.pointee.recordPaused = 0
                        next.pointee.recordLimiterPrimingFrames = 0
                    })
            else {
                return RecorderFinalisationFence(completedWith: .detachmentFailed)
            }
        } else {
            let primingFrames = Int(graph?.pointee.recordLimiterPrimingFrames ?? 0)
            owner.makeSafe(primingFrames: primingFrames)
            graph?.pointee.recordRing = nil
            graph?.pointee.recordLimiter = nil
            graph?.pointee.recordChannels = 0
            graph?.pointee.recordPaused = 0
            graph?.pointee.recordLimiterPrimingFrames = 0
        }
        let fence = recorderFinaliser.submit(owner)
        self.recorder = nil
        publishedSnapshotLock.withLock {
            publishedRecordingSnapshot = .stopped
        }
        recordingLimiter = nil
        recordingChannels = 0
        recordingIsPaused = false
        return fence
    }

    /// Emits the delayed recording tail after its realtime producer detached.
    ///
    /// Start discards exactly the look-ahead's leading zeroes and detach emits
    /// exactly the held tail. Therefore N canonical input frames become N file
    /// frames: no 48-frame prefix, no 48-frame truncation.
    private func flushRecordingLimiterLocked(graph: UnsafeMutablePointer<RTGraph>) {
        guard let limiter = recordingLimiter, let ring = recorder?.ringHandle else { return }
        _ = Self.flushRecordingLimiter(
            limiter, into: ring, channels: Int(graph.pointee.recordChannels),
            primingFrames: Int(graph.pointee.recordLimiterPrimingFrames),
            limiting: graph.pointee.outputLimiterEnabled != 0,
            preGain: outputLimiterPreGain)
        graph.pointee.recordLimiterPrimingFrames = 0
    }

    /// Control-thread half of the recording look-ahead trim.
    ///
    /// Internal so a pure test can prove the exact frame count without opening
    /// an audio device or relying on a file writer's scheduling.
    @discardableResult
    static func flushRecordingLimiter(
        _ limiter: OutputLimiterBank, into ring: OpaquePointer,
        channels: Int, primingFrames: Int, limiting: Bool, preGain: Float
    ) -> Int {
        guard channels > 0, limiter.channelCounts == [channels] else { return 0 }
        let frames = limiter.latencyFrames
        guard frames > 0 else { return 0 }
        var tail = [Float](repeating: 0, count: frames * channels)
        let processed = tail.withUnsafeMutableBufferPointer {
            limiter.processInterleaved(
                bus: 0, samples: $0.baseAddress!, frames: frames, channels: channels,
                limiting: limiting, preGain: preGain)
        }
        guard processed else { return 0 }
        let skip = min(frames, max(0, primingFrames))
        let writtenFrames = frames - skip
        guard writtenFrames > 0 else { return 0 }
        return tail.withUnsafeBufferPointer {
            Int(
                yun_rt_ring_write(
                    ring, $0.baseAddress! + skip * channels,
                    UInt32(writtenFrames * channels)))
        } / channels
    }

    // MARK: Live topology

    /// Replaces the whole set of routes without interrupting audio.
    ///
    /// The alternative — restarting the device — costs about 108 ms of silence
    /// every time a route is added or removed. Here a new graph is built on this
    /// thread, swapped in atomically, and the old one is freed only once the
    /// realtime thread has been seen to complete two cycles past the swap: one
    /// cycle may already have been in flight holding the old pointer.
    @discardableResult
    public func updateRoutes(_ requestedRoutes: [Route]) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard isRunning, let cell = graphCell, let previous = graph,
            let processingPlan = routeProcessingPlan
        else { return false }
        guard retiredGenerations.prepareForPublication() else { return false }
        let routes = Self.preservingRouteControls(
            from: activeRoutes, to: requestedRoutes)

        guard let rtRoutes = realtimeRoutesLocked(routes, processingPlan: processingPlan)
        else { return false }

        let nextRouteKeys = Route.occurrenceKeys(in: routes)
        var nextAlignmentHistories: [RouteOccurrenceKey: RTGraph.SharedAlignmentHistory] = [:]
        nextAlignmentHistories.reserveCapacity(nextRouteKeys.count)
        for key in nextRouteKeys {
            nextAlignmentHistories[key] =
                alignmentHistories[key] ?? RTGraph.SharedAlignmentHistory.allocate()
        }
        let retiredAlignmentHistories = alignmentHistories.compactMap { entry in
            nextAlignmentHistories[entry.key] == nil ? entry.value : nil
        }
        let orderedAlignmentHistories = nextRouteKeys.map {
            nextAlignmentHistories[$0]!
        }

        guard
            let next = RTGraph.allocateIfSupported(
                routes: rtRoutes,
                bufferFrames: graphBufferFrames,
                sampleRate: graphSampleRate,
                sharedClock: sharedClock,
                sharedAnalysisRing: sharedAnalysisRing,
                sharedAlignmentHistories: orderedAlignmentHistories)
        else { return false }
        configurePersistentGraphLocked(next)
        // A live route edit changes only which source feeds an existing output
        // map. Sharing the bank keeps both the per-bus identity and its running
        // history; rebuilding it here would drop every correction until the
        // model happened to publish the same settings again.
        RTGraph.carryCorrections(from: previous, to: next)
        let handoverRoutes = RoutingEngine.carriedPositions(
            from: activeRoutes, to: routes)
        RTGraph.installStateHandover(
            from: previous, to: next, routeSlots: handoverRoutes)

        _ = yun_rt_cell_publish(cell, UnsafeMutableRawPointer(next))
        RTGraph.recordPublication(of: UnsafePointer(next))
        recordEngineGraphPublicationLocked()
        let retirementFence = yun_rt_cell_retirement_fence(cell)
        graph = next
        alignmentHistories = nextAlignmentHistories
        installActiveRoutes(routes)
        lastConfiguration?.rememberLiveRoutes(routes)
        _ = makeAndPublishEngineUISnapshotLocked()

        precondition(
            retiredGenerations.enqueue(safeAfterCycle: retirementFence) {
                RTGraph.deallocate(previous)
                for history in retiredAlignmentHistories { history.deallocate() }
            })
        return true
    }

    /// Replaces the processing chain without interrupting audio.
    ///
    /// Changing one stage used to tear the aggregate down and build it back:
    /// about 880 ms inside the engine, 645 of it in `AudioDeviceStart` alone,
    /// and seconds end to end once the model's stop-then-start hop is counted.
    /// That is seconds of silence for one switch, and it was the worst
    /// interaction in the application.
    ///
    /// Swapping only the isolation block would not have helped, because the
    /// case that dominates is going from no chain to one stage and back — and
    /// that changes which buffer every route reads, so it is a different graph
    /// rather than a different block. This therefore does what `updateRoutes`
    /// does and is proven by: build the next graph, carry across everything
    /// that belongs to the route, publish it, wait for the realtime thread to
    /// be seen past the swap, then free what it can no longer be holding. The
    /// aggregate, the IOProc and the devices are not touched at all.
    ///
    /// - Parameters:
    ///   - kinds: The stages that should be rendering. Empty takes the chain
    ///     out of the path entirely.
    ///   - plugins: Third-party units, placed as `start` places them. Passed
    ///     again rather than remembered, because a chain rebuilt without them
    ///     would drop somebody's plugin on an unrelated toggle.
    ///   - voiceIsolation: Settings for the dedicated isolation unit, which is
    ///     what runs when isolation is the only stage: it carries a mix and a
    ///     quality that the chain has no way to express.
    /// - Returns: False when there is nothing to swap underneath — no route is
    ///   running, or no aggregate — so the caller can fall back to a restart.
    @discardableResult
    public func updateEffects(
        _ kinds: [EffectKind],
        plugins: [AudioUnitPlugin] = [],
        voiceIsolation: VoiceIsolationSettings? = nil
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        storedEffectUpdateRefusal = nil
        defer { _ = makeAndPublishEngineUISnapshotLocked() }

        do {
            try Self.validateProcessingResources(
                effects: kinds, plugins: plugins, voiceIsolation: voiceIsolation)
        } catch {
            storedEffectUpdateRefusal = .invalidConfiguration(String(describing: error))
            return false
        }

        guard isRunning, let cell = graphCell, let previous = graph,
            aggregate != nil, !activeRoutes.isEmpty,
            let currentProcessingPlan = routeProcessingPlan
        else {
            storedEffectUpdateRefusal = .unavailable
            return false
        }
        let sourceKinds = kinds.filter { $0 != .limiter }
        let isolationOnly = sourceKinds == [.voiceIsolation] && plugins.isEmpty
        let constructsAudioUnits = sourceKinds.contains { !$0.isNative } || !plugins.isEmpty
        guard
            !constructsAudioUnits
                || (BoundedAudioUnitConstructionLane.shared.admitsConstruction
                    && BoundedAudioUnitDisposer.shared.admitsNewGraph)
        else {
            storedEffectUpdateRefusal = .resourcesBusy
            return false
        }
        if !EffectTransition.admitsSuccessor(
            after: effectTransitionController)
        {
            // The audible old path is still an A/B blend. Treating only its B
            // half as the old side of B→C can jump to a path which has never
            // been heard, including a cold latency line full of silence.
            storedEffectUpdateRefusal = .transitionInFlight
            return false
        }
        guard retiredGenerations.prepareForPublication() else {
            storedEffectUpdateRefusal = .resourcesBusy
            return false
        }

        // What the device settled on rather than what was asked for. The cycle
        // drives time constants; the separate ceiling sizes storage. A chain
        // built for only the ordinary cycle can truncate a larger slice after a
        // live device change, while using the ceiling as the cycle would make
        // every release and envelope sixteen times too fast.
        let rate = graphSampleRate
        let cycleFrames = graphBufferFrames
        let maximumFrames = graphMaximumFrames

        // Held so that assigning the new ones below does not release units the
        // IO thread is still rendering through. They go at the end, once the
        // swap has been seen.
        let retiredChain = effectChain
        let retiredUnit = isolationUnit
        let retiredBlock = isolationBlock
        let previousTransitionController = effectTransitionController
        let previousTransitionBlock = effectTransitionBlock
        let previousTransitionOldChain = transitionOldChain
        let previousTransitionOldUnit = transitionOldUnit
        let previousTransitionOldBlock = transitionOldBlock

        // The same split `start` makes: the complete-mix limiter is not part of
        // this mono source chain, and a dedicated unit handles isolation alone.
        var chain: EffectChain?
        var unit: VoiceIsolationUnit?
        var audioUnitPublicationAdmission: AudioUnitGraphAdmissionBox?
        defer { audioUnitPublicationAdmission?.release() }
        if constructsAudioUnits {
            guard let admission = AudioUnitGraphAdmissionBox(waitingUpTo: 2) else {
                storedEffectUpdateRefusal = .resourcesBusy
                return false
            }
            audioUnitPublicationAdmission = admission
        }
        if !sourceKinds.isEmpty || !plugins.isEmpty, !isolationOnly {
            let admission = audioUnitPublicationAdmission
            let result = BoundedAudioUnitConstructionLane.shared.perform { context in
                guard context.mayBeginOperation else { return nil as EffectChain? }
                return EffectChain(
                    kinds: sourceKinds, plugins: plugins, sampleRate: rate,
                    maximumFrames: maximumFrames,
                    teardownDeadline: context.deadline,
                    constructionContext: context,
                    suppliedGraphAdmission: admission)
            }
            if case .completed(let built) = result { chain = built }
            if chain == nil {
                storedIsolationError = IsolationFailure.chainNotBuilt
                if !BoundedAudioUnitConstructionLane.shared.admitsConstruction
                    || !BoundedAudioUnitDisposer.shared.admitsNewGraph
                {
                    storedEffectUpdateRefusal = .resourcesBusy
                    return false
                }
            }
        } else if isolationOnly, let settings = voiceIsolation {
            let admission = audioUnitPublicationAdmission
            let result = BoundedAudioUnitConstructionLane.shared.perform { context in
                guard context.mayBeginOperation else {
                    return nil as VoiceIsolationUnit?
                }
                let built = VoiceIsolationUnit(
                    sampleRate: rate, maximumFrames: maximumFrames,
                    teardownDeadline: context.deadline,
                    constructionContext: context,
                    suppliedGraphAdmission: admission)
                guard let built, context.mayBeginOperation,
                    built.setMix(settings.mixPercent) == noErr,
                    context.mayBeginOperation,
                    built.setHighQuality(settings.isHighQuality) == noErr,
                    context.mayBeginOperation
                else { return nil }
                return built
            }
            if case .completed(let built) = result { unit = built }
            if unit == nil {
                storedIsolationError = IsolationFailure.unitNotInstantiated
                if !BoundedAudioUnitConstructionLane.shared.admitsConstruction
                    || !BoundedAudioUnitDisposer.shared.admitsNewGraph
                {
                    storedEffectUpdateRefusal = .resourcesBusy
                    return false
                }
            }
        }
        let oldLatency = retiredChain?.latencyFrames ?? retiredUnit?.latencyFrames ?? 0
        let newLatency = chain?.latencyFrames ?? unit?.latencyFrames ?? 0
        let maximumLatency = Self.maximumSourceProcessingLatencyFrames(
            sampleRate: rate)
        let requestedLatency = max(oldLatency, newLatency)
        guard
            Self.supportsSourceProcessingLatency(
                requestedLatency, sampleRate: rate)
        else {
            storedIsolationError = IsolationFailure.latencyExceedsRealtimeLimit
            storedEffectUpdateRefusal = .unsupportedLatency(
                requested: requestedLatency, maximum: maximumLatency)
            return false
        }

        // Both stage kinds present the IO thread with the same four things — an
        // opaque pointer, two staging buffers and a block size. Which of the two
        // it is travels separately, in `isolationIsChain`, because they render
        // through different types.
        let stage:
            (
                unit: UnsafeMutableRawPointer,
                input: UnsafeMutablePointer<Float>,
                output: UnsafeMutablePointer<Float>,
                frames: Int,
                isChain: Bool
            )?
        if let chain {
            stage = (
                Unmanaged.passUnretained(chain).toOpaque(), chain.inputBuffer,
                chain.outputBuffer, chain.maximumFrames, true
            )
        } else if let unit {
            stage = (
                Unmanaged.passUnretained(unit).toOpaque(), unit.inputBuffer,
                unit.outputBuffer, unit.maximumFrames, false
            )
        } else {
            stage = nil
        }

        // Isolation is a mono stage fed from the first route's source, exactly
        // as at start. With the canceller in front that source is not in this
        // aggregate at all, so an absent map entry is expected there rather
        // than fatal.
        let microphoneUID = currentProcessingPlan.microphoneDeviceUID
        let isolatedSource = activeRoutes.first?.source ?? currentProcessingPlan.processedSource
        let fromCancelled =
            currentProcessingPlan.echoCancellationActive
            && isolatedSource?.deviceUID == microphoneUID
        let mapped = isolatedSource.flatMap { inputMap[$0] }
        let point = mapped ?? (buffer: Int32(0), channel: Int32(0))
        let canReachSource = fromCancelled || mapped != nil
        // Disabling the final stage still needs one isolated source while the
        // old processed path fades to raw. Keying routes only on the new stage
        // would route around the transition at the exact swap it exists for.
        let isolates = canReachSource && (retiredBlock != nil || stage != nil)
        let nextProcessingPlan = currentProcessingPlan.replacingProcessedSource(
            isolates ? isolatedSource : nil)

        guard
            let rtRoutes = realtimeRoutesLocked(
                activeRoutes, processingPlan: nextProcessingPlan)
        else {
            storedEffectUpdateRefusal = .unavailable
            return false
        }

        // The block is graph-generation storage and must be fresh: the IO
        // thread may still hold the old one, which points at the unit about to
        // retire. The diagnostic counter is route-lifetime storage instead;
        // both sides of a handover publish into it so no failure disappears
        // merely because a control edit crossed the callback.
        var block: UnsafeMutablePointer<RTVoiceIsolation>?
        var failures = isolationFailureCounter
        if let stage, canReachSource {
            guard let maximumFrames32 = Int32(exactly: stage.frames) else {
                storedEffectUpdateRefusal = .unavailable
                return false
            }
            if failures == nil {
                guard let counter = yun_rt_counter_create(0) else {
                    storedEffectUpdateRefusal = .unavailable
                    return false
                }
                failures = counter
            }
            guard let failures else {
                storedEffectUpdateRefusal = .unavailable
                return false
            }

            let allocated = UnsafeMutablePointer<RTVoiceIsolation>.allocate(capacity: 1)
            allocated.initialize(
                to: RTVoiceIsolation(
                    enabled: 1,
                    sourceBuffer: point.buffer,
                    sourceChannel: point.channel,
                    sourceIsCancelled: fromCancelled ? 1 : 0,
                    unit: stage.unit,
                    inputBuffer: stage.input,
                    outputBuffer: stage.output,
                    maximumFrames: maximumFrames32,
                    renderFailures: failures))
            block = allocated
        }

        var transitionController: EffectTransition?
        var transitionBlock: UnsafeMutablePointer<RTEffectTransition>?
        if isolates {
            let controller = EffectTransition(
                sampleRate: rate, oldLatencyFrames: oldLatency,
                newLatencyFrames: newLatency)
            transitionController = controller
            transitionBlock = RTEffectTransition.allocate(
                sourceBuffer: point.buffer,
                sourceChannel: point.channel,
                sourceIsCancelled: fromCancelled,
                oldStage: retiredBlock,
                oldIsChain: retiredChain != nil,
                newStage: block,
                newIsChain: stage?.isChain ?? false,
                controller: controller,
                maximumFrames: maximumFrames,
                oldAlignmentFrames: oldLatency,
                newAlignmentFrames: newLatency)
        }

        guard
            let next = RTGraph.allocateIfSupported(
                routes: rtRoutes, bufferFrames: cycleFrames, sampleRate: rate,
                sharedClock: sharedClock, sharedAnalysisRing: sharedAnalysisRing,
                sharedAlignmentHistories: activeAlignmentHistoriesLocked())
        else {
            storedEffectUpdateRefusal = .unavailable
            return false
        }
        configurePersistentGraphLocked(next)
        if let block, let stage {
            next.pointee.voiceIsolation = block
            next.pointee.isolationIsChain = stage.isChain ? 1 : 0
        }
        next.pointee.effectTransition = transitionBlock

        // Everything `updateRoutes` carries, for the reason it carries it:
        // whatever belongs to the route rather than to this particular graph is
        // silently switched off otherwise.
        next.pointee.outputLimiterPreGain = outputLimiterPreGain
        // The bank and its delay history stay the same; only attenuation is
        // switched. Bypass therefore has the same fixed delay as enabled mode.
        next.pointee.outputLimiterEnabled = kinds.contains(.limiter) ? 1 : 0
        // And every bus's correction. The output map is unchanged by this
        // graph-only swap, so retaining the same bank preserves both its bus
        // identity and the filter history being advanced by the callback.
        RTGraph.carryCorrections(from: previous, to: next)

        // The chain is what decides the alignment, so a chain swap is the one
        // rebuild that can change it. Set before the graph is published, or a
        // cycle would run the new chain against the old compensation.
        next.pointee.alignmentFrames = Int32(
            min(newLatency, RTGraph.maximumAlignmentFrames))
        RTGraph.installStateHandover(
            from: previous, to: next,
            routeSlots: activeRoutes.indices.map(Optional.some))

        _ = yun_rt_cell_publish(cell, UnsafeMutableRawPointer(next))
        RTGraph.recordPublication(of: UnsafePointer(next))
        recordEngineGraphPublicationLocked()
        let retirementFence = yun_rt_cell_retirement_fence(cell)
        graph = next
        routeProcessingPlan = nextProcessingPlan
        outputLimiterIsEnabled = kinds.contains(.limiter)
        lastConfiguration?.rememberLiveEffects(
            kinds, plugins: plugins, voiceIsolation: voiceIsolation)

        effectChain = chain
        isolationUnit = unit
        isolationBlock = block
        isolationFailureCounter = failures
        effectTransitionController = transitionController
        effectTransitionBlock = transitionBlock
        transitionOldChain = transitionBlock == nil ? nil : retiredChain
        transitionOldUnit = transitionBlock == nil ? nil : retiredUnit
        transitionOldBlock = transitionBlock == nil ? nil : retiredBlock
        // Named rather than silently dropped, as at start: a chain that quietly
        // lost a stage sounds different and says nothing about why.
        storedFailedPlugins = chain?.pluginFailures ?? []
        storedSourceProcessingLatencyFrames = ProcessingLatency.sourceStageFrames(
            chainFrames: chain?.latencyFrames,
            isolationFrames: unit?.latencyFrames)
        if let chain {
            storedVoiceIsolationLatencyFrames =
                sourceKinds.contains(.voiceIsolation) ? chain.latencyFrames : 0
        } else {
            storedVoiceIsolationLatencyFrames = unit?.latencyFrames ?? 0
        }
        if let transitionController {
            scheduleEffectTransitionFinalisation(
                transitionController,
                cycleFrames: cycleFrames,
                sampleRate: rate)
        }

        let retainedByNewTransition = transitionBlock != nil
        precondition(
            retiredGenerations.enqueue(safeAfterCycle: retirementFence) {
                RTGraph.deallocate(previous)

                // A previous handover is now beyond the same fence as its
                // graph. Its old path can finally be reclaimed; the current
                // old path moved into the new handover and must survive.
                if let previousTransitionBlock {
                    RTEffectTransition.deallocate(previousTransitionBlock)
                }
                if let previousTransitionOldBlock {
                    previousTransitionOldBlock.deinitialize(count: 1)
                    previousTransitionOldBlock.deallocate()
                }
                // If neither side could be transitioned, the old path was not
                // handed to the new graph and follows its retirement fence.
                if !retainedByNewTransition {
                    if let retiredBlock {
                        retiredBlock.deinitialize(count: 1)
                        retiredBlock.deallocate()
                    }
                }
                var owners: [any AudioUnitTeardownOwner] = []
                if let previousTransitionOldChain {
                    owners.append(previousTransitionOldChain)
                }
                if let previousTransitionOldUnit {
                    owners.append(previousTransitionOldUnit)
                }
                if !retainedByNewTransition {
                    if let retiredChain { owners.append(retiredChain) }
                    if let retiredUnit { owners.append(retiredUnit) }
                }
                let capsule = AudioUnitOwnerCapsule(owners)
                if capsule.audioUnitCount > 0 {
                    BoundedAudioUnitDisposer.shared.disposeAfterFence(capsule)
                }
                withExtendedLifetime(
                    (previousTransitionController, transitionController)
                ) {}
            })
        return true
    }

    // MARK: Live control

    /// Installs the stored mix before a fresh graph is made visible.
    ///
    /// `AudioDeviceStart` can call the IOProc before it returns. Restoring these
    /// values afterwards left at least the first two callbacks at unity and
    /// unmuted — most seriously, a muted microphone could leak during every
    /// restart or clock recovery.
    static func initialisePersistedMixState(
        inputGain: Float, inputMuted: Bool,
        outputGain: Float, outputMuted: Bool,
        on graph: UnsafeMutablePointer<RTGraph>
    ) {
        graph.pointee.inputGain = inputGain
        graph.pointee.inputMuted = inputMuted ? 1 : 0
        graph.pointee.outputGain = outputGain
        graph.pointee.outputMuted = outputMuted ? 1 : 0
        RTGraph.synchroniseGainSlews(on: graph)
    }

    /// Sets a route's gain without interrupting audio.
    ///
    /// The value travels through the lock-free queue and is picked up at the
    /// top of the next cycle, so nothing is rebuilt and nothing blocks.
    @discardableResult
    public func setGain(_ gain: Float, forRouteAt index: Int) -> Bool {
        guard gain.isFinite else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeRoutes.indices.contains(index) else { return false }
        activeRoutes[index].gain = gain
        return push(kind: kYunRTCommandSetGain, index: index, value: gain)
    }

    @discardableResult
    public func setMuted(_ muted: Bool, forRouteAt index: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeRoutes.indices.contains(index) else { return false }
        activeRoutes[index].isMuted = muted
        return push(kind: kYunRTCommandSetMute, index: index, value: muted ? 1 : 0)
    }

    /// Sets a route by topology-stable identity rather than a captured slot.
    ///
    /// A false queue push still leaves the desired value in `activeRoutes`, as
    /// global controls do. A later graph publication or clock recovery will
    /// therefore not resurrect the old value.
    @discardableResult
    public func setGain(_ gain: Float, for key: RouteOccurrenceKey) -> Bool {
        guard gain.isFinite else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let index = activeRouteIndex[key] else { return false }
        activeRoutes[index].gain = gain
        return push(kind: kYunRTCommandSetGain, index: index, value: gain)
    }

    @discardableResult
    public func setMuted(_ muted: Bool, for key: RouteOccurrenceKey) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let index = activeRouteIndex[key] else { return false }
        activeRoutes[index].isMuted = muted
        return push(kind: kYunRTCommandSetMute, index: index, value: muted ? 1 : 0)
    }

    /// Trim on the microphone, ahead of every route that reads it.
    @discardableResult
    public func setInputGain(_ gain: Float) -> Bool {
        guard gain.isFinite else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        inputGain = gain
        return pushGlobal(kind: kYunRTCommandSetInputGain, value: gain)
    }

    @discardableResult
    public func setInputMuted(_ muted: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        isInputMuted = muted
        return pushGlobal(kind: kYunRTCommandSetInputMute, value: muted ? 1 : 0)
    }

    /// The master, over the whole output bus after everything is mixed in.
    @discardableResult
    public func setOutputGain(_ gain: Float) -> Bool {
        guard gain.isFinite else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        outputGain = gain
        return pushGlobal(kind: kYunRTCommandSetOutputGain, value: gain)
    }

    @discardableResult
    public func setOutputMuted(_ muted: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        isOutputMuted = muted
        return pushGlobal(kind: kYunRTCommandSetOutputMute, value: muted ? 1 : 0)
    }

    /// Neither of these carries a route index, so they skip the range check
    /// that `push` does — there is no route to check against.
    private typealias MailboxPublication = (mailbox: OpaquePointer, generation: UInt64)

    private func publishGlobal(
        kind: YunRTCommandKind, value: Float
    ) -> MailboxPublication? {
        guard let graph, let mailbox = graph.pointee.controlMailbox else { return nil }
        guard
            yun_rt_control_mailbox_publish(
                mailbox,
                YunRTCommand(kind: Int32(kind.rawValue), index: 0, value: value))
        else { return nil }
        return (mailbox, yun_rt_control_mailbox_desired_generation(mailbox))
    }

    private func pushGlobal(kind: YunRTCommandKind, value: Float) -> Bool {
        publishGlobal(kind: kind, value: value) != nil
    }

    /// Waits only for a command whose memory-safety follow-up requires proof
    /// that the callback stopped touching a branch. Ordinary controls never
    /// wait; they remain one mailbox publication.
    private func waitForMailbox(
        _ publication: MailboxPublication, timeoutMilliseconds: UInt64
    ) -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        let budget = timeoutMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        let deadline =
            budget.overflow || budget.partialValue > UInt64.max - started
            ? UInt64.max : started + budget.partialValue
        repeat {
            if yun_rt_control_mailbox_applied_generation(publication.mailbox)
                >= publication.generation
            {
                return true
            }
            Thread.sleep(forTimeInterval: 0.000_25)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return yun_rt_control_mailbox_applied_generation(publication.mailbox)
            >= publication.generation
    }

    private func push(kind: YunRTCommandKind, index: Int, value: Float) -> Bool {
        guard let graph, let mailbox = graph.pointee.controlMailbox,
            index >= 0, index < Int(graph.pointee.routeCount)
        else { return false }
        return yun_rt_control_mailbox_publish(
            mailbox,
            YunRTCommand(kind: Int32(kind.rawValue), index: Int32(index), value: value))
    }

    /// Turns on the process-wide allocation tripwire.
    ///
    /// A measurement which failed to arm must never return a persuasive zero.
    /// The non-trapping form is for the interactive diagnostics switch, which
    /// can decline while Instruments owns the allocator logger.
    public static func tryEnableAllocationTripwire() -> Bool {
        yun_rt_tripwire_enable()
    }

    public static func enableAllocationTripwire() {
        precondition(
            tryEnableAllocationTripwire(),
            "the allocation tripwire cannot replace an existing allocator logger")
    }

    /// Takes the hook back out. Worth doing: it is process-wide, so while it is
    /// installed every allocation anywhere in the process goes through it.
    public static func disableAllocationTripwire() { yun_rt_tripwire_disable() }

    /// True when this is an unoptimised build, in which case the violation
    /// count is Swift's own bounds and exclusivity machinery rather than
    /// anything about the code that ships, and says nothing.
    public static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    /// Allocations seen on the IO thread. Any non-zero value is a bug in the
    /// realtime path, not a tuning opportunity.
    public static var allocationViolations: UInt64 { yun_rt_tripwire_violations() }

    public struct SelftestCaptureSnapshot: Sendable {
        /// Route owner identity retained for command-line compatibility.
        public let generation: UInt64
        /// Exact graph which produced the fixed capture prefix.
        public let graphGeneration: UInt64
        public let lease: SelftestCaptureLease
    }

    public enum SelftestCaptureRead: Sendable {
        case available(SelftestCaptureSnapshot)
        case busy
        case unavailable
    }

    /// Takes one owned capture without waiting behind an engine lifecycle.
    ///
    /// The lease records only an acquire-observed fixed prefix and retains its
    /// raw owner. Copying the bounded one-megabyte allocation and evaluating it
    /// both happen after this method has released the engine lock.
    public func captureSelftest() -> SelftestCaptureRead {
        guard stateLock.try() else { return .busy }
        guard let selftestOwner, let selftestBlock else {
            stateLock.unlock()
            return .unavailable
        }
        let capacity = max(0, Int(selftestBlock.pointee.captureCapacity))
        let published = yun_rt_counter_load(selftestBlock.pointee.captureCount)
        let count = Int(min(published, UInt64(capacity)))
        let startFrame =
            count > 0 ? selftestBlock.pointee.captureStartFrame.pointee : 0
        let generation = routeLifetimeGeneration
        let graphGeneration = graphPublicationGeneration
        stateLock.unlock()
        return .available(
            SelftestCaptureSnapshot(
                generation: generation,
                graphGeneration: graphGeneration,
                lease: SelftestCaptureLease(
                    owner: selftestOwner, startFrame: startFrame,
                    capturedFrames: count)))
    }

    /// Grades the loopback capture against what was generated.
    ///
    /// Kept for command-line callers. The application uses captureSelftest and
    /// its bounded diagnostic worker so the expensive comparison never runs on
    /// MainActor or while the engine lock is held.
    public func evaluateSelftest() -> SelftestResult? {
        guard case let .available(snapshot) = captureSelftest() else { return nil }
        return snapshot.lease.capture().evaluate(
            sampleRate: pathQuality?.sampleRate ?? SelftestCapture.assumedSampleRate)
    }

    public enum SelftestProgressRead: Equatable, Sendable {
        case available(
            generation: UInt64,
            graphGeneration: UInt64,
            fraction: Double
        )
        case busy
        case unavailable
    }

    /// How much of the capture buffer has been filled, without inventing zero
    /// when graph publication currently owns the lock.
    public func readSelftestProgress() -> SelftestProgressRead {
        guard stateLock.try() else { return .busy }
        defer { stateLock.unlock() }
        guard let selftestBlock else { return .unavailable }
        let capacity = Double(selftestBlock.pointee.captureCapacity)
        guard capacity > 0 else { return .unavailable }
        let published = Double(yun_rt_counter_load(selftestBlock.pointee.captureCount))
        return .available(
            generation: routeLifetimeGeneration,
            graphGeneration: graphPublicationGeneration,
            fraction: min(1, max(0, published / capacity)))
    }

    /// Compatibility for command-line polling. The application consumes the
    /// typed read above and retains its last complete value through contention.
    public var selftestProgress: Double {
        guard case let .available(_, _, fraction) = readSelftestProgress() else { return 0 }
        return fraction
    }

    /// Waits for the loopback capture to fill, or gives up.
    ///
    /// Deliberately not an open loop. The capture only fills if the destination
    /// has an input to read back from; when it has none — a pair of speakers, a
    /// Bluetooth headset, a display — nothing ever arrives and the obvious
    /// `while progress < 1` never ends. That is not hypothetical: it held this
    /// project's own command line for thirty-one minutes before anybody noticed,
    /// printing 0% every quarter second.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait in total. The capture is a fixed number of
    ///     frames, so a generous multiple of the time it should take is the
    ///     right shape of limit.
    ///   - poll: How often to check progress.
    ///   - onProgress: Called on each poll, for a caller that wants to say so.
    /// - Returns: True when the capture filled. False means it stalled, and the
    ///   caller should say that rather than grading whatever partial data
    ///   arrived.
    @discardableResult
    public func awaitSelftest(
        timeout: TimeInterval = 30, poll: TimeInterval = 0.25,
        onProgress: (Double) -> Void = { _ in }
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastProgress = selftestProgress
        var lastMovement = Date()
        while selftestProgress < 1.0 {
            if Date() >= deadline { return false }
            // A capture that has stopped moving has stopped for good — the
            // loopback is not carrying anything — so there is no reason to sit
            // out the whole timeout once that is established.
            if selftestProgress > lastProgress {
                lastProgress = selftestProgress
                lastMovement = Date()
            } else if Date().timeIntervalSince(lastMovement) > 5 {
                return false
            }
            Thread.sleep(forTimeInterval: poll)
            onProgress(selftestProgress)
        }
        return true
    }

    /// Clears the latch so a future start may attempt clock locking again.
    public func allowClockLockRetry() {
        stateLock.lock()
        defer { stateLock.unlock() }
        clockLockAbandoned = false
    }

    // MARK: Channel mapping

    /// Works out which IOProc buffer and channel each device channel lands on.
    ///
    /// An aggregate concatenates its members' streams in sub-device order, so
    /// the mapping has to be derived rather than assumed — the Seiren exposes
    /// three channels on one stream, BlackHole sixteen on another.
    private func buildChannelMaps(
        aggregate: AggregateDevice, members: [AudioDevice], taps: [ProcessTap]
    ) throws {
        guard let aggregateDevice = aggregate.device else {
            throw RoutingError.aggregateUnavailable
        }

        // Duplicates kept rather than trapped. `members` is source, destination
        // and extras, and those can name the same device — the application
        // guards against it for a route, but nothing does for a tap, and
        // `yunaudio-cli tap` with the YunAudio device as the system input died
        // in `Dictionary(uniqueKeysWithValues:)` with "Duplicate values for key".
        // A device listed twice is still that device, so there is nothing to
        // decide between; trapping on it is the one wrong answer.
        let byUID = Dictionary(
            members.map { ($0.uid, $0) },
            uniquingKeysWith: { first, _ in first })

        // Taps are appended after the sub-devices on the input side, in the
        // order they were listed, and contribute no output channels. A tap's
        // channels are addressed with its UID as the device reference, so a
        // route can name an application exactly as it names a microphone.
        let inputUIDs = aggregate.subDevices.map(\.uid) + taps.map(\.uid)
        var tapChannelPairs: [(String, Int)] = []
        tapChannelPairs.reserveCapacity(taps.count)
        for tap in taps {
            guard
                let channels = AudioProcessingContract.admittedChannelCount(
                    tap.format?.mChannelsPerFrame ?? 2),
                channels > 0
            else { throw RoutingError.aggregateUnavailable }
            tapChannelPairs.append((tap.uid, channels))
        }
        let tapChannels = Dictionary(
            tapChannelPairs,
            uniquingKeysWith: { first, _ in first })

        let inputStreams = aggregateDevice.inputStreams
        let outputStreams = aggregateDevice.outputStreams
        let outputUIDs = aggregate.subDevices.map(\.uid)
        guard
            let nextInputMap = Self.map(
                streams: inputStreams,
                orderedUIDs: inputUIDs,
                channelCount: {
                    byUID[$0]?.inputChannels ?? tapChannels[$0] ?? 0
                }),
            let nextOutputMap = Self.map(
                streams: outputStreams,
                orderedUIDs: outputUIDs,
                channelCount: { byUID[$0]?.outputChannels ?? 0 })
        else { throw RoutingError.aggregateUnavailable }
        let nextOutputChannelCounts = outputStreams.map {
            $0.currentPhysicalFormat?.channels ?? 0
        }
        guard
            AudioProcessingContract.admittedChannelTotal(
                nextOutputChannelCounts) != nil
        else { throw RoutingError.aggregateUnavailable }

        // What the aggregate publishes, against what the members claim.
        //
        // `map` walks the members in order and takes `inputChannels` channels
        // each out of one flat run of stream channels, so the two totals have to
        // agree or every member after the disagreement is offset by the
        // difference. Printed rather than assumed, because the difference is
        // invisible from either side on its own.
        if ProcessInfo.processInfo.environment["YUNAUDIO_CHANNEL_MAP"] != nil {
            var report = "channel map\n  input streams:"
            for (index, stream) in inputStreams.enumerated() {
                report +=
                    "\n    [\(index)] starting \(stream.startingChannel)"
                    + " × \(stream.currentPhysicalFormat?.channels ?? 0)"
            }
            report += "\n  members claim:"
            for uid in inputUIDs {
                let claimed = byUID[uid]?.inputChannels ?? tapChannels[uid] ?? 0
                report += "\n    \(byUID[uid]?.name ?? uid): \(claimed)"
            }
            let published = inputStreams.reduce(0) {
                $0 + ($1.currentPhysicalFormat?.channels ?? 0)
            }
            let claimed = inputUIDs.reduce(0) {
                $0 + (byUID[$1]?.inputChannels ?? tapChannels[$1] ?? 0)
            }
            report += "\n  published \(published), claimed \(claimed)"
            FileHandle.standardError.write(Data((report + "\n").utf8))
        }
        inputMap = nextInputMap
        outputMap = nextOutputMap
        outputChannelCounts = nextOutputChannelCounts
    }

    private static func map(
        streams: [AudioStream],
        orderedUIDs: [String],
        channelCount: (String) -> Int
    ) -> [ChannelRef: (buffer: Int32, channel: Int32)]? {
        var layouts: [ChannelStreamLayout] = []
        layouts.reserveCapacity(streams.count)
        for (index, stream) in streams.enumerated() {
            guard let buffer = Int32(exactly: index) else { return nil }
            layouts.append(
                ChannelStreamLayout(
                    buffer: buffer,
                    startingChannel: stream.startingChannel,
                    channelCount: stream.currentPhysicalFormat?.channels ?? 0))
        }
        return map(
            streamLayouts: layouts,
            orderedUIDs: orderedUIDs,
            channelCount: channelCount)
    }

    /// Admits both the published and claimed sides before either becomes a
    /// loop bound or an Int32 buffer offset.
    static func supportsChannelMap(
        streamLayouts: [ChannelStreamLayout], orderedChannelCounts: [Int]
    ) -> Bool {
        guard
            streamLayouts.allSatisfy({
                $0.buffer >= 0 && $0.startingChannel >= 0
                    && AudioProcessingContract.admittedChannelCount($0.channelCount) != nil
            }),
            AudioProcessingContract.admittedChannelTotal(
                streamLayouts.map(\.channelCount)) != nil,
            AudioProcessingContract.admittedChannelTotal(
                orderedChannelCounts) != nil
        else { return false }
        return true
    }

    /// Maps logical member channels onto the buffers CoreAudio will hand over.
    ///
    /// `kAudioStreamPropertyStartingChannel` is the ordering fact. HAL does not
    /// promise that the stream-object array itself is ordered, and a disabled
    /// or reserved pair can leave a gap between two starting-channel values.
    /// Flattening the array in enumeration order silently swaps those streams.
    static func map(
        streamLayouts: [ChannelStreamLayout],
        orderedUIDs: [String],
        channelCount: (String) -> Int
    ) -> [ChannelRef: (buffer: Int32, channel: Int32)]? {
        let orderedChannelCounts = orderedUIDs.map(channelCount)
        guard
            supportsChannelMap(
                streamLayouts: streamLayouts,
                orderedChannelCounts: orderedChannelCounts)
        else { return nil }

        // Slots remain tied to the original AudioBufferList index while their
        // ordering follows the owning device's one-based channel numbers.
        let orderedStreams =
            streamLayouts
            .filter { $0.startingChannel > 0 && $0.channelCount > 0 }
            .sorted {
                if $0.startingChannel == $1.startingChannel {
                    return $0.buffer < $1.buffer
                }
                return $0.startingChannel < $1.startingChannel
            }

        var result: [ChannelRef: (buffer: Int32, channel: Int32)] = [:]
        var streamIndex = 0
        var channelInStream = 0

        for (uid, count) in zip(orderedUIDs, orderedChannelCounts) {
            for channel in 0..<count {
                while streamIndex < orderedStreams.count,
                    channelInStream >= orderedStreams[streamIndex].channelCount
                {
                    streamIndex += 1
                    channelInStream = 0
                }
                guard streamIndex < orderedStreams.count else { break }
                let stream = orderedStreams[streamIndex]
                guard let offset = Int32(exactly: channelInStream) else { return nil }
                result[ChannelRef(deviceUID: uid, channel: channel)] =
                    (buffer: stream.buffer, channel: offset)
                channelInStream += 1
            }
        }
        return result
    }

    // MARK: Introspection

    /// One coherent set of values consumed by the interface's meter tick.
    ///
    /// Nil means the graph owner is busy, not that the signal or its diagnostics
    /// became empty. Keeping that distinction in the type prevents a graph swap
    /// from publishing a false zero frame between two real readings.
    public struct TelemetrySnapshot: Sendable, Equatable {
        public let routePeaks: [Float]
        public let outputPeak: Float
        public let outputClippedSamples: UInt64
        public let failedPlugins: [AudioUnitLoadFailure]
        public let droppedMonitor: DroppedMonitor?
    }

    /// The scalar half of one interface telemetry read.
    ///
    /// Route peaks are written into storage owned by the caller. Keeping the
    /// array outside this value lets a twenty-hertz consumer reuse two buffers
    /// instead of allocating a fresh array on every poll.
    public struct TelemetryValues: Sendable, Equatable {
        public let cycleCount: UInt64?
        public let outputPeak: Float
        public let outputClippedSamples: UInt64
        public let failedPlugins: [AudioUnitLoadFailure]
        public let droppedMonitor: DroppedMonitor?
        public let echoCancellationStatus: EchoCancellationStatus?
    }

    /// Reads interface telemetry into reusable caller-owned route storage.
    ///
    /// The buffer is left untouched when the engine lock is busy, so holding
    /// the last complete frame remains the contract. Once its capacity has
    /// reached the route count, a steady topology needs no collection
    /// allocation here. With sixteen routes, 10,000 Release reads measured
    /// **20,000 allocations / 1,055,250 ns** through the snapshot API and
    /// **0 allocations / 437,042 ns** through this reusable boundary.
    public func readTelemetry(into routePeaks: inout [Float]) -> TelemetryValues? {
        guard stateLock.try() else { return nil }
        defer { stateLock.unlock() }

        let count = graph.map { Int($0.pointee.routeCount) } ?? 0
        if telemetryPeakScratch.count != count {
            telemetryPeakScratch = [Float](repeating: 0, count: count)
        }
        var outputPeak: Float = 0
        var outputClipped: UInt64 = 0
        if let graph {
            let loaded = telemetryPeakScratch.withUnsafeMutableBufferPointer { peaks in
                yun_rt_telemetry_load(
                    graph.pointee.telemetry,
                    peaks.baseAddress, nil, nil, nil, UInt32(count),
                    &outputPeak, &outputClipped, nil)
            }
            guard loaded else { return nil }
        }
        routePeaks.removeAll(keepingCapacity: true)
        routePeaks.reserveCapacity(count)
        routePeaks.append(contentsOf: telemetryPeakScratch)
        return TelemetryValues(
            cycleCount: graphCell.map { yun_rt_cell_cycles($0) },
            outputPeak: outputPeak,
            outputClippedSamples: outputClipped,
            failedPlugins: storedFailedPlugins,
            droppedMonitor: storedDroppedMonitor,
            echoCancellationStatus: echoCancellationStatusLocked())
    }

    /// Reads every interface value under one non-blocking lock acquisition.
    public var telemetrySnapshotIfAvailable: TelemetrySnapshot? {
        var peaks: [Float] = []
        guard let values = readTelemetry(into: &peaks) else { return nil }
        return TelemetrySnapshot(
            routePeaks: peaks,
            outputPeak: values.outputPeak,
            outputClippedSamples: values.outputClippedSamples,
            failedPlugins: values.failedPlugins,
            droppedMonitor: values.droppedMonitor)
    }

    /// Installs numeric state without constructing audio hardware.
    ///
    /// Test support for the snapshot boundary above. A non-zero fixture matters:
    /// otherwise nil accidentally being replaced with an empty snapshot would
    /// satisfy the test for the same wrong reason it made meters blink.
    func installTelemetryForTesting(_ snapshot: TelemetrySnapshot) {
        stateLock.lock()
        defer { stateLock.unlock() }
        precondition(graph == nil)
        let routes = snapshot.routePeaks.map { _ in
            RTRoute(
                sourceBuffer: 0, sourceChannel: 0,
                destinationBuffer: 0, destinationChannel: 0)
        }
        let installed = RTGraph.allocate(routes: routes, bufferFrames: 64)
        for (index, peak) in snapshot.routePeaks.enumerated() {
            installed.pointee.peaks[index] = peak
        }
        installed.pointee.outputPeak = snapshot.outputPeak
        installed.pointee.outputClipped = snapshot.outputClippedSamples
        RTGraph.publishTelemetry(installed)
        graph = installed
        storedFailedPlugins = snapshot.failedPlugins
        storedDroppedMonitor = snapshot.droppedMonitor
    }

    /// Loudest sample leaving on the destination bus, after every gain stage.
    ///
    /// The one number that says whether what the far end receives is too quiet,
    /// about right, or already damaged. Nothing else in the engine measures
    /// after the multiply.
    public var outputPeak: Float {
        guard stateLock.try() else { return 0 }
        defer { stateLock.unlock() }
        guard let graph else { return 0 }
        var value: Float = 0
        guard
            yun_rt_telemetry_load(
                graph.pointee.telemetry, nil, nil, nil, nil, 0,
                &value, nil, nil)
        else { return 0 }
        return value
    }

    /// Samples that reached or passed full scale on the destination bus since
    /// routing started.
    public var outputClippedSamples: UInt64 {
        guard stateLock.try() else { return 0 }
        defer { stateLock.unlock() }
        guard let graph else { return 0 }
        var value: UInt64 = 0
        guard
            yun_rt_telemetry_load(
                graph.pointee.telemetry, nil, nil, nil, nil, 0,
                nil, &value, nil)
        else { return 0 }
        return value
    }

    /// Clears the clip count, so a latch can be reset without restarting.
    public func clearOutputClipping() {
        stateLock.lock()
        defer { stateLock.unlock() }
        outputClippingEpoch &+= 1
        if outputClippingEpoch == 0 { outputClippingEpoch = 1 }
        _ = pushGlobal(
            kind: kYunRTCommandClearOutputClipping,
            value: Float(bitPattern: outputClippingEpoch))
    }

    // MARK: Calibration

    public enum CalibrationMutationResult: Equatable, Sendable {
        case applied
        case revoked
        case routeUnavailable
        case publicationFailed
    }

    /// Applies one desired calibration state only if its generation is current.
    ///
    /// The permit is checked after taking the lifecycle lock and immediately
    /// before mutation. A Cancel submitted while Begin waits for Core Audio
    /// therefore wins without briefly resurrecting calibration.
    public func setCalibrationActive(
        _ active: Bool, ifCurrent: @Sendable () -> Bool
    ) -> CalibrationMutationResult {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard ifCurrent() else { return .revoked }
        if !active {
            calibrationIsActive = false
            guard graph != nil else { return .applied }
            return pushGlobal(kind: kYunRTCommandSetCalibrating, value: 0)
                ? .applied : .publicationFailed
        }
        guard let graph else { return .routeUnavailable }
        calibrationIsActive = true
        calibrationEpoch &+= 1
        if calibrationEpoch == 0 { calibrationEpoch = 1 }
        calibrationSnapshot = Array(
            repeating: (energy: 0, frames: 0),
            count: Int(graph.pointee.routeCount))
        publishedSnapshotLock.withLock {
            publishedCalibrationSnapshot = calibrationSnapshot
        }
        if pushGlobal(
            kind: kYunRTCommandSetCalibrating,
            value: Float(bitPattern: calibrationEpoch)) == false
        {
            calibrationIsActive = false
            return .publicationFailed
        }
        return .applied
    }

    /// Starts accumulating per-source energy. Clears whatever was there.
    public func beginCalibration() {
        _ = setCalibrationActive(true, ifCurrent: { true })
    }

    public func endCalibration() {
        _ = setCalibrationActive(false, ifCurrent: { true })
    }

    /// Gated RMS in dBFS and the seconds behind it, per route.
    public func calibrationLevels(sampleRate: Double) -> [(decibels: Double, seconds: Double)] {
        guard sampleRate > 0 else { return [] }
        guard stateLock.try() else {
            let snapshot = publishedSnapshotLock.withLock { publishedCalibrationSnapshot }
            return Self.calibrationLevels(from: snapshot, sampleRate: sampleRate)
        }
        defer { stateLock.unlock() }
        guard let graph else { return [] }
        let count = Int(graph.pointee.routeCount)
        var energy = [Double](repeating: 0, count: count)
        var frames = [UInt64](repeating: 0, count: count)
        let loaded = energy.withUnsafeMutableBufferPointer { energy in
            frames.withUnsafeMutableBufferPointer { frames in
                yun_rt_telemetry_load(
                    graph.pointee.telemetry, nil, nil,
                    energy.baseAddress, frames.baseAddress, UInt32(count),
                    nil, nil, nil)
            }
        }
        if loaded {
            calibrationSnapshot = (0..<count).map {
                (energy: energy[$0], frames: frames[$0])
            }
            publishedSnapshotLock.withLock {
                publishedCalibrationSnapshot = calibrationSnapshot
            }
        }
        let snapshot =
            calibrationSnapshot.count == count
            ? calibrationSnapshot
            : Array(repeating: (energy: 0, frames: 0), count: count)
        return Self.calibrationLevels(from: snapshot, sampleRate: sampleRate)
    }

    private static func calibrationLevels(
        from snapshot: [(energy: Double, frames: UInt64)], sampleRate: Double
    ) -> [(decibels: Double, seconds: Double)] {
        return snapshot.map { value in
            let frames = value.frames
            guard frames > 0 else { return (-Double.infinity, 0) }
            let mean = value.energy / Double(frames)
            let decibels = mean > 0 ? 10 * log10(mean) : -.infinity
            return (decibels, Double(frames) / sampleRate)
        }
    }

    /// Installs the last complete calibration frame without audio hardware.
    func installCalibrationSnapshotForTesting(
        _ snapshot: [(energy: Double, frames: UInt64)]
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        calibrationSnapshot = snapshot
        publishedSnapshotLock.withLock {
            publishedCalibrationSnapshot = snapshot
        }
    }

    /// Smoothed RMS per route. Closer to how loud something sounds than the
    /// peak beside it.
    /// Per-route levels, read from the interface twenty times a second.
    ///
    /// **Taken under the lock, or not taken.** These dereference the graph the
    /// engine queue is free to free: `stop` and every rebuild release it, and a
    /// read that arrives in between is a use-after-free. It is not theoretical
    /// — two segfaults in one afternoon, one here and one in the IO thread's
    /// ring write, with the crash reports to match.
    ///
    /// Not the ordinary lock, for the reason `echoCancellationStatus` explains
    /// at length: `startAttempt` holds it across a synchronous message to
    /// `coreaudiod`, which is unbounded when the audio server is wedged, and
    /// blocking here would freeze the interface for as long as that took. A
    /// meter that holds its last value for one frame of a rebuild is not worth
    /// a frozen application — and it is what the meter did anyway, because the
    /// levels it is reading are a decaying peak hold.
    public var routeRMS: [Float] {
        guard stateLock.try() else { return [] }
        defer { stateLock.unlock() }
        guard let graph else { return [] }
        let count = Int(graph.pointee.routeCount)
        var values = [Float](repeating: 0, count: count)
        let loaded = values.withUnsafeMutableBufferPointer {
            yun_rt_telemetry_load(
                graph.pointee.telemetry, nil, $0.baseAddress, nil, nil,
                UInt32(count), nil, nil, nil)
        }
        return loaded ? values : []
    }

    /// Peak magnitude of each active route since the last read.
    public var routePeaks: [Float] {
        guard stateLock.try() else { return [] }
        defer { stateLock.unlock() }
        guard let graph else { return [] }
        let count = Int(graph.pointee.routeCount)
        var values = [Float](repeating: 0, count: count)
        let loaded = values.withUnsafeMutableBufferPointer {
            yun_rt_telemetry_load(
                graph.pointee.telemetry, $0.baseAddress, nil, nil, nil,
                UInt32(count), nil, nil, nil)
        }
        return loaded ? values : []
    }

    /// Number of IO cycles completed, or nil when nobody could answer.
    ///
    /// The distinction matters and cost a day of chasing a bug that was not
    /// there. Zero means three different things here: the route is not running,
    /// the cell has just been freed and its replacement has not counted a cycle
    /// yet, and — the one that bites — the lock was held by the engine queue at
    /// the moment of asking. It is taken with `try` rather than waited on
    /// because the alternative is an interface that freezes for as long as
    /// `coreaudiod` takes, so a contended read is normal rather than
    /// exceptional.
    ///
    /// A meter can treat all three as "nothing to show". A check asking whether
    /// audio survived a device change cannot: comparing a real count against a
    /// non-answer is how a route that was running perfectly well, carrying a
    /// tone the very next assertion measured at −6 dBFS, was reported as
    /// stalled.
    public var cycleCountIfKnown: UInt64? {
        // The cell too: `stop` frees it, and this is read from the interface
        // and from every check that asks whether audio is flowing.
        guard stateLock.try() else { return nil }
        defer { stateLock.unlock() }
        return graphCell.map { yun_rt_cell_cycles($0) }
    }

    /// Whether there is a realtime graph behind the router at all.
    ///
    /// The one honest answer to "is audio flowing". `RouterModel.isRunning` is
    /// the model's own belief and the two were caught disagreeing — the
    /// interface showing a running route with two cables while this was false.
    public var hasLiveGraph: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return graphCell != nil
    }

    /// Why the count could not be read, when it could not.
    ///
    /// `cycleCountIfKnown` answers nil for two unrelated reasons and the caller
    /// cannot tell them apart: the state lock was busy, or there is no graph
    /// cell to read. They are different faults with different fixes — one is
    /// contention, the other is a route that is not running — and after a
    /// patching edit the flow check sees nil on nearly every one of seventy-five
    /// attempts across a second and a half, which neither explanation obviously
    /// accounts for.
    public enum CycleCountRefusal: String, Sendable {
        case lockBusy
        case noCell
        case readable
    }

    /// Whether the sole audio-unit disposer would admit a new route right now.
    ///
    /// False while owners it queued behind a graph admission are still waiting
    /// — which is the state a deferred teardown leaves, and the one a Stop
    /// retry needs to see clear before it can finish. Exposed so the flow check
    /// can ask whether the deferral resolves once nothing else is building,
    /// rather than leaving that to be reasoned about.
    public var audioUnitDisposerAdmitsNewGraph: Bool {
        BoundedAudioUnitDisposer.shared.admitsNewGraph
    }

    /// How many owners the disposer is still holding for deferred disposal.
    public var audioUnitDisposerPendingOwners: Int {
        BoundedAudioUnitDisposer.shared.pendingOwnerCount
    }

    /// Where the running chain's latency comes from, by stage.
    ///
    /// Summed, this is what the router already reported; broken down, it says
    /// which switch is buying it. A pitch shifter set to no shift is
    /// bit-transparent and still reports 4096 frames, and nothing above here
    /// could see that.
    public var effectLatencyByStage: [EffectKind: Int] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return effectChain?.latencyByStage ?? [:]
    }

    public var whyCycleCountIsUnknown: CycleCountRefusal {
        guard stateLock.try() else { return .lockBusy }
        defer { stateLock.unlock() }
        return graphCell == nil ? .noCell : .readable
    }

    /// Number of IO cycles completed. A stalled counter means the device is not
    /// actually pulling audio.
    ///
    /// For anything that wants a number to show. Anything comparing two
    /// readings wants `cycleCountIfKnown`.
    public var cycleCount: UInt64 { cycleCountIfKnown ?? 0 }

    /// The clock master's most recent timestamp, read through the cycle counter
    /// as a sequence number so a half-updated pair is never published.
    public var masterClockAnchor: ClockAnchor? {
        guard stateLock.try() else { return nil }
        defer { stateLock.unlock() }
        guard let sharedClock, isRunning else { return nil }
        let rate = aggregate?.device?.currentSampleRate ?? 0
        guard rate > 0 else { return nil }
        return Self.anchor(from: sharedClock, sampleRate: rate)
    }

    /// Reads one coherent anchor pair from the bounded C atomic seqlock.
    static func anchor(
        from clock: RTGraph.SharedClock, sampleRate: Double
    ) -> ClockAnchor? {
        var sampleTime = 0.0
        var hostTime: UInt64 = 0
        guard yun_rt_clock_load(clock.storage, &sampleTime, &hostTime), hostTime != 0 else {
            return nil
        }
        return ClockAnchor(
            sampleTime: sampleTime, hostTime: hostTime, sampleRate: sampleRate)
    }

    /// Lock state and rate from one lifetime-safe publisher observation.
    ///
    /// `clockPublisher` is cleared after its queue drains during Stop. Reading
    /// that Optional without `stateLock` raced both the nil write and release;
    /// waiting for the lock instead would put the interface behind a blocking
    /// HAL teardown. A try-lock produces a fresh coherent pair when possible
    /// and otherwise returns the last pair already copied out of the owner.
    public var clockTelemetry: ClockTelemetry {
        guard stateLock.try() else {
            return publishedSnapshotLock.withLock { publishedClockTelemetry }
        }
        defer { stateLock.unlock() }
        return clockTelemetryLocked()
    }

    private func clockTelemetryLocked() -> ClockTelemetry {
        let telemetry = clockPublisher?.telemetry
        let snapshot =
            telemetry.map {
                ClockTelemetry(isLocked: $0.isLocked, rateRatio: $0.rateRatio)
            } ?? .unlocked
        publishedSnapshotLock.withLock {
            publishedClockTelemetry = snapshot
        }
        return snapshot
    }

    /// True when the destination is our own driver and it has confirmed that it
    /// is following the master's clock.
    public var isClockLocked: Bool { clockTelemetry.isLocked }

    /// How far the master's crystal is from its nominal rate, as a ratio.
    public var measuredRateRatio: Double { clockTelemetry.rateRatio }

    public var pathQuality: PathQuality? {
        // Polled by the interface. A route rebuild can hold the state lock
        // across CoreAudio work, so retain the last published answer instead of
        // freezing a frame or reading a graph that is being retired.
        guard stateLock.try() else { return nil }
        defer { stateLock.unlock() }
        guard let aggregate, let device = aggregate.device else { return nil }
        let drifted = aggregate.driftCorrectedUIDs
        // The destination's own level control counts as processing. Ours has
        // one now — the volume keys reach it, and so does anyone else — and a
        // path that called itself bit-exact while the device attenuated it on
        // the way out would be claiming something false.
        let attenuated =
            destinationDevice?.alters(scope: kAudioObjectPropertyScopeInput) ?? false
        let processing =
            isolationUnit != nil || effectChain != nil
            || graph?.pointee.outputLimiterEnabled != 0 || attenuated
        let clockTelemetry = clockTelemetryLocked()
        let quality = PathQuality(
            // Nothing is being drift-corrected, nothing is processing the
            // signal, and where the first was only true because the driver
            // locks its own clock, the lock is confirmed to be holding. These
            // are facts we configured or read back — but "nothing is configured
            // to alter the signal" is still weaker than "the samples came back
            // identical", which is what --selftest is for. The final bank's
            // fixed bypass delay does not count as processing here: it moves
            // samples in time but returns their Float values bit for bit, and
            // its 48 frames are always published separately as output latency.
            isBitExact: drifted.isEmpty && !processing
                && (requiresClockLock ? clockTelemetry.isLocked : true),
            hasProcessing: processing,
            isClockLocked: clockTelemetry.isLocked,
            measuredRateRatio: clockTelemetry.rateRatio,
            driftCorrectedDeviceUIDs: drifted,
            hasSampleRateMismatch: sampleRateMismatch,
            bufferFrames: Int(device.currentBufferFrameSize ?? 0),
            sampleRate: device.currentSampleRate ?? 0)
        incidentRecorder?.recordPathReportedBitExact(quality.isBitExact)
        return quality
    }
}

/// One CoreAudio stream's position in an IOProc `AudioBufferList`.
///
/// Separate from `AudioStream` so ordering and gap behaviour can be proved
/// without constructing HAL objects.
struct ChannelStreamLayout: Sendable, Equatable {
    let buffer: Int32
    let startingChannel: Int
    let channelCount: Int
}

public enum RoutingError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case channelNotFound(ChannelRef, isInput: Bool)
    case noCommonSampleRate
    case aggregateUnavailable
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)
    case noIOCycles
    case clockPublisherFailedToStart
    case echoCancellerFailed
    case outputLimiterUnavailable
    case realtimeStorageUnavailable
    case sourceProcessingLatencyExceedsLimit(requested: Int, maximum: Int)
    case routeTopologyExceedsLimit(requested: Int, maximum: Int)
    case startResourceExceedsLimit(resource: String, requested: Int, maximum: Int)
    case invalidStartConfiguration(String)
    case bufferFrameSizeExceedsLimit(requested: UInt32, maximum: Int)
    case unsupportedSampleRate(requested: Double, minimum: Double, maximum: Double)
    case teardownIncomplete(RoutingTeardownResult)
    case audioResiduePresent(AudioResidueTelemetry)
    case audioServerHealthUnavailable

    public var description: String {
        switch self {
        case let .deviceNotFound(uid):
            "no audio device with UID \(uid)"
        case let .channelNotFound(ref, isInput):
            "\(isInput ? "input" : "output") channel \(ref.channel) of \(ref.deviceUID) is not part of the aggregate"
        case .noCommonSampleRate:
            "the selected devices share no sample rate"
        case .aggregateUnavailable:
            "the aggregate device could not be inspected after creation"
        case let .ioProcFailed(status):
            "AudioDeviceCreateIOProcID failed with \(fourCharDescription(status))"
        case let .startFailed(status):
            "AudioDeviceStart failed with \(fourCharDescription(status))"
        case .noIOCycles:
            "AudioDeviceStart returned success but no IO cycle ran within 750 ms"
        case .clockPublisherFailedToStart:
            "the driver clock publisher could not start within its teardown deadline"
        case .echoCancellerFailed:
            "the echo canceller could not take the microphone and the speaker"
        case .outputLimiterUnavailable:
            "the final output limiter could not be prepared for this device layout"
        case .realtimeStorageUnavailable:
            "realtime diagnostic storage could not be allocated"
        case let .sourceProcessingLatencyExceedsLimit(requested, maximum):
            "the processing chain reports \(requested) frames of latency; this route can align at most \(maximum)"
        case let .routeTopologyExceedsLimit(requested, maximum):
            "the requested \(requested)-route topology exceeds the realtime limit of \(maximum)"
        case let .startResourceExceedsLimit(resource, requested, maximum):
            "the requested \(resource) count or size \(requested) exceeds the limit of \(maximum)"
        case .invalidStartConfiguration(let reason):
            "the audio route configuration is invalid: \(reason)"
        case let .bufferFrameSizeExceedsLimit(requested, maximum):
            "the requested \(requested)-frame slice exceeds the realtime limit of \(maximum)"
        case let .unsupportedSampleRate(requested, minimum, maximum):
            "the requested \(requested) Hz rate is outside the supported \(minimum)…\(maximum) Hz range"
        case .teardownIncomplete(let result):
            "the previous audio route is still retained: \(result)"
        case .audioResiduePresent(let telemetry):
            "new audio ownership refused while \(telemetry.retainedEntries) cleanup owner(s) remain"
        case .audioServerHealthUnavailable:
            "Core Audio did not return bounded driver-health evidence; no new route was created"
        }
    }
}
