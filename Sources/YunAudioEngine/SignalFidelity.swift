import Accelerate
import Foundation

/// What a processing chain did to a signal, as numbers.
///
/// Every conditioning feature in this application changes the sound — that is
/// what they are for — and each one is on or off by default on somebody's
/// judgement rather than on a measurement. This is the measurement. Without it,
/// "should this be on by default" is an argument; with it, it is arithmetic
/// against a stated cost.
///
/// ## What is deliberately separated
///
/// **Delay is not damage.** Anything with a filter in it comes out later than
/// it went in. Comparing sample *n* with sample *n* then reports the delay as
/// distortion and buries whatever really happened. The lag is found first, by
/// cross-correlation, reported on its own, and removed before anything else is
/// compared.
///
/// **Gain is not damage either.** A chain that is 3 dB quieter is not 3 dB
/// worse; it is 3 dB quieter, and somebody can turn it up. The broadband gain
/// is reported on its own and removed before the shape is compared, so what is
/// left is the part a volume control cannot undo.
///
/// What remains after those two removals is the honest answer to "what did this
/// cost me", and it is what `residualDecibels` carries.
public enum SignalFidelity {

    /// One comparison of a processed signal against what went in.
    public struct Measurement: Sendable, Equatable {
        /// Samples the output lags the input by, found rather than assumed.
        public let delayFrames: Int
        /// Broadband level change, which a fader can undo.
        public let gainDecibels: Double
        /// What is left once the delay and the gain are taken out, relative to
        /// the reference's own level. This is the number that matters: −60 dB
        /// is inaudible, −20 dB is a different recording.
        public let residualDecibels: Double
        /// How much of the reference survived, after alignment and gain match.
        /// 1 is identical; below about 0.99 something structural happened.
        public let correlation: Double
        /// Level change per octave band, after the broadband gain is removed —
        /// so this is tone, not volume.
        public let bandDecibels: [Band]
        /// Reference and processed peak, so clipping is visible rather than
        /// inferred.
        public let referencePeak: Double
        public let processedPeak: Double
        /// True when the processed signal reached or passed full scale and the
        /// reference did not.
        public var clipped: Bool { processedPeak >= 0.999 && referencePeak < 0.999 }

        public struct Band: Sendable, Equatable {
            public let centreHertz: Double
            public let decibels: Double
        }

        /// One line, for a table.
        public var summary: String {
            String(
                format:
                    "delay %4d fr  gain %+6.2f dB  residual %7.2f dB  r %.5f",
                delayFrames, gainDecibels, residualDecibels, correlation)
        }
    }

    /// Runs a signal through a chain and says what the chain cost.
    ///
    /// The chain is built and driven exactly as the route drives it — the same
    /// callback-sized blocks, the same `render` — because a measurement of a
    /// differently-driven chain is a measurement of something else. Effects
    /// carry state across blocks, and one long call would measure a version of
    /// the effect that never runs.
    ///
    /// - Returns: Nil when the chain refuses to build at this rate, which is a
    ///   different answer from costing nothing.
    public static func cost(
        of kinds: [EffectKind], on source: [Float], sampleRate: Double,
        callbackFrames: Int = 512
    ) -> Measurement? {
        guard let chain = EffectChain(
            kinds: kinds, sampleRate: sampleRate, maximumFrames: callbackFrames)
        else { return nil }
        var processed = [Float](repeating: 0, count: source.count)
        var offset = 0
        while offset < source.count {
            let frames = min(callbackFrames, source.count - offset)
            source.withUnsafeBufferPointer { buffer in
                chain.inputBuffer.update(
                    from: buffer.baseAddress! + offset, count: frames)
            }
            guard chain.render(frames: frames, sampleTime: Float64(offset)) else {
                return nil
            }
            processed.withUnsafeMutableBufferPointer { buffer in
                (buffer.baseAddress! + offset).update(
                    from: chain.outputBuffer, count: frames)
            }
            offset += frames
        }
        return compare(reference: source, processed: processed, sampleRate: sampleRate)
    }

