import Accelerate
import CoreAudio
import Foundation
import YunAudioRT

/// One source channel copied into one destination channel.
///
/// Deliberately a fixed-layout struct of scalars: the realtime callback walks
/// an array of these, and anything with a reference count in it would mean ARC
/// traffic on a time-constrained thread.
public struct RTRoute: Sendable, Equatable {
    /// Index into the IOProc's input `AudioBufferList`.
    public var sourceBuffer: Int32
    /// Channel within that buffer (buffers from an aggregate are interleaved).
    public var sourceChannel: Int32
    public var destinationBuffer: Int32
    public var destinationChannel: Int32
    public var gain: Float
    /// Int32 rather than Bool so the struct stays a fixed-layout scalar record
    /// that the command queue can update without any bridging.
    public var muted: Int32
    /// Non-zero when this route should read the voice-isolated signal instead
    /// of the raw input buffer.
    public var usesIsolatedSource: Int32
    /// Non-zero when this route should read the echo-cancelled microphone,
    /// which arrives across a ring from another IO thread rather than in this
    /// cycle's input buffer list.
    public var usesCancelledSource: Int32
    /// Non-zero when the input trim applies to this route — that is, when its
    /// source is the microphone rather than a tapped application. A trim that
    /// also moved the applications would be a master, and there is one of
    /// those already.
    public var appliesInputTrim: Int32
    /// Which stem file this route's source belongs to, or -1 for none.
    ///
    /// Stems are recorded per source rather than per route, so a stereo source
    /// lands in one two-channel file rather than two mono ones — and the two
    /// stay in step, which two independent rings could not guarantee.
    public var stemIndex: Int32
    /// Which channel of that stem this route carries.
    public var stemChannel: Int32

    /// Which transcription ring this route feeds, or -1 for none.
    ///
    /// Set on exactly one route per source — the first channel — rather than on
    /// all of them. A speech model does not benefit from a stereo fold, and one
    /// route per ring means the gather below is a single contiguous write per
    /// cycle with nothing to keep in step and nothing to scale.
    public var transcriptIndex: Int32

    /// Non-zero when this route gets out of the way while somebody is talking.
    ///
    /// Set for application audio, never for the microphone: ducking is the
    /// music going quiet under a voice, and a voice that ducked itself would be
    /// a gate with extra steps.
    public var isDuckable: Int32

    public init(
        sourceBuffer: Int32, sourceChannel: Int32,
        destinationBuffer: Int32, destinationChannel: Int32,
        gain: Float = 1.0,
        muted: Bool = false,
        usesIsolatedSource: Bool = false,
        usesCancelledSource: Bool = false,
        appliesInputTrim: Bool = false,
        isDuckable: Bool = false,
        stemIndex: Int32 = -1,
        stemChannel: Int32 = 0,
        transcriptIndex: Int32 = -1
    ) {
        self.sourceBuffer = sourceBuffer
        self.sourceChannel = sourceChannel
        self.destinationBuffer = destinationBuffer
        self.destinationChannel = destinationChannel
        self.gain = gain
        self.muted = muted ? 1 : 0
        self.usesIsolatedSource = usesIsolatedSource ? 1 : 0
        self.usesCancelledSource = usesCancelledSource ? 1 : 0
        self.appliesInputTrim = appliesInputTrim ? 1 : 0
        self.isDuckable = isDuckable ? 1 : 0
        self.stemIndex = stemIndex
        self.stemChannel = stemChannel
        self.transcriptIndex = transcriptIndex
    }
}

/// The realtime-visible state of the router.
///
/// Plain old data behind a manually managed pointer. It is never a Swift class
/// and never contains one, so the IOProc can read it without retain/release.
/// Allocation and deallocation happen only on the control thread.
struct RTGraph {
    var routes: UnsafeMutablePointer<RTRoute>
    var routeCount: Int32

    /// Audible route levels, one independently moving scalar per route.
    ///
    /// `RTRoute.gain` and `muted` remain the control truth. Keeping the moving
    /// value beside them rather than in them means a graph rebuild can carry
    /// the sample the listener reached without making the interface inherit an
    /// intermediate value.
    var routeGainSlews: UnsafeMutablePointer<RTGainSlew>

    /// Peak magnitude per route since the last cycle. Realtime code owns this
    /// mutable working storage; control readers use the atomic telemetry frame
    /// below rather than racing these ordinary floats.
    var peaks: UnsafeMutablePointer<Float>

    /// Smoothed RMS per route, alongside the peaks.
    ///
    /// Peak says whether something will clip; RMS is much closer to how loud it
    /// sounds, and for balancing two people against each other it is the only
    /// one of the two worth using — a plosive and a shout have similar peaks
    /// and nothing like the same level.
    var rms: UnsafeMutablePointer<Float>
    /// Coherent atomic publication of the realtime-owned meter arrays and
    /// output counters. Control code reads this storage, never the mutable
    /// fields above directly.
    var telemetry: OpaquePointer

    // MARK: Calibration

    /// Non-zero while a calibration pass is accumulating.
    var calibrating: Int32
    /// Identity of the most recent reset, carried as raw Float bits through the
    /// scalar mailbox. A replacement graph copies accumulated energy only when
    /// it names the same pass.
    var calibrationEpoch: UInt32
    /// Sum of squares per route since the pass started, and how many frames
    /// went into it. Double because a ten-second pass at 48 kHz is half a
    /// million samples and float would start losing the quiet ones.
    var calibrationEnergy: UnsafeMutablePointer<Double>
    var calibrationFrames: UnsafeMutablePointer<UInt64>
    /// Block RMS below which a cycle is not counted.
    ///
    /// Without this the measurement would be the average of somebody's voice
    /// *and* their silences, so whoever spoke least would be measured quietest
    /// and get the most gain — the exact opposite of what is wanted. It is the
    /// same reasoning as the loudness standard's gate, applied per source.
    var calibrationGate: Float

    /// Incremented once per IO cycle for the synthetic callback benchmark.
    /// Live graph retirement uses the atomic counter in `YunRTCell`; sharing
    /// this ordinary Swift allocation across threads would itself be a race.
    var cycleCounter: UnsafeMutablePointer<UInt64>

    /// Route-lifetime callback distribution; borrowed from the engine owner.
    /// Every graph generation receives the same fixed C allocation, and the
    /// engine frees it only after the IOProc destruction fence.
    var incidentTelemetry: OpaquePointer?
    /// The complete IO deadline for the settled route format, in nanoseconds.
    var incidentDeadlineNanoseconds: UInt64

    /// Per-cycle decay applied to the peak meters.
    ///
    /// Computed from the buffer size so the meter falls at the same rate in
    /// wall-clock terms whatever the buffer is. A fixed per-cycle factor ties
    /// the ballistics to the IO rate: at 128 frames the meter decays four times
    /// faster than at 512, for the same signal.
    var peakDecay: Float

    /// Most recent input timestamp from the aggregate, which is the clock
    /// master's own sample time. Published to the virtual driver so it can lock
    /// its clock to the microphone instead of free-running on the host clock.
    /// C11 atomics keep both the sequence and the payload free of data races.
    /// An unchanged ordinary Swift counter either side of two ordinary loads
    /// does not: the writer can pause between payload stores before touching
    /// that counter at all.
    var clock: OpaquePointer
    /// Zero when this graph borrowed the clock storage above from the engine
    /// rather than allocating its own.
    ///
    /// A patchbay edit swaps in a new graph and frees the old one, and the
    /// clock publisher reads that storage from its own queue — so storage tied
    /// to a single graph's lifetime is read after it is freed the first time
    /// anybody moves a cable. It belongs to the route, not to the graph.
    var ownsClockStorage: Int32

    /// The voice isolation stage, or null when it is not in use.
    var voiceIsolation: UnsafeMutablePointer<RTVoiceIsolation>?
    /// Non-zero when the isolation slot holds a multi-stage chain rather than
    /// the single isolation unit. They render through different types.
    var isolationIsChain: Int32
    /// Old and new processing paths during a live effect handover.
    ///
    /// The block remains installed after its fade completes, cheaply forwarding
    /// the new path, until the next control-thread graph swap retires it. That
    /// keeps every allocation and release off the IO thread.
    var effectTransition: UnsafeMutablePointer<RTEffectTransition>?

    /// Ring the recorder drains, or null when nothing is recording. Fed with
    /// the canonical destination mix after the master and before any output's
    /// correction, so a headphone profile is never baked into the file.
    var recordRing: OpaquePointer?
    /// Channels the recorder expects per frame.
    var recordChannels: Int32
    /// Non-zero while recording is paused.
    ///
    /// Paused at the source rather than in the writer: nothing is put into the
    /// ring at all, so the file becomes a seamless splice of the parts that
    /// were not paused. A writer that dropped frames instead would leave the
    /// ring holding audio from before the pause and play it back after.
    var recordPaused: Int32
    /// A limiter state owned by the recorder branch, or null.
    ///
    /// It cannot share the hardware output's detector: the recorder is taken
    /// before per-bus correction, while the hardware path is taken after it.
    /// Sharing one state would let a headphone-only boost turn down the file.
    var recordLimiter: UnsafeMutableRawPointer?
    /// Look-ahead output still to discard before the first real recorded frame.
    ///
    /// The same number is flushed at detach, so the file contains exactly the
    /// canonical sequence with no leading silence and no missing tail.
    var recordLimiterPrimingFrames: Int32
    /// Scratch for de-striding the destination bus before it goes into the ring.
    /// Allocated with the graph, because the IO thread cannot allocate and the
    /// destination is usually wider than the recording — BlackHole presents
    /// sixteen channels for a two-channel capture.
    var recordScratch: UnsafeMutablePointer<Float>
    var recordScratchCapacity: Int32

    /// Which output buffer is the destination the router is actually feeding.
    ///
    /// Everything that means "what the far end receives" — the recorder, the
    /// loudness meter, the spectrum — has to read this one. They all used
    /// `output[0]` on the assumption that there is only ever one destination,
    /// which stopped being true the moment monitoring could send the microphone
    /// somewhere else as well: the aggregate lists sub-devices in its own order,
    /// so buffer zero can perfectly well be the headphones.
    var mainOutputBuffer: Int32

    // MARK: Ducking

    /// Non-zero when application audio should get out of the way of a voice.
    var duckEnabled: Int32
    /// The gain duckable routes fall to while somebody is talking.
    var duckDepth: Float
    /// Microphone magnitude above which ducking triggers.
    var duckThreshold: Float
    /// Set by the control thread from Apple's sound classifier: non-zero while
    /// what the microphone is hearing has recently been speech.
    ///
    /// This is what separates it from a sidechain compressor. An envelope alone
    /// cannot tell a sentence from a cough, a keyboard or a chair, and every one
    /// of those would pull the music down. The model can, but it reports twice a
    /// second — far too slow to catch the front of a word. So the two are used
    /// for what each is good at: the envelope decides *when*, instantly, and the
    /// model decides *whether*, over the last few seconds.
    var duckAllowed: Int32
    /// Current smoothed duck gain, 1 when nothing is talking.
    ///
    /// Mirrored from `duckGainSlew` after each callback for the control-side
    /// diagnostics that already report this value.
    var duckGain: Float
    /// Moving duck state and per-sample smoothing coefficients. Attack is fast
    /// enough not to clip the first syllable, release slow enough that the
    /// music does not pump between words.
    var duckGainSlew: RTGainSlew
    var duckAttack: Float
    var duckRelease: Float
    /// Loudest microphone sample seen last cycle, which is what the trigger
    /// reads.
    ///
    /// Last cycle rather than this one because the duck has to be applied to a
    /// route in the same pass that reads it, and the microphone's level is not
    /// known until that pass is over. One buffer of lag is 2.7 ms at 128 frames,
    /// which is nothing next to an attack measured in tens of milliseconds.
    var micPeak: Float

    // MARK: What actually leaves

    /// Loudest sample on the destination bus after every gain stage, decayed
    /// like the route meters.
    ///
    /// The route meters are deliberately taken *before* gain, so that a meter
    /// shows what arrived rather than what the fader did to it. That is right
    /// for a fader, and it meant nothing in the application could see the one
    /// thing that ruins a call: the trim, the master or a route gain pushing
    /// the signal past full scale. Everything downstream truncates it, the far
    /// end hears distortion, and every meter here reads healthy because none of
    /// them was looking after the multiply.
    var outputPeak: Float
    /// Samples at or beyond full scale on the destination bus since the last
    /// read. Non-zero means audible damage has already happened.
    var outputClipped: UInt64
    /// Identity of the most recent manual reset. This prevents a graph swap
    /// from restoring a predecessor's latch while its reset command is pending.
    var outputClippingEpoch: UInt32
    /// Final linked limiter shared by every output buffer, retained by the
    /// engine and reached here without touching a reference count.
    var outputLimiter: UnsafeMutableRawPointer?
    /// Non-zero when the final limiter attenuates. Its delay stays installed
    /// while bypassed so a live toggle cannot shift the complete mix by a
    /// millisecond in one callback.
    var outputLimiterEnabled: Int32
    /// Linear drive into the final and recording limiters.
    var outputLimiterPreGain: Float
    /// Topology mismatches rejected by the final stage.
    ///
    /// Such a bus is silenced rather than sent unbounded or walked with a stale
    /// channel stride. This counter makes the fail-closed branch observable.
    var outputLimiterFailures: UInt64

    /// An output buffer the master fader does not apply to, or -1 for none.
    ///
    /// This is the monitor. The master is the level going to the far end, and
    /// pulling it down — or muting it — must not take away the ability to hear
    /// yourself. The input trim and input mute *do* reach the monitor, through
    /// the route's own `appliesInputTrim`, which is the behaviour anybody
    /// expects: muting the microphone should stop you hearing it.
    var masterExemptBuffer: Int32

    /// Trim on the microphone, applied before any route reads it, and the
    /// master on the output bus, applied after everything is mixed into it.
    ///
    /// The per-route faders are for balancing sources against each other. These
    /// two are the ones anybody expects to find first: how loud the microphone
    /// is, and how loud the whole thing comes out.
    var inputGain: Float
    var inputMuted: Int32
    var outputGain: Float
    var outputMuted: Int32
    /// Audible input and output levels. Targets above remain separate so an
    /// in-flight ramp never leaks back into persisted control state.
    var inputGainSlew: RTGainSlew
    var outputGainSlew: RTGainSlew
    /// Five milliseconds towards silence; ten for every move away from it.
    var muteRampFrames: Int32
    var gainRampFrames: Int32
    /// Three contiguous callback envelopes: input, duck and output. They are
    /// shared rather than advanced once per route, which makes the answer
    /// independent of route count and keeps the states on one timeline.
    var gainEnvelopeScratch: UnsafeMutablePointer<Float>
    var gainEnvelopeCapacity: Int32
    /// Zero until the first callback has installed setup-time target changes.
    ///
    /// Tests are not the only caller that configures an unpublished graph by
    /// writing its scalar targets. Making that setup atomic prevents a stored
    /// mute from opening for the first five milliseconds of a fresh route.
    var hasRendered: Int32

