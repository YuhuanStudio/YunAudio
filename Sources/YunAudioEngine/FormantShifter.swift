import Accelerate
import Foundation

/// Moves the resonances of a voice without moving its pitch.
///
/// This is the half of a voice changer that nobody ships and everybody misses.
/// Pitch shifting alone moves the whole spectrum — the fundamental *and* the
/// resonances of the throat and mouth that sit on top of it — and the ear reads
/// a shifted-up spectrum as a smaller head rather than a different person. That
/// is why a pitch shifter makes a chipmunk: the formants went with it.
///
/// The two are independent in a real voice. A tall man and a small woman can
/// sing the same note; what differs is where their formants sit. Shifting
/// formants alone changes who is talking while leaving the tune where it was,
/// and combining that with the pitch stage is what a convincing voice change
/// actually is.
///
/// The method is the standard one: estimate the spectral envelope by keeping
/// only the slowly-varying part of the log spectrum, stretch that envelope
/// along the frequency axis, and divide it back in. The excitation — the
/// harmonics, which carry the pitch — is untouched, which is exactly the
/// separation the effect needs.
public final class FormantShifter {

    /// Power of two. 1024 at 48 kHz is 21 ms of window, which is long enough to
    /// resolve a male fundamental and short enough that a moving vowel does not
    /// smear across the transition.
    public static let windowSize = 1024
    private static let log2n = vDSP_Length(10)
    /// Quarter-window hop. Smaller callbacks are gathered across calls rather
    /// than increasing the transform rate: callback geometry must not change
    /// either the sound or the cost of processing one second of audio.
    public static let hop = windowSize / 4

    /// How many cepstral coefficients count as "envelope".
    ///
    /// Low quefrency is the vocal tract, high quefrency is the pitch. Thirty
    /// bins at this window puts the boundary around 700 Hz of spectral
    /// detail — above every formant bandwidth and below every fundamental, so
    /// the two separate cleanly. Too few and the envelope misses a formant;
    /// too many and it starts tracking the harmonics, at which point shifting
    /// it shifts the pitch too and the whole point is lost.
    private static let cepstralDepth = 30

    /// Latency the shifter introduces, in frames. One window: nothing can come
    /// out until a whole window has gone in.
    public var latencyFrames: Int { Self.windowSize }

    /// Formant ratio. 1 is unchanged; above 1 moves the resonances up, which
    /// reads as a smaller speaker.
    public var ratio: Float = 1

    private let setup: FFTSetup
    private let window: [Float]
    /// Normalisation for the overlap-added Hann windows, applied twice.
    private let overlapScale: Float

    private var input: [Float]
    private var output: [Float]
    /// The IO callback is allowed to deliver fewer than one processing hop.
    ///
    /// One ready hop is kept in front of the gather. Besides making arbitrary
    /// callback boundaries safe, that final quarter-window makes the actual
    /// algorithmic delay agree with `latencyFrames`: overlap-add itself emits a
    /// frame three hops behind the input and this queue supplies the fourth.
    private var pendingInput: [Float]
    private var readyOutput: [Float]
    private var pendingFrames = 0

    private var real: [Float]
    private var imaginary: [Float]
    private var frame: [Float]
    private var magnitudes: [Float]
    private var logMagnitude: [Float]
    private var cepstrumReal: [Float]
    private var cepstrumImaginary: [Float]
    private var envelope: [Float]
    private var warped: [Float]
    private var symmetric: [Float]

