import Accelerate
import Foundation

/// A short-time spectrum of the signal, in bands a person can read.
///
/// The point is not decoration. A meter says how loud; a spectrum says *what* —
/// a hum at 60 Hz, a desk thump under 100, sibilance piled up at 7 kHz, a room
/// resonance. Those are the problems people actually have with a microphone,
/// and none of them are visible on a level meter. The bands are logarithmic
/// because hearing is: a linear FFT spends half its bins above 12 kHz, where
/// almost nothing about a voice happens.
///
/// A class rather than a struct because it owns an `FFTSetup`, which is a
/// manually managed allocation — a struct would copy the handle and the second
/// copy to be released would free it twice.
public final class SpectrumAnalyser {

    /// Power of two. 2048 at 48 kHz is 23 Hz per bin and 43 ms of window —
    /// enough resolution to separate mains hum from its harmonics, short enough
    /// that the display still tracks speech.
    public static let windowSize = 2048
    private static let log2n = vDSP_Length(11)

    /// Magnitude per band, 0...1 after the same decibel mapping the meters use.
    public private(set) var bands: [Float]

    /// A real-input FFT, not a complex one.
    ///
    /// This distinction is the whole reason the C interface is used here rather
    /// than `vDSP.FFT`. `vDSP_fft_zrip` treats the split-complex buffers as the
    /// packed form of `windowSize` *real* samples, so each half is
    /// `windowSize / 2` long. The Swift `vDSP.FFT<DSPSplitComplex>` built with
    /// the same `log2n` is complex-to-complex and expects both halves to be
    /// `windowSize` long — handing it the packed buffers reads and writes twice
    /// past the end of each, which is a heap overflow on every frame that
    /// produces a perfectly plausible-looking spectrum while it does it.
    private let setup: FFTSetup
    private let sampleRate: Double
    /// Hann, applied before the transform. Without it the ends of the window are
    /// a discontinuity, and a discontinuity is broadband — every band would read
    /// a noise floor that is not in the signal.
    private let window: [Float]
    /// First and last bin of each band, precomputed: the mapping depends only on
    /// the sample rate, and recomputing 24 logarithms per frame for a display
    /// that changes 20 times a second is work for nothing.
    private let bandRanges: [(start: Int, end: Int)]

    private var pending: [Float] = []
    private var real: [Float]
    private var imaginary: [Float]
    private var windowed: [Float]
    private var magnitudes: [Float]

    /// Bands are third-octave-ish across the range that matters for voice and
    /// music. Twenty-four is what fits legibly in a panel this wide.
    public static let bandCount = 24
    public static let lowestFrequency: Double = 40
    public static let highestFrequency: Double = 16000

    public init?(sampleRate: Double) {
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.setup = setup
        self.sampleRate = sampleRate

        window = vDSP.window(
            ofType: Float.self, usingSequence: .hanningDenormalized,
            count: Self.windowSize, isHalfWindow: false)

        let half = Self.windowSize / 2
        real = [Float](repeating: 0, count: half)
        imaginary = [Float](repeating: 0, count: half)
        windowed = [Float](repeating: 0, count: Self.windowSize)
        magnitudes = [Float](repeating: 0, count: half)
        bands = [Float](repeating: 0, count: Self.bandCount)
        pending.reserveCapacity(Self.windowSize)

        let binWidth = sampleRate / Double(Self.windowSize)
        let ratio = Self.highestFrequency / Self.lowestFrequency
        var ranges: [(Int, Int)] = []
        ranges.reserveCapacity(Self.bandCount)
        for index in 0..<Self.bandCount {
            let low =
                Self.lowestFrequency
                * pow(ratio, Double(index) / Double(Self.bandCount))
            let high =
                Self.lowestFrequency
                * pow(ratio, Double(index + 1) / Double(Self.bandCount))
            // At the bottom the bands are narrower than one bin, so each takes
            // the bin it lands in rather than an empty range. Bin 0 is skipped:
            // in this packed form it holds DC in the real part and Nyquist in
            // the imaginary one, so its magnitude is not a frequency at all.
            let start = min(half - 1, max(1, Int(low / binWidth)))
            let end = min(half - 1, max(start, Int(high / binWidth)))
            ranges.append((start, end))
        }
        bandRanges = ranges
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Feeds samples. Transforms whenever a whole window has arrived, and keeps
    /// only the most recent one — the display wants what is happening now, not
    /// an average over everything that queued up while it was not looking.
    public func add(_ samples: UnsafePointer<Float>, count: Int) {
        var offset = 0
        while offset < count {
            let take = min(Self.windowSize - pending.count, count - offset)
            pending.append(
                contentsOf: UnsafeBufferPointer(start: samples + offset, count: take))
            offset += take
            if pending.count == Self.windowSize {
                transform()
                // 50% overlap, so a transient landing at a window boundary is
                // not halved by the window function twice running.
                pending.removeFirst(Self.windowSize / 2)
            }
        }
    }

    private func transform() {
        vDSP.multiply(pending, window, result: &windowed)

        let half = Self.windowSize / 2
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(
                        raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1,
                        vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { output in
                    vDSP_zvabs(&split, 1, output.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // Three factors, none of them optional if the bars are to agree with the
        // meters rather than sit at some arbitrary offset from them:
        //   · `vDSP_fft_zrip` returns twice the true transform,
        //   · a single-sided spectrum needs the other half added back, ×2,
        //   · the Hann window has a coherent gain of 0.5, so ×2 again,
        // over N. Net: 2/N, and a full-scale sine reads 0 dB.
        let scale = 2.0 / Float(Self.windowSize)

        for (index, range) in bandRanges.enumerated() {
            var peak: Float = 0
            for bin in range.start...range.end {
                peak = max(peak, magnitudes[bin])
            }
            let amplitude = peak * scale
            // −72 dB to 0 dB across the display, matching the meters.
            let decibels = amplitude > 0 ? 20 * log10(amplitude) : -120
            let normalised = max(0, min(1, (decibels + 72) / 72))
            // Rise instantly, fall slowly. A spectrum that decayed as fast as it
            // rose would be unreadable strobing.
            bands[index] =
                normalised > bands[index]
                ? normalised
                : bands[index] * 0.82 + normalised * 0.18
        }
    }

    /// The decibel level of a band, which is what the normalised value came
    /// from. Exposed so the calibration can be asserted against a known tone
    /// rather than only its position.
    public func decibels(ofBand index: Int) -> Float {
        guard bands.indices.contains(index) else { return -120 }
        return bands[index] * 72 - 72
    }

    public func reset() {
        pending.removeAll(keepingCapacity: true)
        for index in bands.indices { bands[index] = 0 }
    }

    /// The centre frequency of a band, for labelling.
    public func centreFrequency(ofBand index: Int) -> Double {
        let ratio = Self.highestFrequency / Self.lowestFrequency
        return Self.lowestFrequency
            * pow(ratio, (Double(index) + 0.5) / Double(Self.bandCount))
    }
}
