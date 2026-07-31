import Foundation
import Testing

@testable import YunAudioEngine

/// The learned head against the rule it was built to replace, on the ruler that
/// found the failure in the first place.
///
/// The comparison is the point. A model that is not measured against what it
/// replaces is a claim, and this project does not ship claims.
@Suite("the learned pitch head against the rule")
struct LearnedPitchTests {

    private let rate: Double = 48_000

    private struct Random {
        var state: UInt64 = 0xC0FFEE
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }

    /// A voice, and optionally the room it is in.
    private func frame(
        voice f0: Double, backing: [Double] = [], backingGain: Double = 0,
        noise: Double = 0
    ) -> [Float] {
        var out = [Float](repeating: 0, count: PitchTracker.frameSize)
        var random = Random()
        func add(_ hertz: Double, harmonics: Int, gain: Double) {
            for index in out.indices {
                let t = Double(index) / rate
                var sample = 0.0
                for harmonic in 1...harmonics {
                    sample += sin(2 * .pi * hertz * Double(harmonic) * t) / Double(harmonic)
                }
                out[index] += Float(sample * gain)
            }
        }
        add(f0, harmonics: 10, gain: 0.3)
        for note in backing { add(note, harmonics: 5, gain: backingGain * 0.3 / 3) }
        if noise > 0 {
            for index in out.indices { out[index] += Float(noise * (random.next() * 2 - 1)) }
        }
        return out
    }

    private func cents(_ measured: Double, _ wanted: Double) -> Double {
        guard measured > 0, wanted > 0 else { return .infinity }
        return abs(1200 * log2(measured / wanted))
    }

    private func tracker() -> PitchTracker? {
        PitchTracker(
            sampleRate: rate, lowest: PitchTracker.lowestSungHertz,
            highest: PitchTracker.highestSungHertz)
    }

    @Test("the model is in the bundle and loads")
    func itLoads() throws {
        _ = try #require(LearnedPitch(sampleRate: rate))
    }

    @Test("on a clean voice it agrees with the rule, which is already exact")
    func cleanAgreement() throws {
        // The head must not be a regression where the rule is perfect. This is
        // the half of the comparison that a paper would leave out.
        let head = try #require(LearnedPitch(sampleRate: rate))
        let tracker = try #require(self.tracker())
        var worst = 0.0
        for wanted in [110.0, 164.81, 220.0, 329.63, 440.0, 523.25] {
            let curve = tracker.correlationCurve(frame: frame(voice: wanted))
            worst = max(worst, cents(Double(head.hertz(from: curve)), wanted))
        }
        print(String(format: "learned, clean voice: worst %.1f cents", worst))
        #expect(worst < 50)
    }

    @Test("and with the backing at the singer's level it wins")
    func theCaseItWasBuiltFor() throws {
        // The measurement that started this: the rule loses five notes out of
        // five at 1902 cents when the accompaniment matches the voice.
        let head = try #require(LearnedPitch(sampleRate: rate))
        let tracker = try #require(self.tracker())
        let chord = [130.81, 164.81, 196.00]
        var ruleLost = 0
        var headLost = 0
        var ruleWorst = 0.0
        var headWorst = 0.0
        let notes = [261.63, 329.63, 392.00, 440.00, 523.25]
        for wanted in notes {
            let samples = frame(voice: wanted, backing: chord, backingGain: 1.0)
            let byRule = Double(tracker.track(frame: samples))
            let curve = tracker.correlationCurve(frame: samples)
            let byHead = Double(head.hertz(from: curve))
            let ruleError = cents(byRule, wanted)
            let headError = cents(byHead, wanted)
            if ruleError > 50 { ruleLost += 1 }
            if headError > 50 { headLost += 1 }
            ruleWorst = max(ruleWorst, min(ruleError, 9999))
            headWorst = max(headWorst, min(headError, 9999))
        }
        print(
            String(
                format: "backing at the voice's level — rule: %d/%d lost, worst %.0f¢; "
                    + "learned: %d/%d lost, worst %.0f¢",
                ruleLost, notes.count, ruleWorst, headLost, notes.count, headWorst))
        // The claim, stated as a comparison rather than a threshold.
        #expect(headLost < ruleLost)
    }

    @Test("combined, it keeps the rule's precision and the head's judgement")
    func combined() throws {
        // The design: the head chooses which periodicity, the rule places it.
        // Both halves are asserted, because taking either alone is a trade.
        let head = try #require(LearnedPitch(sampleRate: rate))
        let tracker = try #require(self.tracker())

        var cleanWorst = 0.0
        for wanted in [110.0, 164.81, 220.0, 329.63, 440.0, 523.25] {
            let samples = frame(voice: wanted)
            let ruled = tracker.track(frame: samples)
            let curve = tracker.correlationCurve(frame: samples)
            let combined = Double(head.hertz(from: curve, agreeingWith: ruled))
            cleanWorst = max(cleanWorst, cents(combined, wanted))
        }
        print(String(format: "combined, clean voice: worst %.1f cents", cleanWorst))
        // The rule is exact here and the combination must not spend that.
        #expect(cleanWorst < 5)

        let chord = [130.81, 164.81, 196.00]
        var lost = 0
        var worst = 0.0
        let notes = [261.63, 329.63, 392.00, 440.00, 523.25]
        for wanted in notes {
            let samples = frame(voice: wanted, backing: chord, backingGain: 1.0)
            let ruled = tracker.track(frame: samples)
            let curve = tracker.correlationCurve(frame: samples)
            let combined = Double(head.hertz(from: curve, agreeingWith: ruled))
            let error = cents(combined, wanted)
            if error > 50 { lost += 1 }
            worst = max(worst, min(error, 9999))
        }
        print(
            String(
                format: "combined, backing at the voice's level: %d/%d lost, worst %.0f¢",
                lost, notes.count, worst))
        #expect(lost == 0)
    }

    @Test("and it costs a fraction of a millisecond")
    func itIsAffordable() throws {
        let head = try #require(LearnedPitch(sampleRate: rate))
        let tracker = try #require(self.tracker())
        let curve = tracker.correlationCurve(frame: frame(voice: 220))
        for _ in 0..<20 { _ = head.hertz(from: curve) }
        let began = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 { _ = head.hertz(from: curve) }
        let milliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - began) / 200 / 1_000_000
        print(String(format: "learned head: %.3f ms per frame", milliseconds))
        // Scoring runs at four hertz. Anything under a millisecond is free.
        #expect(milliseconds < 2)
    }
}
