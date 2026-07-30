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

    /// Peak magnitude per route since the last read. Written by the realtime
    /// thread and read by the UI; a torn float is not worth a lock here,
    /// because the worst case is one frame of a meter being stale.
    var peaks: UnsafeMutablePointer<Float>

    /// Smoothed RMS per route, alongside the peaks.
    ///
    /// Peak says whether something will clip; RMS is much closer to how loud it
    /// sounds, and for balancing two people against each other it is the only
    /// one of the two worth using — a plosive and a shout have similar peaks
    /// and nothing like the same level.
    var rms: UnsafeMutablePointer<Float>

    // MARK: Calibration

    /// Non-zero while a calibration pass is accumulating.
    var calibrating: Int32
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

    /// Incremented once per IO cycle. The control thread watches this to know
    /// the realtime thread has moved past a graph it is about to free, and it
    /// doubles as the sequence number guarding the clock anchor below.
    var cycleCounter: UnsafeMutablePointer<UInt64>

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
    /// Written before `cycleCounter` is bumped, so a reader that sees the same
    /// counter either side of its read got a consistent pair.
    var clockSampleTime: UnsafeMutablePointer<Float64>
    var clockHostTime: UnsafeMutablePointer<UInt64>
    /// Zero when this graph borrowed the counter and clock storage above from
    /// the engine rather than allocating its own.
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
    /// the destination bus after all processing, so what lands on disk is what
    /// the far end hears.
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
    var duckGain: Float
    /// Per-cycle smoothing coefficients. Attack is fast enough not to clip the
    /// first syllable, release slow enough that the music does not pump between
    /// words.
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
    /// One delay line per route, `maximumAlignmentFrames` apart.
    ///
    /// Per route rather than per source channel: two routes reading one channel
    /// are two lines and a few kilobytes, whereas sharing would need a table
    /// mapping channels to lines that has to be rebuilt in step with the routes
    /// — one more thing to get out of step, for memory nobody is short of.
    var alignmentLines: UnsafeMutablePointer<Float>
    /// Where each line is being read and written.
    var alignmentPositions: UnsafeMutablePointer<Int32>
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

    // MARK: Per-bus correction

    /// Sections to run on each output buffer, indexed by buffer; zero for none.
    ///
    /// One slot per output rather than one slot in total, and that is the whole
    /// design decision. A headphone correction belongs on what *you* hear and
    /// nowhere else — putting it on the main output would send the far end a
    /// signal shaped for the deficiencies of your headphones, which is worse
    /// than not correcting at all. But the converse is just as true: a stream
    /// mix wants its own tone, and the reason VoiceMeeter is praised is that
    /// its buses are shaped independently. One slot could express the first
    /// rule and not the second.
    ///
    /// The slot index *is* the output buffer index. A separate table of "which
    /// buffer does slot k belong to" would be one more thing the IO thread has
    /// to read and one more thing that can be stale after a rebuild.
    var eqStages: UnsafeMutablePointer<Int32>
    /// Five per section per slot — b0, b1, b2, a1, a2 — already normalised by
    /// a0, so the IO thread does no division. Slot-major, `maximumEQStages`
    /// sections apart, so a slot's block is contiguous.
    var eqCoefficients: UnsafeMutablePointer<Float>
    /// Four per section per channel per slot: two inputs back, two outputs
    /// back. Slot-major on the same stride argument.
    var eqState: UnsafeMutablePointer<Float>
    /// Headroom for the boost, per slot, applied first.
    var eqPreampGain: UnsafeMutablePointer<Float>
    static let maximumEQStages = 24
    static let maximumEQChannels = 8
    /// Outputs that can carry a curve at once.
    ///
    /// Fixed for the same reason the section count is: the whole table is
    /// allocated once and handed to the IO thread, and a table that could grow
    /// would mean allocating there. Eight is generous — an aggregate with more
    /// than two output streams is already unusual, and the buses somebody
    /// actually shapes are the two the mixer names.
    static let maximumEQBuffers = 8

    /// Where one slot's coefficients start.
    static func eqCoefficientOffset(slot: Int) -> Int { slot * maximumEQStages * 5 }
    /// Where one slot's filter history starts.
    static func eqStateOffset(slot: Int) -> Int {
        slot * maximumEQStages * maximumEQChannels * 4
    }
    /// Words of history one slot owns.
    static var eqStateStride: Int { maximumEQStages * maximumEQChannels * 4 }

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
    /// Where the mono fold is built before it goes into the ring. The IO thread
    /// cannot allocate, and the output bus is interleaved and usually wider
    /// than two channels.
    var analysisScratch: UnsafeMutablePointer<Float>
    var analysisCapacity: Int32

    /// Parameter changes waiting to be applied. Drained at the top of each
    /// cycle so a fader move lands without rebuilding anything.
    var commands: OpaquePointer?

    /// Null unless a loopback integrity check is running. Checked once per
    /// cycle, so the normal path costs one predictable branch.
    var selftest: UnsafeMutablePointer<RTSelftest>?

    /// Peak meters fall by 20 dB per second, which is the usual ballistic for
    /// a peak-reading meter and slow enough to read.
    static func decay(bufferFrames: Int, sampleRate: Double) -> Float {
        guard bufferFrames > 0, sampleRate > 0 else { return 0.85 }
        let secondsPerCycle = Double(bufferFrames) / sampleRate
        return Float(pow(10.0, -20.0 * secondsPerCycle / 20.0))
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
        var cycleCounter: UnsafeMutablePointer<UInt64>
        var sampleTime: UnsafeMutablePointer<Float64>
        var hostTime: UnsafeMutablePointer<UInt64>

        static func allocate() -> SharedClock {
            let counter = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
            counter.initialize(to: 0)
            let sample = UnsafeMutablePointer<Float64>.allocate(capacity: 1)
            sample.initialize(to: 0)
            let host = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
            host.initialize(to: 0)
            return SharedClock(cycleCounter: counter, sampleTime: sample, hostTime: host)
        }

        func deallocate() {
            cycleCounter.deinitialize(count: 1)
            cycleCounter.deallocate()
            sampleTime.deinitialize(count: 1)
            sampleTime.deallocate()
            hostTime.deinitialize(count: 1)
            hostTime.deallocate()
        }
    }

    static func allocate(
        routes routeList: [RTRoute], bufferFrames: Int = 128, sampleRate: Double = 48000,
        sharedClock: SharedClock? = nil
    ) -> UnsafeMutablePointer<RTGraph> {
        let count = max(routeList.count, 1)

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

        let peakStorage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        peakStorage.initialize(repeating: 0, count: count)
        let rmsStorage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        rmsStorage.initialize(repeating: 0, count: count)
        let energyStorage = UnsafeMutablePointer<Double>.allocate(capacity: count)
        energyStorage.initialize(repeating: 0, count: count)
        let framesStorage = UnsafeMutablePointer<UInt64>.allocate(capacity: count)
        framesStorage.initialize(repeating: 0, count: count)

        let counterStorage =
            sharedClock?.cycleCounter
            ?? {
                let storage = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
                storage.initialize(to: 0)
                return storage
            }()

        // Sized for the largest block the device is likely to ask for, times a
        // stereo frame.
        let scratchCapacity = max(bufferFrames, 4096) * 2
        let scratchStorage = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratchStorage.initialize(repeating: 0, count: scratchCapacity)

        // Sized for the largest block the device is likely to ask for. Mono, so
        // no channel factor.
        let cancelledCapacity = max(bufferFrames, 4096)
        let cancelledStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: cancelledCapacity)
        cancelledStorage.initialize(repeating: 0, count: cancelledCapacity)

        // One slot per route is the most stems there can be, and costs a
        // pointer each.
        let stemRingStorage = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: count)
        stemRingStorage.initialize(repeating: nil, count: count)
        let stemChannelStorage = UnsafeMutablePointer<Int32>.allocate(capacity: count)
        stemChannelStorage.initialize(repeating: 0, count: count)
        let stemCapacity = max(bufferFrames, 4096)
        let stemScratchCount = count * stemCapacity * maxStemChannels
        let stemScratchStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: stemScratchCount)
        stemScratchStorage.initialize(repeating: 0, count: stemScratchCount)

        let alignmentLineCount = count * maximumAlignmentFrames
        let alignmentLineStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: alignmentLineCount)
        alignmentLineStorage.initialize(repeating: 0, count: alignmentLineCount)
        let alignmentPositionStorage = UnsafeMutablePointer<Int32>.allocate(capacity: count)
        alignmentPositionStorage.initialize(repeating: 0, count: count)
        let alignmentCapacity = max(bufferFrames, 4096)
        let alignmentScratchStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: alignmentCapacity)
        alignmentScratchStorage.initialize(repeating: 0, count: alignmentCapacity)

        // Every slot's worth, whether or not any of them is used: the IO thread
        // cannot allocate, so the table for the second bus has to exist before
        // anybody asks for a curve on it.
        let eqStageStorage = UnsafeMutablePointer<Int32>.allocate(
            capacity: maximumEQBuffers)
        eqStageStorage.initialize(repeating: 0, count: maximumEQBuffers)
        let eqPreampStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: maximumEQBuffers)
        eqPreampStorage.initialize(repeating: 1, count: maximumEQBuffers)
        let eqCoefficientCount = maximumEQBuffers * maximumEQStages * 5
        let eqCoefficientStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: eqCoefficientCount)
        eqCoefficientStorage.initialize(repeating: 0, count: eqCoefficientCount)
        let eqStateCount = maximumEQBuffers * eqStateStride
        let eqStateStorage = UnsafeMutablePointer<Float>.allocate(capacity: eqStateCount)
        eqStateStorage.initialize(repeating: 0, count: eqStateCount)

        let transcriptRingStorage = UnsafeMutablePointer<OpaquePointer?>.allocate(
            capacity: count)
        transcriptRingStorage.initialize(repeating: nil, count: count)
        let transcriptCapacity = max(bufferFrames, 4096)
        let transcriptScratchStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: transcriptCapacity)
        transcriptScratchStorage.initialize(repeating: 0, count: transcriptCapacity)

        let analysisCapacity = max(bufferFrames, 4096)
        let analysisScratch = UnsafeMutablePointer<Float>.allocate(
            capacity: analysisCapacity)
        analysisScratch.initialize(repeating: 0, count: analysisCapacity)

        let clockSampleStorage =
            sharedClock?.sampleTime
            ?? {
                let storage = UnsafeMutablePointer<Float64>.allocate(capacity: 1)
                storage.initialize(to: 0)
                return storage
            }()
        let clockHostStorage =
            sharedClock?.hostTime
            ?? {
                let storage = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
                storage.initialize(to: 0)
                return storage
            }()

        let graph = UnsafeMutablePointer<RTGraph>.allocate(capacity: 1)
        graph.initialize(
            to: RTGraph(
                routes: routeStorage,
                routeCount: Int32(routeList.count),
                peaks: peakStorage,
                rms: rmsStorage,
                calibrating: 0,
                calibrationEnergy: energyStorage,
                calibrationFrames: framesStorage,
                // −60 dBFS. Below this nobody is talking into anything.
                calibrationGate: 0.001,
                cycleCounter: counterStorage,
                peakDecay: decay(bufferFrames: bufferFrames, sampleRate: sampleRate),
                clockSampleTime: clockSampleStorage,
                clockHostTime: clockHostStorage,
                ownsClockStorage: sharedClock == nil ? 1 : 0,
                voiceIsolation: nil,
                isolationIsChain: 0,
                effectTransition: nil,
                recordRing: nil,
                recordChannels: 0,
                recordPaused: 0,
                recordScratch: scratchStorage,
                recordScratchCapacity: Int32(scratchCapacity),
                mainOutputBuffer: 0,
                duckEnabled: 0,
                duckDepth: 0.1,
                duckThreshold: 0.02,
                duckAllowed: 0,
                duckGain: 1,
                duckAttack: coefficient(
                    seconds: 0.08, bufferFrames: bufferFrames, sampleRate: sampleRate),
                duckRelease: coefficient(
                    seconds: 0.6, bufferFrames: bufferFrames, sampleRate: sampleRate),
                micPeak: 0,
                outputPeak: 0,
                outputClipped: 0,
                masterExemptBuffer: -1,
                inputGain: 1,
                inputMuted: 0,
                outputGain: 1,
                outputMuted: 0,
                cancelledRing: nil,
                cancelledBuffer: cancelledStorage,
                cancelledCapacity: Int32(cancelledCapacity),
                cancelledFrames: 0,
                // Two seconds at 48 kHz. Long enough that a UI poll at any
                // practical rate finds a whole 400 ms loudness block waiting,
                // short enough that a stalled consumer discards stale audio
                // rather than showing a reading from a second ago.
                analysisEnabled: 0,
                stemRings: stemRingStorage,
                stemChannels: stemChannelStorage,
                stemScratch: stemScratchStorage,
                stemCount: Int32(count),
                stemCapacity: Int32(stemCapacity),
                stemFrames: 0,
                alignmentFrames: 0,
                alignmentLines: alignmentLineStorage,
                alignmentPositions: alignmentPositionStorage,
                alignmentScratch: alignmentScratchStorage,
                alignmentCapacity: Int32(alignmentCapacity),
                eqStages: eqStageStorage,
                eqCoefficients: eqCoefficientStorage,
                eqState: eqStateStorage,
                eqPreampGain: eqPreampStorage,
                transcriptRings: transcriptRingStorage,
                transcriptScratch: transcriptScratchStorage,
                transcriptCount: Int32(count),
                transcriptCapacity: Int32(transcriptCapacity),
                analysisRing: yun_rt_ring_create(131_072),
                analysisScratch: analysisScratch,
                analysisCapacity: Int32(analysisCapacity),
                commands: yun_rt_queue_create(256),
                selftest: nil))
        return graph
    }

    static func deallocate(_ graph: UnsafeMutablePointer<RTGraph>) {
        let count = max(Int(graph.pointee.routeCount), 1)
        graph.pointee.routes.deinitialize(count: count)
        graph.pointee.routes.deallocate()
        graph.pointee.peaks.deinitialize(count: count)
        graph.pointee.peaks.deallocate()
        graph.pointee.rms.deinitialize(count: count)
        graph.pointee.rms.deallocate()
        graph.pointee.calibrationEnergy.deinitialize(count: count)
        graph.pointee.calibrationEnergy.deallocate()
        graph.pointee.calibrationFrames.deinitialize(count: count)
        graph.pointee.calibrationFrames.deallocate()
        if graph.pointee.ownsClockStorage != 0 {
            graph.pointee.cycleCounter.deinitialize(count: 1)
            graph.pointee.cycleCounter.deallocate()
        }
        graph.pointee.recordScratch.deinitialize(
            count: Int(graph.pointee.recordScratchCapacity))
        graph.pointee.recordScratch.deallocate()
        graph.pointee.cancelledBuffer.deinitialize(
            count: Int(graph.pointee.cancelledCapacity))
        graph.pointee.cancelledBuffer.deallocate()
        if graph.pointee.ownsClockStorage != 0 {
            graph.pointee.clockSampleTime.deinitialize(count: 1)
            graph.pointee.clockSampleTime.deallocate()
            graph.pointee.clockHostTime.deinitialize(count: 1)
            graph.pointee.clockHostTime.deallocate()
        }
        graph.pointee.stemRings.deinitialize(count: count)
        graph.pointee.stemRings.deallocate()
        graph.pointee.stemChannels.deinitialize(count: count)
        graph.pointee.stemChannels.deallocate()
        let stemScratchCount =
            count * Int(graph.pointee.stemCapacity) * maxStemChannels
        graph.pointee.stemScratch.deinitialize(count: stemScratchCount)
        graph.pointee.stemScratch.deallocate()
        graph.pointee.alignmentLines.deinitialize(count: count * maximumAlignmentFrames)
        graph.pointee.alignmentLines.deallocate()
        graph.pointee.alignmentPositions.deinitialize(count: count)
        graph.pointee.alignmentPositions.deallocate()
        graph.pointee.alignmentScratch.deinitialize(
            count: Int(graph.pointee.alignmentCapacity))
        graph.pointee.alignmentScratch.deallocate()
        graph.pointee.eqStages.deinitialize(count: maximumEQBuffers)
        graph.pointee.eqStages.deallocate()
        graph.pointee.eqPreampGain.deinitialize(count: maximumEQBuffers)
        graph.pointee.eqPreampGain.deallocate()
        graph.pointee.eqCoefficients.deinitialize(
            count: maximumEQBuffers * maximumEQStages * 5)
        graph.pointee.eqCoefficients.deallocate()
        graph.pointee.eqState.deinitialize(count: maximumEQBuffers * eqStateStride)
        graph.pointee.eqState.deallocate()
        graph.pointee.transcriptRings.deinitialize(count: count)
        graph.pointee.transcriptRings.deallocate()
        graph.pointee.transcriptScratch.deinitialize(
            count: Int(graph.pointee.transcriptCapacity))
        graph.pointee.transcriptScratch.deallocate()
        graph.pointee.analysisScratch.deinitialize(
            count: Int(graph.pointee.analysisCapacity))
        graph.pointee.analysisScratch.deallocate()
        if let ring = graph.pointee.analysisRing { yun_rt_ring_free(ring) }
        if let commands = graph.pointee.commands { yun_rt_queue_free(commands) }
        graph.deinitialize(count: 1)
        graph.deallocate()
    }

    // MARK: Installing a correction

    /// Puts one output's cascade in place, from the control thread.
    ///
    /// Here rather than in `RoutingEngine` because the slot arithmetic is the
    /// part that is easy to get wrong — an off-by-one in the stride would run
    /// bus A's curve on bus B's history and sound like nothing in particular —
    /// and it should exist in exactly one place.
    ///
    /// The section count is written last and zeroed first. The IO thread reads
    /// it before it reads anything else in the slot, so a cycle landing in the
    /// middle of this sees either the old curve or no curve, never the old
    /// count against the new coefficients.
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
        guard buffer >= 0, buffer < maximumEQBuffers else { return false }
        let stages = min(packed.count / 5, maximumEQStages)
        guard stages > 0, preampGain.isFinite, preampGain >= 0,
            packed.prefix(stages * 5).allSatisfy(\.isFinite)
        else {
            clearCorrection(onBuffer: buffer, of: graph)
            return false
        }
        let coefficients = graph.pointee.eqCoefficients + eqCoefficientOffset(slot: buffer)

        // Whether the filter this slot runs actually changed. Reinstalling the
        // same curve happens on every publish — moving bus A's tone control
        // republishes bus B untouched — and resetting a filter's memory for
        // that would be a click on an output nobody adjusted.
        var changed =
            Int(graph.pointee.eqStages[buffer]) != stages
            || graph.pointee.eqPreampGain[buffer] != preampGain
        if !changed {
            for index in 0..<(stages * 5) where coefficients[index] != packed[index] {
                changed = true
                break
            }
        }

        graph.pointee.eqStages[buffer] = 0
        for index in 0..<(stages * 5) { coefficients[index] = packed[index] }
        if changed {
            // Carrying the history across a change of curve puts the tail of
            // the old filter into the first milliseconds of the new one.
            let state = graph.pointee.eqState + eqStateOffset(slot: buffer)
            for index in 0..<eqStateStride { state[index] = 0 }
        }
        graph.pointee.eqPreampGain[buffer] = preampGain
        graph.pointee.eqStages[buffer] = Int32(stages)
        return stages > 0
    }

    /// Takes the correction off one output, leaving every other one alone.
    static func clearCorrection(
        onBuffer buffer: Int, of graph: UnsafeMutablePointer<RTGraph>
    ) {
        guard buffer >= 0, buffer < maximumEQBuffers else { return }
        graph.pointee.eqStages[buffer] = 0
        graph.pointee.eqPreampGain[buffer] = 1
        let state = graph.pointee.eqState + eqStateOffset(slot: buffer)
        for index in 0..<eqStateStride { state[index] = 0 }
    }

    /// Carries one route's alignment delay line across a graph rebuild.
    ///
    /// The line always uses `maximumAlignmentFrames` as its modulus, even while
    /// today's delay is zero. Its history therefore remains ordered when a new
    /// effect asks for a different delay. Refusing to carry it on that exact
    /// rebuild would fill a backing track with silence while the new line
    /// warmed up — the same discontinuity the effect handover exists to avoid.
    ///
    /// - Returns: True when the line was carried.
    @discardableResult
    static func carryAlignment(
        from previous: UnsafeMutablePointer<RTGraph>, slot old: Int,
        to next: UnsafeMutablePointer<RTGraph>, slot new: Int
    ) -> Bool {
        guard old >= 0, old < Int(previous.pointee.routeCount),
            new >= 0, new < Int(next.pointee.routeCount)
        else { return false }
        let from = previous.pointee.alignmentLines + old * maximumAlignmentFrames
        let to = next.pointee.alignmentLines + new * maximumAlignmentFrames
        to.update(from: from, count: maximumAlignmentFrames)
        next.pointee.alignmentPositions[new] = previous.pointee.alignmentPositions[old]
        return true
    }

    /// Copies every slot — curves and history alike — from one graph to another.
    ///
    /// The history comes across with the coefficients on purpose: after a chain
    /// swap it is the same filter continuing, and starting it again from
    /// nothing is a click.
    static func carryCorrections(
        from previous: UnsafeMutablePointer<RTGraph>,
        to next: UnsafeMutablePointer<RTGraph>
    ) {
        for slot in 0..<maximumEQBuffers {
            next.pointee.eqStages[slot] = previous.pointee.eqStages[slot]
            next.pointee.eqPreampGain[slot] = previous.pointee.eqPreampGain[slot]
        }
        for index in 0..<(maximumEQBuffers * maximumEQStages * 5) {
            next.pointee.eqCoefficients[index] = previous.pointee.eqCoefficients[index]
        }
        for index in 0..<(maximumEQBuffers * eqStateStride) {
            next.pointee.eqState[index] = previous.pointee.eqState[index]
        }
    }
}

