import Testing

@testable import YunAudioApp

/// Titles that name the same song without being the same string.
///
/// Measured against the real case: Spotify reports 「來不及愛妳」 and NetEase
/// indexes 「来不及爱你」, both by h3R3 and both 205 seconds, and the song has a
/// full timed lyric. It came back with nothing. `妳` is not a traditional form
/// of `你` — it is its own character — so ICU's Hant-Hans leaves it alone, and
/// Foundation transliterates it "nai" against 你 as "ni", which is what broke
/// the pinyin fallback that exists for exactly this.
@Suite("Lyric title matching")
struct LyricTitleMatchTests {

    @Test("one script, then one character in five, is the same song")
    func oneEditIsTheSameSong() {
        // ICU folds the systematic half — 來→来 and 愛→爱 — and leaves 妳 alone.
        #expect(OnlineLyrics.simplified("來不及愛妳") == "来不及爱妳")
        #expect(
            OnlineLyrics.isNearly(
                OnlineLyrics.simplified("來不及愛妳"),
                OnlineLyrics.simplified("来不及爱你")))
    }

    @Test("the script fold alone settles most of them")
    func scriptFoldIsUsuallyEnough() {
        #expect(OnlineLyrics.simplified("無人之島") == OnlineLyrics.simplified("无人之岛"))
        #expect(OnlineLyrics.simplified("年少心動雨季") == OnlineLyrics.simplified("年少心动雨季"))
    }

    @Test("a different song of the same length is not")
    func differentSongsStayDifferent() {
        #expect(!OnlineLyrics.isNearly("慢冷", "慢熱"))
        #expect(!OnlineLyrics.isNearly("说完了好像话都说完了", "总是沉默对坐着"))
        #expect(!OnlineLyrics.isNearly("無人之島", "疑心病"))
    }

    @Test("short titles are compared exactly")
    func shortTitlesAreExact() {
        // At three characters one edit is a third of the title, which is not a
        // spelling difference — it is a different song.
        #expect(!OnlineLyrics.isNearly("那年", "那天"))
        #expect(OnlineLyrics.isNearly("那年", "那年"))
    }

    @Test("the budget grows with the title, but only slowly")
    func budgetScalesWithLength() {
        // Eight characters tolerate two edits.
        #expect(OnlineLyrics.isNearly("一二三四五六七八", "一二三四五六XY"))
        #expect(!OnlineLyrics.isNearly("一二三四五六七八", "一二三四五XYZ"))
        // A title far longer than the other is not a spelling of it.
        #expect(!OnlineLyrics.isNearly("來不及愛妳", "來不及愛妳的那個下午"))
    }
}