    /// Echo-cancelled microphone frames, or null when the canceller is off.
    ///
    /// The microphone is not in this aggregate when echo cancellation is on —
    /// `AUVoiceProcessingIO` owns it, bound to an aggregate of its own holding
    /// the microphone and the speaker, because it can only cancel a speaker it
    /// is also driving. So the cancelled signal arrives across a ring from that
    /// unit's IO thread instead of in this cycle's input buffer list, and a
    /// route reads it through `usesCancelledSource` rather than by buffer index.
    var cancelledRing: OpaquePointer?
    /// Mono, packed. Drained once per cycle so several routes share one read;
    /// draining per route would give each a different slice of the stream.
    var cancelledBuffer: UnsafeMutablePointer<Float>
    var cancelledCapacity: Int32
    /// Frames drained this cycle. Zero while the canceller is still filling.
    var cancelledFrames: Int32

    /// Non-zero while something is actually consuming the analysis ring.
    ///
    /// The fold below is cheap but it is not free, and it runs on the IO thread
    /// every cycle. With the panel closed and levelling off there is no
    /// consumer, so the work — and the ring traffic behind it — is skipped
    /// rather than performed for nobody.
    var analysisEnabled: Int32

    // MARK: Stems

    /// One ring per source being recorded separately, or null.
    ///
    /// Recording the mix answers "what did the far end hear"; recording each
    /// source answers "what did each of us say", which is the question anybody
    /// editing a podcast afterwards actually has. The two are different files
    /// and both are worth having.
    var stemRings: UnsafeMutablePointer<OpaquePointer?>
    /// Channels each stem expects per frame.
    var stemChannels: UnsafeMutablePointer<Int32>
    /// Interleaved scratch, `stemCapacity` frames of `maxStemChannels` per stem.
    /// Written during the route loop and drained once at the end, so a stereo
    /// source goes into its ring as whole frames rather than two half-frames
    /// that could be split by a short write.
    var stemScratch: UnsafeMutablePointer<Float>
    var stemCount: Int32
    var stemCapacity: Int32
    /// Frames put into the scratch this cycle.
    var stemFrames: Int32
    static let maxStemChannels = 2

    // MARK: Aligning what did not go through the chain

    /// Frames every path that skipped the effect chain is held back by.
    ///
    /// The chain's own reported latency, so the two arrive together. Zero when
    /// nothing in the chain adds any, which is the ordinary case and costs one
    /// branch per route.
    var alignmentFrames: Int32
    /// One route-lifetime history owner per slot.
    ///
    /// Graph generations borrow these pointers. Reusing the route's owner
    /// makes a publication O(routes): the first callback adopts meters and
    /// slews, but never copies 8192 samples for every retained route.
    var alignmentHistories: UnsafeMutablePointer<UnsafeMutablePointer<AlignmentHistory>>
    /// Non-zero only when this standalone graph allocated the owners above.
    /// Production graphs borrow owners from `RoutingEngine` until their route's
    /// retirement fence passes.
    var ownsAlignmentHistories: Int32
    /// Packed scratch for one route's delayed block, reused by each in turn.
    var alignmentScratch: UnsafeMutablePointer<Float>
    var alignmentCapacity: Int32
    /// The longest delay a chain can ask for.
    ///
    /// Voice isolation, the longest stage here, is 56 ms — 5376 frames at
    /// 96 kHz, the highest rate this router offers. Eight thousand is the next
    /// power of two above that with room to spare. Fixed because the lines are
    /// allocated once and handed to the IO thread, and a delay that could grow
    /// without bound would mean allocating there.
    static let maximumAlignmentFrames = 8192
    /// Hard topology admission bound for the realtime graph.
    ///
    /// Every per-route loop and scratch allocation is therefore measurable at
    /// one finite worst case. Sixty-four covers the external parity target and
    /// keeps the shortest supported 64-frame/96-kHz callback bounded.
    static let maximumRoutes = 64
    /// The publisher refuses a ninth unreclaimed generation. Mirroring that
    /// bound here turns corrupted handover metadata into one fresh-state cycle
    /// instead of an unbounded walk on the audio thread.
    static let maximumStateHandoverDepth = 8

    // MARK: Per-bus correction

    /// The independently published correction state for every output buffer.
    ///
    /// An unmanaged reference keeps ARC off the IO thread. Each graph owns one
    /// retain; live graph swaps retain the same bank so its filter history
    /// moves without being copied from under the callback.
    var outputCorrections: UnsafeMutableRawPointer
    static let maximumEQStages = OutputCorrectionBank.maximumStages
    static let maximumEQChannels = OutputCorrectionBank.maximumChannels
    static let maximumEQBuffers = OutputCorrectionBank.maximumSlots

    // MARK: Transcription

    /// One ring per source being transcribed, or null.
    ///
    /// Separate from the stems because the two are wanted separately: somebody
    /// transcribing a call is usually not also recording one, and a transcript
    /// that only worked while stem recording was on would be a surprising rule
    /// to have to learn.
    ///
    /// Mono, at the router's rate. The framework's own converter resamples to
    /// whatever the model wants, which is not this rate.
    var transcriptRings: UnsafeMutablePointer<OpaquePointer?>
    /// Gather space for one route's channel, reused by each in turn. A single
    /// buffer is enough because the write happens immediately after the gather
    /// — there is only ever one route per ring, so nothing has to be held
    /// until the end of the cycle the way a stereo stem does.
    var transcriptScratch: UnsafeMutablePointer<Float>
    var transcriptCount: Int32
    var transcriptCapacity: Int32

    /// Ring carrying a mono fold of the output bus to the analysers.
    ///
    /// Separate from `recordRing` even though both come off the same bus,
    /// because they answer to different consumers: the recorder must not lose a
    /// sample and stops when nothing is recording, while the analysers want a
    /// continuous stream and would rather drop than stall. Sharing one ring
    /// would mean the loudness meter reading nothing until somebody pressed
    /// record.
    var analysisRing: OpaquePointer?
    /// Zero when the route owns the analysis ring and every graph only borrows
    /// it. A consumer keeps one read cursor across live publications, so
    /// transferring ownership by clearing the retiring graph is itself an
    /// illegal mutation of memory a callback may still be reading.
    var ownsAnalysisRing: Int32
    /// Where the mono fold is built before it goes into the ring. The IO thread
    /// cannot allocate, and the output bus is interleaved and usually wider
    /// than two channels.
    var analysisScratch: UnsafeMutablePointer<Float>
    var analysisCapacity: Int32

    /// Parameter changes waiting to be applied. Drained at the top of each
    /// cycle so a fader move lands without rebuilding anything.
    var commands: OpaquePointer?
    /// Latest value of every continuous control.
    ///
    /// Engine changes use this rather than the FIFO above: a full event queue
    /// must never discard the final microphone mute. The FIFO remains for
    /// discrete compatibility probes and is drained before this mailbox, so
    /// the latest desired value always wins.
    var controlMailbox: OpaquePointer?

    /// Null unless a loopback integrity check is running. Checked once per
    /// cycle, so the normal path costs one predictable branch.
    var selftest: UnsafeMutablePointer<RTSelftest>?

    // MARK: Publication handover

    /// The graph which held the preceding callback's moving state.
    ///
    /// The control thread may publish a replacement while the callback is
    /// still inside this predecessor, so copying its slews, meters or delay
    /// lines before publication is a data race. Core Audio serialises calls to
    /// one IOProc. The first callback which observes the replacement is
    /// therefore the first context that can safely copy this state.
    var stateHandover: UnsafeMutablePointer<RTGraph>?
    /// For each new route, its slot in `stateHandover`, or -1 when it is new.
    var stateHandoverRoutes: UnsafeMutablePointer<Int32>

    /// Peak meters fall by 20 dB per second, which is the usual ballistic for
    /// a peak-reading meter and slow enough to read.
    static func decay(bufferFrames: Int, sampleRate: Double) -> Float {
        guard bufferFrames > 0, sampleRate > 0 else { return 0.85 }
        let secondsPerCycle = Double(bufferFrames) / sampleRate
        return Float(pow(10.0, -20.0 * secondsPerCycle / 20.0))
    }

    /// Peak-meter release with a finite silence state.
    ///
    /// The display floors at −60 dBFS. Keeping smaller values alive made the
    /// callback publish an ever-decreasing subnormal forever; converting that
    /// residue to decibels eventually produced readings such as −865 dBFS.
    @inline(__always)
    static func nextMeterPeak(previous: Float, incoming: Float, decay: Float) -> Float {
        let next = max(incoming, previous * decay)
        return next <= 0.001 ? 0 : next
    }

    /// One-pole smoothing coefficient for a given time constant.
    ///
    /// Expressed in seconds rather than as a per-cycle number for the same
    /// reason the meter decay is: a fixed factor would make the attack four
    /// times faster at 128 frames than at 512, for the same setting.
    static func coefficient(
        seconds: Double, bufferFrames: Int, sampleRate: Double
    ) -> Float {
        guard seconds > 0, bufferFrames > 0, sampleRate > 0 else { return 0.5 }
        let perCycle = Double(bufferFrames) / sampleRate
        return Float(exp(-perCycle / seconds))
    }

    /// One-pole coefficient for one sample rather than one callback.
    static func sampleCoefficient(seconds: Double, sampleRate: Double) -> Float {
        guard seconds > 0, sampleRate > 0 else { return 0.5 }
        return Float(exp(-1 / (seconds * sampleRate)))
    }

    /// A wall-clock duration represented as a bounded whole number of frames.
    static func rampFrames(seconds: Double, sampleRate: Double) -> Int32 {
        guard seconds > 0, sampleRate > 0 else { return 1 }
        let frames = min(max((seconds * sampleRate).rounded(), 1), Double(Int32.max))
        return Int32(frames)
    }

    /// Frames one processing stage may consume from this callback.
    ///
    /// Capacity is storage, never a request to manufacture more audio. Keeping
    /// this decision shared by the steady and transition paths makes a 4096-
    /// frame safety allocation harmless to an ordinary 64- or 256-frame slice.
    @inline(__always)
    static func processingFrames(available: Int, capacity: Int) -> Int {
        max(0, min(available, capacity))
    }

    /// Storage whose lifetime is the route's rather than any one graph's.
    struct SharedClock {
        let storage: OpaquePointer

        static func allocate() -> SharedClock {
            guard let storage = yun_rt_clock_create() else {
                preconditionFailure("could not allocate the realtime clock")
            }
            return SharedClock(storage: storage)
        }

        func deallocate() {
            yun_rt_clock_free(storage)
        }
    }

    /// Analysis storage belongs to one running route, not one graph generation.
    struct SharedAnalysisRing {
        let storage: OpaquePointer

        static func allocate() -> SharedAnalysisRing {
            guard let storage = yun_rt_ring_create(131_072) else {
                preconditionFailure("could not allocate the analysis ring")
            }
            return SharedAnalysisRing(storage: storage)
        }

        func deallocate() {
            yun_rt_ring_free(storage)
        }
    }

    /// Mutable delay state which survives graph generations for one route.
    struct AlignmentHistory {
        var line: UnsafeMutablePointer<Float>
        var position: Int32
    }

    /// Explicit owner for one route's fixed-capacity alignment history.
    struct SharedAlignmentHistory: @unchecked Sendable {
        let storage: UnsafeMutablePointer<AlignmentHistory>

        static func allocate() -> SharedAlignmentHistory {
            let line = UnsafeMutablePointer<Float>.allocate(
                capacity: maximumAlignmentFrames)
            line.initialize(repeating: 0, count: maximumAlignmentFrames)
            let storage = UnsafeMutablePointer<AlignmentHistory>.allocate(capacity: 1)
            storage.initialize(to: AlignmentHistory(line: line, position: 0))
            return SharedAlignmentHistory(storage: storage)
        }

        func deallocate() {
            storage.pointee.line.deinitialize(count: RTGraph.maximumAlignmentFrames)
            storage.pointee.line.deallocate()
            storage.deinitialize(count: 1)
            storage.deallocate()
        }
    }

    static func supportsRouteCount(_ count: Int) -> Bool {
        count >= 0 && count <= maximumRoutes
    }

    /// Every derived allocation and narrow integer needed by one graph.
    ///
    /// Constructed before the first allocation so an invalid HAL value cannot
    /// leave a half-built graph or reach a trapping integer conversion.
    struct AllocationPlan: Equatable {
        let routeStorageCount: Int
        let routeCount: Int32
        let routeStorageCount32: Int32
        let routeCountForC: UInt32
        let processingCapacity: Int
        let processingCapacity32: Int32
        let recordScratchCount: Int
        let recordScratchCount32: Int32
        let stemScratchCount: Int
        let gainEnvelopeCount: Int
    }

    static func allocationPlan(
        routeCount: Int, bufferFrames: Int, sampleRate: Double
    ) -> AllocationPlan? {
        guard supportsRouteCount(routeCount),
            AudioProcessingContract.supports(framesPerSlice: bufferFrames),
            AudioProcessingContract.supports(sampleRate: sampleRate)
        else { return nil }

        let routeStorageCount = max(routeCount, 1)
        let processingCapacity = AudioProcessingContract.maximumFramesPerSlice
        guard
            let recordScratchCount = AudioProcessingContract.checkedProduct(
                processingCapacity, 2),
            let stemScratchCount = AudioProcessingContract.checkedProduct(
                routeStorageCount, processingCapacity, maxStemChannels),
            let gainEnvelopeCount = AudioProcessingContract.checkedProduct(
                processingCapacity, 3),
            let routeCount32 = Int32(exactly: routeCount),
            let routeStorageCount32 = Int32(exactly: routeStorageCount),
            let routeCountForC = UInt32(exactly: routeCount),
            let processingCapacity32 = Int32(exactly: processingCapacity),
            let recordScratchCount32 = Int32(exactly: recordScratchCount)
        else { return nil }

        return AllocationPlan(
            routeStorageCount: routeStorageCount,
            routeCount: routeCount32,
            routeStorageCount32: routeStorageCount32,
            routeCountForC: routeCountForC,
            processingCapacity: processingCapacity,
            processingCapacity32: processingCapacity32,
            recordScratchCount: recordScratchCount,
            recordScratchCount32: recordScratchCount32,
            stemScratchCount: stemScratchCount,
            gainEnvelopeCount: gainEnvelopeCount)
    }

