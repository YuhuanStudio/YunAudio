import Accelerate
import Foundation
import Testing

@testable import YunAudioEngine

/// How accurate the pitch tracker actually is, on signals whose pitch is known
/// exactly.
///
/// Nobody had measured it. The tracker has been the foundation of the scoring
/// since it was written, and the only evidence for it was that the numbers on
/// screen looked plausible — which is the same evidence a broken tracker
/// produces.
///
/// This is the ruler. Every claim about a better estimator — a neural one on the
/// Neural Engine, a fitted one, a differently tuned one — has to beat these
/// numbers on these signals, and "it sounds better" stops being an argument.
///
/// ## Why synthetic
///
/// The ground truth for a recording of a person is somebody's opinion. The
/// ground truth for a harmonic stack synthesised at 220.00 Hz is 220.00 Hz, and
/// the interesting failures — a missing fundamental, a strong third harmonic,
/// noise, vibrato, a slightly inharmonic voice — are all things that can be
/// built on purpose and measured exactly. A tracker that handles those handles
/// a singer; one that does not is broken in a way a real recording would let it
/// hide.
@Suite("what the pitch tracker actually measures")
struct PitchAccuracyTests {

    private let rate: Double = 48_000

    /// A sung note: a fundamental with the harmonic series above it, the way a
    /// voice makes one.
    ///
    /// - Parameters:
    ///   - harmonics: How many partials. A voice on a vowel has a dozen; a
    ///     whistle has one.
    ///   - fundamentalGain: Zero removes the fundamental entirely, which is the
    ///     case that breaks a naive spectrum peak — the ear still hears the
    ///     pitch, and it is not in the signal.
    ///   - inharmonicity: How far the partials drift from exact multiples, as a
    ///     fraction. Real voices are slightly inharmonic.
    ///   - noise: Broadband, as a fraction of the total amplitude.
    private func voice(
        hertz: Double, seconds: Double = 0.2, harmonics: Int = 8,
        fundamentalGain: Double = 1, inharmonicity: Double = 0, noise: Double = 0,
        vibratoCents: Double = 0, seed: UInt64 = 1
    ) -> [Float] {
        let count = Int(seconds * rate)
        var out = [Float](repeating: 0, count: count)
        var random = SplitMix(seed: seed)
        for index in 0..<count {
            let t = Double(index) / rate
            // Vibrato at five hertz, which is where a trained voice sits.
            let cents = vibratoCents * sin(2 * .pi * 5 * t)
            let f0 = hertz * pow(2, cents / 1200)
            var sample = 0.0
            for harmonic in 1...harmonics {
                let gain = (harmonic == 1 ? fundamentalGain : 1) / Double(harmonic)
                let drift = 1 + inharmonicity * Double(harmonic - 1)
                sample += gain * sin(2 * .pi * f0 * Double(harmonic) * drift * t)
            }
            if noise > 0 { sample += noise * (random.nextUnit() * 2 - 1) }
            out[index] = Float(sample * 0.2)
        }
        return out
    }

