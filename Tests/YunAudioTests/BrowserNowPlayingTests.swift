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
                reply("advert", "", "1", "0", "playing", "u"), browser: "Safari") == nil)
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
                reply("jingyaogong/minimind-o", "", "0", "NaN", "paused", "https://github.com/x"),
                browser: "Safari") == nil)
        #expect(BrowserNowPlaying.parsePosition(reply("https://github.com/x", "NaN", "paused")) == nil)
    }

    @Test("a title that is not a credit is left whole")
    func onlyRealCreditsAreSplit() {
        // 「Wonderwall」 must not become 「Wonder」 and 「wall」: only a hyphen
        // with space either side, and only when both halves have something.
        #expect(BrowserNowPlaying.splitTitle("Wonderwall", channel: "Oasis").title == "Wonderwall")
        #expect(BrowserNowPlaying.splitTitle("Wonderwall", channel: "Oasis").artist == "Oasis")
        #expect(BrowserNowPlaying.splitTitle("Spider-Man", channel: "x").title == "Spider-Man")
        #expect(BrowserNowPlaying.splitTitle("- lonely -", channel: "x").title == "- lonely -")
    }

    @Test("an automatic channel's label is not part of anybody's name")
    func topicChannelsAreCleaned() {
        // YouTube appends 「 - Topic」 to the channels it generates, and a
        // lyric index has never heard of an artist called that.
        #expect(
            BrowserNowPlaying.splitTitle("稻香", channel: "周杰倫 - Topic").artist == "周杰倫")
    }

    @Test("what an uploader wraps round a title is removed")
    func decorationIsStripped() {
        #expect(
            BrowserNowPlaying.strippedDecoration("稻香 (Official Music Video)") == "稻香")
        #expect(BrowserNowPlaying.strippedDecoration("稻香【完整版】") == "稻香")
        #expect(BrowserNowPlaying.strippedDecoration("稻香 [HD]") == "稻香")
        // And what is part of the title stays: a bracket is not decoration
        // just for being a bracket.
        #expect(
            BrowserNowPlaying.strippedDecoration("年少心動雨季 (那年盛夏)")
                == "年少心動雨季 (那年盛夏)")
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

        let answer = try? #require(
            BrowserNowPlaying.parsePosition(
                reply("https://y/watch?v=abc", "61.25", "playing")))
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
            BrowserNowPlaying.artworkURL(forTab: "https://www.youtube.com/watch?v=a/../b") == nil)
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

    @Test("seeking is bounded and never asks for a position that is not one")
    func seekingIsBounded() {
        #expect(BrowserNowPlaying.seekScript(toSeconds: 12.5).contains("12.500"))
        #expect(BrowserNowPlaying.seekScript(toSeconds: -4).contains("0.000"))
        #expect(BrowserNowPlaying.seekScript(toSeconds: .nan).contains("0.000"))
    }
}