    /// Production entry point. Invalid numeric dimensions are a refused graph,
    /// not a precondition failure or a request to the allocator.
    static func allocateIfSupported(
        routes routeList: [RTRoute], bufferFrames: Int = 128, sampleRate: Double = 48000,
        sharedClock: SharedClock? = nil,
        sharedAnalysisRing: SharedAnalysisRing? = nil,
        sharedAlignmentHistories: [SharedAlignmentHistory]? = nil
    ) -> UnsafeMutablePointer<RTGraph>? {
        guard
            allocationPlan(
                routeCount: routeList.count, bufferFrames: bufferFrames,
                sampleRate: sampleRate) != nil,
            sharedAlignmentHistories == nil
                || sharedAlignmentHistories?.count == routeList.count
        else { return nil }
        return allocate(
            routes: routeList, bufferFrames: bufferFrames, sampleRate: sampleRate,
            sharedClock: sharedClock, sharedAnalysisRing: sharedAnalysisRing,
            sharedAlignmentHistories: sharedAlignmentHistories)
    }

    /// Trusted fixture entry point. Production code uses `allocateIfSupported`.
    static func allocate(
        routes routeList: [RTRoute], bufferFrames: Int = 128, sampleRate: Double = 48000,
        sharedClock: SharedClock? = nil,
        sharedAnalysisRing: SharedAnalysisRing? = nil,
        sharedAlignmentHistories: [SharedAlignmentHistory]? = nil
    ) -> UnsafeMutablePointer<RTGraph> {
        guard
            let plan = allocationPlan(
                routeCount: routeList.count, bufferFrames: bufferFrames,
                sampleRate: sampleRate)
        else {
            preconditionFailure("unsupported realtime graph dimensions")
        }
        precondition(
            sharedAlignmentHistories == nil
                || sharedAlignmentHistories?.count == routeList.count,
            "one alignment history is required for every route")
        let count = plan.routeStorageCount

        let routeStorage = UnsafeMutablePointer<RTRoute>.allocate(capacity: count)
        routeStorage.initialize(
            repeating: RTRoute(
                sourceBuffer: 0, sourceChannel: 0,
                destinationBuffer: 0, destinationChannel: 0, gain: 0, muted: true,
                usesIsolatedSource: false, usesCancelledSource: false,
                appliesInputTrim: false), count: count)
        for (index, route) in routeList.enumerated() {
            routeStorage[index] = route
        }
        let routeSlewStorage = UnsafeMutablePointer<RTGainSlew>.allocate(capacity: count)
        routeSlewStorage.initialize(repeating: RTGainSlew(0), count: count)
        for (index, route) in routeList.enumerated() {
            routeSlewStorage[index] = RTGainSlew(route.muted != 0 ? 0 : route.gain)
        }
        let handoverRouteStorage = UnsafeMutablePointer<Int32>.allocate(capacity: count)
        handoverRouteStorage.initialize(repeating: -1, count: count)

        let peakStorage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        peakStorage.initialize(repeating: 0, count: count)
        let rmsStorage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        rmsStorage.initialize(repeating: 0, count: count)
        let energyStorage = UnsafeMutablePointer<Double>.allocate(capacity: count)
        energyStorage.initialize(repeating: 0, count: count)
        let framesStorage = UnsafeMutablePointer<UInt64>.allocate(capacity: count)
        framesStorage.initialize(repeating: 0, count: count)
        guard let telemetryStorage = yun_rt_telemetry_create(plan.routeCountForC) else {
            preconditionFailure("could not allocate realtime telemetry")
        }

        let counterStorage = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        counterStorage.initialize(to: 0)

        // Sized for the largest block the device is likely to ask for, times a
        // stereo frame.
        let scratchCapacity = plan.recordScratchCount
        let scratchStorage = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratchStorage.initialize(repeating: 0, count: scratchCapacity)

        // Sized for the largest block the device is likely to ask for. Mono, so
        // no channel factor.
        let cancelledCapacity = plan.processingCapacity
        let cancelledStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: cancelledCapacity)
        cancelledStorage.initialize(repeating: 0, count: cancelledCapacity)

