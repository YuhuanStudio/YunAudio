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
            bands: [Float](repeating: 0, count: SpectrumAnalyser.bandCount),
            duration: 0, verdict: .quiet, verdictConfidence: 0, verdictLabel: "",
            pitchHertz: 0)
    }

    private var loudness: LoudnessMeter
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
    private var tracker: PitchTracker?
    /// Samples waiting for a whole tracker frame.
    private var pitchPending: [Float] = []
    private var lastPitch: Float = 0
    private let sampleRate: Double
    private var buffer: [Float]
    private var measuredFrames: Int = 0

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

        if wanted.contains(.spectrum) {
            if spectrum == nil { spectrum = SpectrumAnalyser(sampleRate: sampleRate) }
        } else {
            spectrum = nil
        }

        if wanted.contains(.classification) {
            if classifier == nil { classifier = SoundClassifier(sampleRate: sampleRate) }
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

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        loudness = LoudnessMeter(sampleRate: sampleRate)
        // A quarter of a second at 96 kHz. The drain runs far more often than
        // that; the headroom is for the case where the main thread was busy and
        // several polls' worth piled up.
        buffer = [Float](repeating: 0, count: 24576)
    }

    /// Pulls from the engine and folds the result into both meters.
    ///
    /// Loops until the ring is dry rather than taking one bufferful, so a
    /// backlog is measured rather than discarded — dropping it would make the
    /// integrated reading depend on how busy the interface happened to be.
    public func drain(from engine: RoutingEngine) {
        while true {
            let taken = buffer.withUnsafeMutableBufferPointer { pointer in
                engine.drainAnalysis(into: pointer.baseAddress!, capacity: pointer.count)
            }
            guard taken > 0 else { return }
            buffer.withUnsafeBufferPointer { pointer in
                let base = pointer.baseAddress!
                loudness.add(base, count: taken)
                spectrum?.add(base, count: taken)
                classifier?.add(base, count: taken)
                if tracker != nil {
                    pitchPending.append(
                        contentsOf: UnsafeBufferPointer(start: base, count: taken))
                }
            }
            measuredFrames += taken
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

    /// True when nothing at all is wanted, so the drain can skip the ring
    /// entirely rather than copying audio nobody will look at.
    public var isIdle: Bool { needs.isEmpty }

    public func reading() -> Reading {
        Reading(
            momentary: loudness.momentary,
            shortTerm: loudness.shortTerm,
            integrated: loudness.integrated,
            range: loudness.range,
            peak: loudness.peak,
            bands: spectrum?.bands ?? [Float](repeating: 0, count: SpectrumAnalyser.bandCount),
            duration: Double(measuredFrames) / sampleRate,
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
        loudness.reset()
        spectrum?.reset()
        classifier?.reset()
        pitchPending.removeAll(keepingCapacity: true)
        lastPitch = 0
        measuredFrames = 0
    }
}
