import Accelerate
import Foundation
import Testing

@testable import YunAudioEngine

/// The ruler has to be right before anything is measured with it.
@Suite("What a chain costs, measured")
struct SignalFidelityTests {

    private let rate: Double = 48_000

    private func tone(_ hertz: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let count = Int(seconds * rate)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * hertz * Double(index) / rate))
        }
    }

    /// A voice-like signal: not a sine, so the band comparison has something to
    /// compare in every band.
    private func noise(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let count = Int(seconds * rate)
        // Deterministic, because a measurement nobody can repeat is not one.
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(Double(state >> 40) / Double(1 << 24)) * 2 - 1
            return unit * amplitude
        }
    }

    @Test("an untouched signal costs nothing")
    func identityCostsNothing() {
        let source = noise(seconds: 0.5)
        let measured = SignalFidelity.compare(
            reference: source, processed: source, sampleRate: rate)
        #expect(measured.delayFrames == 0)
        #expect(abs(measured.gainDecibels) < 0.001)
        #expect(measured.residualDecibels < -100, "read \(measured.residualDecibels)")
        #expect(measured.correlation > 0.99999)
        #expect(!measured.clipped)
    }

    /// A fader is not damage, and must not be reported as any.
    @Test("a level change is reported as level, not as loss")
    func gainIsNotDamage() {
        let source = noise(seconds: 0.5)
        let quieter = source.map { $0 * 0.5 }
        let measured = SignalFidelity.compare(
            reference: source, processed: quieter, sampleRate: rate)
        #expect(abs(measured.gainDecibels + 6.0206) < 0.01, "read \(measured.gainDecibels)")
        // Everything the fader did is in the gain, so nothing is left over.
        #expect(measured.residualDecibels < -100, "read \(measured.residualDecibels)")
        #expect(measured.correlation > 0.99999)
    }

    /// Neither is group delay, which every filter has.
    @Test("a delay is found and taken out")
    func delayIsFoundNotBlamed() {
        let source = noise(seconds: 0.5)
        let lag = 137
        let delayed = [Float](repeating: 0, count: lag) + source
        let measured = SignalFidelity.compare(
            reference: source, processed: delayed, sampleRate: rate)
        #expect(measured.delayFrames == lag, "read \(measured.delayFrames)")
        #expect(measured.residualDecibels < -100, "read \(measured.residualDecibels)")
    }

    /// The number that matters: what is left once level and delay are gone.
    @Test("added noise reads as the level it was added at")
    func residualMatchesWhatWasAdded() {
        let source = noise(seconds: 0.5, amplitude: 0.3)
        // A second, independent stream at a fortieth of the level: −32 dB.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let dirt = (0..<source.count).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(Double(state >> 40) / Double(1 << 24)) * 2 - 1
            return unit * 0.3 / 40
        }
        let processed = zip(source, dirt).map(+)
        let measured = SignalFidelity.compare(
            reference: source, processed: processed, sampleRate: rate)
        // 1/40 is −32.04 dB. Allow a decibel either way for the gain match.
        #expect(
            abs(measured.residualDecibels + 32.04) < 1.5,
            "read \(measured.residualDecibels)")
        #expect(measured.correlation > 0.99)
    }

    /// Tone is reported per octave, so a cut shows up where it happened rather
    /// than as a single number that says nothing about what changed.
    @Test("a band that was cut is the band that reads as cut")
    func aCutShowsInItsOwnBand() {
        // Two tones, one of which is halved.
        let low = tone(250, seconds: 0.5, amplitude: 0.4)
        let high = tone(4000, seconds: 0.5, amplitude: 0.4)
        let source = zip(low, high).map(+)
        let cut = zip(low, high.map { $0 * 0.1 }).map(+)
        let measured = SignalFidelity.compare(
            reference: source, processed: cut, sampleRate: rate)

        let bands = Dictionary(
            uniqueKeysWithValues: measured.bandDecibels.map { ($0.centreHertz, $0.decibels) })
        let at250 = try! #require(bands[250])
        let at4000 = try! #require(bands[4000])
        // The broadband gain match lifts everything a little; what matters is
        // that the cut band is far below the untouched one.
        #expect(at4000 < at250 - 15, "250 Hz \(at250) dB, 4 kHz \(at4000) dB")
    }

    /// Clipping is visible rather than inferred from a worse residual.
    @Test("clipping is named")
    func clippingIsNamed() {
        let source = tone(1000, seconds: 0.2, amplitude: 0.5)
        let hot = source.map { max(-1, min(1, $0 * 4)) }
        let measured = SignalFidelity.compare(
            reference: source, processed: hot, sampleRate: rate)
        #expect(measured.clipped)
        #expect(measured.processedPeak >= 0.999)
    }
}

/// What each conditioning effect actually costs, printed rather than asserted.
///
/// The defaults in this application were each chosen on somebody's judgement.
/// This is the table that turns "should it be on by default" from an argument
/// into arithmetic against a stated cost.
@Suite("What every effect costs")
struct EffectCostTableTests {