    /// Deterministic noise, so a failure is reproducible.
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func nextUnit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            return Double(z >> 11) / Double(1 << 53)
        }
    }

    /// Error in cents, which is the unit that matters: a hundred cents is a
    /// semitone, and the scorer's threshold is fifty.
    private func cents(_ measured: Double, _ wanted: Double) -> Double {
        guard measured > 0, wanted > 0 else { return .infinity }
        return abs(1200 * log2(measured / wanted))
    }

    private func track(_ samples: [Float], sung: Bool = false) -> Double {
        guard
            let tracker = PitchTracker(
                sampleRate: rate,
                lowest: sung ? PitchTracker.lowestSungHertz : PitchTracker.lowestHertz,
                highest: sung ? PitchTracker.highestSungHertz : PitchTracker.highestHertz)
        else { return 0 }
        // The median of the frames, so one bad frame at an edge does not decide
        // the answer — which is what the live tracker's own smoothing does.
        var readings: [Double] = []
        var start = 0
        while start + PitchTracker.frameSize <= samples.count {
            let frame = Array(samples[start..<(start + PitchTracker.frameSize)])
            let hertz = Double(tracker.track(frame: frame))
            if hertz > 0 { readings.append(hertz) }
            start += PitchTracker.frameSize / 2
        }
        guard !readings.isEmpty else { return 0 }
        readings.sort()
        return readings[readings.count / 2]
    }

    /// Notes across a singer's range, from a low male voice to a high soprano.
    /// Inside the tracker's declared 60…400 Hz.
    private let scale: [Double] = [
        82.41, 98.00, 110.00, 130.81, 164.81, 196.00, 220.00, 261.63, 329.63, 392.00,
    ]

    /// Above it. A4 is 440 and a soprano's line lives here, so this is not an
    /// exotic case — it is most of the female pop repertoire.
    private let aboveTheCeiling: [Double] = [440.00, 523.25, 659.25, 783.99, 880.00]

    @Test("a clean sung vowel is measured to within a few cents")
    func cleanVoice() {
        var worst = 0.0
        var failures: [String] = []
        for wanted in scale {
            let measured = track(voice(hertz: wanted), sung: true)
            let error = cents(measured, wanted)
            worst = max(worst, error)
            if error > 25 {
                failures.append(String(format: "%.1f Hz → %.1f Hz", wanted, measured))
            }
        }
        print(String(format: "clean voice: worst %.1f cents", worst))
        #expect(failures.isEmpty, "\(failures)")
        // A quarter of a semitone. Beyond this the scorer's own fifty-cent
        // threshold is being spent on the tracker rather than on the singer.
        #expect(worst < 25)
    }

    @Test("and so is one with the fundamental missing")
    func missingFundamental() {
        // The case that separates a pitch tracker from a spectrum peak finder.
        // A voice down a telephone, or through a small speaker, has no energy
        // at its own fundamental and is still unambiguously that note.
        var worst = 0.0
        var failures: [String] = []
        for wanted in scale where wanted >= 110 {
            let measured = track(voice(hertz: wanted, fundamentalGain: 0), sung: true)
            let error = cents(measured, wanted)
            worst = max(worst, error)
            if error > 50 {
                failures.append(String(format: "%.1f Hz → %.1f Hz", wanted, measured))
            }
        }
        print(String(format: "missing fundamental: worst %.1f cents", worst))
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test("noise costs accuracy, and this is how much")
    func withNoise() {
        for level in [0.05, 0.15, 0.3] {
            var worst = 0.0
            for wanted in scale {
                let measured = track(voice(hertz: wanted, noise: level, seed: 7), sung: true)
                worst = max(worst, cents(measured, wanted))
            }
            print(String(format: "noise %.2f: worst %.1f cents", level, worst))
        }
    }

    @Test("vibrato is a note, not a mistake")
    func vibrato() {
        // Fifty cents either way at five hertz is an ordinary trained voice.
        // What is asserted is that the answer lands inside the vibrato rather
        // than outside it — a tracker that reports the extreme is one that will
        // score a good singer as flat.
        var worst = 0.0
        for wanted in scale where wanted >= 130 {
            let measured = track(voice(hertz: wanted, vibratoCents: 50), sung: true)
            worst = max(worst, cents(measured, wanted))
        }
        print(String(format: "vibrato ±50 cents: worst %.1f cents", worst))
        #expect(worst < 60)
    }

    @Test("a slightly inharmonic voice is still that note")
    func inharmonic() {
        var worst = 0.0
        for wanted in scale where wanted >= 110 {
            let measured = track(voice(hertz: wanted, inharmonicity: 0.001), sung: true)
            worst = max(worst, cents(measured, wanted))
        }
        print(String(format: "inharmonic: worst %.1f cents", worst))
        #expect(worst < 40)
    }

    @Test("the ceiling is 400 Hz, and a soprano lives above it")
    func theCeiling() {
        // Not a bug in the estimator — a declared range, chosen for a *speaking*
        // voice: "sixty hertz is below any adult male and four hundred above any
        // adult female". That is true of speech and false of singing. A4 is 440.
        // Most of the female pop repertoire sits above this line, and no
        // improvement to the estimator — neural or otherwise — can reach a note
        // the search never looks for.
        var spoken: [String] = []
        var worstSung = 0.0
        for wanted in aboveTheCeiling {
            let byTheSpeakingRange = track(voice(hertz: wanted))
            spoken.append(
                String(
                    format: "%.0f→%.0f (%.0f¢)", wanted, byTheSpeakingRange,
                    cents(byTheSpeakingRange, wanted)))
            let bySinging = track(voice(hertz: wanted), sung: true)
            worstSung = max(worstSung, cents(bySinging, wanted))
        }
        print("speaking range above 400 Hz: " + spoken.joined(separator: ", "))
        print(String(format: "singing range above 400 Hz: worst %.1f cents", worstSung))
        // The speaking range is still the speaking range, and still wrong up
        // here — deliberately, because widening it invites octave errors in the
        // path that only ever hears talking.
        #expect(PitchTracker.highestHertz == 400)
        // And the singing range gets it right, which is the whole point.
        #expect(worstSung < 25)
    }

    @Test("silence is silence rather than a guess")
    func silence() {
        #expect(track([Float](repeating: 0, count: 9600)) == 0)
    }
}
