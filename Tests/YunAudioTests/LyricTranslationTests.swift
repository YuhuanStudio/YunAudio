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

/// The stamps public indexes actually emit, as opposed to the ones the format
/// describes.
///
/// A file this parser rejects does not degrade — it collapses. Every line
/// without a recognised stamp is dropped, so a suffix on every line leaves no
/// lines at all, `parse` answers nil, and the panel falls back to drawing the
/// raw document: brackets in the text, and the production credits on the stage
/// because the filter that removes them only runs over parsed lines.
@Suite("Timestamps in the wild")
struct LyricTimestampToleranceTests {

    /// 「下雨天」 from NetEase, which is what put `[00:00.00-1] 作词 : Lara
    /// Liang/Zhang Jie` on screen.
    @Test("a NetEase line-length suffix does not cost the line its time")
    func neteaseSuffixParses() throws {
        #expect(Lyrics.timestamp("00:00.00-1") == 0)
        #expect(Lyrics.timestamp("01:15.50-12") == 75.5)
        // And the plain forms still read the same.
        #expect(Lyrics.timestamp("00:12.50") == 12.5)
        #expect(Lyrics.timestamp("00:12.500") == 12.5)
        #expect(Lyrics.timestamp("01:00") == 60)
    }

    /// Tolerated narrowly. A bracket holding something else must still end the
    /// header, or a tag would be read as a time and its value drawn as a lyric.
    @Test("only a hyphen and digits are forgiven")
    func onlyTheSuffixIsForgiven() {
        #expect(Lyrics.timestamp("00:00.00-") == nil)
        #expect(Lyrics.timestamp("00:00.00-x") == nil)
        #expect(Lyrics.timestamp("ti:Song") == nil)
        #expect(Lyrics.timestamp("offset:-500") == nil)
        #expect(Lyrics.timestamp("00:61.00-1") == nil)
    }

    /// The whole failure, end to end: the file parses, and the credits it
    /// opened with are gone from the stage.
    @Test("a file suffixed throughout parses and drops its credits")
    func suffixedFileParsesAndFiltersCredits() throws {
        let file = """
            [00:00.00-1] 作词 : Lara Liang/Zhang Jie
            [00:00.00-1] 作曲 : Lara Liang/Zhang Jie
            [00:18.50-1]下雨天了怎麼辦
            [00:22.10-1]我好想你
            """
        let lyrics = try #require(Lyrics.parse(file), "the file must not collapse")
        #expect(lyrics.lines.map(\.text) == ["下雨天了怎麼辦", "我好想你"])
        #expect(lyrics.lines.first?.time == 18.5)
        #expect(!lyrics.lines.contains { $0.text.contains("作词") })
        #expect(!lyrics.lines.contains { $0.text.contains("[") })
    }
}

/// The other door into the stage: the untimed field.
///
/// A file the parser cannot read is not shown as nothing — the indexes answer
/// with a second, untimed field and that is drawn instead. It was drawn
/// verbatim, so a document that was `.lrc` all along came back through here
/// with its brackets and its credits, which is what the timed path exists to
/// remove.
@Suite("Untimed words")
struct PlainLyricCleaningTests {

    @Test("bracketed heads and credits do not reach the stage")
    func headsAndCreditsAreRemoved() throws {
        let raw = """
            [00:00.00-1] 作词 : Lara Liang/Zhang Jie
            [00:00.00-1] 作曲 : Lara Liang/Zhang Jie
            [ti:下雨天]
            [00:18.50-1]下雨天了怎麼辦

            [00:22.10-1]我好想你
            """
        let words = try #require(Lyrics.plainWords(from: raw))
        // The blank between them survives as a stanza break; the `[ti:]` tag
        // above does not become one, because it was never a gap.
        #expect(words == "下雨天了怎麼辦\n\n我好想你")
    }

    /// Plain words that were always plain are left alone.
    @Test("words with no brackets pass through unchanged")
    func plainWordsSurvive() throws {
        let words = try #require(Lyrics.plainWords(from: "Hello darkness\nMy old friend"))
        #expect(words == "Hello darkness\nMy old friend")
    }

    /// A plain sheet's own structure is not `.lrc` syntax.
    ///
    /// The strip took every bracket at the head of a line, which deletes the
    /// section headings an untimed sheet exists to show.
    @Test("section headings and stage directions survive")
    func sheetStructureSurvives() throws {
        let words = try #require(
            Lyrics.plainWords(
                from: "[Verse 1]\nOpen your eyes: I'm still here\n[Chorus]\n[laughs] oh well"))
        #expect(
            words == "[Verse 1]\nOpen your eyes: I'm still here\n[Chorus]\n[laughs] oh well")
    }

    /// `op` and `sp` are real credit roles, and matched as bare prefixes they
    /// also match a lyric that begins with them.
    @Test("an English role must end where a word ends")
    func creditRolesRespectWordBoundaries() {
        #expect(!Lyrics.isCredit("Open your eyes: I'm still here"))
        #expect(!Lyrics.isCredit("Special: the way you are"))
        #expect(Lyrics.isCredit("OP : Universal"))
        #expect(Lyrics.isCredit("SP: Sony"))
        // The Chinese roles keep the loose prefix they need — what arrives is
        // the role in two languages at once.
        #expect(Lyrics.isCredit("作词 Lyricist : 翟云鹏"))
        #expect(Lyrics.isCredit("鼓Drum : 郝稷倫"))
    }

    /// Stanza breaks are the sheet's grouping, and flattening them turns a
    /// song into one block — but a run of six blanks is padding, not six rests.
    @Test("one stanza break is kept and a run of them is not")
    func stanzaBreaksCollapseToOne() throws {
        let words = try #require(
            Lyrics.plainWords(from: "\n\nfirst verse\n\n\n\nsecond verse\n\n"))
        #expect(words == "first verse\n\nsecond verse")
    }

    /// Nothing left is nil, not an empty stage — the caller can then fall
    /// through to another index instead of showing a blank.
    @Test("a document that is only credits has nothing to show")
    func creditsOnlyIsNil() {
        #expect(Lyrics.plainWords(from: "[00:00.00]作词 : A\n[00:01.00]编曲 : B") == nil)
        #expect(Lyrics.plainWords(from: "\n\n  \n") == nil)
    }
}