        // One slot per route is the most stems there can be, and costs a
        // pointer each.
        let stemRingStorage = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: count)
        stemRingStorage.initialize(repeating: nil, count: count)
        let stemChannelStorage = UnsafeMutablePointer<Int32>.allocate(capacity: count)
        stemChannelStorage.initialize(repeating: 0, count: count)
        let stemScratchCount = plan.stemScratchCount
        let stemScratchStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: stemScratchCount)
        stemScratchStorage.initialize(repeating: 0, count: stemScratchCount)

        let alignmentHistoryStorage = UnsafeMutablePointer<
            UnsafeMutablePointer<AlignmentHistory>
        >.allocate(capacity: count)
        let ownsAlignmentHistories = sharedAlignmentHistories == nil || routeList.isEmpty
        if let sharedAlignmentHistories, !routeList.isEmpty {
            for index in routeList.indices {
                alignmentHistoryStorage[index] = sharedAlignmentHistories[index].storage
            }
        } else {
            for index in 0..<count {
                alignmentHistoryStorage[index] = SharedAlignmentHistory.allocate().storage
            }
        }
        let alignmentCapacity = plan.processingCapacity
        let alignmentScratchStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: alignmentCapacity)
        alignmentScratchStorage.initialize(repeating: 0, count: alignmentCapacity)

        let correctionBank = OutputCorrectionBank(
            sampleRate: sampleRate, maximumFrames: plan.processingCapacity)!
        let correctionStorage =
            Unmanaged.passRetained(correctionBank).toOpaque()

        let transcriptRingStorage = UnsafeMutablePointer<OpaquePointer?>.allocate(
            capacity: count)
        transcriptRingStorage.initialize(repeating: nil, count: count)
        let transcriptCapacity = plan.processingCapacity
        let transcriptScratchStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: transcriptCapacity)
        transcriptScratchStorage.initialize(repeating: 0, count: transcriptCapacity)

        let analysisCapacity = plan.processingCapacity
        let analysisScratch = UnsafeMutablePointer<Float>.allocate(
            capacity: analysisCapacity)
        analysisScratch.initialize(repeating: 0, count: analysisCapacity)

        let gainEnvelopeStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: plan.gainEnvelopeCount)
        gainEnvelopeStorage.initialize(repeating: 1, count: plan.gainEnvelopeCount)

        let ownsClockStorage = sharedClock == nil
        guard let clockStorage = sharedClock?.storage ?? yun_rt_clock_create() else {
            preconditionFailure("could not allocate the realtime clock")
        }

        let graph = UnsafeMutablePointer<RTGraph>.allocate(capacity: 1)
        graph.initialize(
            to: RTGraph(
                routes: routeStorage,
                routeCount: plan.routeCount,
                routeGainSlews: routeSlewStorage,
                peaks: peakStorage,
                rms: rmsStorage,
                telemetry: telemetryStorage,
                calibrating: 0,
                calibrationEpoch: 0,
                calibrationEnergy: energyStorage,
                calibrationFrames: framesStorage,
                // −60 dBFS. Below this nobody is talking into anything.
                calibrationGate: 0.001,
                cycleCounter: counterStorage,
                incidentTelemetry: nil,
                incidentDeadlineNanoseconds: 0,
                peakDecay: decay(bufferFrames: bufferFrames, sampleRate: sampleRate),
                clock: clockStorage,
                ownsClockStorage: ownsClockStorage ? 1 : 0,
                voiceIsolation: nil,
                isolationIsChain: 0,
                effectTransition: nil,
                recordRing: nil,
                recordChannels: 0,
                recordPaused: 0,
                recordLimiter: nil,
                recordLimiterPrimingFrames: 0,
                recordScratch: scratchStorage,
                recordScratchCapacity: plan.recordScratchCount32,
                mainOutputBuffer: 0,
                duckEnabled: 0,
                duckDepth: 0.1,
                duckThreshold: 0.02,
                duckAllowed: 0,
                duckGain: 1,
                duckGainSlew: RTGainSlew(1),
                duckAttack: sampleCoefficient(seconds: 0.08, sampleRate: sampleRate),
                duckRelease: sampleCoefficient(seconds: 0.6, sampleRate: sampleRate),
                micPeak: 0,
                outputPeak: 0,
                outputClipped: 0,
                outputClippingEpoch: 0,
                outputLimiter: nil,
                outputLimiterEnabled: 0,
                outputLimiterPreGain: 1,
                outputLimiterFailures: 0,
                masterExemptBuffer: -1,
                inputGain: 1,
                inputMuted: 0,
                outputGain: 1,
                outputMuted: 0,
                inputGainSlew: RTGainSlew(1),
                outputGainSlew: RTGainSlew(1),
                muteRampFrames: rampFrames(seconds: 0.005, sampleRate: sampleRate),
                gainRampFrames: rampFrames(seconds: 0.010, sampleRate: sampleRate),
                gainEnvelopeScratch: gainEnvelopeStorage,
                gainEnvelopeCapacity: plan.processingCapacity32,
                hasRendered: 0,
                cancelledRing: nil,
                cancelledBuffer: cancelledStorage,
                cancelledCapacity: plan.processingCapacity32,
                cancelledFrames: 0,
                // Two seconds at 48 kHz. Long enough that a UI poll at any
                // practical rate finds a whole 400 ms loudness block waiting,
                // short enough that a stalled consumer discards stale audio
                // rather than showing a reading from a second ago.
                analysisEnabled: 0,
                stemRings: stemRingStorage,
                stemChannels: stemChannelStorage,
                stemScratch: stemScratchStorage,
                stemCount: plan.routeStorageCount32,
                stemCapacity: plan.processingCapacity32,
                stemFrames: 0,
                alignmentFrames: 0,
                alignmentHistories: alignmentHistoryStorage,
                ownsAlignmentHistories: ownsAlignmentHistories ? 1 : 0,
                alignmentScratch: alignmentScratchStorage,
                alignmentCapacity: plan.processingCapacity32,
                outputCorrections: correctionStorage,
                transcriptRings: transcriptRingStorage,
                transcriptScratch: transcriptScratchStorage,
                transcriptCount: plan.routeStorageCount32,
                transcriptCapacity: plan.processingCapacity32,
                analysisRing: sharedAnalysisRing?.storage ?? yun_rt_ring_create(131_072),
                ownsAnalysisRing: sharedAnalysisRing == nil ? 1 : 0,
                analysisScratch: analysisScratch,
                analysisCapacity: plan.processingCapacity32,
                commands: yun_rt_queue_create(256),
                controlMailbox: yun_rt_control_mailbox_create(plan.routeCountForC),
                selftest: nil,
                stateHandover: nil,
                stateHandoverRoutes: handoverRouteStorage))
        return graph
    }

    static func deallocate(_ graph: UnsafeMutablePointer<RTGraph>) {
        let count = max(Int(graph.pointee.routeCount), 1)
        graph.pointee.routes.deinitialize(count: count)
        graph.pointee.routes.deallocate()
        graph.pointee.routeGainSlews.deinitialize(count: count)
        graph.pointee.routeGainSlews.deallocate()
        graph.pointee.stateHandoverRoutes.deinitialize(count: count)
        graph.pointee.stateHandoverRoutes.deallocate()
        graph.pointee.peaks.deinitialize(count: count)
        graph.pointee.peaks.deallocate()
        graph.pointee.rms.deinitialize(count: count)
        graph.pointee.rms.deallocate()
        yun_rt_telemetry_free(graph.pointee.telemetry)
        graph.pointee.calibrationEnergy.deinitialize(count: count)
        graph.pointee.calibrationEnergy.deallocate()
        graph.pointee.calibrationFrames.deinitialize(count: count)
        graph.pointee.calibrationFrames.deallocate()
        graph.pointee.cycleCounter.deinitialize(count: 1)
        graph.pointee.cycleCounter.deallocate()
        graph.pointee.recordScratch.deinitialize(
            count: Int(graph.pointee.recordScratchCapacity))
        graph.pointee.recordScratch.deallocate()
        graph.pointee.cancelledBuffer.deinitialize(
            count: Int(graph.pointee.cancelledCapacity))
        graph.pointee.cancelledBuffer.deallocate()
        if graph.pointee.ownsClockStorage != 0 {
            yun_rt_clock_free(graph.pointee.clock)
        }
        graph.pointee.stemRings.deinitialize(count: count)
        graph.pointee.stemRings.deallocate()
        graph.pointee.stemChannels.deinitialize(count: count)
        graph.pointee.stemChannels.deallocate()
        let stemScratchCount =
            count * Int(graph.pointee.stemCapacity) * maxStemChannels
        graph.pointee.stemScratch.deinitialize(count: stemScratchCount)
        graph.pointee.stemScratch.deallocate()
        if graph.pointee.ownsAlignmentHistories != 0 {
            for index in 0..<count {
                SharedAlignmentHistory(
                    storage: graph.pointee.alignmentHistories[index]
                ).deallocate()
            }
        }
        graph.pointee.alignmentHistories.deallocate()
        graph.pointee.alignmentScratch.deinitialize(
            count: Int(graph.pointee.alignmentCapacity))
        graph.pointee.alignmentScratch.deallocate()
        Unmanaged<OutputCorrectionBank>
            .fromOpaque(graph.pointee.outputCorrections).release()
        graph.pointee.transcriptRings.deinitialize(count: count)
        graph.pointee.transcriptRings.deallocate()
        graph.pointee.transcriptScratch.deinitialize(
            count: Int(graph.pointee.transcriptCapacity))
        graph.pointee.transcriptScratch.deallocate()
        graph.pointee.analysisScratch.deinitialize(
            count: Int(graph.pointee.analysisCapacity))
        graph.pointee.analysisScratch.deallocate()
        graph.pointee.gainEnvelopeScratch.deinitialize(
            count: Int(graph.pointee.gainEnvelopeCapacity) * 3)
        graph.pointee.gainEnvelopeScratch.deallocate()
        if graph.pointee.ownsAnalysisRing != 0, let ring = graph.pointee.analysisRing {
            yun_rt_ring_free(ring)
        }
        if let commands = graph.pointee.commands { yun_rt_queue_free(commands) }
        if let mailbox = graph.pointee.controlMailbox {
            yun_rt_control_mailbox_free(mailbox)
        }
        graph.deinitialize(count: 1)
        graph.deallocate()
    }

    // MARK: Installing a correction

    /// Puts one output's cascade into an unpublished graph.
    ///
    /// Here rather than in `RoutingEngine` because the slot arithmetic is the
    /// part that is easy to get wrong — an off-by-one in the stride would run
    /// bus A's curve on bus B's history and sound like nothing in particular —
    /// and it should exist in exactly one place.
    ///
    /// Live changes go through `OutputCorrectionBank.publish`. Keeping this
    /// setup-only entry point makes it impossible for a test or graph builder
    /// to bypass the same slot bounds and coefficient validation.
    ///
    /// - Parameters:
    ///   - packed: Five coefficients per section, as `ParametricEQ` produces.
    ///   - preampGain: Linear headroom, applied ahead of the first section.
    ///   - buffer: Which output buffer, which is also the slot.
    ///   - graph: The graph to install into.
    /// - Returns: True when something will now run on that output. False means
    ///   the curve was empty or the buffer is beyond the fixed table, and in
    ///   either case the slot is left running nothing.
    @discardableResult
    static func installCorrection(
        _ packed: [Float], preampGain: Float, onBuffer buffer: Int,
        of graph: UnsafeMutablePointer<RTGraph>
    ) -> Bool {
        let bank = correctionBank(of: graph)
        let configuration = OutputCorrectionBank.Configuration(
            coefficients: packed, preampGain: preampGain)
        return bank.installImmediately(configuration, slot: buffer)
    }

    /// Takes a correction off one unpublished output.
    static func clearCorrection(
        onBuffer buffer: Int, of graph: UnsafeMutablePointer<RTGraph>
    ) {
        _ = correctionBank(of: graph).installImmediately(nil, slot: buffer)
    }

    static func correctionBank(
        of graph: UnsafeMutablePointer<RTGraph>
    ) -> OutputCorrectionBank {
        Unmanaged<OutputCorrectionBank>
            .fromOpaque(graph.pointee.outputCorrections).takeUnretainedValue()
    }

    /// Carries one route's alignment delay line across a graph rebuild.
    ///
    /// The line always uses `maximumAlignmentFrames` as its modulus, even while
    /// today's delay is zero. Its history therefore remains ordered when a new
    /// effect asks for a different delay. Refusing to carry it on that exact
    /// rebuild would fill a backing track with silence while the new line
    /// warmed up — the same discontinuity the effect handover exists to avoid.
    ///
    /// Production generations point at the same route-lifetime owner, so the
    /// common path is two pointer comparisons. Copying remains only for
    /// standalone graphs and deliberately replaced owners.
    ///
    /// - Returns: True when the history was already shared or was copied.
    @discardableResult
    static func carryAlignment(
        from previous: UnsafeMutablePointer<RTGraph>, slot old: Int,
        to next: UnsafeMutablePointer<RTGraph>, slot new: Int
    ) -> Bool {
        guard old >= 0, old < Int(previous.pointee.routeCount),
            new >= 0, new < Int(next.pointee.routeCount)
        else { return false }
        let from = previous.pointee.alignmentHistories[old]
        let to = next.pointee.alignmentHistories[new]
        if from == to { return true }
        to.pointee.line.update(from: from.pointee.line, count: maximumAlignmentFrames)
        to.pointee.position = from.pointee.position
        return true
    }

    /// Shares every slot — curves and history alike — with a live replacement graph.
    ///
    /// Retaining the bank rather than copying its live state removes the race
    /// between this control-thread rebuild and the IO thread updating biquad
    /// history. Live route and effect swaps both keep the aggregate's output
    /// map, so a slot still names the same physical output in the replacement.
    static func carryCorrections(
        from previous: UnsafeMutablePointer<RTGraph>,
        to next: UnsafeMutablePointer<RTGraph>
    ) {
        let previousOwner = Unmanaged<OutputCorrectionBank>
            .fromOpaque(previous.pointee.outputCorrections)
        _ = previousOwner.retain()
        Unmanaged<OutputCorrectionBank>
            .fromOpaque(next.pointee.outputCorrections).release()
        next.pointee.outputCorrections = previous.pointee.outputCorrections
    }

    /// Carries only immutable owner pointers between unpublished test graphs.
    ///
    /// The limiter pointer is intentionally the same pointer. A fresh bank has
    /// an empty look-ahead line, so replacing it during a route or effect edit
    /// would insert `latencyFrames` of silence even though the device never
    /// stopped. Limiter pre-gain is deliberately not copied from this live
    /// graph: the IOProc owns that copy, while the engine installs its
    /// state-lock-protected control value into the unpublished replacement.
    /// Moving state is deliberately absent: a live publication uses
    /// `installStateHandover`, because reading it here on the control thread is
    /// a data race with the callback.
    static func carryOutputStages(
        from previous: UnsafeMutablePointer<RTGraph>,
        to next: UnsafeMutablePointer<RTGraph>
    ) {
        next.pointee.outputLimiter = previous.pointee.outputLimiter
        next.pointee.outputLimiterEnabled = previous.pointee.outputLimiterEnabled

        next.pointee.recordRing = previous.pointee.recordRing
        next.pointee.recordChannels = previous.pointee.recordChannels
        next.pointee.recordLimiter = previous.pointee.recordLimiter
    }

    /// Installs setup-time targets as audible values without opening a ramp.
    ///
    /// A graph that has not reached the IO thread has no previous sample to
    /// protect. Persisted mute and gain therefore belong on its very first
    /// sample, while the same change on a live graph is slewed.
    static func synchroniseGainSlews(on graph: UnsafeMutablePointer<RTGraph>) {
        for index in 0..<Int(graph.pointee.routeCount) {
            let route = graph.pointee.routes[index]
            graph.pointee.routeGainSlews[index] =
                RTGainSlew(route.muted != 0 ? 0 : route.gain)
        }
        graph.pointee.inputGainSlew = RTGainSlew(
            graph.pointee.inputMuted != 0 ? 0 : graph.pointee.inputGain)
        graph.pointee.outputGainSlew = RTGainSlew(
            graph.pointee.outputMuted != 0 ? 0 : graph.pointee.outputGain)
        graph.pointee.duckGainSlew = RTGainSlew(graph.pointee.duckGain)
        graph.pointee.hasRendered = 1
    }

    /// Carries the moving global levels across a live graph publication.
    static func carryGlobalGainSlews(
        from previous: UnsafeMutablePointer<RTGraph>,
        to next: UnsafeMutablePointer<RTGraph>
    ) {
        next.pointee.inputGainSlew = previous.pointee.inputGainSlew
        next.pointee.outputGainSlew = previous.pointee.outputGainSlew
        next.pointee.duckGainSlew = previous.pointee.duckGainSlew
        next.pointee.duckGain = previous.pointee.duckGain
        next.pointee.hasRendered = previous.pointee.hasRendered
    }

    /// Carries one route's exact in-flight fader position to its new slot.
    static func carryRouteGainSlew(
        from previous: UnsafeMutablePointer<RTGraph>, slot old: Int,
        to next: UnsafeMutablePointer<RTGraph>, slot new: Int
    ) {
        guard old >= 0, old < Int(previous.pointee.routeCount),
            new >= 0, new < Int(next.pointee.routeCount)
        else { return }
        next.pointee.routeGainSlews[new] = previous.pointee.routeGainSlews[old]
    }

    /// Installs only immutable handover metadata on an unpublished graph.
    /// No field from the live predecessor is read on the control thread.
    static func installStateHandover(
        from previous: UnsafeMutablePointer<RTGraph>,
        to next: UnsafeMutablePointer<RTGraph>,
        routeSlots: [Int?]
    ) {
        next.pointee.incidentTelemetry = previous.pointee.incidentTelemetry
        next.pointee.incidentDeadlineNanoseconds =
            previous.pointee.incidentDeadlineNanoseconds
        next.pointee.stateHandover = previous
        for index in 0..<Int(next.pointee.routeCount) {
            let old = index < routeSlots.count ? routeSlots[index] : nil
            next.pointee.stateHandoverRoutes[index] = Int32(old ?? -1)
        }
    }

    /// Commits diagnostic generation evidence after the RCU exchange.
    ///
    /// Counting while a candidate was merely prepared created a narrow crash
    /// window in which the incident claimed a graph the callback never could
    /// have observed.
    static func recordPublication(of graph: UnsafePointer<RTGraph>) {
        if let incident = graph.pointee.incidentTelemetry {
            yun_rt_incident_graph_published(incident)
        }
    }

    /// Adopts mutable state only after the IO thread has moved to the new graph.
    ///
    /// Rapid publications can make a chain whose middle graph never rendered.
    /// The retirement queue bounds that chain to eight generations. Walking
    /// every route's immutable slot map back to the last graph which actually
    /// rendered copies each delay line once rather than once per unpublished
    /// generation. That keeps a pointer-drag storm from multiplying work on
    /// the first callback which gets through.
    @inline(__always)
    static func adoptStateHandover(on next: UnsafeMutablePointer<RTGraph>) {
        guard let immediate = next.pointee.stateHandover else { return }

        // A predecessor with no handover is the last generation seen by the
        // callback. All generations between it and `next` contain setup-time
        // targets but no audible moving state worth copying.
        var audible = immediate
        var depth = 1
        while depth < maximumStateHandoverDepth,
            let predecessor = audible.pointee.stateHandover
        {
            audible = predecessor
            depth += 1
        }
        guard audible.pointee.stateHandover == nil else {
            next.pointee.stateHandover = nil
            return
        }

        next.pointee.outputLimiterFailures = audible.pointee.outputLimiterFailures
        next.pointee.outputPeak = audible.pointee.outputPeak
        if next.pointee.outputClippingEpoch == audible.pointee.outputClippingEpoch {
            next.pointee.outputClipped = audible.pointee.outputClipped
        }
        if next.pointee.recordRing == audible.pointee.recordRing,
            next.pointee.recordLimiter == audible.pointee.recordLimiter
        {
            next.pointee.recordLimiterPrimingFrames =
                audible.pointee.recordLimiterPrimingFrames
        }

        next.pointee.inputGainSlew = audible.pointee.inputGainSlew
        next.pointee.inputGainSlew.retargetLinear(
            to: next.pointee.inputMuted != 0 ? 0 : next.pointee.inputGain,
            frames: Int(next.pointee.gainRampFrames))
        next.pointee.outputGainSlew = audible.pointee.outputGainSlew
        next.pointee.outputGainSlew.retargetLinear(
            to: next.pointee.outputMuted != 0 ? 0 : next.pointee.outputGain,
            frames: Int(next.pointee.gainRampFrames))
        next.pointee.duckGainSlew = audible.pointee.duckGainSlew
        next.pointee.duckGain = audible.pointee.duckGain
        next.pointee.micPeak = audible.pointee.micPeak
        next.pointee.hasRendered = audible.pointee.hasRendered

        for new in 0..<Int(next.pointee.routeCount) {
            var old = Int(next.pointee.stateHandoverRoutes[new])
            var generation = immediate
            var routeDepth = 1
            var mappingIsValid = old >= 0 && old < Int(generation.pointee.routeCount)
            while mappingIsValid, routeDepth < maximumStateHandoverDepth,
                let predecessor = generation.pointee.stateHandover
            {
                old = Int(generation.pointee.stateHandoverRoutes[old])
                generation = predecessor
                routeDepth += 1
                mappingIsValid = old >= 0 && old < Int(generation.pointee.routeCount)
            }
            guard mappingIsValid, generation == audible else { continue }
            next.pointee.peaks[new] = audible.pointee.peaks[old]
            next.pointee.rms[new] = audible.pointee.rms[old]
            if next.pointee.calibrating != 0 && audible.pointee.calibrating != 0
                && next.pointee.calibrationEpoch == audible.pointee.calibrationEpoch
            {
                next.pointee.calibrationEnergy[new] =
                    audible.pointee.calibrationEnergy[old]
                next.pointee.calibrationFrames[new] =
                    audible.pointee.calibrationFrames[old]
            }
            _ = carryAlignment(from: audible, slot: old, to: next, slot: new)
            carryRouteGainSlew(from: audible, slot: old, to: next, slot: new)
            let target =
                next.pointee.routes[new].muted != 0
                ? 0 : next.pointee.routes[new].gain
            next.pointee.routeGainSlews[new].retargetLinear(
                to: target, frames: Int(next.pointee.gainRampFrames))
        }

        // These generations can no longer become current. Clearing their
        // links makes a later assertion distinguish a fully adopted chain from
        // one which accidentally stopped part-way through its route maps.
        var generation: UnsafeMutablePointer<RTGraph>? = immediate
        var generationsCleared = 0
        while generationsCleared < maximumStateHandoverDepth,
            let current = generation
        {
            generation = current.pointee.stateHandover
            current.pointee.stateHandover = nil
            generationsCleared += 1
        }
        next.pointee.stateHandover = nil
    }

    /// Publishes one complete control-facing frame after all DSP for this cycle.
    @inline(__always)
    static func publishTelemetry(_ graph: UnsafeMutablePointer<RTGraph>) {
        yun_rt_telemetry_publish(
            graph.pointee.telemetry,
            graph.pointee.peaks,
            graph.pointee.rms,
            graph.pointee.calibrationEnergy,
            graph.pointee.calibrationFrames,
            UInt32(graph.pointee.routeCount),
            graph.pointee.outputPeak,
            graph.pointee.outputClipped,
            graph.pointee.outputLimiterFailures)
    }

    /// Pays Swift's process-wide first callback cost on the control thread.
    ///
    /// A release process which had never entered this IOProc measured eight
    /// allocator calls in its first synthetic callback and zero in the second.
    /// Core Audio's first device callback has the same deadline as every later
    /// one, so leaving that lazy runtime work there would make the zero-
    /// allocation contract false exactly once per launch. A disposable graph
    /// warms the identical function without advancing any audible route state.
    @discardableResult
    static func prewarmRealtimeRuntime() -> OSStatus {
        let graph = allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0)
            ], bufferFrames: 1)
        defer { deallocate(graph) }

        let input = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        input.initialize(to: 0)
        defer {
            input.deinitialize(count: 1)
            input.deallocate()
        }
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        output.initialize(to: 0)
        defer {
            output.deinitialize(count: 1)
            output.deallocate()
        }
        let inputList = AudioBufferList.allocate(maximumBuffers: 1)
        inputList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(input))
        defer { free(inputList.unsafeMutablePointer) }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        outputList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(output))
        defer { free(outputList.unsafeMutablePointer) }
        guard let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph)) else {
            return kAudioHardwareUnspecifiedError
        }
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid
        return yunAudioIOProc(
            0, &now, UnsafePointer(inputList.unsafeMutablePointer), &time,
            outputList.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))
    }
}

