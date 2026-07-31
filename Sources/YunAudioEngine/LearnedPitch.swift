import CoreML
import Foundation

/// Chooses which periodicity in the autocorrelation curve belongs to the singer.
///
/// The front end is not replaced and should not be. `PitchTracker` measures
/// periodicity to **0.0 cents** on a clean sung vowel and on one with its
/// fundamental removed — better than any small network would — and it fails at
/// exactly one thing, which no amount of accuracy would help with: it cannot
/// *choose*. Autocorrelation finds periodicities; it has no way to prefer the
/// singer's over the accompaniment's. Measured, with a backing track at the
/// singer's own level: **five notes out of five lost, 1902 cents**.
///
/// So the rule that picks the peak is what gets replaced, and the curve it picks
/// from is what the network reads. 940 lags in, a distribution over the same 940
/// lags out, with the same parabolic refinement applied to the winner that the
/// rule already used.
///
/// ## What it was trained on
///
/// Nothing anybody else's. Sixty thousand frames synthesised by
/// `yunaudio-pitchdata`: a voice from 80 to 900 Hz with four to fourteen
/// partials and a little inharmonicity, an accompaniment in three quarters of
/// them at between a fifth and *one and a half times* the singer's level, and
/// broadband noise. The labels are exact by construction — a harmonic stack
/// built at 261.63 Hz is 261.63 Hz — which is the one thing a recording of a
/// real person can never give you.
///
/// The features come out of `PitchTracker.correlationCurve`, the same call that
/// serves them here. Reimplementing the front end in Python to generate training
/// data would have been two implementations of one thing, which is the defect
/// this project keeps finding elsewhere.
///
/// **What it has not seen**: a real voice, a real room, a real speaker. It knows
/// the decision problem, not the world. That is stated rather than glossed,
/// because it is the reason the DSP answer is still consulted.
///
/// ## Why it is not on the Neural Engine
///
/// Because it does not need to be, and the numbers say so rather than the
/// architecture. Measured on this machine, per frame: CPU only 0.051 ms, CPU and
/// ANE 0.049, CPU and GPU 0.047, everything 0.045 — four ways of saying the same
/// thing. The model is 362,000 parameters and dispatching it to the Neural
/// Engine costs more than running it.
///
/// The hardware is not the problem and that was checked rather than assumed: a
/// control model large enough to matter — eight 3×3 convolutions over 256
/// channels at 64×64 — goes from **6.17 ms on the CPU to 2.64 ms on the ANE**,
/// on this machine, through this toolchain. The Neural Engine works. This model
/// is below the size where it pays, which is a consequence of putting the DSP
/// front end in front of it, and that trade was the right one: 0.045 ms is free
/// at a scoring cadence of four hertz, and the front end is what makes the
/// network small enough to train on synthetic data at all.
public final class LearnedPitch: @unchecked Sendable {

    /// Where the curve's first lag sits, so a bin can become a frequency.
    public let minimumLag: Int
    public let sampleRate: Double
    public let width: Int

    private let model: MLModel
    private let input: MLMultiArray

    /// Loads the head from the package's own bundle.
    ///
    /// - Returns: Nil when the model is absent or will not compile, which is a
    ///   perfectly good state — the caller keeps the rule.
    public init?(sampleRate: Double) {
        guard
            let url = Bundle.module.url(
                forResource: "PitchHead", withExtension: "mlpackage")
        else { return nil }
        let configuration = MLModelConfiguration()
        // Everything, and let Core ML decide. Pinning it to the Neural Engine
        // would be slower here — see the note above — and pinning it to the CPU
        // would be a decision made once, in a comment, about every machine this
        // ever runs on.
        configuration.computeUnits = .all
        guard
            let compiled = try? MLModel.compileModel(at: url),
            let model = try? MLModel(contentsOf: compiled, configuration: configuration)
        else { return nil }
        self.model = model

        let metadata =
            model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        minimumLag = metadata["minimumLag"].flatMap(Int.init) ?? 42
        self.sampleRate = sampleRate
        guard
            let shape = model.modelDescription.inputDescriptionsByName["curve"]?
                .multiArrayConstraint?.shape,
            shape.count == 4
        else { return nil }
        width = shape[1].intValue
        guard
            let input = try? MLMultiArray(
                shape: [1, NSNumber(value: width), 1, 1], dataType: .float32)
        else { return nil }
        self.input = input
    }