    public init?() {
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.setup = setup
        window = vDSP.window(
            ofType: Float.self, usingSequence: .hanningDenormalized,
            count: Self.windowSize, isHalfWindow: false)

        // Two factors, and both were wrong at first because nothing exercised
        // them: the identity case returns before the transform, so the only
        // test that existed proved the bypass worked.
        //
        // A Hann window applied on the way in and again on the way out sums to
        // Σ w²[n − mH] = (3/8)(N/H) = 1.5 at a quarter-window hop. A
        // forward-then-inverse pass of `vDSP_fft_zrip` also scales by 2N, so
        // reconstruction divides by both.
        overlapScale = 1 / (1.5 * 2 * Float(Self.windowSize))

        let half = Self.windowSize / 2
        input = [Float](repeating: 0, count: Self.windowSize)
        output = [Float](repeating: 0, count: Self.windowSize)
        pendingInput = [Float](repeating: 0, count: Self.hop)
        readyOutput = [Float](repeating: 0, count: Self.hop)
        real = [Float](repeating: 0, count: half)
        imaginary = [Float](repeating: 0, count: half)
        frame = [Float](repeating: 0, count: Self.windowSize)
        magnitudes = [Float](repeating: 0, count: half)
        logMagnitude = [Float](repeating: 0, count: Self.windowSize)
        cepstrumReal = [Float](repeating: 0, count: half)
        cepstrumImaginary = [Float](repeating: 0, count: half)
        envelope = [Float](repeating: 0, count: half)
        warped = [Float](repeating: 0, count: half)
        symmetric = [Float](repeating: 0, count: Self.windowSize)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public func reset() {
        for index in input.indices { input[index] = 0 }
        for index in output.indices { output[index] = 0 }
        for index in pendingInput.indices { pendingInput[index] = 0 }
        for index in readyOutput.indices { readyOutput[index] = 0 }
        pendingFrames = 0
    }

    /// Processes in place, retaining incomplete hops across calls.
    ///
    /// - Parameters:
    ///   - samples: The block to rewrite.
    ///   - count: Frames to process. It need not be a multiple of `hop`.
    public func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var offset = 0
        while offset < count {
            let frames = min(Self.hop - pendingFrames, count - offset)
            pendingInput.withUnsafeMutableBufferPointer { pending in
                readyOutput.withUnsafeBufferPointer { ready in
                    (pending.baseAddress! + pendingFrames).update(
                        from: samples + offset, count: frames)
                    (samples + offset).update(
                        from: ready.baseAddress! + pendingFrames, count: frames)
                }
            }
            pendingFrames += frames
            offset += frames

            if pendingFrames == Self.hop {
                pendingInput.withUnsafeMutableBufferPointer {
                    processHop($0.baseAddress!)
                }
                readyOutput.withUnsafeMutableBufferPointer { ready in
                    pendingInput.withUnsafeBufferPointer { pending in
                        ready.baseAddress!.update(
                            from: pending.baseAddress!, count: Self.hop)
                    }
                }
                pendingFrames = 0
            }
        }
    }

    private func processHop(_ samples: UnsafeMutablePointer<Float>) {
        let size = Self.windowSize
        let hop = Self.hop

        // Slide the analysis window along and take the new hop.
        input.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            // This is a realtime stage. Array remove/append leaves its storage
            // and copy-on-write decisions to the standard library; this makes
            // the fixed O(window) slide explicit. The overlap is intentional,
            // so `memmove` rather than `memcpy` carries the retained samples.
            memmove(
                base, base + hop,
                (size - hop) * MemoryLayout<Float>.stride)
            (base + size - hop).update(from: samples, count: hop)
        }

        // Identity is a real setting, not a special case: somebody switching the
        // stage on before deciding what to do with it should hear the latency
        // and nothing else. Skipping the transform for it also keeps the cost
        // honest — an effect at zero has no business spending an FFT.
        if abs(ratio - 1) < 0.001 {
            // Still delayed by a window, so switching the ratio around does
            // not jump the signal in time. Overlap-add supplies three hops of
            // delay and the ready-output queue supplies the fourth.
            for index in 0..<hop { samples[index] = input[index] }
            return
        }

        input.withUnsafeBufferPointer { inputBuffer in
            window.withUnsafeBufferPointer { windowBuffer in
                frame.withUnsafeMutableBufferPointer { frameBuffer in
                    vDSP_vmul(
                        inputBuffer.baseAddress!, 1,
                        windowBuffer.baseAddress!, 1,
                        frameBuffer.baseAddress!, 1,
                        vDSP_Length(size))
                }
            }
        }