// MARK: - The realtime callback

/// Applies one already-published scalar without allocating or leaving a
/// partially updated slew target behind.
@inline(__always)
private func applyRTControl(
    _ command: YunRTCommand, to graph: UnsafeMutablePointer<RTGraph>
) {
    // The trim and the master are one control each rather than one per route,
    // so they are handled before the index is range-checked.
    switch command.kind {
    case Int32(kYunRTCommandSetInputGain.rawValue):
        if command.value.isFinite {
            graph.pointee.inputGain = command.value
            let target = graph.pointee.inputMuted != 0 ? 0 : command.value
            graph.pointee.inputGainSlew.retargetLinear(
                to: target, frames: Int(graph.pointee.gainRampFrames))
        }
        return
    case Int32(kYunRTCommandSetInputMute.rawValue):
        graph.pointee.inputMuted = command.value != 0 ? 1 : 0
        graph.pointee.inputGainSlew.retargetLinear(
            to: graph.pointee.inputMuted != 0 ? 0 : graph.pointee.inputGain,
            frames: Int(
                graph.pointee.inputMuted != 0
                    ? graph.pointee.muteRampFrames : graph.pointee.gainRampFrames))
        return
    case Int32(kYunRTCommandSetOutputGain.rawValue):
        if command.value.isFinite {
            graph.pointee.outputGain = command.value
            let target = graph.pointee.outputMuted != 0 ? 0 : command.value
            graph.pointee.outputGainSlew.retargetLinear(
                to: target, frames: Int(graph.pointee.gainRampFrames))
        }
        return
    case Int32(kYunRTCommandSetOutputMute.rawValue):
        graph.pointee.outputMuted = command.value != 0 ? 1 : 0
        graph.pointee.outputGainSlew.retargetLinear(
            to: graph.pointee.outputMuted != 0 ? 0 : graph.pointee.outputGain,
            frames: Int(
                graph.pointee.outputMuted != 0
                    ? graph.pointee.muteRampFrames : graph.pointee.gainRampFrames))
        return
    case Int32(kYunRTCommandSetLimiterPreGain.rawValue):
        if command.value.isFinite, command.value >= 0 {
            graph.pointee.outputLimiterPreGain = command.value
        }
        return
    case Int32(kYunRTCommandSetDuckingEnabled.rawValue):
        graph.pointee.duckEnabled = command.value != 0 ? 1 : 0
        return
    case Int32(kYunRTCommandSetDuckingDepth.rawValue):
        if command.value.isFinite {
            graph.pointee.duckDepth = max(0, min(1, command.value))
        }
        return
    case Int32(kYunRTCommandSetDuckingAllowed.rawValue):
        graph.pointee.duckAllowed = command.value != 0 ? 1 : 0
        return
    case Int32(kYunRTCommandSetAnalysisEnabled.rawValue):
        graph.pointee.analysisEnabled = command.value != 0 ? 1 : 0
        return
    case Int32(kYunRTCommandSetRecordingPaused.rawValue):
        graph.pointee.recordPaused = command.value != 0 ? 1 : 0
        return
    case Int32(kYunRTCommandSetCalibrating.rawValue):
        let count = max(Int(graph.pointee.routeCount), 1)
        let epoch = command.value.bitPattern
        if epoch != 0 {
            for index in 0..<count {
                graph.pointee.calibrationEnergy[index] = 0
                graph.pointee.calibrationFrames[index] = 0
            }
            graph.pointee.calibrating = 1
            graph.pointee.calibrationEpoch = epoch
        } else {
            graph.pointee.calibrating = 0
        }
        return
    case Int32(kYunRTCommandClearOutputClipping.rawValue):
        graph.pointee.outputClipped = 0
        graph.pointee.outputClippingEpoch = command.value.bitPattern
        return
    default:
        break
    }

    let index = Int(command.index)
    guard index >= 0, index < Int(graph.pointee.routeCount) else { return }
    switch command.kind {
    case Int32(kYunRTCommandSetGain.rawValue):
        if command.value.isFinite {
            graph.pointee.routes[index].gain = command.value
            let target = graph.pointee.routes[index].muted != 0 ? 0 : command.value
            graph.pointee.routeGainSlews[index].retargetLinear(
                to: target, frames: Int(graph.pointee.gainRampFrames))
        }
    case Int32(kYunRTCommandSetMute.rawValue):
        graph.pointee.routes[index].muted = command.value != 0 ? 1 : 0
        graph.pointee.routeGainSlews[index].retargetLinear(
            to: graph.pointee.routes[index].muted != 0
                ? 0 : graph.pointee.routes[index].gain,
            frames: Int(
                graph.pointee.routes[index].muted != 0
                    ? graph.pointee.muteRampFrames : graph.pointee.gainRampFrames))
    default:
        break
    }
}

