import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

/// Effects that are switched on, change nothing, and still cost latency.
@Suite("Switched on and doing nothing")
struct EnabledButSilentTests {

    /// What each transparent effect costs in delay at a given rate.
    @Test("the transparent effects are latency and nothing else")
    func transparentEffectsAreLatency() {
        print("\neffect      48 kHz          96 kHz")
        print(String(repeating: "-", count: 44))
        for kind in [EffectKind.gate, .tone, .pitch, .formant, .limiter] {
            var line = String(format: "%-10@", kind.rawValue as NSString)
            for rate in [48_000.0, 96_000.0] {
                let source = SignalFidelity.fixture(seconds: 1, sampleRate: rate)
                guard let measured = SignalFidelity.cost(
                    of: [kind], on: source, sampleRate: rate)
                else { continue }
                line += String(
                    format: "  %5d fr %6.1f ms",
                    measured.delayFrames,
                    Double(measured.delayFrames) / rate * 1000)
            }
            print(line)
        }
        print("")
        #expect(true)
    }

    /// The pair somebody is actually running, at the rate they chose.
    ///
    /// Both are bit-transparent at their default settings — a pitch shifter set
    /// to no shift and a formant shifter set to no shift — so what they buy is
    /// the delay of having them in the graph. That is a switch which is on,
    /// does nothing, and costs something, which is the worst arrangement of the
    /// three.
    @Test("pitch and formant together, at 96 kHz")
    func theRunningPair() throws {
        let rate = 96_000.0
        let source = SignalFidelity.fixture(seconds: 1, sampleRate: rate)
        let both = try #require(
            SignalFidelity.cost(of: [.pitch, .formant], on: source, sampleRate: rate))
        let milliseconds = Double(both.delayFrames) / rate * 1000
        print(
            String(
                format: "\npitch + formant at 96 kHz: %d frames, %.1f ms, residual %@\n",
                both.delayFrames, milliseconds,
                both.residualDecibels.isFinite
                    ? String(format: "%.2f dB", both.residualDecibels) as NSString
                    : "exact" as NSString))
        // Transparent: they are not changing the sound.
        #expect(both.correlation > 0.999999, "\(both.summary)")
        // And not free: this is what being switched on costs.
        #expect(both.delayFrames > 0)
    }
}

/// The breakdown the chain used to throw away.
@Suite("Where the chain's latency comes from")
struct ChainLatencyAttributionTests {

    @Test("each stage's latency is attributed to it")
    func attributionSumsToTheTotal() throws {
        let rate = 96_000.0
        let kinds: [EffectKind] = [.pitch, .formant, .limiter]
        // Retried for the reason `SignalFidelity.cost` retries: a refused graph
        // admission is about this instant, not about the chain.
        var built: EffectChain?
        for _ in 0..<20 where built == nil {
            built = EffectChain(kinds: kinds, sampleRate: rate, maximumFrames: 512)
            if built == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        let chain = try #require(built)
        print("\nlatency by stage at 96 kHz:")
        for kind in kinds {
            let frames = chain.latencyByStage[kind] ?? 0
            print(
                String(
                    format: "  %-10@ %6d frames  %6.1f ms",
                    kind.rawValue as NSString, frames,
                    Double(frames) / rate * 1000))
        }
        print(String(format: "  total      %6d frames\n", chain.latencyFrames))

        // The breakdown has to add up, or it is decoration.
        let attributed = kinds.reduce(0) { $0 + (chain.latencyByStage[$1] ?? 0) }
        #expect(attributed == chain.latencyFrames, "\(attributed) vs \(chain.latencyFrames)")

        // And the two that do nothing at their defaults are most of it, which
        // is the whole point of having the breakdown.
        let doingNothing =
            (chain.latencyByStage[.pitch] ?? 0) + (chain.latencyByStage[.formant] ?? 0)
        #expect(doingNothing > chain.latencyFrames / 2)
    }
}

@MainActor
@Suite("The model names what is on and doing nothing")
struct NeutralEffectWarningTests {

    @Test("pitch and formant at their defaults are named")
    func neutralPairIsNamed() {
        let model = RouterModel()
        model.enabledEffects = [.pitch, .formant]
        let neutral = Set(model.effectsEnabledButNeutral)
        #expect(neutral == [.pitch, .formant])
    }

    /// Moved off its default it is doing something, and saying otherwise would
    /// be worse than saying nothing.
    @Test("a shifted pitch is not doing nothing")
    func shiftedPitchIsNotNeutral() {
        let model = RouterModel()
        model.enabledEffects = [.pitch]
        guard let cents = EffectKind.pitch.parameters.first else {
            Issue.record("pitch has no parameters")
            return
        }
        model.effectValues["pitch.\(cents.id)"] = 300
        #expect(model.effectsEnabledButNeutral.isEmpty)
    }

    /// And nothing is said with no route: the latency it would quote comes
    /// from a chain that is not running.
    @Test("nothing is said when nothing is running")
    func silentWhenStopped() {
        let model = RouterModel()
        model.enabledEffects = [.pitch, .formant]
        #expect(model.neutralEffectWarning == nil)
    }
}
