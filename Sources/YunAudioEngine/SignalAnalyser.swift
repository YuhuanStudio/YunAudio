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

        public static let silent = Reading(
            momentary: -.infinity, shortTerm: -.infinity, integrated: -.infinity,
            range: 0, peak: -.infinity,
            bands: [Float](repeating: 0, count: SpectrumAnalyser.bandCount),
            duration: 0, verdict: .quiet, verdictConfidence: 0, verdictLabel: "")
    }

    private var loudness: LoudnessMeter
    private var spectrum: SpectrumAnalyser?
    /// Apple's on-device sound model. Optional because it can fail to build,
    /// and everything here still works without it — the levelling simply holds
    /// still rather than guessing.
    public let classifier: SoundClassifier?
    private let sampleRate: Double
    private var buffer: [Float]
    private var measuredFrames: Int = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        loudness = LoudnessMeter(sampleRate: sampleRate)
        spectrum = SpectrumAnalyser(sampleRate: sampleRate)
        classifier = SoundClassifier(sampleRate: sampleRate)
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
            }
            measuredFrames += taken
            if taken < buffer.count { return }
        }
    }

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
            verdictLabel: classifier?.label ?? "")
    }

    /// Starts the integrated measurement over. Bound to a button, because an
    /// integrated figure that has been running since the application launched
    /// answers a question nobody asked — the useful one is "how loud was I in
    /// the take I just did".
    public func reset() {
        loudness.reset()
        spectrum?.reset()
        classifier?.reset()
        measuredFrames = 0
    }
}
