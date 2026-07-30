import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

/// The curve the render server walks while a line fills.
///
/// A single linear animation crosses a row evenly, which is right only if
/// every syllable in it lasts the same time. Handed the shape instead, the
/// fill runs slowly through a held note and quickly through a short one, and
/// the highlight stays under the word being sung.
@Suite("Composited lyric key frames")
struct CompositedLyricKeyFrameTests {

    private func syllables(_ pairs: [(Double, String)]) -> [Lyrics.Line.Syllable] {
        pairs.map { Lyrics.Line.Syllable(time: $0.0, text: $0.1) }
    }

    @Test("a line with no word times keeps its linear animation")
    func withoutWordTimesThereIsNoCurve() {
        #expect(
            CompositedLyricKeyFrames.fill(
                row: (0, 1), syllables: [], line: (0, 4), text: "abcd") == nil)
    }

    @Test("the curve bends where the words do")
    func theCurveFollowsTheWords() throws {
        // Two characters in the first four seconds, eight in the next four.
        let frames = try #require(
            CompositedLyricKeyFrames.fill(
                row: (0, 1),
                syllables: syllables([(0, "ab"), (4, "cdefghij")]),
                line: (0, 8),
                text: "abcdefghij"))

        #expect(frames.keyTimes == [0, 0.5, 1])
        // Halfway through the line, a fifth of it has been sung. A linear
        // animation would be at one half — eight characters ahead of the voice.
        #expect(abs(frames.values[1] - 0.2) < 0.001)
        #expect(frames.values.first == 0)
        #expect(frames.values.last == 1)
    }

    @Test("a row only fills across its own share of the line")
    func rowsFillWithinTheirOwnSpan() throws {
        // The second half of a wrapped line: nothing until the line is half
        // sung, then all of it.
        let frames = try #require(
            CompositedLyricKeyFrames.fill(
                row: (0.5, 1.0),
                syllables: syllables([(0, "abcde"), (4, "fghij")]),
                line: (0, 8),
                text: "abcdefghij"))

        #expect(frames.values.first == 0)
        // At the boundary the first row is exactly full and this one is empty.
        #expect(abs(frames.values[1] - 0.0) < 0.001)
        #expect(frames.values.last == 1)
    }

    @Test("two words stamped at the same moment do not break the animation")
    func repeatedTimesAreDropped() throws {
        // Core Animation rejects key times that do not increase, and rejecting
        // the animation means the row never fills at all — worse than the
        // linear sweep this replaces.
        let frames = try #require(
            CompositedLyricKeyFrames.fill(
                row: (0, 1),
                syllables: syllables([(0, "a"), (2, "b"), (2, "c"), (4, "d")]),
                line: (0, 6),
                text: "abcd"))

        #expect(frames.keyTimes == frames.keyTimes.sorted())
        #expect(Set(frames.keyTimes).count == frames.keyTimes.count)
        #expect(frames.keyTimes.count == frames.values.count)
    }

    @Test("key times stay inside the animation's own span")
    func keyTimesAreBounded() throws {
        let frames = try #require(
            CompositedLyricKeyFrames.fill(
                row: (0, 1),
                syllables: syllables([(-4, "a"), (2, "b"), (99, "c")]),
                line: (0, 6),
                text: "abc"))

        #expect(frames.keyTimes.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(frames.values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}
