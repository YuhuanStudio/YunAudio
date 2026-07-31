import Testing

@testable import YunAudioApp
@testable import YunAudioEngine
@testable import YunDesign

/// What a finished song is called, and what it is told.
@Suite("KTV performance grade")
struct KTVPerformanceGradeTests {

    private func score(
        percentage: Double, error: Double? = nil, silent: Double = 0,
        reference: Double = 100, lines: [KaraokeScore.Line] = []
    ) -> KaraokeScore {
        KaraokeScore(
            percentage: percentage, onPitchSeconds: reference * percentage / 100,
            nearPitchSeconds: 0, silentSeconds: silent, referenceSeconds: reference,
            sungSeconds: reference - silent, meanErrorSemitones: error, lines: lines)
    }

    private func line(_ index: Int, _ text: String, _ percentage: Double) -> KaraokeScore.Line {
        KaraokeScore.Line(
            index: index, time: Double(index) * 4, text: text, referenceSeconds: 4,
            onPitchSeconds: 4 * percentage / 100, nearPitchSeconds: 0,
            percentage: percentage)
    }

    @Test("the bands do not hand out the top of the scale")
    func gradesAreNotGenerous() {
        // A score is time within half a semitone of the tune across the whole
        // song, silence included. Calling 70 「不錯」 rather than 「很好」 is what
        // keeps the top of the scale worth reaching.
        #expect(KTVPerformanceGrade.of(100) == .perfect)
        #expect(KTVPerformanceGrade.of(90) == .perfect)
        #expect(KTVPerformanceGrade.of(89.9) == .great)
        #expect(KTVPerformanceGrade.of(75) == .great)
        #expect(KTVPerformanceGrade.of(74.9) == .good)
        #expect(KTVPerformanceGrade.of(55) == .good)
        #expect(KTVPerformanceGrade.of(54.9) == .keepGoing)
        #expect(KTVPerformanceGrade.of(0) == .keepGoing)
    }

    @Test("a singer who was not singing is not told they were flat")
    @MainActor
    func coverageComesFirst() {
        // Half the tune unsung and what was sung was flat. The flatness is
        // true and useless: the score is low for a reason they already know.
        let unsung = KTVPerformanceGrade.advice(
            for: score(percentage: 30, error: -0.6, silent: 55))
        let flat = KTVPerformanceGrade.advice(for: score(percentage: 70, error: -0.6))
        #expect(unsung != nil)
        // Whatever the language, it is not the sentence about being flat.
        #expect(unsung != flat)
    }

    @Test("being consistently off is the one thing worth saying")
    @MainActor
    func flatAndSharpAreNamed() {
        let flat = KTVPerformanceGrade.advice(for: score(percentage: 70, error: -0.42))
        let sharp = KTVPerformanceGrade.advice(for: score(percentage: 70, error: 0.42))
        #expect(flat != nil)
        #expect(sharp != nil)
        #expect(flat != sharp)
        // A quarter of a semitone is inside anybody's vibrato; below it there
        // is nothing to act on and the card says nothing.
        #expect(KTVPerformanceGrade.advice(for: score(percentage: 70, error: -0.1)) == nil)
        #expect(KTVPerformanceGrade.advice(for: score(percentage: 70, error: nil)) == nil)
    }

    @Test("the best line is a line that had a tune under it")
    func bestLineIgnoresLinesWithNoTune() {
        let lines = [
            line(0, "唱得普通的一句", 61),
            KaraokeScore.Line(
                index: 1, time: 4, text: "沒有旋律的一句", referenceSeconds: 0,
                onPitchSeconds: 0, nearPitchSeconds: 0, percentage: 100),
            line(2, "唱得最好的一句", 93),
            KaraokeScore.Line(
                index: 3, time: 12, text: "", referenceSeconds: 4,
                onPitchSeconds: 4, nearPitchSeconds: 0, percentage: 99),
        ]
        let best = KTVPerformanceGrade.bestLine(in: score(percentage: 70, lines: lines))
        // Not the 100% line with no melody behind it, and not the wordless
        // 99% one — both are numbers about nothing.
        #expect(best?.text == "唱得最好的一句")
    }

    @Test("a song nobody scored has no best line")
    func noLinesMeansNoBestLine() {
        #expect(KTVPerformanceGrade.bestLine(in: .none) == nil)
        #expect(KTVPerformanceGrade.bestLine(in: score(percentage: 80)) == nil)
    }
}