/// The IO callback. Runs on a time-constrained thread.
///
/// Rules that hold for every line below, without exception: no allocation, no
/// ARC, no locks, no syscalls, no Swift runtime calls that could do any of
/// those. Everything it touches was allocated before the device started.
func yunAudioIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    // The graph is reached through a cell rather than directly, so the control
    // thread can swap in a new one between cycles instead of stopping the
    // device to change a route.
    let cell = OpaquePointer(clientData)
    guard let raw = yun_rt_cell_load(cell) else {
        // This is either an intentionally empty cell or proof that Core Audio
        // overlapped two calls despite exposing no non-reentrancy contract.
        // Reusing whatever the destination buffer held would turn containment
        // into a loud stale block, so the refused callback is explicit silence.
        for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        return noErr
    }
    let graph = raw.assumingMemoryBound(to: RTGraph.self)
    defer { yun_rt_cell_retire(cell) }

    let incident = graph.pointee.incidentTelemetry
    let incidentBegan = incident == nil ? 0 : AudioGetCurrentHostTime()
    let allocationViolationsBefore =
        incident == nil ? 0 : yun_rt_tripwire_violations()

    // Anything allocated between here and the matching call at the end is a
    // violation of the realtime contract and gets counted.
    //
    // Not gated on DEBUG: the allocator hook is only installed when the
    // tripwire is explicitly enabled, so the cost when it is off is two relaxed
    // atomic loads per cycle. Gating it on the build configuration made the
    // optimised build — the only one whose allocation behaviour actually
    // matters — report a meaningless zero.
    yun_rt_tripwire_mark_realtime(true)
    defer {
        yun_rt_tripwire_mark_realtime(false)
        if let incident {
            let elapsed = AudioConvertHostTimeToNanos(
                AudioGetCurrentHostTime() &- incidentBegan)
            let allocationViolations =
                yun_rt_tripwire_violations() &- allocationViolationsBefore
            yun_rt_incident_callback_observe(
                incident,
                elapsed,
                graph.pointee.incidentDeadlineNanoseconds,
                allocationViolations)
        }
    }

    RTGraph.adoptStateHandover(on: graph)

    // Apply any pending parameter changes before touching audio, so a whole
    // cycle uses one consistent set of values.
    if let commands = graph.pointee.commands {
        var command = YunRTCommand(kind: 0, index: 0, value: 0)
        while yun_rt_queue_pop(commands, &command) {
            applyRTControl(command, to: graph)
        }
    }
    if let mailbox = graph.pointee.controlMailbox {
        let generation = yun_rt_control_mailbox_begin(mailbox)
        if generation != 0 {
            var command = YunRTCommand(kind: 0, index: 0, value: 0)
            for kind in Int32(
                kYunRTCommandSetInputGain.rawValue)...Int32(
                    kYunRTCommandClearOutputClipping.rawValue)
            where yun_rt_control_mailbox_take(mailbox, kind, 0, &command) {
                applyRTControl(command, to: graph)
            }
            for index in 0..<Int(graph.pointee.routeCount) {
                for kind in Int32(
                    kYunRTCommandSetGain.rawValue)...Int32(
                        kYunRTCommandSetMute.rawValue)
                where yun_rt_control_mailbox_take(
                    mailbox, kind, Int32(index), &command)
                {
                    applyRTControl(command, to: graph)
                }
            }
            yun_rt_control_mailbox_finish(mailbox, generation)
        }
    }

    let input = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inputData))
    let output = UnsafeMutableAudioBufferListPointer(outputData)
    // The destination the router is feeding, which is not necessarily buffer
    // zero once monitoring adds a second output device to the aggregate.
    let mainIndex = Int(graph.pointee.mainOutputBuffer)

    // Setup writes happen before a graph is published and have no previous
    // audible sample to interpolate from. This includes a persisted mute: its
    // first sample must be silence rather than the beginning of a five-
    // millisecond fade.
    if graph.pointee.hasRendered == 0 {
        RTGraph.synchroniseGainSlews(on: graph)
        graph.pointee.hasRendered = 1
    }

    // The output tells us the callback's timeline even if a particular route
    // has no source buffer this cycle. Fall back to the input for an input-only
    // aggregate. Capacity was sized from the device's maximum frame request.
    var cycleFrames = 0
    if mainIndex >= 0, mainIndex < output.count {
        let buffer = output[mainIndex]
        let channels = Int(buffer.mNumberChannels)
        if channels > 0 {
            cycleFrames =
                Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        }
    } else {
        for index in 0..<output.count {
            let channels = Int(output[index].mNumberChannels)
            if channels > 0 {
                cycleFrames = max(
                    cycleFrames,
                    Int(output[index].mDataByteSize)
                        / (MemoryLayout<Float>.size * channels))
            }
        }
    }
    if cycleFrames == 0 {
        for buffer in input {
            let channels = Int(buffer.mNumberChannels)
            if channels > 0 {
                cycleFrames = max(
                    cycleFrames,
                    Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            }
        }
    }
    let envelopeFrames = min(cycleFrames, Int(graph.pointee.gainEnvelopeCapacity))
    let inputEnvelope = graph.pointee.gainEnvelopeScratch
    let duckEnvelope = inputEnvelope + Int(graph.pointee.gainEnvelopeCapacity)
    let outputEnvelope = duckEnvelope + Int(graph.pointee.gainEnvelopeCapacity)

    // Also notice unpublished scalar writes made by graph setup and test
    // harnesses. Live controls take the command path above; this comparison is
    // cheap when their target is already installed.
    let inputTarget =
        graph.pointee.inputMuted != 0 ? Float(0) : graph.pointee.inputGain
    if inputTarget != graph.pointee.inputGainSlew.target {
        graph.pointee.inputGainSlew.retargetLinear(
            to: inputTarget,
            frames: Int(
                graph.pointee.inputMuted != 0
                    ? graph.pointee.muteRampFrames : graph.pointee.gainRampFrames))
    }
    let outputTarget =
        graph.pointee.outputMuted != 0 ? Float(0) : graph.pointee.outputGain
    if outputTarget != graph.pointee.outputGainSlew.target {
        graph.pointee.outputGainSlew.retargetLinear(
            to: outputTarget,
            frames: Int(
                graph.pointee.outputMuted != 0
                    ? graph.pointee.muteRampFrames : graph.pointee.gainRampFrames))
    }

    let inputIsMoving = graph.pointee.inputGainSlew.remainingFrames > 0
    let outputIsMoving = graph.pointee.outputGainSlew.remainingFrames > 0
    if inputIsMoving {
        for frame in 0..<envelopeFrames {
            inputEnvelope[frame] = graph.pointee.inputGainSlew.nextLinear()
        }
        graph.pointee.inputGainSlew.advanceLinear(frames: cycleFrames - envelopeFrames)
    }
    if outputIsMoving {
        for frame in 0..<envelopeFrames {
            outputEnvelope[frame] = graph.pointee.outputGainSlew.nextLinear()
        }
        graph.pointee.outputGainSlew.advanceLinear(frames: cycleFrames - envelopeFrames)
    }

    // Ducking shares the callback timeline with the faders but keeps one-pole
    // time constants: 80 ms down and 600 ms back up, one sample at a time.
    let talking =
        graph.pointee.duckEnabled != 0
        && graph.pointee.duckAllowed != 0
        && graph.pointee.micPeak > graph.pointee.duckThreshold
        && graph.pointee.inputMuted == 0
    let duckTarget =
        graph.pointee.duckEnabled != 0 && talking ? graph.pointee.duckDepth : 1
    let duckCoefficient =
        duckTarget < graph.pointee.duckGainSlew.current
        ? graph.pointee.duckAttack : graph.pointee.duckRelease
    let duckIsMoving = duckTarget != graph.pointee.duckGainSlew.current
    if duckIsMoving {
        for frame in 0..<envelopeFrames {
            duckEnvelope[frame] = graph.pointee.duckGainSlew.nextOnePole(
                towards: duckTarget, coefficient: duckCoefficient)
        }
        for _ in envelopeFrames..<cycleFrames {
            _ = graph.pointee.duckGainSlew.nextOnePole(
                towards: duckTarget, coefficient: duckCoefficient)
        }
    }
    graph.pointee.duckGain = graph.pointee.duckGainSlew.current

    // CoreAudio does not promise a zeroed output buffer, and routes accumulate
    // into it, so clear first. Any channel with no route feeding it must end up
    // silent rather than replaying whatever was left in the buffer.
    for index in 0..<output.count {
        if let data = output[index].mData {
            memset(data, 0, Int(output[index].mDataByteSize))
        }
    }

    // Drain the echo-cancelled microphone once, before anything reads it. Doing
    // it per route would hand each route a different slice of the same stream.
    //
    // A short read is normal for the first cycles while the canceller fills, and
    // the remainder is silenced rather than left holding the previous cycle:
    // repeating audio here would be heard as a stutter and would also give the
    // canceller a phantom to chase.
    graph.pointee.cancelledFrames = 0
    if let ring = graph.pointee.cancelledRing, mainIndex < output.count {
        let stride = max(1, Int(output[mainIndex].mNumberChannels))
        let wanted = min(
            Int(output[mainIndex].mDataByteSize) / (MemoryLayout<Float>.size * stride),
            Int(graph.pointee.cancelledCapacity))
        if wanted > 0 {
            let buffer = graph.pointee.cancelledBuffer
            let taken = Int(yun_rt_ring_read(ring, buffer, UInt32(wanted)))
            if taken < wanted {
                buffer.advanced(by: taken).update(repeating: 0, count: wanted - taken)
            }
            graph.pointee.cancelledFrames = Int32(wanted)
        }
    }
    let cancelledFrames = Int(graph.pointee.cancelledFrames)

    // Processing runs once per cycle, ahead of routing, so several routes can
    // share one pass rather than each paying for it.
    var isolatedFrames = 0
    if let handover = graph.pointee.effectTransition {
        // Both paths see one gathered input. Apart from halving the de-striding
        // work, that makes a crossfade compare the same source frame on both
        // sides rather than two reads that could move independently.
        let fromCancelled =
            handover.pointee.sourceIsCancelled != 0 && cancelledFrames > 0
        let sourceIndex = Int(handover.pointee.sourceBuffer)
        if fromCancelled || (sourceIndex < input.count && input[sourceIndex].mData != nil) {
            let stride = fromCancelled ? 1 : Int(input[sourceIndex].mNumberChannels)
            let channel = fromCancelled ? 0 : Int(handover.pointee.sourceChannel)
            if stride > 0, channel < stride {
                let available =
                    fromCancelled
                    ? cancelledFrames
                    : Int(input[sourceIndex].mDataByteSize)
                        / (MemoryLayout<Float>.size * stride)
                let frames = RTGraph.processingFrames(
                    available: available,
                    capacity: Int(handover.pointee.maximumFrames))
                let source =
                    fromCancelled
                    ? UnsafePointer(graph.pointee.cancelledBuffer)
                    : UnsafePointer(
                        input[sourceIndex].mData!.assumingMemoryBound(to: Float.self))
                let raw = handover.pointee.rawBuffer
                for frame in 0..<frames {
                    raw[frame] =
                        sanitisedAudioSample(source[frame * stride + channel])
                }

                let controller = Unmanaged<EffectTransition>
                    .fromOpaque(handover.pointee.controller).takeUnretainedValue()
                var oldSource = UnsafePointer(raw)
                if !controller.isComplete, let old = handover.pointee.oldStage,
                    old.pointee.enabled != 0
                {
                    old.pointee.inputBuffer.update(from: raw, count: frames)
                    let rendered =
                        handover.pointee.oldIsChain != 0
                        ? Unmanaged<EffectChain>
                            .fromOpaque(old.pointee.unit).takeUnretainedValue()
                            .render(
                                frames: frames,
                                sampleTime: inputTime.pointee.mSampleTime)
                        : Unmanaged<VoiceIsolationUnit>
                            .fromOpaque(old.pointee.unit).takeUnretainedValue()
                            .render(
                                frames: frames,
                                sampleTime: inputTime.pointee.mSampleTime)
                    if rendered {
                        oldSource = UnsafePointer(old.pointee.outputBuffer)
                    } else {
                        yun_rt_counter_increment(old.pointee.renderFailures)
                    }
                }

                var newSource = UnsafePointer(raw)
                if let new = handover.pointee.newStage, new.pointee.enabled != 0 {
                    new.pointee.inputBuffer.update(from: raw, count: frames)
                    let rendered =
                        handover.pointee.newIsChain != 0
                        ? Unmanaged<EffectChain>
                            .fromOpaque(new.pointee.unit).takeUnretainedValue()
                            .render(
                                frames: frames,
                                sampleTime: inputTime.pointee.mSampleTime)
                        : Unmanaged<VoiceIsolationUnit>
                            .fromOpaque(new.pointee.unit).takeUnretainedValue()
                            .render(
                                frames: frames,
                                sampleTime: inputTime.pointee.mSampleTime)
                    if rendered {
                        newSource = UnsafePointer(new.pointee.outputBuffer)
                    } else {
                        yun_rt_counter_increment(new.pointee.renderFailures)
                    }
                }

                if frames > 0 {
                    handover.pointee.cycleTimelineStart =
                        Int64(controller.processedFrames)
                    controller.process(
                        old: oldSource, new: newSource,
                        output: handover.pointee.outputBuffer, frames: frames)
                    isolatedFrames = frames
                }
            }
        }
    } else if let isolation = graph.pointee.voiceIsolation,
        isolation.pointee.enabled != 0
    {
        // With the canceller in front, the model has to see what it produced;
        // reading the aggregate's input would process the uncancelled signal
        // and then throw it away.
        let fromCancelled =
            isolation.pointee.sourceIsCancelled != 0 && cancelledFrames > 0
        let sourceIndex = Int(isolation.pointee.sourceBuffer)
        if fromCancelled || (sourceIndex < input.count && input[sourceIndex].mData != nil) {
            let stride = fromCancelled ? 1 : Int(input[sourceIndex].mNumberChannels)
            let channel = fromCancelled ? 0 : Int(isolation.pointee.sourceChannel)
            if stride > 0, channel < stride {
                let available =
                    fromCancelled
                    ? cancelledFrames
                    : Int(input[sourceIndex].mDataByteSize)
                        / (MemoryLayout<Float>.size * stride)
                let frames = RTGraph.processingFrames(
                    available: available,
                    capacity: Int(isolation.pointee.maximumFrames))
                let source =
                    fromCancelled
                    ? UnsafePointer(graph.pointee.cancelledBuffer)
                    : UnsafePointer(
                        input[sourceIndex].mData!.assumingMemoryBound(to: Float.self))
                let staging = isolation.pointee.inputBuffer
                for frame in 0..<frames {
                    staging[frame] =
                        sanitisedAudioSample(source[frame * stride + channel])
                }
                let rendered =
                    graph.pointee.isolationIsChain != 0
                    ? Unmanaged<EffectChain>
                        .fromOpaque(isolation.pointee.unit).takeUnretainedValue()
                        .render(
                            frames: frames,
                            sampleTime: inputTime.pointee.mSampleTime)
                    : Unmanaged<VoiceIsolationUnit>
                        .fromOpaque(isolation.pointee.unit).takeUnretainedValue()
                        .render(
                            frames: frames,
                            sampleTime: inputTime.pointee.mSampleTime)
                if rendered {
                    isolatedFrames = frames
                } else {
                    yun_rt_counter_increment(isolation.pointee.renderFailures)
                }
            }
        }
    }

    let routeCount = Int(graph.pointee.routeCount)
    let routes = graph.pointee.routes
    let peaks = graph.pointee.peaks
    let rms = graph.pointee.rms
    let calibrating = graph.pointee.calibrating != 0
    var micPeak: Float = 0
    graph.pointee.stemFrames = 0

    for index in 0..<routeCount {
        let route = routes[index]
        let routeTarget = route.muted != 0 ? Float(0) : route.gain
        if routeTarget != graph.pointee.routeGainSlews[index].target {
            graph.pointee.routeGainSlews[index].retargetLinear(
                to: routeTarget,
                frames: Int(
                    route.muted != 0
                        ? graph.pointee.muteRampFrames : graph.pointee.gainRampFrames))
        }
        let routeIsMoving = graph.pointee.routeGainSlews[index].remainingFrames > 0
        var renderedGainFrames = 0
        defer {
            if routeIsMoving {
                graph.pointee.routeGainSlews[index].advanceLinear(
                    frames: cycleFrames - renderedGainFrames)
            }
        }

        let destinationIndex = Int(route.destinationBuffer)
        guard destinationIndex < output.count else { continue }

        // Both the isolated signal and the cancelled microphone are mono and
        // packed, so their stride is one and their channel index zero. Neither
        // is in the input buffer list at all, which is why the buffer index is
        // only consulted for a route reading the aggregate directly.
        let useIsolated = route.usesIsolatedSource != 0 && isolatedFrames > 0
        let useCancelled =
            !useIsolated && route.usesCancelledSource != 0 && cancelledFrames > 0
        let readsInput = !useIsolated && !useCancelled

        let sourceIndex = Int(route.sourceBuffer)
        if readsInput && sourceIndex >= input.count { continue }
        let sourceBuffer = readsInput ? input[sourceIndex] : AudioBuffer()
        let destinationBuffer = output[destinationIndex]
        guard let destinationData = destinationBuffer.mData else { continue }
        if readsInput && sourceBuffer.mData == nil { continue }

        var sourceStride = readsInput ? Int(sourceBuffer.mNumberChannels) : 1
        let destinationStride = Int(destinationBuffer.mNumberChannels)
        var sourceChannel = readsInput ? Int(route.sourceChannel) : 0
        let destinationChannel = Int(route.destinationChannel)
        guard sourceChannel < sourceStride, destinationChannel < destinationStride,
            sourceStride > 0, destinationStride > 0
        else { continue }

        // Both endpoints present 32-bit float physical formats, and the HAL's
        // virtual format is float32 regardless, so no conversion is needed.
        let sourceFrames: Int
        if useIsolated {
            sourceFrames = isolatedFrames
        } else if useCancelled {
            sourceFrames = cancelledFrames
        } else {
            sourceFrames =
                Int(sourceBuffer.mDataByteSize) / (MemoryLayout<Float>.size * sourceStride)
        }
        let destinationFrames =
            Int(destinationBuffer.mDataByteSize)
            / (MemoryLayout<Float>.size * destinationStride)
        let frames = min(sourceFrames, destinationFrames)
        guard frames > 0 else { continue }

        var source: UnsafePointer<Float>
        if useIsolated {
            if let handover = graph.pointee.effectTransition {
                source = UnsafePointer(handover.pointee.outputBuffer)
            } else {
                source = UnsafePointer(graph.pointee.voiceIsolation!.pointee.outputBuffer)
            }
        } else if useCancelled {
            source = UnsafePointer(graph.pointee.cancelledBuffer)
        } else {
            source = UnsafePointer(
                sourceBuffer.mData!.assumingMemoryBound(to: Float.self))
        }

        // Hold back everything that did not go through the effect chain.
        //
        // The microphone goes through the chain and comes out late by whatever
        // the chain's units report — voice isolation alone is 56 ms. Tapped
        // application audio goes through none of it and arrives on time. Mixed
        // together, the voice is behind the backing track by the whole chain,
        // which in a karaoke session is tens of milliseconds and is exactly the
        // thing somebody compensates for by rushing the beat. The per-source
        // stems were offset from each other by the same amount, so a recording
        // had to be nudged back into line by hand afterwards.
        //
        // The choice this makes is explicit: **aligned or early, not both.**
        // A tapped application now reaches the destination later than it used
        // to, by the length of the chain. That is the price of the mix being in
        // time, and there is no arrangement of a causal signal path that avoids
        // it — the only alternative is predicting the chain's output.
        //
        // Keyed on the route's own flag rather than on whether the chain
        // produced anything this cycle, so a chain that is still filling does
        // not make the alignment flicker on and off between cycles.
        //
        // The delay is taken before the fader, before the meters and before the
        // stems, so what a stem records and what a meter reads are both what
        // the mix will hear.
        let alignment = max(
            0,
            min(
                Int(graph.pointee.alignmentFrames),
                RTGraph.maximumAlignmentFrames))
        if route.usesIsolatedSource == 0,
            frames <= Int(graph.pointee.alignmentCapacity)
        {
            // A fixed-size history rather than a ring only as long as today's
            // delay. Even at zero delay it keeps receiving the source, so a
            // future effect toggle can read real samples from 1024 frames ago
            // immediately instead of manufacturing 1024 frames of silence.
            let history = graph.pointee.alignmentHistories[index]
            let line = history.pointee.line
            let scratch = graph.pointee.alignmentScratch
            var position = Int(history.pointee.position)
            if position >= RTGraph.maximumAlignmentFrames { position = 0 }
            var take = sourceChannel
            if let handover = graph.pointee.effectTransition {
                let controller = Unmanaged<EffectTransition>
                    .fromOpaque(handover.pointee.controller).takeUnretainedValue()
                let oldDelay = max(
                    0,
                    min(
                        Int(handover.pointee.oldAlignmentFrames),
                        RTGraph.maximumAlignmentFrames))
                let newDelay = max(
                    0,
                    min(
                        Int(handover.pointee.newAlignmentFrames),
                        RTGraph.maximumAlignmentFrames))
                let timeline = Int(handover.pointee.cycleTimelineStart)

                for frame in 0..<frames {
                    let current = sanitisedAudioSample(source[take])
                    var oldIndex = position - oldDelay
                    if oldIndex < 0 { oldIndex += RTGraph.maximumAlignmentFrames }
                    var newIndex = position - newDelay
                    if newIndex < 0 { newIndex += RTGraph.maximumAlignmentFrames }
                    let oldSample = oldDelay == 0 ? current : line[oldIndex]
                    let newSample = newDelay == 0 ? current : line[newIndex]
                    scratch[frame] = controller.sample(
                        old: oldSample, new: newSample,
                        at: timeline + frame)
                    line[position] = current
                    position += 1
                    if position == RTGraph.maximumAlignmentFrames { position = 0 }
                    take += sourceStride
                }
                source = UnsafePointer(scratch)
                sourceStride = 1
                sourceChannel = 0
            } else {
                for frame in 0..<frames {
                    let current = sanitisedAudioSample(source[take])
                    var read = position - alignment
                    if read < 0 { read += RTGraph.maximumAlignmentFrames }
                    if alignment > 0 { scratch[frame] = line[read] }
                    line[position] = current
                    position += 1
                    if position == RTGraph.maximumAlignmentFrames { position = 0 }
                    take += sourceStride
                }
                if alignment > 0 {
                    source = UnsafePointer(scratch)
                    sourceStride = 1
                    sourceChannel = 0
                }
            }
            history.pointee.position = Int32(position)
        }

        let destination = destinationData.assumingMemoryBound(to: Float.self)

        var peak: Float = 0
        // Accumulated unconditionally rather than behind a branch on whether
        // anybody is calibrating: it is one fused multiply-add per sample in a
        // loop that already does a multiply and an add, and having RMS for
        // every route all the time is worth more than the fraction of a percent
        // it costs.
        var energy: Float = 0
        // Hand-written and staying that way. The obvious rewrite is three
        // strided Accelerate passes — vDSP_maxmgv, vDSP_svesq, vDSP_vsma — and
        // it was tried and is slower: Accelerate's strided entry points fall
        // back to scalar code, so all it buys is three call boundaries and
        // three walks instead of one. Measured at 512 frames with two routes,
        // 1501 ns a cycle against 954 for this loop. Interleaved audio is
        // always strided, so the fast paths are never the ones taken.
        var readAt = sourceChannel
        var writeAt = destinationChannel
        let trimIsMoving = route.appliesInputTrim != 0 && inputIsMoving
        let duckIsMovingForRoute = route.isDuckable != 0 && duckIsMoving
        if routeIsMoving || trimIsMoving || duckIsMovingForRoute {
            for frame in 0..<frames {
                let sample = sanitisedAudioSample(source[readAt])
                let routeGain =
                    routeIsMoving
                    ? graph.pointee.routeGainSlews[index].nextLinear()
                    : graph.pointee.routeGainSlews[index].current
                // The shared envelopes were advanced once at the top of the
                // cycle. Reading them here keeps two routes from consuming
                // twice as much fader or duck time as one route.
                let trim =
                    route.appliesInputTrim != 0
                    ? (trimIsMoving && frame < envelopeFrames
                        ? inputEnvelope[frame] : graph.pointee.inputGainSlew.current)
                    : 1
                let duck =
                    route.isDuckable != 0
                    ? (duckIsMovingForRoute && frame < envelopeFrames
                        ? duckEnvelope[frame] : graph.pointee.duckGainSlew.current)
                    : 1
                let gain = sanitisedAudioSample(routeGain * trim * duck)
                let contribution = sanitisedAudioSample(sample * gain)
                destination[writeAt] += contribution
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
                energy += sample * sample
                readAt += sourceStride
                writeAt += destinationStride
            }
        } else {
            // The overwhelmingly common path keeps the complete gain in one
            // register, preserving the old route loop's measured cost once a
            // ten-millisecond move has finished.
            let trim =
                route.appliesInputTrim != 0 ? graph.pointee.inputGainSlew.current : 1
            let duck =
                route.isDuckable != 0 ? graph.pointee.duckGainSlew.current : 1
            let gain = sanitisedAudioSample(
                graph.pointee.routeGainSlews[index].current * trim * duck)
            for _ in 0..<frames {
                let sample = sanitisedAudioSample(source[readAt])
                let contribution = sanitisedAudioSample(sample * gain)
                destination[writeAt] += contribution
                // Metered before gain: a meter should show what arrived, not
                // what the fader did to it. It also lets a gain-0 route act as a
                // pure probe, which is how the loopback verification works.
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
                energy += sample * sample
                readAt += sourceStride
                writeAt += destinationStride
            }
        }
        renderedGainFrames = frames

        // Into the stem scratch, before the fader and before the master: a
        // stem is what that source produced, which is the whole point of having
        // it separately. Anything else and the file is a record of this
        // session's mix decisions rather than of the performance.
        let stem = Int(route.stemIndex)
        if stem >= 0, stem < Int(graph.pointee.stemCount) {
            let channels = Int(graph.pointee.stemChannels[stem])
            let channel = Int(route.stemChannel)
            let capacity = Int(graph.pointee.stemCapacity)
            if channels > 0, channel < channels {
                let usable = min(frames, capacity)
                let base =
                    graph.pointee.stemScratch
                    + stem * capacity * RTGraph.maxStemChannels
                for frame in 0..<usable {
                    base[frame * channels + channel] =
                        sanitisedAudioSample(
                            source[frame * sourceStride + sourceChannel])
                }
                if Int32(usable) > graph.pointee.stemFrames {
                    graph.pointee.stemFrames = Int32(usable)
                }
            }
        }

        // And into the transcription ring, from the same pre-fader point and
        // for the same reason: what a transcript should say is what somebody
        // said, not what the mix decided about them afterwards. Gathered
        // because the source is interleaved and a ring write wants contiguous
        // samples; written straight away because there is one route per ring.
        let transcript = Int(route.transcriptIndex)
        if transcript >= 0, transcript < Int(graph.pointee.transcriptCount),
            let ring = graph.pointee.transcriptRings[transcript]
        {
            let scratch = graph.pointee.transcriptScratch
            let usable = min(frames, Int(graph.pointee.transcriptCapacity))
            for frame in 0..<usable {
                scratch[frame] =
                    sanitisedAudioSample(
                        source[frame * sourceStride + sourceChannel])
            }
            _ = yun_rt_ring_write(ring, scratch, UInt32(usable))
        }

        let blockRMS = frames > 0 ? (energy / Float(frames)).squareRoot() : 0
        rms[index] = max(blockRMS, rms[index] * graph.pointee.peakDecay)

        // Only cycles with something in them count towards a calibration.
        // Averaging somebody's voice together with their silences would measure
        // whoever spoke least as the quietest, and hand them the most gain.
        if calibrating, blockRMS > graph.pointee.calibrationGate {
            graph.pointee.calibrationEnergy[index] += Double(energy)
            graph.pointee.calibrationFrames[index] += UInt64(frames)
        }

        // The microphone's own level, for next cycle's duck trigger. Taken
        // before the trim so that turning the trim down does not stop the duck
        // firing — the question it answers is "is somebody talking", not "how
        // loud did we make them".
        if route.appliesInputTrim != 0, peak > micPeak { micPeak = peak }

        // Decay towards the new peak so the meter falls smoothly instead of
        // flickering, without needing any timer on the UI side.
        //
        // The maximum of the two rather than a strict comparison: with a held
        // note the new peak equals the old one exactly, and `peak > previous`
        // is then false, so the meter decayed a step and climbed back on the
        // next cycle. A sustained tone made the bar wobble.
        let previous = peaks[index]
        peaks[index] = max(peak, previous * graph.pointee.peakDecay)
    }
    graph.pointee.micPeak = micPeak

    // The master, over the whole output bus once everything has been mixed
    // into it. After the routes and before the recorder, so what lands on disk
    // is what the far end hears — which is the recorder's whole premise.
    let master = sanitisedAudioSample(graph.pointee.outputGainSlew.current)
    let exempt = Int(graph.pointee.masterExemptBuffer)
    for index in 0..<output.count where index != exempt {
        guard let data = output[index].mData else { continue }
        let channels = Int(output[index].mNumberChannels)
        guard channels > 0 else { continue }
        let samples = Int(output[index].mDataByteSize) / MemoryLayout<Float>.size
        let frames = samples / channels
        let pointer = data.assumingMemoryBound(to: Float.self)
        guard samples > 0 else { continue }
        if outputIsMoving {
            for frame in 0..<frames {
                let scale =
                    frame < envelopeFrames ? outputEnvelope[frame] : master
                let start = frame * channels
                for channel in 0..<channels {
                    pointer[start + channel] *= scale
                }
            }
        } else if master != 1 {
            var scale = master
            // A settled bus is contiguous and every channel gets the same
            // scalar, so the vector pass remains the cheaper steady path.
            vDSP_vsmul(pointer, 1, &scale, pointer, 1, vDSP_Length(samples))
        }
    }

    // Fold the output bus to mono for the analysers. After the master, because
    // a loudness reading that ignored the master would tell the far end's story
    // wrong, and before the self-test, which overwrites a channel with a test
    // sequence nobody wants measured.
    //
    // Averaged rather than summed: two copies of one signal are the same
    // loudness, not twice it, and summing would read three units high on
    // anything panned centre.
    if graph.pointee.analysisEnabled != 0, let ring = graph.pointee.analysisRing,
        mainIndex < output.count, let data = output[mainIndex].mData
    {
        let stride = Int(output[mainIndex].mNumberChannels)
        if stride > 0 {
            let frames = min(
                Int(output[mainIndex].mDataByteSize) / (MemoryLayout<Float>.size * stride),
                Int(graph.pointee.analysisCapacity))
            let source = data.assumingMemoryBound(to: Float.self)
            let scratch = graph.pointee.analysisScratch
            // Two channels is the common case and the one worth folding; a
            // sixteen-channel virtual device carries silence on most of them,
            // and averaging those in would read fourteen units low.
            let folded = min(stride, 2)
            var scale = 1 / Float(folded)
            if frames > 0 {
                if folded == 2 {
                    // (A + B) × ½ over strided pairs, which is what the loop
                    // that was here computed one frame at a time.
                    vDSP_vasm(
                        source, stride, source + 1, stride, &scale, scratch, 1,
                        vDSP_Length(frames))
                } else {
                    // A mono bus folds to itself. The scale is exactly one, so
                    // this is a strided copy and not a multiply pretending to
                    // be one.
                    cblas_scopy(Int32(frames), source, Int32(stride), scratch, 1)
                }
            }
            if frames > 0 {
                _ = yun_rt_ring_write(ring, scratch, UInt32(frames))
            }
        }
    }

    // Loopback integrity check. Overwrites the destination channel with a
    // deterministic sequence and records what comes back, so the return path
    // can be compared sample for sample rather than trusted.
    if let selftest = graph.pointee.selftest {
        let outIndex = Int(selftest.pointee.outBuffer)
        let inIndex = Int(selftest.pointee.inBuffer)

        if outIndex < output.count, let data = output[outIndex].mData {
            let stride = Int(output[outIndex].mNumberChannels)
            let channel = Int(selftest.pointee.outChannel)
            if stride > 0, channel < stride {
                let frames =
                    Int(output[outIndex].mDataByteSize)
                    / (MemoryLayout<Float>.size * stride)
                let pointer = data.assumingMemoryBound(to: Float.self)
                var generated = selftest.pointee.generatedFrames.pointee
                for frame in 0..<frames {
                    pointer[frame * stride + channel] = selftestSample(generated)
                    generated &+= 1
                }
                selftest.pointee.generatedFrames.pointee = generated
            }
        }

        if inIndex < input.count, let data = input[inIndex].mData {
            let stride = Int(input[inIndex].mNumberChannels)
            let channel = Int(selftest.pointee.inChannel)
            let capacity = Int(selftest.pointee.captureCapacity)
            var stored = Int(yun_rt_counter_load(selftest.pointee.captureCount))
            if stride > 0, channel < stride, stored < capacity {
                if stored == 0 {
                    selftest.pointee.captureStartFrame.pointee =
                        selftest.pointee.generatedFrames.pointee
                }
                let frames =
                    Int(input[inIndex].mDataByteSize)
                    / (MemoryLayout<Float>.size * stride)
                let pointer = data.assumingMemoryBound(to: Float.self)
                let capture = selftest.pointee.capture
                for frame in 0..<frames where stored < capacity {
                    capture[stored] = pointer[frame * stride + channel]
                    stored += 1
                }
                yun_rt_counter_store(selftest.pointee.captureCount, UInt64(stored))
            }
        }
    }

    // Each stem into its own ring, once, as whole frames. Written after the
    // route loop rather than inside it so a stereo source cannot be split
    // across two writes and arrive half a frame out of step.
    if graph.pointee.stemFrames > 0 {
        let frames = Int(graph.pointee.stemFrames)
        let capacity = Int(graph.pointee.stemCapacity)
        for stem in 0..<Int(graph.pointee.stemCount) {
            guard let ring = graph.pointee.stemRings[stem] else { continue }
            let channels = Int(graph.pointee.stemChannels[stem])
            guard channels > 0 else { continue }
            let base = graph.pointee.stemScratch + stem * capacity * RTGraph.maxStemChannels
            _ = yun_rt_ring_write(ring, base, UInt32(frames * channels))
        }
    }

    // Feed the recorder from the canonical destination mix: after the source
    // processing, route gains and master, but before a correction that belongs
    // to one particular output. The optional recording limiter has independent
    // state because the hardware detector sees that corrected signal and must
    // never let a headphone-only boost turn down the file.
    if let ring = graph.pointee.recordRing, graph.pointee.recordPaused == 0,
        mainIndex < output.count
    {
        let channels = Int(graph.pointee.recordChannels)
        if let data = output[mainIndex].mData, channels > 0 {
            let stride = Int(output[mainIndex].mNumberChannels)
            let frames =
                Int(output[mainIndex].mDataByteSize)
                / (MemoryLayout<Float>.size * max(stride, 1))
            let source = data.assumingMemoryBound(to: Float.self)
            if let rawLimiter = graph.pointee.recordLimiter {
                let scratch = graph.pointee.recordScratch
                let usable = min(
                    frames, Int(graph.pointee.recordScratchCapacity) / channels)
                for frame in 0..<usable {
                    for channel in 0..<channels {
                        scratch[frame * channels + channel] =
                            channel < stride
                            ? sanitisedAudioSample(source[frame * stride + channel]) : 0
                    }
                }

                let limiter = Unmanaged<OutputLimiterBank>
                    .fromOpaque(rawLimiter).takeUnretainedValue()
                let limited = limiter.processInterleaved(
                    bus: 0, samples: scratch, frames: usable, channels: channels,
                    limiting: graph.pointee.outputLimiterEnabled != 0,
                    preGain: graph.pointee.outputLimiterPreGain)
                if limited {
                    let skip = min(
                        usable, max(0, Int(graph.pointee.recordLimiterPrimingFrames)))
                    graph.pointee.recordLimiterPrimingFrames -= Int32(skip)
                    let writtenFrames = usable - skip
                    if writtenFrames > 0 {
                        _ = yun_rt_ring_write(
                            ring, scratch + skip * channels,
                            UInt32(writtenFrames * channels))
                    }
                } else {
                    graph.pointee.outputLimiterFailures &+= 1
                }
            } else if stride == channels {
                _ = yun_rt_ring_write(ring, source, UInt32(frames * channels))
            } else {
                // The destination is wider than the recording, so the wanted
                // channels are gathered into the graph's own scratch first.
                let scratch = graph.pointee.recordScratch
                let usable = min(frames, Int(graph.pointee.recordScratchCapacity) / channels)
                for frame in 0..<usable {
                    for channel in 0..<channels {
                        scratch[frame * channels + channel] =
                            channel < stride ? source[frame * stride + channel] : 0
                    }
                }
                if usable > 0 {
                    _ = yun_rt_ring_write(ring, scratch, UInt32(usable * channels))
                }
            }
        }
    }

    // Per-bus correction, last of all and deliberately after the recorder and
    // stems took their copies. The unmanaged bank owns both live filter paths
    // and performs its publication only at this cycle boundary.
    let correctionBank = Unmanaged<OutputCorrectionBank>
        .fromOpaque(graph.pointee.outputCorrections).takeUnretainedValue()
    correctionBank.process(output)

    // Final safety stage, after every bus-specific correction and before any
    // sample reaches hardware. The detector is linked within each bus, so a
    // hot left channel turns the pair down together rather than pulling the
    // stereo image sideways. Bypass still runs the delay line: changing one
    // switch must not move the complete mix by the look-ahead in one callback.
    if let rawLimiter = graph.pointee.outputLimiter {
        let limiter = Unmanaged<OutputLimiterBank>
            .fromOpaque(rawLimiter).takeUnretainedValue()
        for slot in 0..<output.count {
            let buffer = output[slot]
            guard let data = buffer.mData else { continue }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            let frames =
                Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let samples = data.assumingMemoryBound(to: Float.self)
            let succeeded = limiter.processInterleaved(
                bus: slot, samples: samples, frames: frames, channels: channels,
                limiting: graph.pointee.outputLimiterEnabled != 0,
                preGain: graph.pointee.outputLimiterPreGain)
            if !succeeded {
                // A stale topology is not permission to send an unbounded bus
                // or to stride it using yesterday's channel count.
                memset(data, 0, Int(buffer.mDataByteSize))
                graph.pointee.outputLimiterFailures &+= 1
            }
        }
    }

    // What actually leaves, after every gain, correction and final limiter.
    //
    // This deliberately stays after the correction rather than beside the
    // pre-correction analyser and recorder. A boost or a filter transient can
    // take an otherwise clean bus over full scale, and a meter sampled before
    // that stage would report healthy audio while the hardware receives
    // clipping. Full scale in float is 1.0; anything at or past it is counted
    // rather than merely peaked.
    //
    // The limiter is optional. With it enabled this counter should stay zero;
    // with it bypassed the same post-stage measurement still exposes damage.
    if mainIndex < output.count, let data = output[mainIndex].mData {
        let samples = Int(output[mainIndex].mDataByteSize) / MemoryLayout<Float>.size
        let pointer = data.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        if samples > 0 {
            vDSP_maxmgv(pointer, 1, &peak, vDSP_Length(samples))
        }
        // Counting the truncated samples is a second pass, and the peak has
        // already answered whether there is anything to count: nothing on the
        // bus can be at or past full scale if the loudest thing on it is
        // below. So the count runs only when something has actually gone wrong,
        // which is the state nobody is in — and the common path stops paying a
        // per-sample comparison for a number that is always zero.
        var clipped: UInt64 = 0
        if peak >= 0.999 {
            for index in 0..<samples where abs(pointer[index]) >= 0.999 { clipped &+= 1 }
        }
        graph.pointee.outputPeak = RTGraph.nextMeterPeak(
            previous: graph.pointee.outputPeak,
            incoming: peak,
            decay: graph.pointee.peakDecay)
        graph.pointee.outputClipped &+= clipped
    }

    yun_rt_clock_publish(
        graph.pointee.clock,
        inputTime.pointee.mSampleTime,
        inputTime.pointee.mHostTime)

    RTGraph.publishTelemetry(graph)
    graph.pointee.cycleCounter.pointee &+= 1
    return noErr
}

