import Testing

@testable import YunAudioEngine

/// Word times, and the sweep that can only be honest once it has them.
///
/// Without them a highlight crossing a line can only move linearly, which is
/// wrong for every line that does not hold its syllables evenly — late on a
/// long word, early on a short one, and a singer following it is pulled off
/// the beat by the display.
@Suite("Lyric syllables")
struct LyricSyllableTests {

    @Test("an ordinary line has no word times and says so")
    func plainLinesHaveNoSyllables() throws {
        let lyrics = try #require(Lyrics.parse("[00:12.50]說完了 好像話都說完了"))
        #expect(lyrics.lines[0].syllables.isEmpty)
        #expect(lyrics.lines[0].text == "說完了 好像話都說完了")
        // Nil rather than a fabricated number: the caller falls back to the
        // linear sweep rather than being handed a guess shaped like a measurement.
        #expect(lyrics.lines[0].progress(at: 13, lineEnd: 16) == nil)
    }

    @Test("enhanced markers become word times and leave the words alone")
    func enhancedMarkersAreRead() throws {
        let text = "[00:12.50]<00:12.50>These <00:12.90>are <00:13.20>words"
        let lyrics = try #require(Lyrics.parse(text))
        let line = lyrics.lines[0]

        // What a person reads, with the markers gone.
        #expect(line.text == "These are words")
        #expect(line.syllables.map(\.time) == [12.5, 12.9, 13.2])
        #expect(line.syllables.map(\.text) == ["These ", "are ", "words"])
    }

    @Test("the sweep follows the words rather than the clock")
    func progressFollowsTheWords() throws {
        let text = "[00:10.00]<00:10.00>aa<00:11.00>bbbbbbbb"
        let lyrics = try #require(Lyrics.parse(text))
        let line = lyrics.lines[0]

        // Two characters then eight. Half the time has passed at 11 s, but only
        // a fifth of the line has been sung — which a linear sweep would have
        // drawn at one half, eight characters ahead of the singer.
        let atSecondWord = try #require(line.progress(at: 11, lineEnd: 12))
        #expect(abs(atSecondWord - 0.2) < 0.001)

        #expect(line.progress(at: 9, lineEnd: 12) == 0)
        #expect(line.progress(at: 12, lineEnd: 12) == 1)
    }

    @Test("a long syllable fills across its own span")
    func longSyllablesFillSlowly() throws {
        let text = "[00:00.00]<00:00.00>ab<00:04.00>cd"
        let lyrics = try #require(Lyrics.parse(text))
        let line = lyrics.lines[0]

        // Halfway through the first word's four seconds is one character of
        // four, not two: the fill moves inside a word as well as between them.
        let halfway = try #require(line.progress(at: 2, lineEnd: 8))
        #expect(abs(halfway - 0.25) < 0.001)
    }

    @Test("markers survive the attribution pass")
    func attributionKeepsWordTimes() throws {
        // Credits are dropped and a singer marker is lifted off the line; the
        // word times on the lines that remain must come through unharmed.
        let text = """
            [00:00.00]作詞：某某
            [00:01.00]合
            [00:02.00]<00:02.00>痛快的<00:03.00>離開
            """
        let lyrics = try #require(Lyrics.parse(text, performers: ["王赫野"]))
        #expect(lyrics.lines.count == 1)
        #expect(lyrics.lines[0].text == "痛快的離開")
        #expect(lyrics.lines[0].singer == "合")
        #expect(lyrics.lines[0].syllables.map(\.text) == ["痛快的", "離開"])
    }
}
