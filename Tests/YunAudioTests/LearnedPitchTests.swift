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
        // The best of five batches, not one.
        //
        // The question is what the call costs, and the answer is a floor: no
        // batch runs faster than the work, and any batch runs slower because
        // the machine did something else. The suite runs its cases in parallel,
        // so one batch measures this model plus whatever else was on the Neural
        // Engine — it passed alone and failed in the suite, which is a fact
        // about the machine. The minimum measures the thing itself: a
        // regression makes every batch slow and the floor rises with them.
        var milliseconds = Double.infinity
        for _ in 0..<5 {
            let began = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<200 { _ = head.hertz(from: curve) }
            let batch =
                Double(DispatchTime.now().uptimeNanoseconds - began) / 200 / 1_000_000
            milliseconds = min(milliseconds, batch)
        }
        print(
            String(
                format: "learned head: %.3f ms per frame (best of 5 batches of 200)",
                milliseconds))
        // Scoring runs at four hertz. Anything under a millisecond is free.
        #expect(milliseconds < 2)
    }
}

/// The whole pipeline, from a microphone signal to a score.
///
/// Every measurement so far has been of a component. This is the one that says
/// the change reaches a singer: a person singing a tune correctly, with the
/// accompaniment coming back into the microphone at their own level, scored
/// through `SingerPitch` and `KaraokeScore` exactly as a performance is.
///
/// Without the head this is the case that reads near zero — not because the
/// singer was wrong, but because the tracker was following the backing track.
@Suite("a whole performance over a loud backing track")
struct EndToEndScoringTests {

    private let rate: Double = 48_000

    /// A tune, and the room it is sung in.
    private func performance(
        notes: [Double], secondsEach: Double, backing: [Double], backingGain: Double
    ) -> [Float] {
        let total = Int(Double(notes.count) * secondsEach * rate)
        var out = [Float](repeating: 0, count: total)
        for (index, note) in notes.enumerated() {
            let start = Int(Double(index) * secondsEach * rate)
            let end = min(total, Int(Double(index + 1) * secondsEach * rate))
            guard start < end else { continue }
            for sample in start..<end {
                let t = Double(sample) / rate
                var value = 0.0
                for harmonic in 1...10 {
                    value += sin(2 * .pi * note * Double(harmonic) * t) / Double(harmonic)
                }
                out[sample] += Float(value * 0.3)
            }
        }
        // The accompaniment runs underneath the whole thing, as it does.
        for chordNote in backing {
            for sample in 0..<total {
                let t = Double(sample) / rate
                var value = 0.0
                for harmonic in 1...5 {
                    value += sin(2 * .pi * chordNote * Double(harmonic) * t) / Double(harmonic)
                }
                out[sample] += Float(value * backingGain * 0.3 / Double(backing.count))
            }
        }
        return out
    }

    @Test("a correct performance over a backing track at the singer's level scores well")
    func scoredThroughTheWholePipeline() throws {
        let notes = [261.63, 329.63, 392.00, 440.00, 392.00, 329.63]
        let secondsEach = 0.5
        let samples = performance(
            notes: notes, secondsEach: secondsEach,
            backing: [130.81, 164.81, 196.00], backingGain: 1.0)

        let singer = try #require(SingerPitch(sampleRate: rate))
        singer.reset(at: 0)
        samples.withUnsafeBufferPointer { buffer in
            singer.add(buffer, advancesTimeline: true)
        }

        // The tune the singer was given, sampled the way the melody path does.
        let reference: [PitchSample] = stride(
            from: 0.0, to: Double(notes.count) * secondsEach,
            by: KaraokeScore.referenceInterval
        )
        .map { time in
            let index = min(notes.count - 1, Int(time / secondsEach))
            return PitchSample(
                time: time, midi: PitchSample.midi(fromHertz: notes[index]))
        }

        let score = KaraokeScore.score(sung: singer.samples, reference: reference)
        print(
            String(
                format: "end to end, backing at the voice's level: %.0f%% (%.0f%% covered)",
                score.percentage, score.coveragePercentage))
        // A correct performance. Anything below this and the pipeline is
        // scoring the room rather than the singer, which is what it did before
        // the head existed — the tracker followed the backing track and every
        // note came back an octave and a fifth out.
        #expect(score.percentage > 70)
        #expect(score.coveragePercentage > 80)
    }

    @Test("a backing that is not an octave of the tune is where it really tells")
    func nonOctaveBacking() throws {
        // The first fixture was accidentally kind. Its chord was rooted on
        // C3 against a melody starting on C4 — an exact octave — and
        // `KaraokeScore` forgives octaves, so following the accompaniment
        // still scored as following the tune. The single-frame error was real
        // and the end-to-end consequence was not.
        //
        // A backing on D major under a melody in C is a genuine competitor: a
        // tracker that locks onto it reports a *different note*, which is what
        // the score is for.
        let notes = [261.63, 329.63, 392.00, 440.00, 392.00, 329.63]
        let samples = performance(
            notes: notes, secondsEach: 0.5,
            backing: [146.83, 185.00, 220.00], backingGain: 1.0)
        let singer = try #require(SingerPitch(sampleRate: rate))
        singer.reset(at: 0)
        samples.withUnsafeBufferPointer { buffer in
            singer.add(buffer, advancesTimeline: true)
        }
        let reference: [PitchSample] = stride(
            from: 0.0, to: Double(notes.count) * 0.5, by: KaraokeScore.referenceInterval
        ).map { time in
            let index = min(notes.count - 1, Int(time / 0.5))
            return PitchSample(time: time, midi: PitchSample.midi(fromHertz: notes[index]))
        }
        let score = KaraokeScore.score(sung: singer.samples, reference: reference)
        print(
            String(
                format: "end to end, non-octave backing (%@): %.0f%%",
                SingerPitch.usesLearnedHead ? "with head" : "no head", score.percentage))
    }