// MARK: - Measuring the callback

/// Drives `yunAudioIOProc` on synthetic buffers, with no audio device involved.
///
/// `soak` reports the whole process at a fraction of one percent of one core.
/// That is the right number for "is this cheap to leave running for an hour"
/// and far too coarse to see a change inside the route loop: at 128 frames the
/// callback runs for a few microseconds out of every 2.7 milliseconds, so
/// halving its cost moves the soak figure by less than its run-to-run scatter.
/// This puts the callback on a treadmill instead — one graph, one pair of buffer
/// lists, a fixed number of cycles — and reports nanoseconds per cycle, which
/// moves when the arithmetic does.
///
/// It is not a substitute for the soak. It cannot see anything that only
/// happens against a real device: drift, the clock lock, or the cost of the
/// rings' other end. It answers one question, which is what a change to this
/// file did to this file.
public enum RTBenchmark {

    public struct Options: Sendable {
        /// Frames per cycle, as the device would ask for.
        public var frames: Int
        /// Routes into the destination bus, round-robin across its channels.
        public var routes: Int
        /// Further routes into the monitor bus, which is what direct monitoring
        /// builds and what the headphone correction runs on.
        ///
        /// Worth having as its own knob because without it the monitor is
        /// silent, and a biquad cascade filtering silence is a measurement of
        /// nothing — the checksum was identical with the EQ on and off, which is
        /// how that was noticed.
        public var monitorRoutes: Int
        /// Biquad sections of headphone correction on the monitor buffer.
        public var eqStages: Int
        /// Frames of alignment on the paths that skipped the effect chain.
        ///
        /// Its own knob because it is a copy per route per cycle that the
        /// ordinary case does not pay, and "how much does aligning the taps
        /// cost" is a question somebody will ask.
        public var alignmentFrames: Int
        /// Whether the mono fold for the analysers runs.
        public var analysis: Bool
        /// Whether the destination bus is also fed to a recording ring.
        public var record: Bool
        /// A master other than 1 makes the whole-bus gain pass run.
        public var master: Float

