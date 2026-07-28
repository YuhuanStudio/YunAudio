import Accelerate
import Foundation

/// Finds the fundamental frequency of a voice, one estimate per frame.
///
/// Every serious voice conversion starts here. The pitch shifter in the effect
/// chain is a generic phase vocoder — it moves the whole spectrum by a ratio
/// without ever knowing what note anybody is on, which is fine for a fixed
/// offset and useless for anything that has to land on a target. Knowing the
/// actual fundamental is what lets a voice be moved *to* a range rather than
/// *by* an amount.
///
/// ## Why this is not in MLX
///
/// It was, for an afternoon. Two things sent it back to Accelerate, and both
/// are worth writing down because the pull towards putting anything
/// signal-shaped on the GPU is strong and usually wrong.
///
/// The first is practical: mlx-swift's own README states that SwiftPM on the
/// command line cannot build its Metal shaders, so a package built the way this
/// one is has no GPU backend at all — and MLX does not degrade to the CPU when
/// that happens, it fails to load its default metallib and takes the process
/// with it. Shipping that would mean the application dying the moment somebody
/// spoke.
///
/// The second matters more, because it would still hold with Metal working.
/// This workload is a two-thousand-point transform over a handful of frames,
/// and at that size the launch and synchronisation cost dominates the
/// arithmetic. vDSP is what Apple wrote for exactly this, and it runs on the
/// vector units without leaving the thread. MLX earns its place when there is a
/// trained model to run — thousands of matrix multiplies against weights that
/// live in unified memory — and that is a different feature with a different
/// dependency, not a faster way to do an FFT.
public final class PitchTracker {

    /// Frames the tracker takes at a time. A power of two, and long enough to
    /// hold two periods of the lowest voice it looks for — an autocorrelation
    /// cannot find a period it has not seen twice.
    public static let frameSize = 2048

    /// The range of a human speaking voice, generously.
    ///
    /// Sixty hertz is below any adult male and four hundred above any adult
    /// female. Wider costs candidates and invites octave errors, which are the
    /// failure mode of every autocorrelation pitch tracker ever written.
    public static let lowestHertz: Double = 60
    public static let highestHertz: Double = 400

    /// Below this there is nothing worth calling a pitch, however periodic it
    /// is.
    ///
    /// The correlation threshold below measures periodicity, not level — and a
    /// quiet mains hum or a fan is extremely periodic. A room at −49 dBFS was
    /// reported as a confident 153 Hz, which for a voice converter means
    /// chasing the room between every word. −50 dBFS RMS is well under any
    /// usable speaking level and well over a room's noise floor.
    public static let floorDecibels: Float = -50

    /// The nearest note to a frequency, in scientific pitch notation.
    ///
    /// Equal temperament from A4 = 440. Hertz alone means something to about
    /// one person in fifty; the note beside it means something to anybody who
    /// has touched an instrument, and it is the same number. Rounded to the
    /// nearest semitone rather than showing cents of deviation — this is a
    /// readout for somebody choosing a voice, not a tuner.
    public static func noteName(_ hertz: Float) -> String? {
        guard hertz > 20, hertz < 5000 else { return nil }
        let names = [
            "C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B",
        ]
        let semitones = 12 * log2(Double(hertz) / 440) + 69
        let rounded = Int(semitones.rounded())
        guard rounded >= 0 else { return nil }
        return "\(names[rounded % 12])\(rounded / 12 - 1)"
    }

    private let sampleRate: Double
    private let minimumLag: Int
    private let maximumLag: Int
    private let setup: FFTSetup
    /// Twice the frame, so the transform gives the linear autocorrelation
    /// rather than the circular one. Without the padding, energy from the end
    /// of the frame wraps onto the beginning and reads as a spurious short
    /// period.
    private static let transformSize = frameSize * 2
    private static let log2n = vDSP_Length(12)

    private var padded: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var correlation: [Float]