        let half = size / 2
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(
                        raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1,
                        vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))

                shapeSpectrum(&split, half: half)

                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_INVERSE))
                frame.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(
                        &split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                        vDSP_Length(half))
                }
            }
        }

        // Window again and overlap-add.
        frame.withUnsafeMutableBufferPointer { frameBuffer in
            window.withUnsafeBufferPointer { windowBuffer in
                vDSP_vmul(
                    frameBuffer.baseAddress!, 1,
                    windowBuffer.baseAddress!, 1,
                    frameBuffer.baseAddress!, 1,
                    vDSP_Length(size))
            }
        }
        var scale = overlapScale
        frame.withUnsafeMutableBufferPointer { frameBuffer in
            vDSP_vsmul(
                frameBuffer.baseAddress!, 1, &scale,
                frameBuffer.baseAddress!, 1, vDSP_Length(size))
        }

        for index in 0..<(size - hop) { output[index] += frame[index] }
        for index in (size - hop)..<size { output[index] = frame[index] }

        for index in 0..<hop { samples[index] = output[index] }
        output.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            memmove(
                base, base + hop,
                (size - hop) * MemoryLayout<Float>.stride)
            (base + size - hop).update(repeating: 0, count: hop)
        }
    }

    /// Replaces the spectral envelope with a stretched copy of itself.
    private func shapeSpectrum(_ split: inout DSPSplitComplex, half: Int) {
        // Magnitudes. Bin 0 packs DC and Nyquist together in this form and is
        // left out of the envelope entirely — it is not a frequency.
        magnitudes.withUnsafeMutableBufferPointer { output in
            vDSP_zvabs(&split, 1, output.baseAddress!, 1, vDSP_Length(half))
        }

        // Log spectrum, floored so silence does not become minus infinity and
        // take the cepstrum with it.
        let floorValue: Float = 1e-7
        for index in 0..<half {
            logMagnitude[index] = log(max(magnitudes[index], floorValue))
        }

        // The real cepstrum: an inverse transform of the log spectrum. Its low
        // end is the vocal tract and its high end is the pitch, which is the
        // separation this whole effect rests on.
        //
        // The log spectrum is real and even, so it is transformed as a real
        // signal of length `half` — mirrored into the second half first, which
        // is what makes the result real rather than complex.
        for index in 0..<half {
            symmetric[index] = logMagnitude[index]
            symmetric[Self.windowSize - 1 - index] = logMagnitude[index]
        }

        cepstrumReal.withUnsafeMutableBufferPointer { realBuffer in
            cepstrumImaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var cepstrum = DSPSplitComplex(
                    realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                symmetric.withUnsafeBytes { raw in
                    vDSP_ctoz(
                        raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &cepstrum, 1,
                        vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &cepstrum, 1, Self.log2n, FFTDirection(FFT_FORWARD))

                // Lifter: everything above the vocal tract's quefrency goes.
                for index in Self.cepstralDepth..<half {
                    realBuffer[index] = 0
                    imaginaryBuffer[index] = 0
                }

                vDSP_fft_zrip(setup, &cepstrum, 1, Self.log2n, FFTDirection(FFT_INVERSE))
                symmetric.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(
                        &cepstrum, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                        vDSP_Length(half))
                }
            }
        }

        // Same 2N from the cepstral round trip. Getting this one wrong is
        // quieter and worse: the envelope comes back doubled in the log domain,
        // so every correction is applied at twice the decibels asked for and
        // the effect is violent at settings that should be subtle.
        let unscale = 1 / (2 * Float(Self.windowSize))
        for index in 0..<half {
            envelope[index] = symmetric[index] * unscale
        }

        // Stretch the envelope along frequency. Reading at k/ratio moves a
        // resonance at k to k×ratio, which is the direction anybody expects
        // from a control labelled "higher".
        for index in 0..<half {
            let source = Float(index) / ratio
            let low = Int(source)
            if low >= half - 1 {
                // Past the top there is nothing to read, so the envelope is
                // held rather than wrapped — wrapping would fold the bottom of
                // the spectrum onto the top and sound like a fault.
                warped[index] = envelope[half - 1]
            } else {
                let fraction = source - Float(low)
                warped[index] = envelope[low] * (1 - fraction) + envelope[low + 1] * fraction
            }
        }

        // Divide the old envelope out and the new one in. Both are logs, so the
        // correction is a subtraction there and an exponent here.
        for index in 1..<half {
            // Bins with nothing in them are left alone.
            //
            // Above the highest harmonic there is no signal, only numerical
            // floor — and warping reads the envelope from a lower bin that does
            // have content, so the correction there is a large boost applied to
            // noise. On a synthetic vowel that lit up three kilohertz of empty
            // spectrum; on a real voice it is a hiss that arrives with the
            // effect and gets blamed on it.
            guard magnitudes[index] > floorValue * 10 else { continue }

            let gain = exp(warped[index] - envelope[index])
            // Bounded either way: a bin where the envelope estimate sits far
            // below the actual magnitude would otherwise produce enormous gain
            // and a click. Twelve decibels is more than any real formant move
            // needs.
            let limited = min(max(gain, 0.25), 4)
            split.realp[index] *= limited
            split.imagp[index] *= limited
        }
    }
}
