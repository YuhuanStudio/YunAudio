import Foundation

/// Everything measured off the routed signal that is too expensive to compute
/// on the IO thread.
///
/// Loudness and the spectrum both want the same samples, and both allocate —
/// the loudness meter grows an array of block energies for the whole session,
/// the FFT keeps a window. Neither belongs anywhere near a time-constrained
/// thread. So the IO thread does the one cheap thing it can do safely, folding
/// the output bus to mono into a ring, and everything else happens here on a
/// timer.
public final class SignalAnalyser {

    /// One reading, as the interface consumes it.
    public struct Reading: Sendable, Equatable {
        /// Loudness over the last 400 ms.
        public var momentary: Double
        /// Loudness over the last 3 seconds. The one worth watching while
        /// speaking: momentary jumps around too much to aim with.
        public var shortTerm: Double
        /// Loudness over the whole session, gated. What a platform normalises.
        public var integrated: Double
        /// The spread between the quiet and loud parts, in LU.
        public var range: Double
        /// Sample peak in decibels, since the last reset.
        public var peak: Double
        /// Log-spaced band magnitudes, 0...1.
        public var bands: [Float]
        /// Seconds of audio measured, so the interface can say the integrated
        /// figure is not meaningful yet rather than showing a number that will
        /// move by five units in the next ten seconds.
        public var duration: Double
        /// What the on-device model hears in the signal.
        public var verdict: SoundClassifier.Verdict
        public var verdictConfidence: Double
        /// The model's own label, which is finer than the verdict.
        public var verdictLabel: String
        /// The fundamental of the voice in hertz, or zero when there is no
        /// pitch to find. Silence, breath and a fan all correctly report zero.
        public var pitchHertz: Float

        public init(
            momentary: Double, shortTerm: Double, integrated: Double, range: Double,
            peak: Double, bands: [Float], duration: Double,
            verdict: SoundClassifier.Verdict, verdictConfidence: Double,
            verdictLabel: String, pitchHertz: Float = 0
        ) {
            self.momentary = momentary
            self.shortTerm = shortTerm
            self.integrated = integrated
            self.range = range
            self.peak = peak
            self.bands = bands
            self.duration = duration
            self.verdict = verdict
            self.verdictConfidence = verdictConfidence
            self.verdictLabel = verdictLabel
            self.pitchHertz = pitchHertz
        }

        public static let silent = Reading(
            momentary: -.infinity, shortTerm: -.infinity, integrated: -.infinity,
            range: 0, peak: -.infinity,
            bands: SignalAnalyser.silentBands,
            duration: 0, verdict: .quiet, verdictConfidence: 0, verdictLabel: "",
            pitchHertz: 0)
    }

    /// One copy-on-write zero spectrum shared by readings which did not ask for
    /// an FFT. Auto-levelling reads at the poll rate; allocating 24 floats for
    /// every one of those readings was work whose visible result was always the
    /// same row of zeroes.
    static let silentBands = [Float](repeating: 0, count: SpectrumAnalyser.bandCount)

    private var loudness: LoudnessMeter?
    private var spectrum: SpectrumAnalyser?
    /// Apple's on-device sound model.
    ///
    /// Built on first use and torn down when nothing wants it. That is not
    /// tidiness: the classifier holds a CoreML model and an analysis queue, and
    /// the FFT below owns a transform setup and two window tables. Somebody who
    /// never opens the analysis panel and never switches on levelling should
    /// not be paying for either — a router that quietly loads a neural network
    /// to forward audio between two devices has misunderstood its own job.
    public private(set) var classifier: SoundClassifier?
    private let makeClassifier: (Double) -> SoundClassifier?
    private var tracker: PitchTracker?
    /// Samples waiting for a whole tracker frame.
    private var pitchPending: [Float] = []
    private var lastPitch: Float = 0
    private let sampleRate: Double
    private var buffer: [Float]
    /// Frames which actually reached loudness, not frames consumed by some
    /// other analyser before loudness was requested.
    private var loudnessMeasuredFrames: Int = 0
    /// A quarter of a second at 96 kHz. The drain runs far more often than
    /// that; the headroom is for the case where the main thread was busy and
    /// several polls' worth piled up.
    static let workingBufferFrames = 24_576

    /// Storage retained solely to drain the analysis ring.
    ///
    /// Internal so the idle-memory contract can assert bytes rather than infer
    /// them from a source declaration.
    var workingBufferBytes: Int {
        buffer.count * MemoryLayout<Float>.stride
    }

    /// Fixed Array elements retained by the loudness meter, excluding Array and
    /// allocator metadata.
    var loudnessStorageBytes: Int {
        loudness == nil ? 0 : LoudnessMeter.retainedArrayBytes(sampleRate: sampleRate)
    }

