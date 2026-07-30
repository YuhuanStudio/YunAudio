import Testing

@testable import YunAudioEngine

/// The second `.lrc` the indexes have been sending all along.
///
/// NetEase returns a translation under `tlyric` and this application has been
/// asking for it since it was written and throwing it away.
@Suite("Lyric translations")
struct LyricTranslationTests {

    @Test("lines are paired by when they are sung")
    func pairedByTime() throws {
        let original = try #require(
            Lyrics.parse(
                """
                [00:12.50]說完了 好像話都說完了
                [00:18.20]總是沉默對坐著
                """))
        let translated = original.withTranslation(
            """
            [00:12.50]It is all said, everything is said
            [00:18.20]We only sit in silence
            """)

        #expect(translated.lines[0].translation == "It is all said, everything is said")
        #expect(translated.lines[1].translation == "We only sit in silence")
        // The words themselves are untouched.
        #expect(translated.lines.map(\.text) == original.lines.map(\.text))
    }

    @Test("a translation that omits the credit block still lines up")
    func indexMismatchDoesNotShift() throws {
        // The original opens with credits, which the parser drops; the
        // translation never had them. Pairing by position would put the first
        // translated line under the wrong lyric and every one after it too.
        let original = try #require(
            Lyrics.parse(
                """
                [00:00.00]作詞：某某
                [00:12.50]說完了
                [00:18.20]總是沉默對坐著
                """))
        let translated = original.withTranslation(
            """
            [00:12.50]It is all said
            [00:18.20]We only sit in silence
            """)

        #expect(translated.lines.count == 2)
        #expect(translated.lines[0].translation == "It is all said")
        #expect(translated.lines[1].translation == "We only sit in silence")
    }

    @Test("a line the translation does not cover keeps none")
    func unmatchedLinesStayUntranslated() throws {
        let original = try #require(
            Lyrics.parse(
                """
                [00:12.50]說完了
                [00:40.00]一句沒有被翻譯的話
                """))
        let translated = original.withTranslation("[00:12.50]It is all said")

        #expect(translated.lines[0].translation == "It is all said")
        // Rather than the nearest one from twenty-seven seconds away.
        #expect(translated.lines[1].translation == nil)
    }

    @Test("a translation identical to the words is not a translation")
    func echoesAreDropped() throws {
        // Some indexes return the original again when none exists. Shown, it
        // doubles every line on the stage for no purpose.
        let original = try #require(Lyrics.parse("[00:12.50]說完了"))
        let translated = original.withTranslation("[00:12.50]說完了")
        #expect(translated.lines[0].translation == nil)
    }

    @Test("nothing usable leaves the lyric exactly as it was")
    func rubbishIsIgnored() throws {
        let original = try #require(Lyrics.parse("[00:12.50]說完了"))
        #expect(original.withTranslation("not an lrc at all").lines == original.lines)
        #expect(original.withTranslation("").lines == original.lines)
    }
}