    public init?(sampleRate: Double) {
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.setup = setup
        self.sampleRate = sampleRate
        minimumLag = Int(sampleRate / Self.highestHertz)
        maximumLag = min(Self.frameSize - 1, Int(sampleRate / Self.lowestHertz))

        let half = Self.transformSize / 2
        padded = [Float](repeating: 0, count: Self.transformSize)
        real = [Float](repeating: 0, count: half)
        imaginary = [Float](repeating: 0, count: half)
        correlation = [Float](repeating: 0, count: Self.transformSize)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// One estimate per frame, in hertz. Zero where the frame is unvoiced.
    ///
    /// - Parameters:
    ///   - frames: `count × frameSize`, laid out row by row.
    ///   - count: How many frames are in the buffer.
    /// - Returns: One estimate per frame, zero where unvoiced.
    public func track(frames: [Float], count: Int) -> [Float] {
        guard count > 0, frames.count >= count * Self.frameSize else { return [] }
        return (0..<count).map { index in
            let start = index * Self.frameSize
            return estimate(Array(frames[start..<(start + Self.frameSize)]))
        }
    }

    /// A single frame, for callers that have one.
    public func track(frame: [Float]) -> Float {
        guard frame.count >= Self.frameSize else { return 0 }
        return estimate(Array(frame.prefix(Self.frameSize)))
    }

    private func estimate(_ frame: [Float]) -> Float {
        // The mean comes off first.
        //
        // A constant offset correlates perfectly with itself at every lag, so
        // any of it swamps the periodic part and the search returns whichever
        // candidate it happened to try first — the top of the range. Real
        // microphone signals carry an offset routinely, from converter bias
        // and from anything with a high-pass that has not settled, so this is
        // not a synthetic concern. It went unnoticed until a test fixture
        // turned out to be accidentally offset and the tracker reported 401 Hz
        // for white noise, three frames out of three.
        var mean: Float = 0
        vDSP_meanv(frame, 1, &mean, vDSP_Length(Self.frameSize))
        var negated = -mean
        vDSP_vsadd(frame, 1, &negated, &padded, 1, vDSP_Length(Self.frameSize))
        for index in Self.frameSize..<Self.transformSize { padded[index] = 0 }

        let half = Self.transformSize / 2
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                padded.withUnsafeBytes { raw in
                    vDSP_ctoz(
                        raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1,
                        vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))

                // The power spectrum, in place. Its inverse transform is the
                // autocorrelation — the same identity the spectrum analyser
                // uses in the other direction.
                for index in 0..<half {
                    let power =
                        realBuffer[index] * realBuffer[index]
                        + imaginaryBuffer[index] * imaginaryBuffer[index]
                    realBuffer[index] = power
                    imaginaryBuffer[index] = 0
                }

                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_INVERSE))
                correlation.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(
                        &split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                        vDSP_Length(half))
                }
            }
        }

        // Nothing quiet enough to be the room gets a pitch, however periodic.
        //
        // The zero-lag term is the frame's total energy, which is exactly the
        // measurement needed — no second pass over the samples.
        let energy = correlation[0]
        guard energy > 1e-9 else { return 0 }
        // zrip's forward-inverse pair scales by 2N, so the mean square is the
        // zero-lag term over that and over the frame length.
        let meanSquare = energy / (2 * Float(Self.transformSize) * Float(Self.frameSize))
        guard meanSquare > 0,
            10 * log10(meanSquare) > Self.floorDecibels
        else { return 0 }

        // The shortest lag that scores nearly as well as the best, not the best
        // outright.
        //
        // Twice a period correlates almost as strongly as the period itself, so
        // a plain maximum reports an octave down perhaps half the time. This is
        // the single thing that separates a pitch tracker from a lag-finder,
        // and it is why the tests below check for octaves specifically.
        var best: Float = 0
        for lag in minimumLag...maximumLag {
            best = max(best, correlation[lag] / energy)
        }
        // Below this the frame is noise, breath or silence, and the best lag is
        // whatever the noise happened to favour. Reporting that as a pitch is
        // worse than reporting nothing.
        guard best > 0.35 else { return 0 }

        // The shortest *local maximum* scoring near the best, not the first lag
        // to cross the threshold.
        //
        // A voice has a sharply peaked autocorrelation and the two are the same
        // thing. A pure tone does not: its correlation is a broad cosine, so
        // lags well before the true period already exceed 85% of the maximum
        // and a threshold crossing lands early — a 150 Hz sine came back as
        // 136. A local maximum is the period whichever shape the signal has.
        for lag in (minimumLag + 1)..<maximumLag {
            let previous = correlation[lag - 1]
            let centre = correlation[lag]
            let next = correlation[lag + 1]
            guard centre > previous, centre >= next, centre / energy > best * 0.85 else {
                continue
            }
            // Parabolic interpolation around the peak: the true period is
            // rarely a whole number of samples, and at 48 kHz one sample at
            // 200 Hz is more than a hertz.
            let denominator = previous - 2 * centre + next
            let offset = denominator != 0 ? 0.5 * (previous - next) / denominator : 0
            let refined = Double(lag) + Double(max(-1, min(1, offset)))
            return Float(sampleRate / refined)
        }
        return 0
    }
}
