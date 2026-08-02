import CoreAudio
import Foundation
import YunAudioHAL
import YunAudioRT

/// Carries the clock storage onto the publisher's queue.
///
/// It carries the storage rather than the graph, and that distinction is the
/// whole point: a patchbay edit swaps in a new graph and frees the old one, so
/// a captured graph pointer is dangling the first time anybody moves a cable.
/// This storage belongs to the route and outlives every graph in it.
///
/// The `@unchecked` is claimed deliberately, not to quiet the compiler: it is
/// allocated before the device starts and freed only after both the IOProc has
/// been destroyed and the publisher's queue has been drained, and the values
/// are read through the cycle counter acting as a sequence number.
private struct GraphHandle: @unchecked Sendable {
    let clock: RTGraph.SharedClock
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
    private let stateLock = NSRecursiveLock()
    public private(set) var aggregate: AggregateDevice?
    public private(set) var isRunning = false

    private var ioProcID: AudioDeviceIOProcID?
    private var graph: UnsafeMutablePointer<RTGraph>?
    /// What the IOProc actually reads. Holding the graph behind this is what
    /// makes a route change a swap rather than a restart.
    private var graphCell: OpaquePointer?
    private var activeRoutes: [Route] = []
    /// Stable identities and their live slots, rebuilt only with the topology.
    ///
    /// Commands arrive on the engine queue after the interface has emitted
    /// them. Resolving an array index there would let a graph publication move
    /// that index onto another cable before the command arrives.
    private var activeRouteKeys: [RouteOccurrenceKey] = []
    private var activeRouteIndex: [RouteOccurrenceKey: Int] = [:]

    /// The routes currently carrying audio, including any built from taps.
    public var currentRoutes: [Route] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeRoutes
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
    private var graphMaximumFrames = 4096
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
    private var selftestBlock: UnsafeMutablePointer<RTSelftest>?
    /// Retained here so the unit outlives the unmanaged pointer the IO thread
    /// holds; the IOProc must never touch a reference count.
    private var isolationUnit: VoiceIsolationUnit?
    private var isolationBlock: UnsafeMutablePointer<RTVoiceIsolation>?
    private var isolationFailureCounter: UnsafeMutablePointer<UInt64>?