    /// What the caller currently wants computed. Everything not asked for is
    /// not merely skipped but not allocated.
    public struct Needs: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Loudness only. Cheap, and the levelling and the readout both need it.
        public static let loudness = Needs(rawValue: 1 << 0)
        /// The FFT and its window tables.
        public static let spectrum = Needs(rawValue: 1 << 1)
        /// Apple's sound model.
        public static let classification = Needs(rawValue: 1 << 2)
        /// The fundamental frequency, which is a transform per frame.
        public static let pitch = Needs(rawValue: 1 << 3)
    }

    private var needs: Needs = []

    /// Declares what is wanted. Building and releasing happen here rather than
    /// on every drain.
    public func require(_ wanted: Needs) {
        guard wanted != needs else { return }
        needs = wanted

        if wanted.isEmpty {
            // An idle analyser is kept around so integrated loudness can resume
            // within the same route, but its drain storage has no state worth
            // preserving. Releasing it saves 98,304 bytes whenever every
            // analysis consumer is closed.
            buffer = []
        } else if buffer.isEmpty {
            buffer = [Float](repeating: 0, count: Self.workingBufferFrames)
        }

        // Integrated loudness is session state, so once requested it survives a
        // window closing. It is nevertheless absent from a menu-bar-only route
        // and from ducking, whose classifier never reads it: 3,033,856 bytes at
        // 48 kHz should not be a prerequisite for recognising speech.
        if wanted.contains(.loudness), loudness == nil {
            loudness = LoudnessMeter(sampleRate: sampleRate)
        }

        if wanted.contains(.spectrum) {
            if spectrum == nil { spectrum = SpectrumAnalyser(sampleRate: sampleRate) }
        } else {
            spectrum = nil
        }

        if wanted.contains(.classification) {
            if classifier == nil { classifier = makeClassifier(sampleRate) }
        } else {
            classifier = nil
        }

        if wanted.contains(.pitch) {
            if tracker == nil { tracker = PitchTracker(sampleRate: sampleRate) }
        } else {
            tracker = nil
            pitchPending.removeAll(keepingCapacity: true)
            lastPitch = 0
        }
    }

    public convenience init(sampleRate: Double) {
        self.init(sampleRate: sampleRate, makeClassifier: SoundClassifier.init(sampleRate:))
    }

    init(
        sampleRate: Double,
        makeClassifier: @escaping (Double) -> SoundClassifier?
    ) {
        self.sampleRate = sampleRate
        self.makeClassifier = makeClassifier
        loudness = nil
        buffer = []
    }

    /// Pulls from the engine and folds the result into both meters.
    ///
    /// Loops until the ring is dry rather than taking one bufferful, so a
    /// backlog is measured rather than discarded — dropping it would make the
    /// integrated reading depend on how busy the interface happened to be.
    public func drain(from engine: RoutingEngine) {
        // `drain` is public and can be called independently of RouterModel's
        // `isIdle` gate. An empty Array has no base address to force-unwrap,
        // and an idle analyser has deliberately released this buffer.
        guard !buffer.isEmpty else { return }
        while true {
            let taken = buffer.withUnsafeMutableBufferPointer { pointer in
                engine.drainAnalysis(into: pointer.baseAddress!, capacity: pointer.count)
            }
            guard taken > 0 else { return }
            buffer.withUnsafeBufferPointer { pointer in
                add(pointer.baseAddress!, count: taken)
            }
            // One frame at a time, keeping only the newest: a backlog of pitch
            // frames is a backlog of answers nobody will read.
            while pitchPending.count >= PitchTracker.frameSize {
                if let tracker {
                    let frame = Array(pitchPending.prefix(PitchTracker.frameSize))
                    let found = tracker.track(frame: frame)
                    // Held through a frame or two of consonant rather than
                    // dropping to nothing: a readout that blinks off on every
                    // plosive is unreadable.
                    if found > 0 {
                        lastPitch = found
                    } else {
                        lastPitch *= 0.5
                        if lastPitch < 20 { lastPitch = 0 }
                    }
                }
                pitchPending.removeFirst(PitchTracker.frameSize)
            }
            if taken < buffer.count { return }
        }
    }

    private func add(_ samples: UnsafePointer<Float>, count: Int) {
        if loudness != nil {
            loudness?.add(samples, count: count)
            loudnessMeasuredFrames += count
        }
        spectrum?.add(samples, count: count)
        classifier?.add(samples, count: count)
        if tracker != nil {
            pitchPending.append(
                contentsOf: UnsafeBufferPointer(start: samples, count: count))
        }
    }

    /// Deterministic control-thread feed for lifecycle tests.
    ///
    /// The production path differs only in where the same contiguous samples
    /// came from; constructing a CoreAudio graph to verify a frame counter
    /// would make a memory test depend on hardware.
    func addForTesting(_ samples: [Float]) {
        samples.withUnsafeBufferPointer {
            guard let base = $0.baseAddress else { return }
            add(base, count: $0.count)
        }
    }

    /// True when nothing at all is wanted, so the drain can skip the ring
    /// entirely rather than copying audio nobody will look at.
    public var isIdle: Bool { needs.isEmpty }

    /// The current chroma, when the spectrum is being computed at all.
    ///
    /// Not part of `Reading`: a chroma is twelve doubles and the reading is
    /// rebuilt on every poll, twenty times a second, for an interface that
    /// wants this once a second at most.
    public func chroma() -> [Double]? { spectrum?.chroma(sampleRate: sampleRate) }

    public func reading() -> Reading {
        Reading(
            momentary: loudness?.momentary ?? -.infinity,
            shortTerm: loudness?.shortTerm ?? -.infinity,
            integrated: loudness?.integrated ?? -.infinity,
            range: loudness?.range ?? 0,
            peak: loudness?.peak ?? -.infinity,
            bands: spectrum?.bands ?? Self.silentBands,
            duration: Double(loudnessMeasuredFrames) / sampleRate,
            verdict: classifier?.verdict ?? .quiet,
            verdictConfidence: classifier?.confidence ?? 0,
            verdictLabel: classifier?.label ?? "",
            pitchHertz: lastPitch)
    }

    /// Starts the integrated measurement over. Bound to a button, because an
    /// integrated figure that has been running since the application launched
    /// answers a question nobody asked — the useful one is "how loud was I in
    /// the take I just did".
    public func reset() {
        loudness?.reset()
        spectrum?.reset()
        classifier?.reset()
        pitchPending.removeAll(keepingCapacity: true)
        lastPitch = 0
        loudnessMeasuredFrames = 0
    }
}
