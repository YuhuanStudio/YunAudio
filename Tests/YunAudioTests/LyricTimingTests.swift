import Foundation
import Testing

@testable import YunAudioEngine

/// Telling the three ways words go out of step apart from each other.
@Suite("Which way the words are wrong")
struct LyricTimingTests {

    private let duration: Double = 200

    /// A song of alternating sung phrases and gaps, and the words that go with
    /// it — moved by whatever the test is about.
    private func song(
        phraseSeconds: Double = 6, gapSeconds: Double = 4,
        wordsShiftedBy shift: @escaping (Double) -> Double = { $0 }
    ) -> (lyrics: [Lyrics.Line], melody: [PitchSample]) {
        var lyrics: [Lyrics.Line] = []
        var melody: [PitchSample] = []
        var start = 10.0
        var index = 0
        while start + phraseSeconds < duration - 10 {
            lyrics.append(
                Lyrics.Line(time: shift(start), text: "line \(index)"))
            var time = start
            while time < start + phraseSeconds {
                melody.append(PitchSample(time: time, midi: 60 + Double(index % 5)))
                time += LyricTiming.step
            }
            start += phraseSeconds + gapSeconds
            index += 1
        }
        return (lyrics, melody)
    }

    @Test("words that are on time are called on time")
    func alignedIsAligned() {
        let (lyrics, melody) = song()
        let found = LyricTiming.diagnose(
            lyrics: lyrics, melody: melody, duration: duration)
        #expect(found.verdict == .aligned, "\(found.summary)")
        #expect(abs(found.offsetSeconds) <= LyricTiming.closeEnoughSeconds, "\(found.summary)")
        #expect(found.agreement > LyricTiming.confidentAgreement, "\(found.summary)")
    }

    /// The ordinary case, and the one the per-song offset control exists for.
    @Test("a lead-in the file does not describe reads as one offset")
    func uniformOffsetIsFound() {
        // The words arrive 1.5 s before the singing does.
        let (lyrics, melody) = song(wordsShiftedBy: { $0 - 1.5 })
        let found = LyricTiming.diagnose(
            lyrics: lyrics, melody: melody, duration: duration)
        #expect(found.verdict == .uniformOffset, "\(found.summary)")
        // Positive means the words are early and belong later.
        #expect(abs(found.offsetSeconds - 1.5) < 0.3, "\(found.summary)")
        #expect(abs(found.driftSecondsPerMinute) < LyricTiming.driftPerMinuteThreshold, "\(found.summary)")
        #expect(found.agreement > LyricTiming.confidentAgreement, "\(found.summary)")
    }

    /// The serious one: no single offset can fix it, and the interface must not
    /// offer one as though it could.
    @Test("two clocks at different rates read as drift, not as an offset")
    func driftIsSeenAsDrift() {
        // A per-cent slow clock: by three minutes the words are seconds out.
        let (lyrics, melody) = song(wordsShiftedBy: { $0 * 0.985 })
        let found = LyricTiming.diagnose(
            lyrics: lyrics, melody: melody, duration: duration)
        #expect(found.verdict == .drifting, "\(found.summary)")
        #expect(abs(found.driftSecondsPerMinute) > LyricTiming.driftPerMinuteThreshold, "\(found.summary)")
    }

    /// Words for another recording line up at no offset at all, and saying
    /// "they are 3 seconds late" about them would send somebody to a control
    /// that cannot help.
    @Test("words for a different recording line up nowhere")
    func wrongWordsAreNamed() {
        let (_, melody) = song(phraseSeconds: 6, gapSeconds: 4)
        // Words on a completely different rhythm, and more of them.
        var other: [Lyrics.Line] = []
        var time = 12.0
        var index = 0
        while time < duration - 10 {
            other.append(Lyrics.Line(time: time, text: "other \(index)"))
            time += 2.3
            index += 1
        }
        let found = LyricTiming.diagnose(
            lyrics: other, melody: melody, duration: duration)
        #expect(found.verdict == .wrongWords, "\(found.summary)")
        #expect(found.agreement < LyricTiming.leastAgreement, "\(found.summary)")
    }

    /// Phrases in a song are regularly spaced, so the coarse score is
    /// periodic: shifting by exactly one phrase pairs every line with its
    /// neighbour and scores just as well as the truth.
    ///
    /// This cost a whole phrase of error before it was found — a song whose
    /// phrases are ten seconds apart diagnosed as ten seconds out, confidently.
    /// The tie-break is toward the smaller shift, for the reason a listener
    /// would use: words one whole phrase out are not what anybody means by
    /// "late".
    @Test("a whole phrase of shift is not preferred to none")
    func periodicityDoesNotWinTies() {
        let (lyrics, melody) = song(phraseSeconds: 6, gapSeconds: 4)
        let found = LyricTiming.diagnose(
            lyrics: lyrics, melody: melody, duration: duration)
        #expect(abs(found.offsetSeconds) < 1, "\(found.summary)")

        // And directly: the coarse pass itself must not take the octave.
        let coarse = LyricTiming.coarseOffset(
            words: LyricTiming.onsets(ofLyrics: lyrics),
            sung: LyricTiming.onsets(ofMelody: melody))
        #expect(abs(coarse) < 1, "coarse pass chose \(coarse) s")
    }

    /// An instrumental has nothing to line up against, and inventing a verdict
    /// would be the same failure the melody extractor already refuses.
    @Test("with nothing sung it says so instead of guessing")
    func silenceIsNotADiagnosis() {
        let (lyrics, _) = song()
        let found = LyricTiming.diagnose(lyrics: lyrics, melody: [], duration: duration)
        #expect(found.verdict == .notEnoughToTell, "\(found.summary)")
        #expect(found.sungSeconds < 1)
    }

    /// And too few lines is the same answer for the same reason.
    @Test("two lines cannot decide anything")
    func tooFewLines() {
        let (_, melody) = song()
        let found = LyricTiming.diagnose(
            lyrics: [
                Lyrics.Line(time: 10, text: "one"), Lyrics.Line(time: 20, text: "two"),
            ],
            melody: melody, duration: duration)
        #expect(found.verdict == .notEnoughToTell, "\(found.summary)")
    }
}