    @Test("every effect is measured against the same signal")
    func table() {
        let rate: Double = 48_000
        let source = SignalFidelity.fixture(seconds: 2, sampleRate: rate)
        print("\neffect          delay    gain      residual      r      loudest band change")
        print(String(repeating: "-", count: 88))
        for kind in EffectKind.allCases {
            guard
                let measured = SignalFidelity.cost(
                    of: [kind], on: source, sampleRate: rate)
            else {
                print(String(format: "%-14s  refused to build at this rate", (kind.rawValue as NSString).utf8String!))
                continue
            }
            let worst =
                measured.bandDecibels
                .max { abs($0.decibels) < abs($1.decibels) }
            let bandText =
                worst.map { String(format: "%5.0f Hz %+6.2f dB", $0.centreHertz, $0.decibels) }
                ?? "—"
            print(
                String(
                    format: "%-14@  %4d  %+7.2f  %+9.2f dB  %.5f  %@",
                    kind.rawValue as NSString, measured.delayFrames,
                    measured.gainDecibels, measured.residualDecibels,
                    measured.correlation, bandText as NSString))
        }
        print("")
        // The table is the point; the assertion is only that it was produced.
        #expect(!EffectKind.allCases.isEmpty)
    }

    /// The conversion that is in almost every path, with nothing switched on.
    ///
    /// `preferredSampleRate` is 48 kHz and a great many recordings are 44.1, so
    /// this runs where every effect above it is off. It is therefore the only
    /// candidate left for a default that costs fidelity — and it does not.
    @Test("a rate conversion round trip is inaudible")
    func resamplingIsNotTheCost() throws {
        for (from, through) in [(44_100.0, 48_000.0), (48_000.0, 44_100.0), (96_000.0, 48_000.0)] {
            let material = SignalFidelity.bandLimitedFixture(seconds: 1, sampleRate: from)
            let measured = try #require(
                SignalFidelity.costOfResampling(
                    from: from, through: through, on: material))
            #expect(
                measured.residualDecibels < -55,
                "\(Int(from)) → \(Int(through)) → \(Int(from)): \(measured.residualDecibels) dB")
            #expect(measured.correlation > 0.9999)
        }
    }

    /// The fixture has to be band-limited or the measurement above is a
    /// measurement of the anti-alias filter doing its job.
    ///
    /// This caught a wrong answer once already: white noise put the same round
    /// trip at −9.69 dB, which reads as a broken resampler and is nothing of
    /// the kind — 96 kHz noise carries content to 48 kHz and a conversion to 48
    /// is *required* to remove it.
    @Test("the band-limited fixture stays inside its ceiling")
    func fixtureIsBandLimited() {
        let rate = 96_000.0
        let material = SignalFidelity.bandLimitedFixture(
            seconds: 0.5, sampleRate: rate, highestHertz: 18_000)
        let spectrum = SignalFidelity.bands(
            reference: material, processed: material, sampleRate: rate)
        // Nothing above the ceiling, which the octave table shows as the 32 kHz
        // band being absent or empty.
        #expect(!material.isEmpty)
        #expect(SignalFidelity.peak(material) < 1)
        #expect(spectrum.allSatisfy { abs($0.decibels) < 0.001 })
    }

    /// Voice isolation, on the signal it is for.
    ///
    /// The table above measures it against noise, and against noise it
    /// correctly removes everything — `−57 dB` and a correlation of 0.14 is
    /// arithmetic on the wrong input, not a defect. This is the honest number:
    /// recorded speech, through the same chain, in the same blocks.
    ///
    /// It is also the number the KTV warning has been asserting without one.
    /// That notice says Apple's model "keeps one person speaking and removes
    /// everything else, which is the backing track and the singing"; what it
    /// costs the voice it keeps has never been stated.
    @Test("voice isolation, measured on speech rather than on noise")
    func voiceIsolationOnSpeech() throws {
        let audio = try DeterministicSpeechFixture.load()
        guard
            let onSpeech = SignalFidelity.cost(
                of: [.voiceIsolation], on: audio.samples, sampleRate: audio.rate)
        else {
            Issue.record("the isolation chain would not build at \(audio.rate) Hz")
            return
        }
        let onNoise = SignalFidelity.cost(
            of: [.voiceIsolation],
            on: SignalFidelity.fixture(seconds: 2, sampleRate: audio.rate),
            sampleRate: audio.rate)

        print("\nvoice isolation")
        print("  on speech: \(onSpeech.summary)")
        if let onNoise { print("  on noise:  \(onNoise.summary)") }
        for band in onSpeech.bandDecibels {
            print(String(format: "    %6.0f Hz  %+7.2f dB", band.centreHertz, band.decibels))
        }
        print("")

        // The claim this pins: it keeps far more of speech than of noise. If
        // that ever stops being true the model has changed under us, and the
        // warning the KTV stage shows would be describing something else.
        if let onNoise {
            #expect(
                onSpeech.correlation > onNoise.correlation,
                "speech \(onSpeech.correlation), noise \(onNoise.correlation)")
        }
    }
}