    /// A repeatable signal to measure against.
    ///
    /// Deterministic noise rather than a tone, because a tone only exercises
    /// one band and every conditioning effect here is frequency-dependent. The
    /// seed is fixed so two runs on two machines are comparable, which is the
    /// whole point of having a number.
    public static func fixture(seconds: Double, sampleRate: Double, amplitude: Float = 0.3)
        -> [Float]
    {
        let count = max(0, Int(seconds * sampleRate))
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(Double(state >> 40) / Double(1 << 24)) * 2 - 1
            samples[index] = unit * amplitude
        }
        return samples
    }

    /// Octave centres from 31.5 Hz up, which is the spacing an equaliser is
    /// described in and therefore the spacing somebody can act on.
    public static let bandCentres: [Double] = [
        31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
    ]

    /// How far apart the two may be before the search gives up. Anything past
    /// this is not a filter's group delay, it is a different signal.
    public static let maximumDelayFrames = 8192

    /// Compares a processed signal with the reference it came from.
    ///
    /// - Parameters:
    ///   - reference: What went in.
    ///   - processed: What came out, at the same rate.
    ///   - sampleRate: Both, since a comparison across rates is not one.
    public static func compare(
        reference: [Float], processed: [Float], sampleRate: Double
    ) -> Measurement {
        let usable = min(reference.count, processed.count)
        guard usable > 0, sampleRate > 0 else {
            return Measurement(
                delayFrames: 0, gainDecibels: 0, residualDecibels: 0,
                correlation: 0, bandDecibels: [], referencePeak: 0, processedPeak: 0)
        }

        let delay = bestDelay(reference: reference, processed: processed)
        // Compare only where both exist after shifting.
        let count = min(reference.count - 0, processed.count - delay)
        guard count > 16 else {
            return Measurement(
                delayFrames: delay, gainDecibels: 0, residualDecibels: 0,
                correlation: 0, bandDecibels: [],
                referencePeak: Double(peak(reference)),
                processedPeak: Double(peak(processed)))
        }
        let a = Array(reference[0..<count])
        let b = Array(processed[delay..<(delay + count)])

        let referenceRMS = rms(a)
        let processedRMS = rms(b)
        let gain = referenceRMS > 0 ? Double(processedRMS / referenceRMS) : 0
        let gainDecibels = gain > 0 ? 20 * log10(gain) : -.infinity

        // Undo the level so what is left is shape rather than volume.
        var matched = b
        if gain > 0 {
            var inverse = Float(1 / gain)
            vDSP_vsmul(b, 1, &inverse, &matched, 1, vDSP_Length(count))
        }

        var residual = [Float](repeating: 0, count: count)
        vDSP_vsub(a, 1, matched, 1, &residual, 1, vDSP_Length(count))
        let residualRMS = rms(residual)
        let residualDecibels =
            referenceRMS > 0 && residualRMS > 0
            ? 20 * log10(Double(residualRMS / referenceRMS))
            : -.infinity

        return Measurement(
            delayFrames: delay,
            gainDecibels: gainDecibels,
            residualDecibels: residualDecibels,
            correlation: pearson(a, matched),
            bandDecibels: bands(
                reference: a, processed: matched, sampleRate: sampleRate),
            referencePeak: Double(peak(reference)),
            processedPeak: Double(peak(processed)))
    }

    /// The lag that lines the two up best, by normalised cross-correlation over
    /// a bounded search.
    static func bestDelay(reference: [Float], processed: [Float]) -> Int {
        let window = min(reference.count, 1 << 14)
        guard window > 64 else { return 0 }
        let limit = min(maximumDelayFrames, processed.count - window)
        guard limit > 0 else { return 0 }
        let a = Array(reference[0..<window])
        var best = 0
        var bestScore = -Double.infinity
        for lag in 0...limit {
            let b = Array(processed[lag..<(lag + window)])
            var dot: Float = 0
            vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(window))
            let score = Double(dot) / max(1e-12, Double(rms(b)))
            if score > bestScore {
                bestScore = score
                best = lag
            }
        }
        return best
    }

    /// Per-octave level difference, after the broadband gain is already out.
    static func bands(
        reference: [Float], processed: [Float], sampleRate: Double
    ) -> [Measurement.Band] {
        let size = 4096
        guard reference.count >= size else { return [] }
        let referenceSpectrum = averageSpectrum(reference, size: size)
        let processedSpectrum = averageSpectrum(processed, size: size)
        guard !referenceSpectrum.isEmpty, referenceSpectrum.count == processedSpectrum.count
        else { return [] }
        let binHertz = sampleRate / Double(size)
        return bandCentres.compactMap { centre -> Measurement.Band? in
            // One octave wide, which is how an equaliser is described.
            let low = centre / sqrt(2)
            let high = centre * sqrt(2)
            guard high < sampleRate / 2 else { return nil }
            let first = max(1, Int(low / binHertz))
            let last = min(referenceSpectrum.count - 1, Int(high / binHertz))
            guard last >= first else { return nil }
            var referenceEnergy = 0.0
            var processedEnergy = 0.0
            for bin in first...last {
                referenceEnergy += Double(referenceSpectrum[bin])
                processedEnergy += Double(processedSpectrum[bin])
            }
            guard referenceEnergy > 0 else { return nil }
            let ratio = processedEnergy / referenceEnergy
            return Measurement.Band(
                centreHertz: centre,
                decibels: ratio > 0 ? 10 * log10(ratio) : -120)
        }
    }

    /// Power spectrum averaged over Hann-windowed halves-overlapping blocks.
    private static func averageSpectrum(_ samples: [Float], size: Int) -> [Float] {
        let log2n = vDSP_Length(log2(Double(size)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))

        let half = size / 2
        var total = [Float](repeating: 0, count: half)
        var blocks = 0
        var offset = 0
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        while offset + size <= samples.count {
            var block = [Float](repeating: 0, count: size)
            vDSP_vmul(
                Array(samples[offset..<(offset + size)]), 1, window, 1, &block, 1,
                vDSP_Length(size))
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(
                        realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    block.withUnsafeBufferPointer { blockBuffer in
                        blockBuffer.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: half
                        ) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }
            vDSP_vadd(total, 1, magnitudes, 1, &total, 1, vDSP_Length(half))
            blocks += 1
            offset += half
        }
        guard blocks > 0 else { return [] }
        var scale = Float(1) / Float(blocks)
        vDSP_vsmul(total, 1, &scale, &total, 1, vDSP_Length(half))
        return total
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }

    static func peak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_maxmgv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }

    static func pearson(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 1 else { return 0 }
        var meanA: Float = 0
        var meanB: Float = 0
        vDSP_meanv(a, 1, &meanA, vDSP_Length(count))
        vDSP_meanv(b, 1, &meanB, vDSP_Length(count))
        var centredA = [Float](repeating: 0, count: count)
        var centredB = [Float](repeating: 0, count: count)
        var negativeA = -meanA
        var negativeB = -meanB
        vDSP_vsadd(a, 1, &negativeA, &centredA, 1, vDSP_Length(count))
        vDSP_vsadd(b, 1, &negativeB, &centredB, 1, vDSP_Length(count))
        var dot: Float = 0
        vDSP_dotpr(centredA, 1, centredB, 1, &dot, vDSP_Length(count))
        let normA = rms(centredA) * sqrtf(Float(count))
        let normB = rms(centredB) * sqrtf(Float(count))
        guard normA > 0, normB > 0 else { return 0 }
        return Double(dot / (normA * normB))
    }
}
