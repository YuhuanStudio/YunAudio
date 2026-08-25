import Foundation
import Testing

@testable import YunAudioEngine

/// "Not bit-exact" is true of a path nobody could hear a fault in and of one
/// that has been ruined, and until now it was all the integrity check could
/// say. These fix what the extra numbers mean.
@Suite("How far off, not only whether")
struct IntegrityMagnitudeTests {

    /// Builds a capture as if the loopback returned `transform` of the
    /// generated sequence, delayed by `delay` frames.
    private func capture(
        frames: Int, startFrame: UInt64 = 8_192, delay: Int,
        _ transform: (Float, Int) -> Float
    ) -> SelftestCapture {
        var samples = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            let absolute = startFrame &+ UInt64(index)
            guard absolute >= UInt64(delay) else { continue }
            samples[index] = transform(selftestSample(absolute &- UInt64(delay)), index)
        }
        return SelftestCapture(startFrame: startFrame, samples: samples)
    }

    /// A path that returns exactly what it was given says nothing further, and
    /// computing an octave analysis to report six zeroes is work done for a
    /// sentence nobody needs.
    @Test("a bit-exact path carries no magnitude")
    func bitExactCarriesNothing() {
        let result = capture(frames: 32_768, delay: 512) { sample, _ in sample }
            .evaluate()
        #expect(result.isBitExact)
        #expect(result.fidelity == nil)
    }

    /// Half a decibel down and otherwise untouched. The old summary called this
    /// "0.00% identical" — the same words it uses for a path carrying a
    /// different recording.
    @Test("a path that is only quieter is named as only quieter")
    func pureGainIsNamedAsGain() throws {
        let result = capture(frames: 65_536, delay: 300) { sample, _ in sample * 0.5 }
            .evaluate()
        #expect(!result.isBitExact)
        let fidelity = try #require(result.fidelity)
        #expect(abs(fidelity.gainDecibels - -6.02) < 0.1)
        // Once the gain is taken out there is nothing left, which is the claim.
        #expect(fidelity.residualDecibels < -100)
        #expect(fidelity.correlation > 0.9999)
        print("gain-only path: \(result.summary)")
    }

    /// A hundredth of the signal added as noise. Audible, and it has to read as
    /// worse than the gain case by a wide margin rather than by a hair.
    @Test("added noise reads as a residual, not as a gain")
    func noiseReadsAsResidual() throws {
        var generator = SystemRandomNumberGenerator()
        let result = capture(frames: 65_536, delay: 128) { sample, _ in
            sample + Float.random(in: -0.01...0.01, using: &generator)
        }.evaluate()
        let fidelity = try #require(result.fidelity)
        #expect(abs(fidelity.gainDecibels) < 0.5)
        #expect(fidelity.residualDecibels > -45)
        #expect(fidelity.residualDecibels < -20)
        print("noisy path: \(result.summary)")
    }

    /// The lesson that cost an afternoon, encoded: the probe is white noise and
    /// fills its own Nyquist, so any resampler *must* take the top of the band
    /// off. A broadband residual alone reads that as damage. The band beside it
    /// says where it went, and on a sane filter that is the highest octave and
    /// nothing else.
    @Test("a top-octave roll-off is named as the top octave")
    func rollOffIsNamedByBand() throws {
        // A one-pole low pass, which is what an anti-alias filter looks like
        // from the outside: flat low down, falling at the top.
        var state: Float = 0
        let result = capture(frames: 65_536, delay: 64) { sample, _ in
            state += 0.7 * (sample - state)
            return state
        }.evaluate(sampleRate: 48_000)
        let fidelity = try #require(result.fidelity)
        // Against the middle of the voice range, which is how the summary reads
        // them and the only way a cut reads as a cut — the raw band values have
        // the broadband gain removed, and a low pass lowers that gain, so every
        // untouched band comes out lifted.
        let middle = try #require(
            fidelity.bandDecibels.min {
                abs($0.centreHertz - 1_000) < abs($1.centreHertz - 1_000)
            })
        let worst = try #require(
            fidelity.bandDecibels.max {
                abs($0.decibels - middle.decibels) < abs($1.decibels - middle.decibels)
            })
        #expect(worst.centreHertz >= 8_000, "worst octave was \(worst.centreHertz) Hz")
        #expect(
            worst.decibels < middle.decibels, "a low pass should cut, not lift")
        print("rolled-off path: \(result.summary)")
    }

    /// And a capture that never lined up must not produce numbers at all: the
    /// residual against a signal that is not there is a measurement of nothing.
    @Test("a path that carried nothing reports no magnitude")
    func silenceCarriesNothing() {
        let result = capture(frames: 32_768, delay: 0) { _, _ in 0 }.evaluate()
        #expect(!result.didAlign)
        #expect(result.fidelity == nil)
    }
}