    /// The rule's answer where the rule is reliable, the head's where it is not,
    /// and the rule's precision either way.
    ///
    /// Measured, on the ruler that motivated all of this:
    ///
    ///     clean sung vowel        rule 0.0¢     head 13.3¢
    ///     backing at voice level  rule 5/5 lost head 0/5 lost, worst 6¢
    ///
    /// Neither is better. The rule *measures* superbly and *chooses* badly; the
    /// head chooses well and measures to about a seventh of a semitone, because
    /// its answer is a bin index and 940 bins over a singer's range is as fine
    /// as it gets. Replacing one with the other would trade a catastrophic
    /// failure for a small permanent one.
    ///
    /// So they are combined along the seam where each is strong. The head picks
    /// which periodicity belongs to the singer. The rule's own parabolic
    /// interpolation then places that periodicity exactly, by looking at the
    /// curve around the head's choice rather than around its own. When the two
    /// already agree — which is every unambiguous frame — this is the rule's
    /// answer unchanged, at no cost in accuracy.
    ///
    /// - Parameters:
    ///   - curve: From `PitchTracker.correlationCurve`.
    ///   - ruled: What `PitchTracker.track` said about the same frame.
    public func hertz(from curve: [Float], agreeingWith ruled: Float) -> Float {
        let chosen = hertz(from: curve)
        guard chosen > 0 else { return ruled }
        guard ruled > 0 else { return chosen }
        // Inside a semitone the two are answering the same question and the
        // rule's answer is the more precise one. Outside it they have picked
        // different periodicities, which is the disagreement the head exists to
        // settle.
        let apart = abs(1200 * log2(Double(ruled) / Double(chosen)))
        guard apart > 50 else { return ruled }
        return refine(curve: curve, near: chosen)
    }

    /// Places the head's choice exactly, using the curve it was chosen from.
    ///
    /// The head's own refinement interpolates the *probability* distribution,
    /// which is smooth and says little about where the period actually is. The
    /// correlation curve around the same lag is the measurement, and it is the
    /// one the rule has always used.
    private func refine(curve: [Float], near hertz: Float) -> Float {
        guard hertz > 0 else { return 0 }
        let lag = sampleRate / Double(hertz)
        let index = Int(lag.rounded()) - minimumLag
        guard index > 0, index + 1 < curve.count else { return hertz }
        // The local maximum nearest the head's answer, since the head's bin is
        // only accurate to a bin.
        var best = index
        for candidate in max(1, index - 2)...min(curve.count - 2, index + 2)
        where curve[candidate] > curve[best] {
            best = candidate
        }
        let left = curve[best - 1]
        let centre = curve[best]
        let right = curve[best + 1]
        let denominator = left - 2 * centre + right
        let offset = denominator != 0 ? 0.5 * (left - right) / denominator : 0
        let refined = Double(best + minimumLag) + Double(max(-1, min(1, offset)))
        guard refined > 0 else { return hertz }
        return Float(sampleRate / refined)
    }

    /// The pitch the curve describes, in hertz, or zero when there is none.
    ///
    /// - Parameter curve: Exactly `width` values from
    ///   `PitchTracker.correlationCurve`.
    public func hertz(from curve: [Float]) -> Float {
        guard curve.count == width else { return 0 }
        let destination = input.dataPointer.bindMemory(to: Float.self, capacity: width)
        curve.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: width)
        }
        guard
            let features = try? MLDictionaryFeatureProvider(dictionary: ["curve": input]),
            let output = try? model.prediction(from: features),
            let probabilities = output.featureValue(for: "lagProbabilities")?
                .multiArrayValue
        else { return 0 }

        let values = probabilities.dataPointer.bindMemory(to: Float.self, capacity: width)
        var best = 0
        var bestValue: Float = 0
        for index in 0..<width where values[index] > bestValue {
            bestValue = values[index]
            best = index
        }
        // Nothing confident enough to be a note. The distribution is over 940
        // bins, so a flat one peaks near a thousandth; anything this far above
        // that is a decision rather than a shrug.
        guard bestValue > 0.05 else { return 0 }

        // The same parabolic refinement the rule uses: the true period is
        // rarely a whole number of samples.
        let left = best > 0 ? values[best - 1] : 0
        let right = best + 1 < width ? values[best + 1] : 0
        let denominator = left - 2 * bestValue + right
        let offset = denominator != 0 ? 0.5 * (left - right) / denominator : 0
        let lag = Double(best + minimumLag) + Double(max(-1, min(1, offset)))
        guard lag > 0 else { return 0 }
        return Float(sampleRate / lag)
    }
}