        public init(
            frames: Int = 128, routes: Int = 2, monitorRoutes: Int = 0, eqStages: Int = 0,
            alignmentFrames: Int = 0, analysis: Bool = false, record: Bool = false,
            master: Float = 1
        ) {
            self.frames = frames
            self.routes = routes
            self.monitorRoutes = monitorRoutes
            self.eqStages = eqStages
            self.alignmentFrames = alignmentFrames
            self.analysis = analysis
            self.record = record
            self.master = master
        }
    }

    public struct Result: Sendable {
        /// Wall-clock nanoseconds one call to the callback costs.
        public var nanosecondsPerCycle: Double
        /// What the tripwire counted while the treadmill was running. Any number
        /// but zero in a release build is a broken invariant, not a slow one.
        public var allocations: UInt64
        /// A fingerprint of everything the cycle produced — the destination bus,
        /// the monitor, and every meter.
        ///
        /// Here so that a faster route loop can be shown to be the *same* route
        /// loop. A speedup that quietly stopped writing a channel would leave
        /// the timing looking excellent and this number looking different.
        public var checksum: Double
    }

    static let maximumCycles = 1_000_000

    /// Every loop bound, allocation count and narrowed byte count used by one
    /// run. Public benchmark options are caller input, even though the CLI's
    /// presets are small, so they cross the same admission boundary as HAL.
    struct Admission: Sendable, Equatable {
        let frames: Int
        let routeCount: Int
        let monitorRouteCount: Int
        let cycles: Int
        let eqStages: Int
        let alignmentFrames: Int32
        let interleavedSampleCount: Int
        let interleavedByteCount: UInt32
        let ringFrameCount: UInt32
        let analysisDrainCount: UInt32
        let recordDrainCount: UInt32
    }

    static func admission(_ options: Options, cycles: Int) -> Admission? {
        guard AudioProcessingContract.supports(framesPerSlice: options.frames),
            cycles > 0, cycles <= maximumCycles,
            options.routes > 0,
            options.monitorRoutes >= 0,
            options.eqStages >= 0, options.eqStages <= RTGraph.maximumEQStages,
            options.alignmentFrames >= 0,
            options.alignmentFrames <= RTGraph.maximumAlignmentFrames,
            options.master.isFinite, options.master >= 0
        else { return nil }

        let (routeCount, routeOverflowed) =
            options.routes.addingReportingOverflow(options.monitorRoutes)
        guard !routeOverflowed, RTGraph.supportsRouteCount(routeCount),
            let alignmentFrames = Int32(exactly: options.alignmentFrames),
            let interleavedSampleCount = AudioProcessingContract.checkedProduct(
                options.frames, 2),
            let interleavedBytes = AudioProcessingContract.checkedProduct(
                interleavedSampleCount, MemoryLayout<Float>.size),
            let interleavedByteCount = UInt32(exactly: interleavedBytes),
            let requestedRingFrames = AudioProcessingContract.checkedProduct(
                options.frames, 16),
            let ringFrameCount = UInt32(exactly: max(requestedRingFrames, 4_096)),
            let requestedRecordDrain = AudioProcessingContract.checkedProduct(
                options.frames, 2),
            let analysisDrainCount = UInt32(exactly: options.frames),
            let recordDrainCount = UInt32(exactly: requestedRecordDrain),
            RTGraph.allocationPlan(
                routeCount: routeCount, bufferFrames: options.frames,
                sampleRate: 48_000) != nil
        else { return nil }

        return Admission(
            frames: options.frames,
            routeCount: options.routes,
            monitorRouteCount: options.monitorRoutes,
            cycles: cycles,
            eqStages: options.eqStages,
            alignmentFrames: alignmentFrames,
            interleavedSampleCount: interleavedSampleCount,
            interleavedByteCount: interleavedByteCount,
            ringFrameCount: ringFrameCount,
            analysisDrainCount: analysisDrainCount,
            recordDrainCount: recordDrainCount)
    }

    /// Runs `cycles` callbacks and reports what one cost.
    ///
    /// - Returns: Nil when an option is outside the bounded realtime contract.
    public static func run(_ options: Options, cycles: Int) -> Result? {
        guard let admission = admission(options, cycles: cycles) else { return nil }
        let frames = admission.frames
        let routeCount = admission.routeCount

        // Two output buffers, main second: the monitor being buffer zero is the
        // ordering the callback historically got wrong, so it is the one worth
        // benchmarking.
        let inputChannels = 2
        let outputChannels = [2, 2]
        let mainIndex = 1

        let inputStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: admission.interleavedSampleCount)
        // A sine rather than zeros or a constant. Zeros are not representative:
        // they make every peak comparison predictable and, on some paths, keep
        // the arithmetic away from the denormal range entirely.
        for frame in 0..<frames {
            let value = Float(sin(Double(frame) * 0.05)) * 0.5
            for channel in 0..<inputChannels {
                inputStorage[frame * inputChannels + channel] =
                    channel == 0 ? value : value * 0.7
            }
        }
        let inputList = AudioBufferList.allocate(maximumBuffers: 1)
        inputList[0] = AudioBuffer(
            mNumberChannels: UInt32(inputChannels),
            mDataByteSize: admission.interleavedByteCount,
            mData: UnsafeMutableRawPointer(inputStorage))

        var outputStorage: [UnsafeMutablePointer<Float>] = []
        let outputList = AudioBufferList.allocate(maximumBuffers: outputChannels.count)
        for (index, channels) in outputChannels.enumerated() {
            let pointer = UnsafeMutablePointer<Float>.allocate(
                capacity: admission.interleavedSampleCount)
            pointer.initialize(
                repeating: 0, count: admission.interleavedSampleCount)
            outputStorage.append(pointer)
            outputList[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: admission.interleavedByteCount,
                mData: UnsafeMutableRawPointer(pointer))
        }

        var routes: [RTRoute] = []
        routes.reserveCapacity(routeCount + admission.monitorRouteCount)
        for index in 0..<routeCount {
            routes.append(
                RTRoute(
                    sourceBuffer: 0, sourceChannel: Int32(index % inputChannels),
                    destinationBuffer: Int32(mainIndex),
                    destinationChannel: Int32(index % 2),
                    gain: 0.8, appliesInputTrim: index == 0))
        }
        for index in 0..<admission.monitorRouteCount {
            routes.append(
                RTRoute(
                    sourceBuffer: 0, sourceChannel: Int32(index % inputChannels),
                    destinationBuffer: 0, destinationChannel: Int32(index % 2),
                    gain: 0.9, appliesInputTrim: true))
        }
        let graph = RTGraph.allocate(routes: routes, bufferFrames: frames)
        graph.pointee.mainOutputBuffer = Int32(mainIndex)
        graph.pointee.masterExemptBuffer = 0
        graph.pointee.outputGain = options.master
        graph.pointee.analysisEnabled = options.analysis ? 1 : 0
        graph.pointee.alignmentFrames = admission.alignmentFrames
        // Benchmark the requested steady state rather than the first ten
        // milliseconds of setup being mistaken for ongoing mixer cost.
        RTGraph.synchroniseGainSlews(on: graph)

        var recordRing: OpaquePointer?
        if options.record {
            recordRing = yun_rt_ring_create(admission.ringFrameCount)
            graph.pointee.recordRing = recordRing
            graph.pointee.recordChannels = 2
        }

        if admission.eqStages > 0 {
            // A gentle peaking section repeated. The coefficients only have to
            // be stable — what is being timed is the cascade, not the curve.
            var packed: [Float] = []
            for _ in 0..<admission.eqStages {
                packed += [1.0009, -1.9781, 0.9781, -1.9781, 0.9790]
            }
            // Slot zero, which is the monitor here — the bus a correction has
            // always run on, so the figures stay comparable with what came
            // before per-bus slots existed.
            RTGraph.installCorrection(packed, preampGain: 0.9, onBuffer: 0, of: graph)
        }

        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid

        /// The rings are finite and nothing is draining them here, so they fill
        /// and then reject every write — which is not the cost the shipping app
        /// pays. Resetting them keeps the ring writes on their real path.
        func drainRings() {
            // Seven callbacks have produced seven complete blocks. Read them
            // in scratch-sized chunks instead of asking either fixed graph
            // buffer to hold their combined size. Seven leaves one complete
            // interleaved block of slack in the SPSC ring's reserved slot.
            for _ in 0..<7 {
                if let ring = graph.pointee.analysisRing {
                    _ = yun_rt_ring_read(
                        ring, graph.pointee.analysisScratch,
                        admission.analysisDrainCount)
                }
                if let ring = recordRing {
                    _ = yun_rt_ring_read(
                        ring, graph.pointee.recordScratch,
                        admission.recordDrainCount)
                }
            }
        }

        func spin(_ count: Int) {
            for cycle in 0..<count {
                time.mSampleTime = Double(cycle * frames)
                _ = yunAudioIOProc(
                    0, &now, UnsafePointer(inputList.unsafeMutablePointer), &time,
                    outputList.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))
                if cycle % 7 == 6 { drainRings() }
            }
        }

        // Warm the caches and let the biquad state settle before the clock
        // starts; a cold first cycle is a page-fault measurement, not this one.
        spin(min(admission.cycles, 2000))
        drainRings()

        let violationsBefore = yun_rt_tripwire_violations()
        let started = DispatchTime.now().uptimeNanoseconds
        spin(admission.cycles)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let violations = yun_rt_tripwire_violations() - violationsBefore

        var checksum = 0.0
        for (index, _) in outputChannels.enumerated() {
            let pointer = outputStorage[index]
            for sample in 0..<admission.interleavedSampleCount {
                checksum += Double(pointer[sample])
            }
        }
        for index in 0..<routes.count {
            checksum += Double(graph.pointee.peaks[index])
            checksum += Double(graph.pointee.rms[index])
        }
        checksum += Double(graph.pointee.outputPeak)

        yun_rt_cell_free(cell)
        if let recordRing { yun_rt_ring_free(recordRing) }
        graph.pointee.recordRing = nil
        RTGraph.deallocate(graph)
        inputStorage.deallocate()
        free(inputList.unsafeMutablePointer)
        for pointer in outputStorage { pointer.deallocate() }
        free(outputList.unsafeMutablePointer)

        return Result(
            nanosecondsPerCycle: Double(elapsed) / Double(admission.cycles),
            allocations: violations,
            checksum: checksum)
    }
}