// MARK: - The realtime callback

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
    guard let raw = yun_rt_cell_load(cell) else { return noErr }
    let graph = raw.assumingMemoryBound(to: RTGraph.self)
    defer { yun_rt_cell_retire(cell) }

    // Anything allocated between here and the matching call at the end is a
    // violation of the realtime contract and gets counted.
    //
    // Not gated on DEBUG: the allocator hook is only installed when the
    // tripwire is explicitly enabled, so the cost when it is off is two relaxed
    // atomic stores per cycle. Gating it on the build configuration made the
    // optimised build — the only one whose allocation behaviour actually
    // matters — report a meaningless zero.
    yun_rt_tripwire_mark_realtime(true)
    defer { yun_rt_tripwire_mark_realtime(false) }

    // Apply any pending parameter changes before touching audio, so a whole
    // cycle uses one consistent set of values.
    if let commands = graph.pointee.commands {
        var command = YunRTCommand(kind: 0, index: 0, value: 0)
        while yun_rt_queue_pop(commands, &command) {
            // The trim and the master are one control each rather than one per
            // route, so they are handled before the index is range-checked —
            // they do not carry one.
            switch command.kind {
            case Int32(kYunRTCommandSetInputGain.rawValue):
                if command.value.isFinite {
                    graph.pointee.inputGain = command.value
                }
                continue
            case Int32(kYunRTCommandSetInputMute.rawValue):
                graph.pointee.inputMuted = command.value != 0 ? 1 : 0
                continue
            case Int32(kYunRTCommandSetOutputGain.rawValue):
                if command.value.isFinite {
                    graph.pointee.outputGain = command.value
                }
                continue
            case Int32(kYunRTCommandSetOutputMute.rawValue):
                graph.pointee.outputMuted = command.value != 0 ? 1 : 0
                continue
            default:
                break
            }
            let index = Int(command.index)
            guard index >= 0, index < Int(graph.pointee.routeCount) else { continue }
            switch command.kind {
            case Int32(kYunRTCommandSetGain.rawValue):
                if command.value.isFinite {
                    graph.pointee.routes[index].gain = command.value
                }
            case Int32(kYunRTCommandSetMute.rawValue):
                graph.pointee.routes[index].muted = command.value != 0 ? 1 : 0
            default:
                break
            }
        }
    }

    let input = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inputData))
    let output = UnsafeMutableAudioBufferListPointer(outputData)
    // The destination the router is feeding, which is not necessarily buffer
    // zero once monitoring adds a second output device to the aggregate.
    let mainIndex = Int(graph.pointee.mainOutputBuffer)

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
                        old.pointee.renderFailures.pointee &+= 1
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
                        new.pointee.renderFailures.pointee &+= 1
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
                    isolation.pointee.renderFailures.pointee &+= 1
                }
            }
        }
    }

    // Ducking, decided once for the whole cycle.
    //
    // The trigger is last cycle's microphone peak, and the qualifier is the
    // classifier's recent verdict. Both have to agree: an envelope alone ducks
    // for a cough or a keyboard, and the model alone is half a second late for
    // the front of a word.
    if graph.pointee.duckEnabled != 0 {
        let talking =
            graph.pointee.duckAllowed != 0
            && graph.pointee.micPeak > graph.pointee.duckThreshold
            && graph.pointee.inputMuted == 0
        let target = talking ? graph.pointee.duckDepth : 1
        // Falling towards the duck uses the attack, coming back uses the
        // release. One coefficient for both would either clip the first
        // syllable or leave the music down for a second after every word.
        let coefficient =
            target < graph.pointee.duckGain
            ? graph.pointee.duckAttack : graph.pointee.duckRelease
        graph.pointee.duckGain =
            target + (graph.pointee.duckGain - target) * coefficient
    } else {
        graph.pointee.duckGain = 1
    }
    let duckGain = graph.pointee.duckGain

    let routeCount = Int(graph.pointee.routeCount)
    let routes = graph.pointee.routes
    let peaks = graph.pointee.peaks
    let rms = graph.pointee.rms
    let calibrating = graph.pointee.calibrating != 0
    var micPeak: Float = 0
    graph.pointee.stemFrames = 0

    for index in 0..<routeCount {
        let route = routes[index]

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
            let line = graph.pointee.alignmentLines + index * RTGraph.maximumAlignmentFrames
            let scratch = graph.pointee.alignmentScratch
            var position = Int(graph.pointee.alignmentPositions[index])
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
            graph.pointee.alignmentPositions[index] = Int32(position)
        }

        let destination = destinationData.assumingMemoryBound(to: Float.self)
        // The trim rides on the route's own fader rather than being a separate
        // pass over the samples: one multiply either way, and no second walk.
        let trim =
            route.appliesInputTrim != 0
            ? (graph.pointee.inputMuted != 0 ? 0 : graph.pointee.inputGain) : 1
        let duck = route.isDuckable != 0 ? duckGain : 1
        let gain = sanitisedAudioSample(
            route.muted != 0 ? 0 : route.gain * trim * duck)

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
        for _ in 0..<frames {
            let sample = sanitisedAudioSample(source[readAt])
            let contribution = sanitisedAudioSample(sample * gain)
            destination[writeAt] += contribution
            // Metered before gain: a meter should show what arrived, not what
            // the fader did to it. It also lets a gain-0 route act as a pure
            // probe, which is how the loopback verification works.
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            energy += sample * sample
            readAt += sourceStride
            writeAt += destinationStride
        }

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
    let master = sanitisedAudioSample(
        graph.pointee.outputMuted != 0 ? 0 : graph.pointee.outputGain)
    if master != 1 {
        let exempt = Int(graph.pointee.masterExemptBuffer)
        var scale = master
        for index in 0..<output.count where index != exempt {
            guard let data = output[index].mData else { continue }
            let samples = Int(output[index].mDataByteSize) / MemoryLayout<Float>.size
            let pointer = data.assumingMemoryBound(to: Float.self)
            guard samples > 0 else { continue }
            // The bus is contiguous and every channel gets the same number, so
            // this is one vector multiply rather than a loop that happens to do
            // the same thing one sample at a time. Same arithmetic, same
            // result: a scale is not an accumulation, so there is no rounding
            // order to disagree about.
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
            var stored = Int(selftest.pointee.captureCount.pointee)
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
                selftest.pointee.captureCount.pointee = Int32(stored)
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

    // Feed the recorder from the destination bus: what is written to disk
    // should be what the far end receives, not what arrived at the input.
    if let ring = graph.pointee.recordRing, graph.pointee.recordPaused == 0,
        mainIndex < output.count
    {
        let channels = Int(graph.pointee.recordChannels)
        if let data = output[mainIndex].mData, channels > 0 {
            let stride = Int(output[mainIndex].mNumberChannels)
            let frames =
                Int(output[mainIndex].mDataByteSize) / (MemoryLayout<Float>.size * stride)
            let source = data.assumingMemoryBound(to: Float.self)
            if stride == channels {
                _ = yun_rt_ring_write(ring, source, UInt32(frames * channels))
            } else {
                // The destination is wider than the recording, so the wanted
                // channels are gathered into the graph's own scratch first.
                let scratch = graph.pointee.recordScratch
                let usable = min(frames, Int(graph.pointee.recordScratchCapacity) / channels)
                for frame in 0..<usable {
                    for channel in 0..<channels {
                        scratch[frame * channels + channel] =
                            source[frame * stride + channel]
                    }
                }
                if usable > 0 {
                    _ = yun_rt_ring_write(ring, scratch, UInt32(usable * channels))
                }
            }
        }
    }

    // Per-bus correction, last of all and deliberately after the recorder and
    // the stems have already taken their copies. A correction is a fault in
    // somebody's headphones being undone and a bus tone is that bus's taste;
    // baking either into a file would carry it to everybody who plays the file
    // back somewhere else.
    //
    // Every output is offered its own cascade, so the monitor mix and the send
    // mix can be shaped differently. The loop is over the outputs rather than
    // over a list of installed curves: there are two of them in practice, the
    // section count for a bus running nothing is one load and one predictable
    // branch, and a list would need its own indirection to stay in step with a
    // rebuild.
    for slot in 0..<min(RTGraph.maximumEQBuffers, output.count) {
        let eqStages = Int(graph.pointee.eqStages[slot])
        guard eqStages > 0 else { continue }
        let buffer = output[slot]
        if let data = buffer.mData {
            let channels = min(Int(buffer.mNumberChannels), RTGraph.maximumEQChannels)
            let stride = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            let samples = data.assumingMemoryBound(to: Float.self)
            let coefficients =
                graph.pointee.eqCoefficients + RTGraph.eqCoefficientOffset(slot: slot)
            let state = graph.pointee.eqState + RTGraph.eqStateOffset(slot: slot)
            let preamp = graph.pointee.eqPreampGain[slot]

            // Section outermost and frames innermost — the transpose of the
            // obvious nesting, and the whole reason this stage is affordable.
            //
            // Written the other way round, every sample of every section
            // reloaded five coefficients and four state words from memory and
            // wrote four back, for nine floating-point operations. Turned
            // inside out, one section's coefficients and one channel's history
            // stay in registers for the whole block and the only memory traffic
            // is the block itself. A cascade is linear, so section k sees
            // exactly the same sequence of values in exactly the same order
            // either way; the result is identical, not merely equivalent.
            //
            // Two channels are run together in the same loop for the same
            // reason a biquad is slow in the first place: each output feeds the
            // next input, so the loop is bound by the latency of the multiply
            // chain rather than by throughput, and a second independent chain
            // fills the gaps for free.
            //
            // Measured at 128 frames on stereo, cascade only, against the same
            // graph with the correction switched off: a ten-section curve went
            // from 4572 ns a cycle to 3256, and a twenty-four-section one from
            // 14894 to 7756. The long curve gains most, which is the tell that
            // what was being paid for was the reloading and not the arithmetic.
            for section in 0..<eqStages {
                let c = coefficients + section * 5
                // Direct form I: two input and two output history terms per
                // section per channel. Form I rather than II because the state
                // is per channel, and running the channels through a shared
                // accumulator is the classic way to make a stereo filter sound
                // like a mono one.
                let b0 = c[0]
                let b1 = c[1]
                let b2 = c[2]
                let a1 = c[3]
                let a2 = c[4]
                // The headroom for the boost belongs ahead of the first section
                // only; every later one is handed what the previous produced.
                let gain = section == 0 ? preamp : 1
                let sectionState = state + section * RTGraph.maximumEQChannels * 4

                var channel = 0
                while channel + 1 < channels {
                    let left = sectionState + channel * 4
                    let right = left + 4
                    var lx1 = left[0]
                    var lx2 = left[1]
                    var ly1 = left[2]
                    var ly2 = left[3]
                    var rx1 = right[0]
                    var rx2 = right[1]
                    var ry1 = right[2]
                    var ry2 = right[3]
                    var index = channel
                    for _ in 0..<frames {
                        let lx = samples[index] * gain
                        let rx = samples[index + 1] * gain
                        let ly = b0 * lx + b1 * lx1 + b2 * lx2 - a1 * ly1 - a2 * ly2
                        let ry = b0 * rx + b1 * rx1 + b2 * rx2 - a1 * ry1 - a2 * ry2
                        lx2 = lx1
                        lx1 = lx
                        ly2 = ly1
                        ly1 = ly
                        rx2 = rx1
                        rx1 = rx
                        ry2 = ry1
                        ry1 = ry
                        samples[index] = ly
                        samples[index + 1] = ry
                        index += stride
                    }
                    left[0] = lx1
                    left[1] = lx2
                    left[2] = ly1
                    left[3] = ly2
                    right[0] = rx1
                    right[1] = rx2
                    right[2] = ry1
                    right[3] = ry2
                    channel += 2
                }

                if channel < channels {
                    let slot = sectionState + channel * 4
                    var x1 = slot[0]
                    var x2 = slot[1]
                    var y1 = slot[2]
                    var y2 = slot[3]
                    var index = channel
                    for _ in 0..<frames {
                        let x = samples[index] * gain
                        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                        x2 = x1
                        x1 = x
                        y2 = y1
                        y1 = y
                        samples[index] = y
                        index += stride
                    }
                    slot[0] = x1
                    slot[1] = x2
                    slot[2] = y1
                    slot[3] = y2
                }
            }
        }
    }

    // What actually leaves, after every gain and the main output's correction.
    //
    // This deliberately stays after the correction rather than beside the
    // pre-correction analyser and recorder. A boost or a filter transient can
    // take an otherwise clean bus over full scale, and a meter sampled before
    // that stage would report healthy audio while the hardware receives
    // clipping. Full scale in float is 1.0; anything at or past it is counted
    // rather than merely peaked.
    //
    // This is telemetry, not a hidden clipper. The untouched route is allowed
    // to stay bit-exact, and the limiter remains an explicitly enabled Audio
    // Unit. Counting damage here makes the downstream boundary visible; it
    // does not pretend a sample at 1.2 was repaired.
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
        let previous = graph.pointee.outputPeak
        graph.pointee.outputPeak = max(peak, previous * graph.pointee.peakDecay)
        graph.pointee.outputClipped &+= clipped
    }

    // Capture the master's clock before bumping the counter: readers use the
    // counter as a sequence number, so the values must already be in place.
    graph.pointee.clockSampleTime.pointee = inputTime.pointee.mSampleTime
    graph.pointee.clockHostTime.pointee = inputTime.pointee.mHostTime

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

    /// Runs `cycles` callbacks and reports what one cost.
    public static func run(_ options: Options, cycles: Int) -> Result {
        let frames = max(options.frames, 1)
        let routeCount = max(options.routes, 1)

        // Two output buffers, main second: the monitor being buffer zero is the
        // ordering the callback historically got wrong, so it is the one worth
        // benchmarking.
        let inputChannels = 2
        let outputChannels = [2, 2]
        let mainIndex = 1

        let inputStorage = UnsafeMutablePointer<Float>.allocate(
            capacity: frames * inputChannels)
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
            mDataByteSize: UInt32(frames * inputChannels * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(inputStorage))

        var outputStorage: [UnsafeMutablePointer<Float>] = []
        let outputList = AudioBufferList.allocate(maximumBuffers: outputChannels.count)
        for (index, channels) in outputChannels.enumerated() {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
            pointer.initialize(repeating: 0, count: frames * channels)
            outputStorage.append(pointer)
            outputList[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer))
        }

        var routes: [RTRoute] = []
        for index in 0..<routeCount {
            routes.append(
                RTRoute(
                    sourceBuffer: 0, sourceChannel: Int32(index % inputChannels),
                    destinationBuffer: Int32(mainIndex),
                    destinationChannel: Int32(index % 2),
                    gain: 0.8, appliesInputTrim: index == 0))
        }
        for index in 0..<max(options.monitorRoutes, 0) {
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
        graph.pointee.alignmentFrames = Int32(
            min(max(options.alignmentFrames, 0), RTGraph.maximumAlignmentFrames))

        var recordRing: OpaquePointer?
        if options.record {
            recordRing = yun_rt_ring_create(UInt32(max(frames * 8, 4096)))
            graph.pointee.recordRing = recordRing
            graph.pointee.recordChannels = 2
        }

        if options.eqStages > 0 {
            let stages = min(options.eqStages, RTGraph.maximumEQStages)
            // A gentle peaking section repeated. The coefficients only have to
            // be stable — what is being timed is the cascade, not the curve.
            var packed: [Float] = []
            for _ in 0..<stages {
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
            if let ring = graph.pointee.analysisRing {
                _ = yun_rt_ring_read(ring, graph.pointee.analysisScratch, UInt32(frames * 4))
            }
            if let ring = recordRing {
                _ = yun_rt_ring_read(ring, graph.pointee.recordScratch, UInt32(frames * 8))
            }
        }

        func spin(_ count: Int) {
            for cycle in 0..<count {
                time.mSampleTime = Double(cycle * frames)
                _ = yunAudioIOProc(
                    0, &now, UnsafePointer(inputList.unsafeMutablePointer), &time,
                    outputList.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))
                if cycle % 8 == 7 { drainRings() }
            }
        }

        // Warm the caches and let the biquad state settle before the clock
        // starts; a cold first cycle is a page-fault measurement, not this one.
        spin(min(cycles, 2000))

        let violationsBefore = yun_rt_tripwire_violations()
        let started = DispatchTime.now().uptimeNanoseconds
        spin(cycles)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let violations = yun_rt_tripwire_violations() - violationsBefore

        var checksum = 0.0
        for (index, channels) in outputChannels.enumerated() {
            let pointer = outputStorage[index]
            for sample in 0..<(frames * channels) {
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
            nanosecondsPerCycle: Double(elapsed) / Double(max(cycles, 1)),
            allocations: violations,
            checksum: checksum)
    }
}