    @Test("and the level at which it starts to matter, if there is one")
    func theRegimeSweep() throws {
        // A negative result is a result. Two end-to-end fixtures showed no
        // difference at all — the score forgives octaves, and a score
        // accumulated over hundreds of frames absorbs the occasional bad one —
        // so this sweeps the level until either the head earns its place or it
        // is established that it does not.
        let notes = [261.63, 329.63, 392.00, 440.00, 392.00, 329.63]
        var line: [String] = []
        var scores: [Double: Double] = [:]
        for gain in [1.0, 1.5, 2.0, 3.0, 4.0] {
            let samples = performance(
                notes: notes, secondsEach: 0.5,
                backing: [146.83, 185.00, 220.00], backingGain: gain)
            guard let singer = SingerPitch(sampleRate: rate) else { continue }
            singer.reset(at: 0)
            samples.withUnsafeBufferPointer { singer.add($0, advancesTimeline: true) }
            let reference: [PitchSample] = stride(
                from: 0.0, to: Double(notes.count) * 0.5,
                by: KaraokeScore.referenceInterval
            ).map { time in
                let index = min(notes.count - 1, Int(time / 0.5))
                return PitchSample(time: time, midi: PitchSample.midi(fromHertz: notes[index]))
            }
            let score = KaraokeScore.score(sung: singer.samples, reference: reference)
            scores[gain] = score.percentage
            line.append(String(format: "%.1f×:%.0f%%", gain, score.percentage))
        }
        print(
            "backing level sweep ("
                + (SingerPitch.usesLearnedHead ? "with head" : "no head") + "): "
                + line.joined(separator: "  "))

        // The regime, measured both ways by running this suite under
        // `YUNAUDIO_NO_LEARNED_PITCH=1`:
        //
        //     backing   1.0×   1.5×   2.0×   3.0×   4.0×
        //     with head   95%    95%    95%    70%    40%
        //     no head     95%    92%    89%    57%    43%
        //
        // Nothing below the singer's own level, which is right — the rule is
        // already correct there and the head defers to it. From one and a half
        // times upward it is worth three, six and thirteen points, and at four
        // times both collapse because the voice is buried and no choice among
        // periodicities can recover a signal that is not there.
        //
        // Asserted at the two levels where the difference is unambiguous, so
        // that removing the head or retraining it worse fails here rather than
        // quietly costing somebody their score in a loud room.
        guard SingerPitch.usesLearnedHead else { return }
        #expect(scores[2.0] ?? 0 > 90, "at twice the singer's level")
        #expect(scores[3.0] ?? 0 > 65, "at three times the singer's level")
    }

    @Test("and the same performance in a quiet room still scores well")
    func quietRoomIsUnharmed() throws {
        // The half that a change like this can quietly break: the head must not
        // cost anything where the rule was already right.
        let notes = [261.63, 329.63, 392.00, 440.00]
        let samples = performance(
            notes: notes, secondsEach: 0.5, backing: [], backingGain: 0)
        let singer = try #require(SingerPitch(sampleRate: rate))
        singer.reset(at: 0)
        samples.withUnsafeBufferPointer { buffer in
            singer.add(buffer, advancesTimeline: true)
        }
        let reference: [PitchSample] = stride(
            from: 0.0, to: Double(notes.count) * 0.5, by: KaraokeScore.referenceInterval
        ).map { time in
            let index = min(notes.count - 1, Int(time / 0.5))
            return PitchSample(time: time, midi: PitchSample.midi(fromHertz: notes[index]))
        }
        let score = KaraokeScore.score(sung: singer.samples, reference: reference)
        print(String(format: "end to end, quiet room: %.0f%%", score.percentage))
        #expect(score.percentage > 80)
    }
}

/// The head must not invent notes where there are none.
///
/// Its training set is 80 000 frames and every one of them contains a voice, so
/// "no voice" is not in its vocabulary — asked about silence it returns the
/// best periodicity it can find in the noise, with no way to signal that the
/// question was wrong. The flow check caught it reading 78 Hz off a quiet room.
///
/// This is the boundary between the two estimators, asserted rather than
/// assumed: the rule decides whether there is a note, the head decides which
/// one it is.
@Suite("the head does not decide whether somebody is singing")
struct LearnedPitchVoicingTests {

    @Test("a rule that found nothing is not overruled")
    func silenceStaysSilent() throws {
        let head = try #require(LearnedPitch(sampleRate: 48_000))
        // A curve with a peak in it — so the head has something to answer with
        // and the test is about the *rule's* zero rather than about an empty
        // input the head would refuse anyway.
        var curve = [Float](repeating: 0, count: 512)
        for index in curve.indices {
            curve[index] = Float(0.6 * cos(2 * Double.pi * Double(index) / 120))
        }
        #expect(head.hertz(from: curve, agreeingWith: 0) == 0)
    }

    @Test("but a rule that found a note still gets the head's opinion")
    func voicedFramesAreStillSettled() throws {
        let head = try #require(LearnedPitch(sampleRate: 48_000))
        var curve = [Float](repeating: 0, count: 512)
        for index in curve.indices {
            curve[index] = Float(0.6 * cos(2 * Double.pi * Double(index) / 120))
        }
        // Whatever it answers, it must answer *something* — the guard above
        // must not have switched the head off for voiced frames too, which is
        // the way a fix like this goes wrong.
        #expect(head.hertz(from: curve, agreeingWith: 220) > 0)
    }
}
