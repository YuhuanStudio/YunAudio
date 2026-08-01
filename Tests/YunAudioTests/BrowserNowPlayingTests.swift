import Foundation
import Testing

@testable import YunAudioApp

/// Reading a song out of a browser tab.
///
/// The event itself needs a browser, a setting somebody has turned on, and a
/// tab with music in it — none of which a test has. What a test can hold is
/// everything either side of the event: the script that goes out, and the
/// answer that comes back.
@Suite("Browser now playing")
struct BrowserNowPlayingTests {

    private let separator = BrowserNowPlaying.separator

    private func reply(_ fields: String...) -> String {
        fields.joined(separator: BrowserNowPlaying.separator)
    }

    @Test("the JavaScript survives being put inside an AppleScript string")
    func theScriptIsEscapedOnce() {
        let script = BrowserNowPlaying.script(
            forBrowser: "Safari", javaScript: BrowserNowPlaying.readingScript)
        // The reading script carries no double quote of its own — single
        // quotes throughout, and `String.fromCharCode(31)` where an escape
        // would otherwise be needed. A quote surviving two layers of escaping
        // intact is a coin toss, and losing it does not fail loudly: it
        // compiles into a different program.
        #expect(!BrowserNowPlaying.readingScript.contains("\""))
        // The backslashes it does carry — a regular expression — come out
        // doubled, which is the escaping having run exactly once. Left single
        // they would be eaten by AppleScript and the pattern would arrive
        // meaning something else.
        #expect(BrowserNowPlaying.readingScript.contains("\\("))
        #expect(script.contains("\\\\("))
        // The escaping is still there for anything that does carry one, and
        // does backslashes before quotes — the other order escapes the
        // escapes.
        #expect(
            BrowserNowPlaying.escapedForAppleScript("a\"b") == "a\\\"b")
        #expect(
            BrowserNowPlaying.escapedForAppleScript("a\\b") == "a\\\\b")
        // And each browser is asked in its own dialect.
        #expect(script.contains("do JavaScript theCode in theTab"))
        #expect(
            BrowserNowPlaying.script(
                forBrowser: "Google Chrome", javaScript: "1"
            ).contains("execute theTab javascript theCode"))
    }

    @Test("every window is searched, not just the front one")
    func everyTabIsAsked() {
        // Music plays in a tab left behind three windows ago. A reader that
        // only asks the front tab would answer nothing for the case that makes
        // this worth having.
        let script = BrowserNowPlaying.script(forBrowser: "Safari", javaScript: "1")
        #expect(script.contains("repeat with theWindow in windows"))
        #expect(script.contains("repeat with theTab in tabs of theWindow"))
        // And a browser that is not open is not launched by asking.
        #expect(script.contains("if it is not running then return \"\""))
    }

    @Test("a tab with a song in it becomes a track")
    func aSongIsRead() throws {
        let track = try #require(
            BrowserNowPlaying.parse(
                reply("周杰倫 - 稻香", "周杰倫", "42.5", "223.1", "playing", "https://x/watch?v=1"),
                browser: "Safari"))
        #expect(track.title == "稻香")
        #expect(track.artist == "周杰倫")
        #expect(track.application == "Safari")
        #expect(abs(track.position - 42.5) < 0.01)
        #expect(abs(track.duration - 223.1) < 0.01)
        #expect(track.isPlaying)
        // The URL, so a change of video is noticed without asking what it is.
        #expect(track.identity == "https://x/watch?v=1")
    }

    @Test("a stream and an advert are not songs")
    func unusableTabsAreRefused() {
        // A live stream reports an infinite duration and an advert a zero one.
        // Neither is something to put a lyric under, and both would otherwise
        // replace the song somebody was actually singing.
        #expect(
            BrowserNowPlaying.parse(
                reply("live", "", "10", "inf", "playing", "u"), browser: "Safari") == nil)
        #expect(
            BrowserNowPlaying.parse(
                reply("advert", "", "1", "11", "playing", "u"), browser: "Safari") == nil)
        #expect(BrowserNowPlaying.parse("", browser: "Safari") == nil)
        #expect(
            BrowserNowPlaying.parse(
                reply("", "", "1", "10", "playing", "u"), browser: "Safari") == nil)
    }

    @Test("a page whose video is not media is not a song")
    func decorativeVideosAreRefused() {
        // Observed, not imagined: a sweep without the guards answered from a
        // GitHub project page — a `<video>` in a README with no source and a
        // duration of NaN. Unguarded it would have become the song, and the
        // application would have looked up lyrics for the name of a
        // repository. The reading script refuses it in the tab; this is the
        // second refusal, for the case where a browser answers anyway.
        #expect(
            BrowserNowPlaying.parse(
                reply(
                    "jingyaogong/minimind-o", "", "0", "NaN", "paused", "https://github.com/x"),
                browser: "Safari") == nil)
        #expect(
            BrowserNowPlaying.parsePosition(reply("https://github.com/x", "NaN", "paused"))
                == nil)
    }

    @Test("the three real titles YouTube answered with")
    func realTitlesAreParsed() {
        // Taken from YouTube's own oEmbed, not imagined. The first version of
        // this parser was written from what a title looks like in the
        // imagination and all three of the first three real ones defeated it.
        let rainy = BrowserNowPlaying.splitTitle(
            "Huang Xiaoyun 黄霄雲 – The Rainy Season of a Youthful Crush《年少心动雨季》Live | Shangyu 2026",
            channel: "Xiaoyun Heavenly Voice")
        #expect(rainy.title == "年少心动雨季")
        #expect(rainy.artist == "黄霄雲")

        let rice = BrowserNowPlaying.splitTitle(
            "周杰倫 Jay Chou【稻香 Rice Field】-Official Music Video",
            channel: "周杰倫 Jay Chou")
        #expect(rice.title == "稻香")
        #expect(rice.artist == "周杰倫")

        let memories = BrowserNowPlaying.splitTitle(
            "尤雅 - 往事只能回味『春風又吹紅了花蕊 你已經也添了新歲，你就要變心 像時光難倒回，"
                + "我只有在夢裡相依偎。』【動態歌詞/Vietsub/Pinyin Lyrics】",
            channel: "EHPMusicChannel")
        #expect(memories.title == "往事只能回味")
        #expect(memories.artist == "尤雅")
    }

    @Test("the whole path, from what the tab would really report")
    func documentTitlesAreWhatTheTabReports() {
        // `document.title` on a watch page is the video's title with 「 - YouTube」
        // appended, and a 「(3) 」 prefix while notifications are waiting. Both
        // were verified against the real pages: for all three videos, the
        // `<title>` element less that suffix is character-for-character the
        // title YouTube's own oEmbed reports. So a reply built from
        // `document.title` is the same string the tests above are pinned to,
        // once the reading script has removed those two.
        for (documentTitle, song, artist) in [
            (
                "(3) 周杰倫 Jay Chou【稻香 Rice Field】-Official Music Video - YouTube",
                "稻香", "周杰倫"
            ),
            (
                "Huang Xiaoyun 黄霄雲 – The Rainy Season of a Youthful Crush"
                    + "《年少心动雨季》Live | Shangyu 2026 - YouTube",
                "年少心动雨季", "黄霄雲"
            ),
        ] {
            // What the script strips before anything else sees it.
            let asRead =
                documentTitle
                .replacingOccurrences(
                    of: " - YouTube$", with: "", options: .regularExpression
                )
                .replacingOccurrences(
                    of: "^\\(\\d+\\) ", with: "", options: .regularExpression)
            let parsed = BrowserNowPlaying.splitTitle(asRead, channel: "")
            #expect(parsed.title == song)
            #expect(parsed.artist == artist)
        }
    }

    @Test("the tab that was actually open, advert and all")
    func theLiveTabIsParsed() {
        // Read off a real Safari tab: a televised performance, playing an
        // eleven-second mid-roll advert at the moment it was asked.
        let advert = BrowserNowPlaying.parse(
            reply(
                "【纯享版】《失眠》原唱登场 Suki刘舒妤温柔嗓音缓缓铺开深夜emo氛围 #天赐的声音7 EP6",
                "中國浙江衛視官方頻道 Zhejiang STV Official Channel - 歡迎訂閱",
                "10.235715667", "11.0735", "playing",
                "https://www.youtube.com/watch?v=Br2BdijMQ1Y"),
            browser: "Safari")
        // For those eleven seconds the stage would have taken the advert as
        // the song, looked for its words, and thrown away the one it was on.
        #expect(advert == nil)

        // The same tab once the song itself is playing.
        let song = BrowserNowPlaying.parse(
            reply(
                "【纯享版】《失眠》原唱登场 Suki刘舒妤温柔嗓音缓缓铺开深夜emo氛围 #天赐的声音7 EP6",
                "中國浙江衛視官方頻道 Zhejiang STV Official Channel - 歡迎訂閱",
                "62.5", "281.0", "playing", "https://www.youtube.com/watch?v=Br2BdijMQ1Y"),
            browser: "Safari")
        // 《》 outranks 【】: the first is the song, the second is a label the
        // programme put on the upload.
        #expect(song?.title == "失眠")
        // And 「纯享版」 is not a person. With every bracket group taken out of
        // the credit there is nothing left, so the channel stands.
        #expect(song?.artist.contains("纯享") == false)
    }

    @Test("the whole chain, on the tab that was open, with the song playing")
    func theLiveTabResolvesToTheRightSong() throws {
        // Read off the same Safari tab once the song itself was playing, and
        // then put to the real index. This is the end of the chain: a tab, a
        // parser, a lyric provider, one song.
        let track = try #require(
            BrowserNowPlaying.parse(
                reply(
                    "【純享版】苦情歌天后遇上新生代實力Vocal！張碧晨徐子未心碎演繹《情結》"
                        + "開口定調！淚腺崩塌就在一瞬間！#天賜的聲音6 EP7 20250530",
                    "中國浙江衛視官方頻道 Zhejiang STV Official Channel - 歡迎訂閱 -",
                    "88.66927702", "217.021", "paused",
                    "https://www.youtube.com/watch?v=EkxJTjYGD70"),
                browser: "Safari"))
        #expect(track.title == "情結")
        // Everything before the name is a presenter's line, not a credit.
        // Taken as the artist it becomes twelve characters of advertising in
        // a lyric query, so it falls back to the channel.
        #expect(!track.artist.contains("苦情歌"))
        // And the length is carried, which is what settles it: asked for
        // 「情結」 the index answers 情结/徐子未 at 217 s, a Live version at
        // 222, and two other songs of the same name at 242 and 121. Only the
        // duration tells them apart, and only the tab knows it.
        #expect(abs(track.duration - 217.021) < 0.01)
        #expect(track.artworkURL?.absoluteString.contains("EkxJTjYGD70") == true)
    }

    @Test("a song with no Chinese in it is left exactly as it is")
    func latinTitlesAreUntouched() {
        // The Han preference must be a no-op for everything it was not written
        // for, which is most of the music in the world.
        let wonderwall = BrowserNowPlaying.splitTitle("Wonderwall", channel: "Oasis")
        #expect(wonderwall.title == "Wonderwall")
        #expect(wonderwall.artist == "Oasis")

        let never = BrowserNowPlaying.splitTitle(
            "Rick Astley - Never Gonna Give You Up (Official Video)",
            channel: "Rick Astley")
        #expect(never.title == "Never Gonna Give You Up")
        #expect(never.artist == "Rick Astley")
        // A hyphen inside a word is not a credit.
        #expect(BrowserNowPlaying.splitTitle("Spider-Man", channel: "x").title == "Spider-Man")
    }

    @Test("a name in brackets beats a credit outside them")
    func bracketsNameTheSong() {
        #expect(BrowserNowPlaying.bracketedName(in: "x《稻香》y") == "稻香")
        #expect(BrowserNowPlaying.bracketedName(in: "x【稻香】y") == "稻香")
        // A sentence in brackets is not a name, and taking it would replace
        // the title with a line of the lyric.
        #expect(
            BrowserNowPlaying.bracketedName(
                in: "【春風又吹紅了花蕊你已經也添了新歲你就要變心像時光難倒回】") == nil)
        #expect(BrowserNowPlaying.bracketedName(in: "no brackets") == nil)
    }

    @Test("an automatic channel's label is not part of anybody's name")
    func topicChannelsAreCleaned() {
        // YouTube appends 「 - Topic」 to the channels it generates.
        #expect(BrowserNowPlaying.splitTitle("稻香", channel: "周杰倫 - Topic").artist == "周杰倫")
    }

    @Test("the transport asks the page rather than inventing a queue")
    func transportUsesThePlayer() {
        // A tab has no queue. What "next" means on YouTube is whatever the
        // page says, so next and previous reach for the page's own buttons.
        #expect(BrowserNowPlaying.script(for: .next)?.contains("ytp-next-button") == true)
        #expect(BrowserNowPlaying.script(for: .previous)?.contains("ytp-prev-button") == true)
        #expect(BrowserNowPlaying.script(for: .playPause)?.contains("v.pause()") == true)
    }

    @Test("the tab is polled with a smaller question than it is read with")
    func thePositionScriptIsCheap() {
        // Asked twenty times a second against once a song: no title, no
        // channel, no regular expression, three fields.
        #expect(!BrowserNowPlaying.positionScript.contains("document.title"))
        #expect(!BrowserNowPlaying.positionScript.contains("querySelector('ytd"))
        #expect(BrowserNowPlaying.positionScript.count < BrowserNowPlaying.readingScript.count)

        // Not `#require`: `parsePosition` returns a non-optional here, so the
        // macro was checking against nil for a value that cannot be one, and
        // said so.
        let answer = BrowserNowPlaying.parsePosition(
            reply("https://y/watch?v=abc", "61.25", "playing"))
        #expect(answer?.identity == "https://y/watch?v=abc")
        #expect(abs((answer?.seconds ?? 0) - 61.25) < 0.001)
        #expect(answer?.isPlaying == true)
        // A tab with no usable video answers nothing rather than zero, or the
        // words would follow a song that is not playing.
        #expect(BrowserNowPlaying.parsePosition("") == nil)
        #expect(BrowserNowPlaying.parsePosition(reply("u", "x", "playing")) == nil)
    }

    @Test("a video's own picture is taken from the address, without asking")
    func artworkComesFromTheAddress() throws {
        // No request is made to find this out: the identifier is in the URL the
        // tab already reported. Without it a song played from a browser is the
        // one kind with no cover behind the words, which is the arrangement the
        // whole stage is built around.
        #expect(
            BrowserNowPlaying.artworkURL(forTab: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")?
                .absoluteString == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        #expect(
            BrowserNowPlaying.artworkURL(forTab: "https://youtu.be/dQw4w9WgXcQ")?
                .absoluteString == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        // Anywhere else, and anything that is not an identifier, gets nothing
        // rather than a guessed address.
        #expect(BrowserNowPlaying.artworkURL(forTab: "https://example.com/watch?v=a") == nil)
        #expect(BrowserNowPlaying.artworkURL(forTab: "https://www.youtube.com/") == nil)
        #expect(
            BrowserNowPlaying.artworkURL(forTab: "https://www.youtube.com/watch?v=a/../b")
                == nil)
    }

    @Test("a browser refusing JavaScript is told apart from one refusing the event")
    func theRefusalHasItsOwnRemedy() {
        // The two look the same from outside and have different remedies. Told
        // "could not be read (Apple Event -2741)" somebody would open System
        // Settings, find the automation permission already granted, and
        // conclude the feature is broken — while the switch that would fix it
        // is in a menu they have never opened.
        for code in [-2741, -1743, 4] {
            #expect(
                NowPlaying.queryFailure(application: "Safari", code: code)
                    == .javaScriptNotAllowed(application: "Safari"))
        }
        // A music player answering the same code means something else: it has
        // no JavaScript switch to turn on.
        #expect(
            NowPlaying.queryFailure(application: "Spotify", code: -2741)
                == .failed(application: "Spotify", code: -2741))
        // And the ordinary refusals keep their own meanings for a browser too.
        #expect(
            NowPlaying.queryFailure(application: "Safari", code: Int(errAETimeout))
                == .timedOut(application: "Safari"))
    }

    @Test("a browser is never asked at the polling rate")
    func browsersAreKeptOffThePollPath() {
        // Measured on this machine with ten tabs open, less `osascript`'s own
        // 37 ms of startup: one tab one evaluation is 88 ms, a sweep of ten is
        // 171 ms. The position poll runs at twenty hertz — a fifty-millisecond
        // budget — so either of those is over it by itself and the sweep by
        // three times. Both intervals must stay well clear of that.
        #expect(NowPlaying.browserAskInterval >= 0.5)
        #expect(NowPlaying.browserSweepInterval >= NowPlaying.browserAskInterval)
    }

    @Test("every browser but Safari is spoken to in Chrome's dialect")
    func chromiumForksShareOneScript() {
        // The dispatch is "Safari or not Safari", so a fork only has to be in
        // the list to be reached. That is the whole cost of supporting one, and
        // it is why leaving Edge or Brave out was never a saving.
        for browser in BrowserNowPlaying.browsers where browser.name != "Safari" {
            let script = BrowserNowPlaying.script(
                forBrowser: browser.name, javaScript: "1")
            #expect(
                script.contains("execute theTab javascript"),
                Comment(rawValue: "\(browser.name) is not being asked in Chromium's dialect"))
            #expect(!script.contains("do JavaScript"))
        }
        let safari = BrowserNowPlaying.script(forBrowser: "Safari", javaScript: "1")
        #expect(safari.contains("do JavaScript theCode in theTab"))
    }

    @Test("no two browsers claim the same identity")
    func browserIdentitiesAreDistinct() {
        // A duplicated bundle identifier would make one browser answer for
        // another's tabs, and a duplicated name would make the failure message
        // point at the wrong application.
        let identifiers = BrowserNowPlaying.browsers.map(\.bundleID)
        #expect(Set(identifiers).count == identifiers.count)
        let names = BrowserNowPlaying.browsers.map(\.name)
        #expect(Set(names).count == names.count)
        // Safari first: it is the one browser on every Mac, so it is the one
        // most likely to answer, and the sweep stops at the first that does.
        #expect(BrowserNowPlaying.browsers.first?.name == "Safari")
    }

    @Test("the wider corpus of real titles YouTube answered with")
    func aWiderCorpusIsParsed() {
        // Five more, fetched the same way, chosen to be different shapes
        // rather than more of the same — and two of them broke the parser as
        // it stood.
        let cases: [(title: String, channel: String, song: String, artist: String)] = [
            // 慢冷 itself. The bracket is a tagline the uploader wrote,
            // and it is short enough to look like a name — taking it made
            // the song's title a line of advertising.
            (
                "梁靜茹 Fish Leong - 慢冷 Slow-To-Cool-Down【慢冷的人啊，會自我折磨】[ 歌詞 ]",
                "TWKchannel", "慢冷", "梁靜茹"
            ),
            // Japanese titles are quoted, not bracketed. Treating 「」 as a
            // lyric quote deleted the song's name and left the channel and
            // the words 「Official Music Video」.
            ("YOASOBI「夜に駆ける」 Official Music Video", "YOASOBI", "夜に駆ける", "YOASOBI"),
            // These two already worked, and must go on working.
            (
                "五月天 Mayday【溫柔 Tenderness】台視 2000年「俠女闖天關」片尾主題曲 Official Music Video",
                "滾石唱片 ROCK RECORDS", "溫柔", "五月天"
            ),
            ("Hype Boy", "NewJeans - Topic", "Hype Boy", "NewJeans"),
        ]
        for one in cases {
            let parsed = BrowserNowPlaying.splitTitle(one.title, channel: one.channel)
            #expect(parsed.title == one.song, Comment(rawValue: one.title))
            #expect(parsed.artist == one.artist, Comment(rawValue: one.title))
        }
    }

    @Test("the answer carried between asks is the answer, not a guess")
    func carriedPositionsAdvance() throws {
        // No sleeping. A wall-clock wait inside the full suite is a race
        // against a saturated executor — the lesson this session already paid
        // for twice — so what is checked is the arithmetic at the moment it is
        // asked, where the elapsed time is nearly zero.
        let playing = NowPlaying.Position(
            application: "Safari", identity: "u", seconds: 10, isPlaying: true)
        NowPlaying.rememberBrowserPosition(playing, for: "Safari")
        let carried = try #require(NowPlaying.carriedBrowserPosition(for: "Safari"))
        // Advanced by the elapsed time, which here is almost none — and never
        // by more than the interval, because past that it is asked again.
        #expect(carried.seconds >= 10)
        #expect(carried.seconds < 10 + NowPlaying.browserAskInterval)
        #expect(carried.identity == "u")
        #expect(carried.isPlaying)

        // A paused song does not move, and carrying it forward as if it did
        // would run the words on without it.
        let paused = NowPlaying.Position(
            application: "Safari", identity: "u", seconds: 10, isPlaying: false)
        NowPlaying.rememberBrowserPosition(paused, for: "Safari")
        #expect(NowPlaying.carriedBrowserPosition(for: "Safari")?.seconds == 10)

        // And forgetting one means the next poll asks rather than carrying a
        // song that has gone.
        NowPlaying.rememberBrowserPosition(nil, for: "Safari")
        #expect(NowPlaying.carriedBrowserPosition(for: "Safari") == nil)
    }

    @Test("seeking is bounded and never asks for a position that is not one")
    func seekingIsBounded() {
        #expect(BrowserNowPlaying.seekScript(toSeconds: 12.5).contains("12.500"))
        #expect(BrowserNowPlaying.seekScript(toSeconds: -4).contains("0.000"))
        #expect(BrowserNowPlaying.seekScript(toSeconds: .nan).contains("0.000"))
    }
}
