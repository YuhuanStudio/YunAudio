import Testing

@testable import YunAudioEngine

/// What a public lyric index actually sends, as opposed to lyrics.
///
/// NetEase and QQ carry three things under the same timestamps: the words, the
/// production credits, and who sings which part. Only the first is a lyric, and
/// drawing all three is what put 「合」, 「王赫野」 and 「黃霄雲」 on the stage
/// between the lines, and opened 「慢冷」 on two lines of marketing credits.
@Suite("Lyric attribution")
struct LyricAttributionTests {

    @Test("production credits are not lines to sing")
    func creditsAreRecognised() {
        for credit in [
            "作詞：梁靜茹",
            "作曲 : 某某",
            "營銷推廣：什麼洋 / 榮兒 @ 網益文化 / 黃成成 @ C.Z· 夢想成真",
            "联合出品：华声时代×C.Z·梦想成真",
            "混音：Simon Li",
            "OP：Universal",
            "Produced by: Someone",
            "Mastered by : Someone Else",
        ] {
            #expect(Lyrics.isCredit(credit), "\(credit) was taken for a lyric")
        }
    }

    @Test("a lyric that contains a colon is still a lyric")
    func lyricsWithColonsSurvive() {
        for lyric in [
            "說完了 好像話都說完了",
            "他說：我們就到這裡吧，然後轉身走進了那個沒有燈的長廊",
            "3:00 a.m. and I am still awake",
        ] {
            #expect(!Lyrics.isCredit(lyric), "\(lyric) was taken for a credit")
        }
    }

    @Test("a line of nothing but a name says who sings the next one")
    func markersAttributeTheFollowingLines() throws {
        let text = """
            [00:01.00]合
            [00:02.00]痛快的離開我的依賴
            [00:03.00]王赫野
            [00:04.00]多少個忍著痛的夜晚你叫我別回來
            [00:05.00]黃霄雲
            [00:06.00]感情是偏執的
            """
        let lyrics = try #require(
            Lyrics.parse(text, performers: ["王赫野 / 黃霄雲"]))

        #expect(lyrics.lines.count == 3)
        #expect(lyrics.lines.map(\.text) == [
            "痛快的離開我的依賴",
            "多少個忍著痛的夜晚你叫我別回來",
            "感情是偏執的",
        ])
        #expect(lyrics.lines.map(\.singer) == ["合", "王赫野", "黃霄雲"])
        // The markers carried timestamps of their own. Taking them as lines
        // moved every real line one place later in the file, so the stage was
        // a line behind for the whole song as well as showing the names.
        #expect(lyrics.lines[0].time == 2)
    }

    @Test("the same thing written inline is read the same way")
    func inlineMarkersAreAttributed() throws {
        let text = """
            [00:02.00]王赫野：痛快的離開我的依賴
            [00:04.00]黃霄雲: 感情是偏執的
            """
        let lyrics = try #require(
            Lyrics.parse(text, performers: ["王赫野", "黃霄雲"]))

        #expect(lyrics.lines.map(\.text) == ["痛快的離開我的依賴", "感情是偏執的"])
        #expect(lyrics.lines.map(\.singer) == ["王赫野", "黃霄雲"])
    }

    @Test("a name is only a marker when the track names that performer")
    func unknownNamesStayLyrics() throws {
        let text = """
            [00:02.00]王赫野
            [00:04.00]痛快的離開我的依賴
            """
        // Nobody told the parser who is on this track, so the first line is a
        // line. Guessing that any short line is a name would eat 「說完了」.
        let anonymous = try #require(Lyrics.parse(text))
        #expect(anonymous.lines.count == 2)
        #expect(anonymous.lines[0].singer == nil)

        let known = try #require(Lyrics.parse(text, performers: ["王赫野"]))
        #expect(known.lines.count == 1)
        #expect(known.lines[0].singer == "王赫野")
    }

    @Test("a performer list arrives joined and is split on the way in")
    func joinedPerformerListsAreSplit() throws {
        let text = """
            [00:02.00]黃霄雲
            [00:04.00]感情是偏執的
            """
        for joined in ["王赫野 / 黃霄雲", "王赫野、黃霄雲", "王赫野, 黃霄雲", "王赫野 & 黃霄雲"] {
            let lyrics = try #require(Lyrics.parse(text, performers: [joined]))
            #expect(lyrics.lines.count == 1, "\(joined) did not split")
            #expect(lyrics.lines[0].singer == "黃霄雲")
        }
    }

    @Test("credits at the head do not become the opening lines")
    func creditsAtTheHeadAreDropped() throws {
        // 「慢冷」 as the index sends it: two credit lines before the first word.
        let text = """
            [00:00.00]營銷推廣：什麼洋 / 榮兒 @ 網益文化
            [00:00.50]聯合出品：華聲時代 × C.Z· 夢想成真
            [00:01.00]說完了 好像話都說完了
            """
        let lyrics = try #require(Lyrics.parse(text))
        #expect(lyrics.lines.count == 1)
        #expect(lyrics.lines[0].text == "說完了 好像話都說完了")
    }

    @Test("a file of nothing but credits has no words in it")
    func creditsOnlyFileIsNotLyrics() {
        let text = """
            [00:00.00]作詞：某某
            [00:01.00]作曲：某某
            """
        // Not an empty lyric with a timeline: nil, so the caller falls through
        // to the next index rather than displaying a blank stage.
        #expect(Lyrics.parse(text) == nil)
    }
}

/// The credit block of a real file, as an index actually sends it.
///
/// Taken from 年少心動雨季 — twenty lines before the first word, and every one
/// of them naming its role in Chinese and English at once. An exact match on
/// the role caught none of them.
@Suite("Real credit blocks")
struct RealCreditBlockTests {

    @Test("a bilingual role is still a role")
    func bilingualRolesAreCredits() {
        for credit in [
            "作词 Lyricist : 翟云鹏/冉亦/黄霄雲",
            "作曲Composer : 黄霄雲",
            "制作人Music Producer : 黄霄雲/马克",
            "编曲Arrangement : 马克/黄霄雲",
            "键盘Keyboard : 马克",
            "配唱制作人Vocal Producer : 黄霄雲",
            "和声编写Backing Vocal : 黄霄雲",
            "吉他Guitar : 朱家明",
            "鼓Drum : 郝稷伦",
            "贝斯Bass : 彭轩/孟凡荻",
            "监制 : 许雯静/彭轩/卢冠囝",
            "录音 Recording Engineer : 孔令祎@TONGX",
            "音频编辑 : 商红阳",
            "混音 Mixing Engineer : 刘俊杰",
            "母带 Mastering : 时俊峰@福达录音棚",
            "后期母带处理制作人MASTERING PRODUCER : 黄霄雲",
            "OP : 回音如果",
            "SP : 回音如果",
            "出品 : 环球音乐",
        ] {
            #expect(Lyrics.isCredit(credit), "\(credit) was taken for a lyric")
        }
    }

    @Test("the first sung line survives the block above it")
    func theSongStartsAtItsFirstWord() throws {
        let text = """
            [00:00.00] 作词 Lyricist : 翟云鹏/冉亦/黄霄雲
            [00:09.00] 鼓Drum : 郝稷伦
            [00:19.00] 出品 : 环球音乐
            [00:23.67]落叶像逾期约定
            [00:29.22]在风中四散飘零
            """
        let lyrics = try #require(Lyrics.parse(text))
        #expect(lyrics.lines.count == 2)
        #expect(lyrics.lines.first?.text == "落叶像逾期约定")
        // And it starts where it is sung, not at zero.
        #expect(lyrics.lines.first?.time == 23.67)
    }
}
