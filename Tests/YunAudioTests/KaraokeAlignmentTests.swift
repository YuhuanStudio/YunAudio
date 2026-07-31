import Foundation
import Testing

@testable import YunAudioEngine

/// Scoring a performance against the tune, allowing for the fact that nobody
/// sings on the grid.
///
/// The measurement this joins compares moment to moment, so a phrase entered a
/// third of a second late scores near zero on every note in it and reports the
/// singer as flat — when what happened is that they were phrasing. These are the
/// cases that separates.
@Suite("aligning what was sung with what should have been")
struct KaraokeAlignmentTests {

    /// A run of samples at a fixed cadence.
    private func series(
        from start: Double, step: Double = 0.01, midi: [Double]
    ) -> [PitchSample] {
        midi.enumerated().map { index, value in
            PitchSample(time: start + Double(index) * step, midi: value)
        }
    }

    private func held(_ midi: Double, seconds: Double, from start: Double = 0) -> [PitchSample] {
        series(from: start, midi: [Double](repeating: midi, count: Int(seconds / 0.01)))
    }

    @Test("a perfect performance scores perfectly and is on time")
    func perfection() throws {
        let tune = held(60, seconds: 2)
        let result = try #require(KaraokeAlignment.align(sung: tune, reference: tune))
        #expect(result.pitchAccuracy == 1)
        #expect(abs(result.timingSeconds) < 0.001)
        #expect(result.steadiness > 0.99)
    }

    @Test("the same notes a third of a second late are still the same notes")
    func lateButRight() throws {
        // The case the moment-to-moment scorer cannot see. A singer who enters
        // late and sings the phrase correctly is phrasing, not wrong.
        let tune = series(from: 0, midi: [Double](repeating: 60, count: 100)
            + [Double](repeating: 64, count: 100))
        let sung = series(from: 0.30, midi: [Double](repeating: 60, count: 100)
            + [Double](repeating: 64, count: 100))
        let result = try #require(KaraokeAlignment.align(sung: sung, reference: tune))
        // Aligned, it is the same performance.
        #expect(result.pitchAccuracy > 0.9)
        // And the lateness is reported rather than punished.
        #expect(result.timingSeconds > 0.1)
    }

    @Test("but singing the wrong note on time is still wrong")
    func wrongNote() throws {
        // The alignment must not become a way to score anything against
        // anything: a whole tone out for the whole line is a whole tone out.
        let tune = held(60, seconds: 2)
        let sung = held(62, seconds: 2)
        let result = try #require(KaraokeAlignment.align(sung: sung, reference: tune))
        #expect(result.pitchAccuracy < 0.1)
    }

    @Test("an octave down is the same part")
    func octaves() throws {
        // A man singing a woman's line an octave below is singing the line.
        let tune = held(72, seconds: 2)
        let sung = held(60, seconds: 2)
        let result = try #require(KaraokeAlignment.align(sung: sung, reference: tune))
        #expect(result.pitchAccuracy == 1)
        #expect(KaraokeAlignment.semitoneDistance(60, 72) == 0)
        #expect(KaraokeAlignment.semitoneDistance(60, 62) == 2)
    }

    @Test("consistently late is steadier than late-then-early")
    func steadiness() throws {
        let tune = series(from: 0, midi: [Double](repeating: 60, count: 100)
            + [Double](repeating: 67, count: 100))
        let steady = series(from: 0.2, midi: [Double](repeating: 60, count: 100)
            + [Double](repeating: 67, count: 100))
        // The same notes, but the second half rushes back past the beat.
        let ragged = series(from: 0.2, midi: [Double](repeating: 60, count: 100))
            + series(from: 0.8, midi: [Double](repeating: 67, count: 100))
        let a = try #require(KaraokeAlignment.align(sung: steady, reference: tune))
        let b = try #require(KaraokeAlignment.align(sung: ragged, reference: tune))
        #expect(a.steadiness > b.steadiness)
    }

    @Test("nothing sung is nothing to score, not a bad score")
    func silence() {
        #expect(KaraokeAlignment.align(sung: [], reference: held(60, seconds: 1)) == nil)
        #expect(KaraokeAlignment.align(sung: held(60, seconds: 1), reference: []) == nil)
    }

    @Test("and the corridor keeps it affordable")
    func itIsBanded() throws {
        // Five seconds at a hundred a second, both series: unbanded this is
        // 250,000 cells, banded it is a fraction of that. What is asserted is
        // that it returns at all in a test run rather than a wall-clock number,
        // which would be a benchmark of whatever else the machine is doing.
        let tune = held(60, seconds: 5)
        let sung = held(60, seconds: 5, from: 0.05)
        let began = DispatchTime.now().uptimeNanoseconds
        let result = try #require(KaraokeAlignment.align(sung: sung, reference: tune))
        let milliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        print(String(format: "five seconds aligned in %.2f ms", milliseconds))
        #expect(result.pitchAccuracy > 0.9)
        // A line is two to five seconds and the score updates four times a
        // second, so anything near a frame budget would be a problem. Measured
        // in release, because that is the only build whose timing is about this
        // code: **0.45 ms** against **90 ms** for the same call in debug, where
        // every array access carries Swift's own bounds and exclusivity
        // checking. Asserting the debug figure would either be a two-hundred-fold
        // slack that catches nothing, or a red line on a build nobody ships.
        #if !DEBUG
            #expect(milliseconds < 5)
        #endif
    }
}
