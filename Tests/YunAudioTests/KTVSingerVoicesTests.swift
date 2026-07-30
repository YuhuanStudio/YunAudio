import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

/// Telling one voice from the other at a glance.
@Suite("KTV singer voices")
struct KTVSingerVoicesTests {

    private func duet() -> Lyrics {
        Lyrics.parse(
            """
            [00:00.00]王赫野
            [00:01.00]痛快的离开
            [00:05.00]黃霄雲
            [00:06.00]再多说一句都是错
            [00:10.00]合
            [00:11.00]我们都不必再回头
            [00:15.00]王赫野
            [00:16.00]天亮之前
            """, performers: ["王赫野", "黃霄雲"])!
    }

    @Test("a solo song takes no colours at all")
    func oneVoiceIsNotADuet() {
        let solo = Lyrics.parse("[00:00.00]告别总来不及练习\n[00:04.00]我只追到你的背影")
        let voices = KTVSingerVoices(solo)
        #expect(!voices.isDuet)
        #expect(voices.colour(for: nil) == nil)
        // Tinting every line of a solo song only makes the stage yellow. The
        // whole point is the contrast between two voices.
        #expect(voices.colour(for: "王赫野") == nil)
    }

    @Test("each voice keeps one colour for the whole song")
    func aVoiceKeepsItsColour() {
        let voices = KTVSingerVoices(duet())
        #expect(voices.isDuet)
        let first = voices.colour(for: "王赫野")
        let second = voices.colour(for: "黃霄雲")
        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
        // The fourth line is his again, four lines later.
        #expect(voices.colour(for: "王赫野") == first)
    }

    @Test("the colours follow the order the song hands out lines")
    func orderIsFirstAppearance() {
        let voices = KTVSingerVoices(duet())
        // 王赫野 opens, so he is the first colour — not because he sorts first,
        // which he does not.
        #expect(voices.colour(for: "王赫野") == KTVSingerVoices.palette[0])
        #expect(voices.colour(for: "黃霄雲") == KTVSingerVoices.palette[1])
    }

    @Test("a chorus line belongs to no voice and stays white")
    func chorusTakesNoColour() {
        let voices = KTVSingerVoices(duet())
        // Colouring 「合」 as a third singer would say the opposite of what it
        // means. White is what the stage draws when the line is everybody's.
        #expect(voices.colour(for: "合") == nil)
        #expect(voices.colour(for: "Both") == nil)
        #expect(voices.colour(for: "chorus") == nil)
    }

    @Test("an unnamed line takes no colour")
    func linesWithoutASingerAreLeftAlone() {
        let voices = KTVSingerVoices(duet())
        #expect(voices.colour(for: nil) == nil)
        #expect(voices.colour(for: "   ") == nil)
        // A name the file never used is not a voice in this song.
        #expect(voices.colour(for: "周杰倫") == nil)
    }

    @Test("a song with no words has no voices")
    func noLyricsIsNotADuet() {
        let voices = KTVSingerVoices(nil)
        #expect(!voices.isDuet)
        #expect(voices.colour(for: "anybody") == nil)
    }

    @Test("more soloists than colours cycle rather than run out")
    func thePaletteCycles() {
        let many = Lyrics.parse(
            (1...6).map { "[00:0\($0).00]歌手\($0)\n[00:0\($0).50]一句歌词" }
                .joined(separator: "\n"),
            performers: (1...6).map { "歌手\($0)" })
        let voices = KTVSingerVoices(many)
        #expect(voices.isDuet)
        // The fifth soloist takes the first colour again. Inventing four more
        // colours nobody can tell apart would be worse than repeating.
        #expect(voices.colour(for: "歌手5") == voices.colour(for: "歌手1"))
    }
}