    /// Latency the isolation model adds, in frames. Zero when it is off.
    public private(set) var voiceIsolationLatencyFrames = 0
    /// Latency introduced before route summing, in frames.
    ///
    /// Paths that skip the source chain are held back by this number. A final
    /// output stage is intentionally not part of it: every route meets that
    /// stage and delaying the bypass path by it would count the same latency
    /// twice.
    public private(set) var sourceProcessingLatencyFrames = 0
    /// Latency introduced after the complete mix, in frames.
    ///
    /// Kept separate before a final output stage exists so no consumer can
    /// quietly reuse the source-alignment number when that stage arrives.
    public private(set) var outputProcessingLatencyFrames = 0
    /// The latency facts consumers should choose between explicitly.
    public var processingLatency: ProcessingLatency {
        ProcessingLatency(
            sourceFrames: sourceProcessingLatencyFrames,
            outputFrames: outputProcessingLatencyFrames)
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
        // Non-blocking, like the other reads the interface makes: this took the
        // lock the ordinary way, and the ordinary way is held across a
        // synchronous message to `coreaudiod` during a start.
        guard stateLock.try() else { return 0 }
        defer { stateLock.unlock() }
        return Int(graph?.pointee.alignmentFrames ?? 0)
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
    private var transitionOldFailures: UnsafeMutablePointer<UInt64>?
    /// Renders the model refused. Non-zero means audio passed through
    /// unprocessed, which the UI should surface rather than hide.
    /// Renders the model refused. Non-zero means audio passed through
    /// unprocessed, which the UI should surface rather than hide.
    ///
    /// The counter is allocated per graph and freed with it, so this is the
    /// same use-after-free as the meters were.
    public var voiceIsolationFailures: UInt64 {
        guard stateLock.try() else { return 0 }
        defer { stateLock.unlock() }
        return isolationFailureCounter?.pointee ?? 0
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
                monitor != destinationDeviceUID, monitor != sourceDeviceUID
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
    /// microphone feeding a 44.1 kHz Bluetooth output still ends at 44.1 kHz,
    /// while 96 kHz doubles every per-frame DSP cost. Honour the preferred
    /// source rate, then preserve its current rate, before falling back to the
    /// highest value only when neither is usable.
    static func sampleRatePlan(
        sourceRates: [Double],
        destinationRates: [Double],
        preferredRate: Double?,
        sourceCurrentRate: Double?
    ) -> SampleRatePlan? {
        let source = Set(sourceRates.filter { $0.isFinite && $0 > 0 })
        guard !source.isEmpty else { return nil }
        let destination = Set(destinationRates.filter { $0.isFinite && $0 > 0 })
        let shared = source.intersection(destination)

        if let preferredRate, preferredRate.isFinite,
            shared.contains(preferredRate)
        {
            return SampleRatePlan(targetRate: preferredRate, hasMismatch: false)
        }
        if let highest = shared.max() {
            return SampleRatePlan(targetRate: highest, hasMismatch: false)
        }
        if let preferredRate, preferredRate.isFinite,
            source.contains(preferredRate)
        {
            return SampleRatePlan(targetRate: preferredRate, hasMismatch: true)
        }
        if let sourceCurrentRate, sourceCurrentRate.isFinite,
            source.contains(sourceCurrentRate)
        {
            return SampleRatePlan(targetRate: sourceCurrentRate, hasMismatch: true)
        }
        guard let highest = source.max() else { return nil }
        return SampleRatePlan(targetRate: highest, hasMismatch: true)
    }

    /// Builds one timing answer from live aggregate properties.
    ///
    /// Four thousand and ninety-six frames is storage headroom, not work to do:
    /// the callback still takes the minimum of the slice's available frames and
    /// this capacity. It covers a device changing its slice after start without
    /// making an ordinary 64- or 256-frame callback process one sample more.
    static func graphTiming(
        actualSampleRate: Double?,
        actualBufferFrames: UInt32?
    ) -> GraphTiming? {
        guard let sampleRate = actualSampleRate, sampleRate.isFinite, sampleRate > 0,
            let reportedFrames = actualBufferFrames, reportedFrames > 0
        else { return nil }
        let cycleFrames = min(Int(reportedFrames), Int(Int32.max))
        return GraphTiming(
            sampleRate: sampleRate,
            cycleFrames: cycleFrames,
            processingCapacity: max(cycleFrames, 4096))
    }
    /// Set once a lock failure has forced drift correction back on, so the
    /// recovery cannot loop.
    private var clockLockAbandoned = false
    private let recoveryQueue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.route-recovery")

    /// Reports a route that had to be rebuilt because the clock lock failed.
    public var onClockLockFailure: (@Sendable () -> Void)?

    /// Why voice isolation is not running, when it was asked for.
    ///
    /// Named constants rather than sentences written out at each site: the
    /// application turns these into something a person can read, and matching
    /// on a phrase that somebody later rewords would silently put the raw
    /// English back in front of the user.
    public enum IsolationFailure {
        public static let chainNotBuilt = "the processing chain could not be built"
        public static let unitNotInstantiated = "AUSoundIsolation could not be instantiated"
    }

    public private(set) var lastIsolationError: String?

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
    public private(set) var droppedMonitor: DroppedMonitor?

    /// Additional inputs and outputs the last start had to give up on, with the
    /// failure that made it give up.
    ///
    /// The same argument as `droppedMonitor`, one level out: an extra
    /// microphone that will not join the aggregate must not cost somebody the
    /// route they already had, and it must not do so quietly either. Empty
    /// when the route came up exactly as asked.
    public private(set) var droppedExtras: [DroppedMonitor] = []

    /// Third-party units that were asked for and would not load, each with the
    /// step that refused and the status it returned.
    public private(set) var failedPlugins: [AudioUnitLoadFailure] = []
    /// The stages actually rendering, which is not the same as the stages that
    /// were asked for: one that will not instantiate is dropped.
    public var activeEffectStages: [EffectKind] {
        stateLock.lock()
        defer { stateLock.unlock() }
        var stages = effectChain?.stages ?? (isolationUnit != nil ? [.voiceIsolation] : [])
        if graph?.pointee.outputLimiterEnabled != 0 { stages.append(.limiter) }
        return stages.sorted { $0.chainOrder < $1.chainOrder }
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

    /// How much a dynamics stage is pulling the signal down right now, in
    /// decibels. Zero when the stage is not in the chain, and nil when a graph
    /// change owns the state long enough that reading it would block.
    public func gainReduction(of kind: EffectKind) -> Float? {
        // Polled by the interface at 20 Hz, including while the chain is being
        // swapped. Nil tells the main-actor snapshot to hold its last reading;
        // zero would make the meter visibly blink during every instantiation.
        guard stateLock.try() else { return nil }
        defer { stateLock.unlock() }
        return effectChain?.gainReduction(of: kind) ?? 0
    }

    /// What the hosted plugins say their controls are, by plugin id.
    public func pluginParameters(_ id: String) -> [EffectParameter] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return effectChain?.parameters(ofPlugin: id) ?? []
    }

    /// The same metadata without making an interface redraw wait for a chain
    /// publication. A plugin's parameter list is structural, so the caller can
    /// keep the last successful answer while a replacement unit is built.
    public func pluginParametersIfAvailable(_ id: String) -> [EffectParameter]? {
        guard stateLock.try() else { return nil }
        defer { stateLock.unlock() }
        return effectChain?.parameters(ofPlugin: id) ?? []
    }

    /// Sets a control on a hosted third-party unit.
    public func setPluginParameter(_ parameter: String, ofPlugin id: String, to value: Float) {
        stateLock.lock()
        defer { stateLock.unlock() }
        effectChain?.set(parameter, ofPlugin: id, to: value)
    }
    /// Why the echo canceller is not running, when it was asked for.
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

    /// The destination as a device, for reading controls back off it.
    private var destinationDevice: AudioDevice?

    /// Cycle counter and clock anchor, owned by the route rather than by any
    /// one graph, so a patchbay edit does not free storage the clock publisher
    /// is still reading from its own queue.
    private var sharedClock: RTGraph.SharedClock?

    /// Held here as well as in the graph, because the graph is replaced on
    /// every restart and would come back at unity otherwise.
    public private(set) var inputGain: Float = 1
    public private(set) var isInputMuted = false
    public private(set) var outputGain: Float = 1
    public private(set) var isOutputMuted = false

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
        guard let bridge = echoBridge else { return nil }
        return EchoCancellationStatus(
            produced: bridge.producedFrames,
            buffered: bridge.bufferedFrames,
            dropped: bridge.droppedFrames,
            hasReference: bridge.hasFarEndReference && !bridge.farEndReferenceFailed,
            truncatedBlocks: bridge.truncatedBlocks,
            inputCallbacks: bridge.inputCallbacks,
            farEndCallbacks: bridge.farEndCallbacks,
            renderFailures: bridge.renderFailures,
            lastRenderStatus: bridge.lastRenderStatus)
    }

    public init() {}

    deinit { stop() }

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
        selftest: Bool = false
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
                selftest: selftest))
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
    private func startLocked(_ configuration: StartConfiguration) throws {
        droppedMonitor = nil
        droppedExtras = []
        var failure: Error
        do {
            try startAttempt(configuration)
            return
        } catch let thrown {
            failure = thrown
        }

        // `AudioDeviceStart` can return `noErr` without the device ever calling
        // its IOProc. Measured after a preset rebuild: the model said Running,
        // while the cycle count, recorder, analyser and Spotify tap all stayed
        // at zero. The same configuration came up on the next attempt.
        //
        // Retry that exact request before the fallback ladder. Dropping a
        // monitor or an extra source would hide a stalled device as a feature
        // that "could not be used", when none of the main mix ran either.
        if case RoutingError.noIOCycles = failure {
            do {
                try startAttempt(configuration)
                return
            } catch let retryFailure {
                failure = retryFailure
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
            guard (try? startAttempt(rung.configuration)) != nil else { continue }
            for uid in rung.drops {
                let dropped = DroppedMonitor(uid: uid, reason: reason)
                if uid == configuration.monitorDeviceUID {
                    droppedMonitor = dropped
                } else {
                    droppedExtras.append(dropped)
                }
            }
            return
        }
        // Nothing additional was what was wrong. The first failure is the one
        // that describes the route the caller actually asked for, so that is
        // the one they are told about; the retries were this layer's own idea.
        stopLocked()
        throw failure
    }

    /// The whole of a start, from one snapshot.
    ///
    /// Taking the configuration as a value rather than as fourteen parameters is
    /// the point: the clock-lock recovery replays exactly what the caller gave,
    /// and a field it forgets is one it cannot forget silently — there is only
    /// one of it.
    private func startAttempt(_ configuration: StartConfiguration) throws {
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

        stopLocked()

        guard let source = try AudioDevices.device(uid: sourceDeviceUID) else {
            throw RoutingError.deviceNotFound(sourceDeviceUID)
        }
        guard let destination = try AudioDevices.device(uid: destinationDeviceUID) else {
            throw RoutingError.deviceNotFound(destinationDeviceUID)
        }

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
        // Remembered so the devices go back the way they were found. Merged
        // rather than replaced: a restart must not forget what the first start
        // changed.
        // Only devices that can actually present it. Asking a 44.1 kHz headset
        // for 48 throws, and the throw would be the whole route rather than the
        // one device that could not oblige.
        let changed = try timed("align sample rates") {
            try AggregateDevice.alignSampleRate(
                targetRate,
                across: alignedDevices.filter {
                    $0.availableSampleRates.contains(targetRate)
                })
        }
        for (uid, previous) in changed where originalSampleRates[uid] == nil {
            originalSampleRates[uid] = previous
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
            do {
                bridge = try EchoCancellationBridge(
                    microphoneUID: sourceDeviceUID, settings: settings,
                    routerSampleRate: targetRate,
                    maximumFrames: Int(bufferFrames) * 4)
            } catch {
                lastEchoCancellationError = error.reason
                lastEchoCancellationDetail = error.detail
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
        if !sourceEffects.isEmpty || !plugins.isEmpty, !isolationOnly,
            let first = routes.first
        {
            isolatedSource = first.source
            let built = timed("build the effect chain") {
                EffectChain(
                    kinds: sourceEffects, plugins: plugins, sampleRate: rate,
                    maximumFrames: maximumFrames)
            }
            if let chain = built {
                effectChain = chain
                // Named rather than silently dropped: a chain that quietly
                // lost a stage sounds different and says nothing about why.
                failedPlugins = chain.pluginFailures
                voiceIsolationLatencyFrames =
                    sourceEffects.contains(.voiceIsolation) ? chain.latencyFrames : 0
            } else {
                isolatedSource = nil
                lastIsolationError = IsolationFailure.chainNotBuilt
            }
        } else if let settings = voiceIsolation, let first = routes.first {
            isolatedSource = first.source
            let unit = VoiceIsolationUnit(
                sampleRate: rate, maximumFrames: maximumFrames)
            if let unit {
                unit.setMix(settings.mixPercent)
                unit.setHighQuality(settings.isHighQuality)
                isolationUnit = unit
                voiceIsolationLatencyFrames = unit.latencyFrames
            } else {
                // Not fatal: the route still carries audio, just unprocessed.
                isolatedSource = nil
                lastIsolationError = IsolationFailure.unitNotInstantiated
            }
        }
        sourceProcessingLatencyFrames = ProcessingLatency.sourceStageFrames(
            chainFrames: effectChain?.latencyFrames,
            isolationFrames: isolationUnit?.latencyFrames)
        guard
            let outputLimiter = OutputLimiterBank(
                channelCounts: outputChannelCounts, sampleRate: rate)
        else {
            throw RoutingError.outputLimiterUnavailable
        }
        outputLimiterBank = outputLimiter
        outputProcessingLatencyFrames = ProcessingLatency.outputStageFrames(
            limiterFrames: outputLimiter.latencyFrames)

        let rtRoutes = try routes.map { route -> RTRoute in
            // With the canceller in front, the microphone's channels are not in
            // this aggregate at all, so they have no entry in the input map and
            // must not be looked for in it.
            let fromMicrophone = cancelsEcho && route.source.deviceUID == sourceDeviceUID
            // An isolated route reads the model's output whether or not the
            // canceller fed it, so the two flags are exclusive: the cancelled
            // buffer is what the model consumed, not what this route wants.
            let isIsolated = isolatedSource != nil && route.source == isolatedSource

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
                usesIsolatedSource: isIsolated,
                usesCancelledSource: fromMicrophone && !isIsolated,
                appliesInputTrim: route.source.deviceUID == sourceDeviceUID,
                isDuckable: route.isDuckable)
        }

        let clock = RTGraph.SharedClock.allocate()
        sharedClock = clock
        let graph = RTGraph.allocate(
            routes: rtRoutes, bufferFrames: cycleFrames, sampleRate: rate,
            sharedClock: clock)
        Self.initialisePersistedMixState(
            inputGain: inputGain, inputMuted: isInputMuted,
            outputGain: outputGain, outputMuted: isOutputMuted,
            on: graph)
        self.graph = graph
        installActiveRoutes(routes)
        graph.pointee.analysisEnabled = analysisEnabled ? 1 : 0
        graph.pointee.outputLimiter = Unmanaged.passUnretained(outputLimiter).toOpaque()
        graph.pointee.outputLimiterEnabled = effects.contains(.limiter) ? 1 : 0
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
            let failures = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
            failures.initialize(to: 0)
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
                    maximumFrames: Int32(chain.maximumFrames),
                    renderFailures: failures))
            isolationBlock = block
            graph.pointee.voiceIsolation = block
            graph.pointee.isolationIsChain = 1
        } else if let unit = isolationUnit, isolatedSource != nil,
            isolationFromCancelled || isolatedSource.flatMap({ inputMap[$0] }) != nil
        {
            let point = isolationPoint
            let failures = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
            failures.initialize(to: 0)
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
                    maximumFrames: Int32(unit.maximumFrames),
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
            min(sourceProcessingLatencyFrames, RTGraph.maximumAlignmentFrames))

        graph.pointee.mainOutputBuffer =
            outputMap[ChannelRef(deviceUID: destinationDeviceUID, channel: 0)]?.buffer ?? 0
        graph.pointee.masterExemptBuffer =
            monitorDeviceUID
            .flatMap { outputMap[ChannelRef(deviceUID: $0, channel: 0)]?.buffer } ?? -1

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
            let block = RTSelftest.allocate(
                outBuffer: outPoint.buffer, outChannel: outPoint.channel,
                inBuffer: inPoint.buffer, inChannel: inPoint.channel,
                captureFrames: 262_144)
            selftestBlock = block
            graph.pointee.selftest = block
        }

        // The canceller has to be producing before the router starts reading,
        // or the first cycles find an empty ring. Started here rather than in
        // the constructor so a failure to build the graph does not leave a unit
        // running with nothing to consume it.
        if let bridge {
            guard bridge.start() else {
                lastEchoCancellationError = EchoFailure.wouldNotStart
                throw RoutingError.echoCancellerFailed
            }
            echoBridge = bridge
            graph.pointee.cancelledRing = bridge.ring
        }

        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        graphCell = cell

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            aggregate.id, yunAudioIOProc, UnsafeMutableRawPointer(cell), &procID)
        guard createStatus == noErr, let procID else {
            throw RoutingError.ioProcFailed(createStatus)
        }
        ioProcID = procID

        let startStatus = timed("AudioDeviceStart") { AudioDeviceStart(aggregate.id, procID) }
        guard startStatus == noErr else {
            throw RoutingError.startFailed(startStatus)
        }
        isRunning = true
        // A success status only means CoreAudio accepted the request. It does
        // not mean an IOProc ran. Two completed cycles are the first numeric
        // proof that both the callback and its retirement path are alive.
        guard yun_rt_cell_wait_for_swap(cell, 750) else {
            throw RoutingError.noIOCycles
        }

        // When the destination is our own driver, hand it the master's clock so
        // it can lock to the microphone. Any other destination — BlackHole, a
        // physical device — has no such channel, and the path stays honestly
        // marked as resampled.
        if clockLockAvailable,
            let publisher = ClockAnchorPublisher(driverDeviceUID: destinationDeviceUID)
        {
            clockPublisher = publisher
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
            publisher.start {
                RoutingEngine.anchor(from: handle.clock, sampleRate: anchorRate)
            }
        }
    }

    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        clockPublisher?.onLockChanged = nil
        clockPublisher?.stop()
        clockPublisher = nil
        requiresClockLock = false

        if let aggregate, let ioProcID {
            if isRunning { AudioDeviceStop(aggregate.id, ioProcID) }
            AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
        }
        ioProcID = nil
        isRunning = false

        // Before the graph is freed, since the graph holds this object's ring.
        // Stopping the unit first also puts the microphone and the speaker back
        // in the hands of whatever wants them next.
        echoBridge?.stop()
        echoBridge = nil

        timed("destroy the aggregate") { aggregate?.destroy() }
        aggregate = nil
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
        stopRecordingLocked()

        // Safe now: the IOProc has been destroyed, so nothing can be reading
        // the graph any more.
        if let graph { RTGraph.deallocate(graph) }
        graph = nil
        // After the graph, and after the publisher was stopped and drained
        // above — this is the storage it reads.
        sharedClock?.deallocate()
        sharedClock = nil
        if let graphCell { yun_rt_cell_free(graphCell) }
        graphCell = nil
        stopStemRecordingLocked()
        stopTranscriptTapsLocked()
        if let selftestBlock { RTSelftest.deallocate(selftestBlock) }
        selftestBlock = nil

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
        if let transitionOldFailures {
            transitionOldFailures.deinitialize(count: 1)
            transitionOldFailures.deallocate()
        }
        transitionOldFailures = nil
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
            isolationFailureCounter.deinitialize(count: 1)
            isolationFailureCounter.deallocate()
        }
        isolationFailureCounter = nil
        isolationUnit = nil
        effectChain = nil
        outputLimiterBank = nil
        recordingLimiter = nil
        voiceIsolationLatencyFrames = 0
        sourceProcessingLatencyFrames = 0
        outputProcessingLatencyFrames = 0
        graphSampleRate = 48000
        graphBufferFrames = 128
        graphMaximumFrames = 4096

        inputMap.removeAll()
        outputMap.removeAll()
        outputChannelCounts.removeAll()
        installActiveRoutes([])

        // Restore last: the aggregate has to be gone first, or the HAL will
        // simply set the rate back to whatever the aggregate wanted.
        if !originalSampleRates.isEmpty {
            _ = timed("restore sample rates") {
                AggregateDevice.restoreSampleRates(originalSampleRates)
            }
            originalSampleRates.removeAll()
        }
    }

    /// Brings the route back up with drift correction enabled after the clock
    /// lock dropped. Runs on `recoveryQueue`, never on the publisher's queue —
    /// stopping the publisher drains that queue and would deadlock on itself.
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
        try? startLocked(configuration)
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
        defer { stateLock.unlock() }
        if kind == .limiter, parameter == "gain", value.isFinite {
            let linear = powf(10, max(-20, min(20, value)) / 20)
            if graph == nil
                || pushGlobal(
                    kind: kYunRTCommandSetLimiterPreGain, value: linear)
            {
                outputLimiterPreGain = linear
            }
        } else if let effectChain {
            effectChain.set(parameter, of: kind, to: value)
        } else if kind == .voiceIsolation, parameter == "mix" {
            isolationUnit?.setMix(value)
        }
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
        defer { stateLock.unlock() }
        if kind == .limiter, parameter == "gain" {
            return 20
                * log10f(
                    max(outputLimiterPreGain, Float.leastNonzeroMagnitude))
        }
        if let effectChain { return effectChain.value(parameter, of: kind) }
        if kind == .voiceIsolation, parameter == "mix" { return isolationUnit?.mix }
        return nil
    }

    // MARK: Recording

    private var recorder: Recorder?

    /// True while audio is being written to disk.
    public var isRecording: Bool { recorder != nil }
    public var recordingURL: URL? { recorder?.url }
    public var recordingDuration: TimeInterval { recorder?.duration ?? 0 }

    /// Why the writer stopped, when it stopped itself.
    ///
    /// The recorder has recorded the file-system error since it was written and
    /// there was no way to ask for it from out here — so the application
    /// substituted "the file could not be written" for a message the engine
    /// already had, and disk-full, permission-denied and a codec refusing the
    /// format all read the same. Worse, the writer failing does not release the
    /// recorder, so `isRecording` stays true and the only symptom was a
    /// duration that stopped counting.
    public var recordingError: String? { recorder?.lastError }

    /// Starts writing the routed signal to a file.
    ///
    /// - Throws: Whatever creating the file throws — a directory that does not
    ///   exist, or is not writable.
    @discardableResult
    public func startRecording(
        to directory: URL, format: Recorder.Format = .wav, now: Date = Date()
    ) throws -> URL {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, let graph, aggregate?.device != nil else {
            throw RecorderError.couldNotAllocate
        }
        stopRecordingLocked()

        let main = Int(graph.pointee.mainOutputBuffer)
        guard main >= 0, main < outputChannelCounts.count else {
            throw RecorderError.couldNotAllocate
        }
        let channels = min(2, outputChannelCounts[main])
        guard channels > 0,
            let limiter = OutputLimiterBank(
                channelCounts: [channels], sampleRate: graphSampleRate)
        else {
            throw RecorderError.couldNotAllocate
        }
        let recorder = try Recorder(
            directory: directory, format: format, channels: channels,
            sampleRate: graphSampleRate, timestamp: now)
        self.recorder = recorder
        recordingLimiter = limiter
        graph.pointee.recordChannels = Int32(channels)
        graph.pointee.recordLimiter = Unmanaged.passUnretained(limiter).toOpaque()
        graph.pointee.recordLimiterPrimingFrames = Int32(limiter.latencyFrames)
        // Published last. Seeing the ring means every field the callback needs
        // for this recording branch is already complete.
        graph.pointee.recordRing = recorder.ringHandle
        return recorder.url
    }

    /// Configures ducking. Takes effect on the next cycle without a rebuild.
    public func setDucking(enabled: Bool, depth: Float) {
        stateLock.lock()
        defer { stateLock.unlock() }
        graph?.pointee.duckEnabled = enabled ? 1 : 0
        graph?.pointee.duckDepth = max(0, min(1, depth))
    }

    /// Tells the realtime side whether the classifier's recent verdict permits
    /// ducking at all. The envelope decides the instant; this decides whether
    /// that instant counts.
    public func setDuckingAllowed(_ allowed: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        graph?.pointee.duckAllowed = allowed ? 1 : 0
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
    public enum CorrectionOutcome: String, Sendable {
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
        graph?.pointee.analysisEnabled = enabled ? 1 : 0
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
        guard let graph, let ring = graph.pointee.analysisRing else {
            return AnalysisStatistics(
                isEnabled: false, written: 0, available: 0, dropped: 0)
        }
        return AnalysisStatistics(
            isEnabled: graph.pointee.analysisEnabled != 0,
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
        guard let ring = graph?.pointee.analysisRing, capacity > 0 else { return 0 }
        return Int(yun_rt_ring_read(ring, destination, UInt32(capacity)))
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
        guard let graph, graph.pointee.recordRing != nil else { return }
        let wasPaused = graph.pointee.recordPaused != 0
        guard wasPaused != paused else { return }
        if paused {
            // Stop the producer first, then finish the delayed tail. Resetting
            // after the flush makes the resumed part a clean splice rather
            // than replaying the last millisecond from before the pause.
            graph.pointee.recordPaused = 1
            letTheRealtimeThreadPast()
            flushRecordingLimiterLocked(graph: graph)
            if let limiter = recordingLimiter {
                _ = limiter.reset(bus: 0)
                graph.pointee.recordLimiterPrimingFrames =
                    Int32(limiter.latencyFrames)
            }
        } else {
            graph.pointee.recordPaused = 0
        }
    }

    /// Under the lock like every other read of the graph, and non-blocking for
    /// the same reason: this dereferences memory the engine queue may free.
    /// Answering "not paused" for the frame a rebuild takes is the honest
    /// default — a recording that is not running is not paused either.
    public var isRecordingPaused: Bool {
        guard stateLock.try() else { return false }
        defer { stateLock.unlock() }
        return graph?.pointee.recordPaused != 0
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
        defer { stateLock.unlock() }
        guard isRunning, let graph, aggregate?.device != nil else {
            throw RecorderError.couldNotAllocate
        }
        stopStemRecordingLocked()

        var urls: [URL] = []
        for (stem, routes) in groups.enumerated() {
            let channels = min(RTGraph.maxStemChannels, max(1, routes.count))
            let recorder = try Recorder(
                directory: directory, format: format, channels: channels,
                sampleRate: graphSampleRate, timestamp: now,
                name: stem < names.count ? names[stem] : "Source \(stem + 1)")
            stemRecorders.append(recorder)
            urls.append(recorder.url)

            graph.pointee.stemChannels[stem] = Int32(channels)
            graph.pointee.stemRings[stem] = recorder.ringHandle
            for (channel, route) in routes.enumerated()
            where route < Int(graph.pointee.routeCount) && channel < channels {
                graph.pointee.routes[route].stemIndex = Int32(stem)
                graph.pointee.routes[route].stemChannel = Int32(channel)
            }
        }
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

    public func stopStemRecording() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopStemRecordingLocked()
    }

    private func stopStemRecordingLocked() {
        guard !stemRecorders.isEmpty else { return }
        // Detached from the graph first: the writer threads must not be
        // draining rings the IO thread is still filling while they are torn
        // down.
        if let graph {
            for stem in 0..<Int(graph.pointee.stemCount) {
                graph.pointee.stemRings[stem] = nil
                graph.pointee.stemChannels[stem] = 0
            }
            for route in 0..<Int(graph.pointee.routeCount) {
                graph.pointee.routes[route].stemIndex = -1
            }
        }
        letTheRealtimeThreadPast()
        for recorder in stemRecorders { recorder.stop() }
        stemRecorders.removeAll()
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
    /// - Returns: How many taps were opened, which is fewer than asked for only
    ///   if a route index was out of range.
    @discardableResult
    public func startTranscriptTaps(routes: [Int]) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, let graph else { return 0 }
        stopTranscriptTapsLocked()

        var opened = 0
        for (slot, route) in routes.enumerated() {
            guard slot < Int(graph.pointee.transcriptCount),
                route >= 0, route < Int(graph.pointee.routeCount)
            else { continue }
            // A second at 48 kHz. The consumer polls on the interface's own
            // timer, so a ring that only held a buffer or two would drop audio
            // every time a window resize got in the way of a poll.
            guard let ring = yun_rt_ring_create(65_536) else { continue }
            graph.pointee.transcriptRings[slot] = ring
            graph.pointee.routes[route].transcriptIndex = Int32(slot)
            transcriptRings.append(ring)
            opened += 1
        }
        return opened
    }

    public func stopTranscriptTaps() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopTranscriptTapsLocked()
    }

    private func stopTranscriptTapsLocked() {
        guard !transcriptRings.isEmpty else { return }
        // Detached before freed, and in that order: the IO thread must not be
        // handed a pointer to a ring that is on its way out.
        if let graph {
            for slot in 0..<Int(graph.pointee.transcriptCount) {
                graph.pointee.transcriptRings[slot] = nil
            }
            for route in 0..<Int(graph.pointee.routeCount) {
                graph.pointee.routes[route].transcriptIndex = -1
            }
        }
        letTheRealtimeThreadPast()
        for ring in transcriptRings { yun_rt_ring_free(ring) }
        transcriptRings.removeAll()
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
        guard capacity > 0 else { return 0 }
        return Self.withTranscriptDrainLock(stateLock) {
            guard slot >= 0, slot < transcriptRings.count else { return 0 }
            return Int(
                yun_rt_ring_read(transcriptRings[slot], destination, UInt32(capacity)))
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

    /// Holds the same lock as graph publication for a deterministic contention test.
    func withStateLockForTesting(_ body: () -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        body()
    }

    /// True while separate files are being written.
    public var isRecordingStems: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !stemRecorders.isEmpty
    }

    /// Samples any stem had to drop. Non-zero means a file has gaps.
    public var stemDroppedSamples: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stemRecorders.reduce(0) { $0 + $1.droppedSamples }
    }

    public func stopRecording() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopRecordingLocked()
    }

    /// Lets the realtime thread past any pointer it loaded before a detach.
    ///
    /// Writing nil into a field of the live graph does not unload the copy the
    /// IO thread may already be holding: the read and the use are two
    /// instructions with a whole buffer's work between them. Freeing on the
    /// other side of that window is a use-after-free in the one thread that
    /// must never fault, and it is not theoretical — measured here as a
    /// `SIGSEGV` inside `yun_rt_ring_write`, called from
    /// `HALC_ProxyIOContext::IOWorkLoop`, while the flow check stopped a
    /// recording. The address had the shape of a freed allocation.
    ///
    /// The same wait the graph swap uses, for the same reason it gives: one
    /// cycle may already be in flight, so two is the first count that cannot
    /// be. Despite its name `yun_rt_cell_wait_for_swap` counts cycles and
    /// nothing else, which is exactly what is wanted here — there is no swap,
    /// only a field that has changed underneath a reader.
    ///
    /// A false return means the device is producing no cycles, in which case
    /// nothing can be holding anything and freeing is safe regardless.
    private func letTheRealtimeThreadPast() {
        guard let graphCell else { return }
        _ = yun_rt_cell_wait_for_swap(graphCell, 200)
    }

    private func stopRecordingLocked() {
        guard let recorder else { return }
        // Detach from the graph first: the writer thread must not be draining a
        // ring the IO thread is still filling while it is being torn down.
        let current = graph
        current?.pointee.recordRing = nil
        current?.pointee.recordLimiter = nil
        letTheRealtimeThreadPast()
        if let current { flushRecordingLimiterLocked(graph: current) }
        current?.pointee.recordChannels = 0
        current?.pointee.recordLimiterPrimingFrames = 0
        recorder.stop()
        self.recorder = nil
        recordingLimiter = nil
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

        guard isRunning, let cell = graphCell, let previous = graph else { return false }
        let routes = Self.preservingRouteControls(
            from: activeRoutes, to: requestedRoutes)

        let rtRoutes = routes.compactMap { route -> RTRoute? in
            guard let source = inputMap[route.source],
                let destination = outputMap[route.destination]
            else { return nil }
            return RTRoute(
                sourceBuffer: source.buffer,
                sourceChannel: source.channel,
                destinationBuffer: destination.buffer,
                destinationChannel: destination.channel,
                gain: route.gain,
                muted: route.isMuted,
                usesIsolatedSource: previous.pointee.routes[0].usesIsolatedSource != 0
                    && route.source == activeRoutes.first?.source,
                usesCancelledSource: previous.pointee.routes[0].usesCancelledSource != 0
                    && route.source == activeRoutes.first?.source,
                appliesInputTrim: previous.pointee.routes.pointee.appliesInputTrim != 0
                    && route.source == activeRoutes.first?.source,
                isDuckable: route.isDuckable)
        }
        guard rtRoutes.count == routes.count else { return false }

        let next = RTGraph.allocate(
            routes: rtRoutes,
            bufferFrames: graphBufferFrames,
            sampleRate: graphSampleRate,
            sharedClock: sharedClock)
        // Everything that belongs to the route rather than to this particular
        // graph has to come across, or moving one cable silently turns it off.
        // Recording and echo cancellation were both being dropped here: a
        // patchbay edit stopped the recorder writing and cut the canceller out
        // of the path, with nothing to say so.
        next.pointee.voiceIsolation = previous.pointee.voiceIsolation
        next.pointee.isolationIsChain = previous.pointee.isolationIsChain
        next.pointee.selftest = previous.pointee.selftest
        RTGraph.carryOutputStages(from: previous, to: next)
        // A live route edit changes only which source feeds an existing output
        // map. Sharing the bank keeps both the per-bus identity and its running
        // history; rebuilding it here would drop every correction until the
        // model happened to publish the same settings again.
        RTGraph.carryCorrections(from: previous, to: next)
        next.pointee.outputLimiterPreGain = outputLimiterPreGain
        next.pointee.cancelledRing = previous.pointee.cancelledRing
        // The scalar is the latest control truth even when its command is still
        // waiting in the retiring graph. The moving state below is the audible
        // truth; keeping both lets the replacement continue from the sample
        // already heard towards the newest target.
        next.pointee.inputGain = inputGain
        next.pointee.inputMuted = isInputMuted ? 1 : 0
        next.pointee.outputGain = outputGain
        next.pointee.outputMuted = isOutputMuted ? 1 : 0
        RTGraph.carryGlobalGainSlews(from: previous, to: next)
        next.pointee.mainOutputBuffer = previous.pointee.mainOutputBuffer
        next.pointee.analysisEnabled = previous.pointee.analysisEnabled
        next.pointee.duckEnabled = previous.pointee.duckEnabled
        next.pointee.duckDepth = previous.pointee.duckDepth
        next.pointee.duckThreshold = previous.pointee.duckThreshold
        next.pointee.duckAllowed = previous.pointee.duckAllowed
        next.pointee.duckGain = previous.pointee.duckGain
        next.pointee.masterExemptBuffer = previous.pointee.masterExemptBuffer

        // The analysis ring is handed over rather than replaced. Its consumer
        // lives outside the graph and holds a running integrated loudness; a
        // fresh ring would silently drop whatever was in flight, so moving one
        // cable would put a gap in a measurement that is supposed to be
        // continuous. The freshly allocated one is released here, and the old
        // graph is detached from the carried one so its deallocation does not
        // take the ring with it.
        if let carried = previous.pointee.analysisRing {
            if let unused = next.pointee.analysisRing { yun_rt_ring_free(unused) }
            next.pointee.analysisRing = carried
            previous.pointee.analysisRing = nil
        }

        // So do the per-source rings, and for a sharper reason than the
        // analysis one: these were being dropped. Stem recording survives a
        // route edit only if both halves come across — the rings themselves,
        // which belong to recorders the engine owns, and the per-route
        // assignment that says which route feeds which. Without this, moving
        // one cable during a recording left every stem file open, silent and
        // still counting time, with nothing anywhere saying so.
        let carriedSlots = min(Int(previous.pointee.stemCount), Int(next.pointee.stemCount))
        for slot in 0..<carriedSlots {
            next.pointee.stemRings[slot] = previous.pointee.stemRings[slot]
            next.pointee.stemChannels[slot] = previous.pointee.stemChannels[slot]
        }
        let carriedTranscripts = min(
            Int(previous.pointee.transcriptCount), Int(next.pointee.transcriptCount))
        for slot in 0..<carriedTranscripts {
            next.pointee.transcriptRings[slot] = previous.pointee.transcriptRings[slot]
        }

        // Moving a cable does not change the chain, so the alignment does not
        // change either — and the delay lines have to come with the routes they
        // belong to, or every patchbay edit would put a hole the length of the
        // chain into the tapped applications.
        next.pointee.alignmentFrames = previous.pointee.alignmentFrames

        for (index, old) in RoutingEngine.carriedPositions(from: activeRoutes, to: routes)
            .enumerated()
        {
            guard let old, old < Int(previous.pointee.routeCount) else { continue }
            RTGraph.carryAlignment(from: previous, slot: old, to: next, slot: index)
            RTGraph.carryRouteGainSlew(from: previous, slot: old, to: next, slot: index)
            next.pointee.routes[index].stemIndex = previous.pointee.routes[old].stemIndex
            next.pointee.routes[index].stemChannel = previous.pointee.routes[old].stemChannel
            next.pointee.routes[index].transcriptIndex =
                previous.pointee.routes[old].transcriptIndex
        }

        _ = yun_rt_cell_publish(cell, UnsafeMutableRawPointer(next))
        graph = next
        installActiveRoutes(routes)
        lastConfiguration?.rememberLiveRoutes(routes)

        // A false return means the device is not producing cycles, so nothing
        // can be holding the old graph and it is safe to free anyway.
        _ = yun_rt_cell_wait_for_swap(cell, 200)
        RTGraph.deallocate(previous)
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

        guard isRunning, let cell = graphCell, let previous = graph,
            aggregate != nil, !activeRoutes.isEmpty
        else { return false }

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
        let retiredFailures = isolationFailureCounter
        let previousTransitionController = effectTransitionController
        let previousTransitionBlock = effectTransitionBlock
        let previousTransitionOldChain = transitionOldChain
        let previousTransitionOldUnit = transitionOldUnit
        let previousTransitionOldBlock = transitionOldBlock
        let previousTransitionOldFailures = transitionOldFailures

        // The same split `start` makes: the complete-mix limiter is not part of
        // this mono source chain, and a dedicated unit handles isolation alone.
        let sourceKinds = kinds.filter { $0 != .limiter }
        let isolationOnly = sourceKinds == [.voiceIsolation] && plugins.isEmpty
        var chain: EffectChain?
        var unit: VoiceIsolationUnit?
        if !sourceKinds.isEmpty || !plugins.isEmpty, !isolationOnly {
            chain = EffectChain(
                kinds: sourceKinds, plugins: plugins, sampleRate: rate,
                maximumFrames: maximumFrames)
            if chain == nil { lastIsolationError = IsolationFailure.chainNotBuilt }
        } else if isolationOnly, let settings = voiceIsolation {
            unit = VoiceIsolationUnit(sampleRate: rate, maximumFrames: maximumFrames)
            if let unit {
                unit.setMix(settings.mixPercent)
                unit.setHighQuality(settings.isHighQuality)
            } else {
                lastIsolationError = IsolationFailure.unitNotInstantiated
            }
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
        let microphoneUID = lastConfiguration?.sourceDeviceUID
        let isolatedSource = activeRoutes.first?.source
        let fromCancelled = echoBridge != nil && isolatedSource?.deviceUID == microphoneUID
        let mapped = isolatedSource.flatMap { inputMap[$0] }
        let point = mapped ?? (buffer: Int32(0), channel: Int32(0))
        let canReachSource = fromCancelled || mapped != nil
        // Disabling the final stage still needs one isolated source while the
        // old processed path fades to raw. Keying routes only on the new stage
        // would route around the transition at the exact swap it exists for.
        let isolates = canReachSource && (retiredBlock != nil || stage != nil)

        // Copied whole rather than rebuilt from `activeRoutes`: nothing about
        // the routes is changing, so their buffer indices, gains, mutes and —
        // the part that would go silently wrong otherwise — their stem and
        // transcript assignments all carry across untouched. Only which source
        // each route reads is in question here.
        var rtRoutes: [RTRoute] = []
        rtRoutes.reserveCapacity(Int(previous.pointee.routeCount))
        for index in 0..<Int(previous.pointee.routeCount) {
            var route = previous.pointee.routes[index]
            let source = index < activeRoutes.count ? activeRoutes[index].source : nil
            if index < activeRoutes.count {
                route.gain = activeRoutes[index].gain
                route.muted = activeRoutes[index].isMuted ? 1 : 0
            }
            let isIsolated = isolates && source != nil && source == isolatedSource
            let fromMicrophone = echoBridge != nil && source?.deviceUID == microphoneUID
            route.usesIsolatedSource = isIsolated ? 1 : 0
            // Exclusive, as at start: the cancelled buffer is what the model
            // consumed, not what a route reading the model's output wants.
            route.usesCancelledSource = fromMicrophone && !isIsolated ? 1 : 0
            rtRoutes.append(route)
        }

        // A fresh block and a fresh counter rather than the old ones rewritten:
        // the IO thread may still be inside a cycle holding the old block, and
        // it points at the unit that is about to be released.
        var block: UnsafeMutablePointer<RTVoiceIsolation>?
        var failures: UnsafeMutablePointer<UInt64>?
        if let stage, canReachSource {
            let counter = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
            counter.initialize(to: 0)
            failures = counter

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
                    maximumFrames: Int32(stage.frames),
                    renderFailures: counter))
            block = allocated
        }

        let oldLatency = retiredChain?.latencyFrames ?? retiredUnit?.latencyFrames ?? 0
        let newLatency = chain?.latencyFrames ?? unit?.latencyFrames ?? 0
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

        let next = RTGraph.allocate(
            routes: rtRoutes, bufferFrames: cycleFrames, sampleRate: rate,
            sharedClock: sharedClock)
        if let block, let stage {
            next.pointee.voiceIsolation = block
            next.pointee.isolationIsChain = stage.isChain ? 1 : 0
        }
        next.pointee.effectTransition = transitionBlock

        // Everything `updateRoutes` carries, for the reason it carries it:
        // whatever belongs to the route rather than to this particular graph is
        // silently switched off otherwise.
        next.pointee.selftest = previous.pointee.selftest
        RTGraph.carryOutputStages(from: previous, to: next)
        next.pointee.outputLimiterPreGain = outputLimiterPreGain
        // The bank and its delay history stay the same; only attenuation is
        // switched. Bypass therefore has the same fixed delay as enabled mode.
        next.pointee.outputLimiterEnabled = kinds.contains(.limiter) ? 1 : 0
        next.pointee.cancelledRing = previous.pointee.cancelledRing
        next.pointee.inputGain = inputGain
        next.pointee.inputMuted = isInputMuted ? 1 : 0
        next.pointee.outputGain = outputGain
        next.pointee.outputMuted = isOutputMuted ? 1 : 0
        RTGraph.carryGlobalGainSlews(from: previous, to: next)
        next.pointee.mainOutputBuffer = previous.pointee.mainOutputBuffer
        next.pointee.analysisEnabled = previous.pointee.analysisEnabled
        next.pointee.duckEnabled = previous.pointee.duckEnabled
        next.pointee.duckDepth = previous.pointee.duckDepth
        next.pointee.duckThreshold = previous.pointee.duckThreshold
        next.pointee.duckAllowed = previous.pointee.duckAllowed
        next.pointee.duckGain = previous.pointee.duckGain
        next.pointee.masterExemptBuffer = previous.pointee.masterExemptBuffer

        // And every bus's correction. The output map is unchanged by this
        // graph-only swap, so retaining the same bank preserves both its bus
        // identity and the filter history being advanced by the callback.
        RTGraph.carryCorrections(from: previous, to: next)

        // The chain is what decides the alignment, so a chain swap is the one
        // rebuild that can change it. Set before the graph is published, or a
        // cycle would run the new chain against the old compensation.
        next.pointee.alignmentFrames = Int32(
            min(newLatency, RTGraph.maximumAlignmentFrames))
        for slot in 0..<Int(next.pointee.routeCount) {
            RTGraph.carryAlignment(from: previous, slot: slot, to: next, slot: slot)
            RTGraph.carryRouteGainSlew(from: previous, slot: slot, to: next, slot: slot)
        }

        // Handed over rather than replaced, as in `updateRoutes`: the consumer
        // lives outside the graph and holds a running integrated loudness, so a
        // fresh ring would put a gap in a measurement that is meant to be
        // continuous.
        if let carried = previous.pointee.analysisRing {
            if let unused = next.pointee.analysisRing { yun_rt_ring_free(unused) }
            next.pointee.analysisRing = carried
            previous.pointee.analysisRing = nil
        }

        let carriedSlots = min(Int(previous.pointee.stemCount), Int(next.pointee.stemCount))
        for slot in 0..<carriedSlots {
            next.pointee.stemRings[slot] = previous.pointee.stemRings[slot]
            next.pointee.stemChannels[slot] = previous.pointee.stemChannels[slot]
        }
        let carriedTranscripts = min(
            Int(previous.pointee.transcriptCount), Int(next.pointee.transcriptCount))
        for slot in 0..<carriedTranscripts {
            next.pointee.transcriptRings[slot] = previous.pointee.transcriptRings[slot]
        }

        _ = yun_rt_cell_publish(cell, UnsafeMutableRawPointer(next))
        graph = next
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
        transitionOldFailures = transitionBlock == nil ? nil : retiredFailures
        // Named rather than silently dropped, as at start: a chain that quietly
        // lost a stage sounds different and says nothing about why.
        failedPlugins = chain?.pluginFailures ?? []
        sourceProcessingLatencyFrames = ProcessingLatency.sourceStageFrames(
            chainFrames: chain?.latencyFrames,
            isolationFrames: unit?.latencyFrames)
        if let chain {
            voiceIsolationLatencyFrames =
                sourceKinds.contains(.voiceIsolation) ? chain.latencyFrames : 0
        } else {
            voiceIsolationLatencyFrames = unit?.latencyFrames ?? 0
        }

        // A false return means the device is not producing cycles, so nothing
        // can be holding the old graph and it is safe to free anyway.
        _ = yun_rt_cell_wait_for_swap(cell, 200)
        RTGraph.deallocate(previous)

        // A previous handover is now beyond the same cycle fence as its graph.
        // Its old path can finally be reclaimed; the current old path moved
        // into the new handover above and must survive this return.
        if let previousTransitionBlock {
            RTEffectTransition.deallocate(previousTransitionBlock)
        }
        if let previousTransitionOldBlock {
            previousTransitionOldBlock.deinitialize(count: 1)
            previousTransitionOldBlock.deallocate()
        }
        if let previousTransitionOldFailures {
            previousTransitionOldFailures.deinitialize(count: 1)
            previousTransitionOldFailures.deallocate()
        }
        withExtendedLifetime(
            (
                previousTransitionController, previousTransitionOldChain,
                previousTransitionOldUnit
            )
        ) {}

        // If neither side could be transitioned, the old path was not handed
        // to the new graph and follows the ordinary retirement order.
        if transitionBlock == nil {
            if let retiredBlock {
                retiredBlock.deinitialize(count: 1)
                retiredBlock.deallocate()
            }
            if let retiredFailures {
                retiredFailures.deinitialize(count: 1)
                retiredFailures.deallocate()
            }
        }
        withExtendedLifetime((retiredChain, retiredUnit, transitionController)) {}
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
    private func pushGlobal(kind: YunRTCommandKind, value: Float) -> Bool {
        guard let graph, let commands = graph.pointee.commands else { return false }
        return yun_rt_queue_push(
            commands, YunRTCommand(kind: Int32(kind.rawValue), index: 0, value: value))
    }

    private func push(kind: YunRTCommandKind, index: Int, value: Float) -> Bool {
        guard let graph, let commands = graph.pointee.commands,
            index >= 0, index < Int(graph.pointee.routeCount)
        else { return false }
        return yun_rt_queue_push(
            commands,
            YunRTCommand(kind: Int32(kind.rawValue), index: Int32(index), value: value))
    }

    /// Turns on the allocation tripwire. Debug builds only — it hooks the
    /// allocator process-wide.
    public static func enableAllocationTripwire() { yun_rt_tripwire_enable() }

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

    /// Grades the loopback capture against what was generated. Valid only while
    /// the route is still up, since stopping frees the capture.
    public func evaluateSelftest() -> SelftestResult? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let selftestBlock else { return nil }
        return RTSelftest.evaluate(selftestBlock)
    }

    /// How much of the capture buffer has been filled, as a fraction.
    public var selftestProgress: Double {
        guard let selftestBlock else { return 0 }
        let capacity = Double(selftestBlock.pointee.captureCapacity)
        guard capacity > 0 else { return 0 }
        return Double(selftestBlock.pointee.captureCount.pointee) / capacity
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
        let tapChannels = Dictionary(
            taps.map { ($0.uid, Int($0.format?.mChannelsPerFrame ?? 2)) },
            uniquingKeysWith: { first, _ in first })

        let inputStreams = aggregateDevice.inputStreams
        let outputStreams = aggregateDevice.outputStreams

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
        inputMap = Self.map(
            streams: inputStreams,
            orderedUIDs: inputUIDs,
            channelCount: { byUID[$0]?.inputChannels ?? tapChannels[$0] ?? 0 })
        outputMap = Self.map(
            streams: outputStreams,
            orderedUIDs: aggregate.subDevices.map(\.uid),
            channelCount: { byUID[$0]?.outputChannels ?? 0 })
        outputChannelCounts = outputStreams.map { $0.currentPhysicalFormat?.channels ?? 0 }
    }

    private static func map(
        streams: [AudioStream],
        orderedUIDs: [String],
        channelCount: (String) -> Int
    ) -> [ChannelRef: (buffer: Int32, channel: Int32)] {
        map(
            streamLayouts: streams.enumerated().map { index, stream in
                ChannelStreamLayout(
                    buffer: Int32(index),
                    startingChannel: stream.startingChannel,
                    channelCount: stream.currentPhysicalFormat?.channels ?? 0)
            },
            orderedUIDs: orderedUIDs,
            channelCount: channelCount)
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
    ) -> [ChannelRef: (buffer: Int32, channel: Int32)] {
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

        for uid in orderedUIDs {
            for channel in 0..<max(0, channelCount(uid)) {
                while streamIndex < orderedStreams.count,
                    channelInStream >= orderedStreams[streamIndex].channelCount
                {
                    streamIndex += 1
                    channelInStream = 0
                }
                guard streamIndex < orderedStreams.count else { break }
                let stream = orderedStreams[streamIndex]
                result[ChannelRef(deviceUID: uid, channel: channel)] =
                    (buffer: stream.buffer, channel: Int32(channelInStream))
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
        routePeaks.removeAll(keepingCapacity: true)
        routePeaks.reserveCapacity(count)
        if let graph {
            for index in 0..<count {
                routePeaks.append(graph.pointee.peaks[index])
            }
        }
        return TelemetryValues(
            cycleCount: graphCell.map { yun_rt_cell_cycles($0) },
            outputPeak: graph?.pointee.outputPeak ?? 0,
            outputClippedSamples: graph?.pointee.outputClipped ?? 0,
            failedPlugins: failedPlugins,
            droppedMonitor: droppedMonitor)
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
        graph = installed
        failedPlugins = snapshot.failedPlugins
        droppedMonitor = snapshot.droppedMonitor
    }

    /// Loudest sample leaving on the destination bus, after every gain stage.
    ///
    /// The one number that says whether what the far end receives is too quiet,
    /// about right, or already damaged. Nothing else in the engine measures
    /// after the multiply.
    public var outputPeak: Float {
        guard stateLock.try() else { return 0 }
        defer { stateLock.unlock() }
        return graph?.pointee.outputPeak ?? 0
    }

    /// Samples that reached or passed full scale on the destination bus since
    /// routing started.
    public var outputClippedSamples: UInt64 {
        guard stateLock.try() else { return 0 }
        defer { stateLock.unlock() }
        return graph?.pointee.outputClipped ?? 0
    }

    /// Clears the clip count, so a latch can be reset without restarting.
    public func clearOutputClipping() {
        stateLock.lock()
        defer { stateLock.unlock() }
        graph?.pointee.outputClipped = 0
    }

    // MARK: Calibration

    /// Starts accumulating per-source energy. Clears whatever was there.
    public func beginCalibration() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let graph else { return }
        let count = max(Int(graph.pointee.routeCount), 1)
        for index in 0..<count {
            graph.pointee.calibrationEnergy[index] = 0
            graph.pointee.calibrationFrames[index] = 0
        }
        graph.pointee.calibrating = 1
    }

    public func endCalibration() {
        stateLock.lock()
        defer { stateLock.unlock() }
        graph?.pointee.calibrating = 0
    }

    /// Gated RMS in dBFS and the seconds behind it, per route.
    public func calibrationLevels(sampleRate: Double) -> [(decibels: Double, seconds: Double)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let graph, sampleRate > 0 else { return [] }
        let count = Int(graph.pointee.routeCount)
        return (0..<count).map { index in
            let frames = graph.pointee.calibrationFrames[index]
            guard frames > 0 else { return (-Double.infinity, 0) }
            let mean = graph.pointee.calibrationEnergy[index] / Double(frames)
            let decibels = mean > 0 ? 10 * log10(mean) : -.infinity
            return (decibels, Double(frames) / sampleRate)
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
        return (0..<count).map { graph.pointee.rms[$0] }
    }

    /// Peak magnitude of each active route since the last read.
    public var routePeaks: [Float] {
        guard stateLock.try() else { return [] }
        defer { stateLock.unlock() }
        guard let graph else { return [] }
        let count = Int(graph.pointee.routeCount)
        return (0..<count).map { graph.pointee.peaks[$0] }
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

    /// Number of IO cycles completed. A stalled counter means the device is not
    /// actually pulling audio.
    ///
    /// For anything that wants a number to show. Anything comparing two
    /// readings wants `cycleCountIfKnown`.
    public var cycleCount: UInt64 { cycleCountIfKnown ?? 0 }

    /// The clock master's most recent timestamp, read through the cycle counter
    /// as a sequence number so a half-updated pair is never published.
    public var masterClockAnchor: ClockAnchor? {
        guard let sharedClock, isRunning else { return nil }
        let rate = aggregate?.device?.currentSampleRate ?? 0
        guard rate > 0 else { return nil }
        return Self.anchor(from: sharedClock, sampleRate: rate)
    }

    /// Reads the anchor pair using the cycle counter as a sequence number. The
    /// realtime thread writes both values before bumping the counter, so an
    /// unchanged counter either side of the read means the pair is consistent.
    static func anchor(
        from clock: RTGraph.SharedClock, sampleRate: Double
    ) -> ClockAnchor? {
        for _ in 0..<8 {
            let before = clock.cycleCounter.pointee
            let sampleTime = clock.sampleTime.pointee
            let hostTime = clock.hostTime.pointee
            let after = clock.cycleCounter.pointee
            if before == after, hostTime != 0 {
                return ClockAnchor(
                    sampleTime: sampleTime, hostTime: hostTime, sampleRate: sampleRate)
            }
        }
        return nil
    }

    /// True when the destination is our own driver and it has confirmed that it
    /// is following the master's clock.
    public var isClockLocked: Bool { clockPublisher?.isLocked ?? false }

    /// How far the master's crystal is from its nominal rate, as a ratio.
    public var measuredRateRatio: Double { clockPublisher?.rateRatio ?? 1.0 }

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
        return PathQuality(
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
                && (requiresClockLock ? isClockLocked : true),
            hasProcessing: processing,
            isClockLocked: isClockLocked,
            measuredRateRatio: measuredRateRatio,
            driftCorrectedDeviceUIDs: drifted,
            hasSampleRateMismatch: sampleRateMismatch,
            bufferFrames: Int(device.currentBufferFrameSize ?? 0),
            sampleRate: device.currentSampleRate ?? 0)
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
    case echoCancellerFailed
    case outputLimiterUnavailable

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
        case .echoCancellerFailed:
            "the echo canceller could not take the microphone and the speaker"
        case .outputLimiterUnavailable:
            "the final output limiter could not be prepared for this device layout"
        }
    }
}
