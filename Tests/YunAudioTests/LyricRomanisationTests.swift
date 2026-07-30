import Testing

@testable import YunAudioApp

/// Pronunciation for a singer who can follow the tune but not the characters.
@Suite("Lyric romanisation")
struct LyricRomanisationTests {

    @Test("a Chinese line is romanised without its tone marks")
    func chineseIsRomanised() throws {
        let latin = try #require(LyricRomanisation.of("說完了"))
        // Diacritics stripped: a tone mark under a lyric at speed is noise, and
        // the characters above carry the meaning anyway.
        #expect(latin.lowercased().contains("shuo"))
        #expect(!latin.contains("ō"))
    }

    @Test("a Latin line gets none, rather than a copy of itself")
    func latinLinesAreLeftAlone() {
        #expect(LyricRomanisation.of("It is all said") == nil)
        #expect(LyricRomanisation.of("") == nil)
        #expect(LyricRomanisation.of("   ") == nil)
        #expect(LyricRomanisation.of("♪ ♪ ♪") == nil)
    }

    @Test("the decision is per line, not per song")
    func mixedSongsAreDecidedLineByLine() {
        // A Chinese song with an English chorus romanises the verses and leaves
        // the chorus alone.
        #expect(LyricRomanisation.needsRomanising("原来年少心动"))
        #expect(!LyricRomanisation.needsRomanising("Never to arrive"))
        // And a line that mixes them counts as needing it.
        #expect(LyricRomanisation.needsRomanising("說完了 baby"))
    }

    @Test("kana and hangul are covered too")
    func otherScriptsAreCovered() {
        #expect(LyricRomanisation.needsRomanising("さよなら"))
        #expect(LyricRomanisation.needsRomanising("사랑해"))
    }

    @Test("the same line twice costs one transform")
    func repeatsAreCached() throws {
        let first = try #require(LyricRomanisation.of("注定了无法走进同一个晴天里"))
        let second = try #require(LyricRomanisation.of("注定了无法走进同一个晴天里"))
        #expect(first == second)
    }
}
