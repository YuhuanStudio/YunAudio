import Foundation
import Testing

@testable import YunAudioApp

@Suite("Multiple independent lyric sources")
struct OnlineLyricsTests {
    private func response(
        for request: URLRequest, status: Int = 200
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: nil)!
    }

    @Test("a Chinese timed result beats an independent plain fallback")
    func qqTimedLyricsWin() async throws {
        let client = OnlineLyrics { request in
            let url = try #require(request.url)
            let body: String
            switch (url.host, url.path) {
            case ("lrclib.net", _):
                body =
                    """
                    [{
                      "trackName":"年少心动雨季 (伴奏)","artistName":"黄霄雲",
                      "albumName":"年少心动雨季","duration":265,
                      "plainLyrics":"wrong backing edition",
                      "syncedLyrics":"[00:01.00]wrong backing edition"
                    }]
                    """
            case ("api.lyrics.ovh", _):
                body = #"{"lyrics":"plain fallback"}"#
            case ("music.163.com", _):
                body = #"{"result":{"songs":[]}}"#
            case ("c.y.qq.com", let path) where path.contains("client_search"):
                body =
                    """
                    {"data":{"song":{"list":[{
                      "songmid":"001QqXit4TUwv2","songname":"年少心动雨季",
                      "albumname":"年少心动雨季","interval":265,
                      "singer":[{"name":"黄霄雲"}]
                    }]}}}
                    """
            case ("c.y.qq.com", let path) where path.contains("lyric"):
                body =
                    #"{"lyric":"[00:18.96]晚风里藏着 多少精灵\n[00:25.65]满天的星辰 都被唤醒"}"#
            default:
                Issue.record("unexpected request \(url)")
                body = "{}"
            }
            return (Data(body.utf8), response(for: request))
        }
        let match = try #require(
            try await client.fetch(
                .init(
                    title: "年少心动雨季", artist: "黄霄雲",
                    album: "年少心动雨季", duration: 265)))
        #expect(match.source == .qqMusic)
        #expect(match.parsed?.lines.count == 2)
        #expect(abs((match.parsed?.lines[0].time ?? 0) - 18.96) < 0.001)
        #expect(match.cacheExtension == "lrc")
    }

    @Test("all four databases are started together")
    func sourcesAreConcurrent() async throws {
        actor Probe {
            var waiting: [CheckedContinuation<Void, Never>] = []
            var arrivals = 0

            func arrive() async {
                arrivals += 1
                if arrivals == 4 {
                    let held = waiting
                    waiting.removeAll()
                    for continuation in held { continuation.resume() }
                    return
                }
                await withCheckedContinuation { waiting.append($0) }
            }
        }
        let probe = Probe()
        let client = OnlineLyrics { request in
            await probe.arrive()
            let url = try #require(request.url)
            let body: String
            switch url.host {
            case "lrclib.net":
                body = "[]"
            case "api.lyrics.ovh":
                body = #"{"lyrics":"four sources arrived"}"#
            case "music.163.com":
                body = #"{"result":{"songs":[]}}"#
            case "c.y.qq.com":
                body = #"{"data":{"song":{"list":[]}}}"#
            default:
                body = "{}"
            }
            return (Data(body.utf8), response(for: request))
        }
        let match = try #require(
            try await client.fetch(
                .init(title: "Song", artist: "Singer", album: "", duration: 200)))
        #expect(match.source == .lyricsOvh)
        #expect(match.plain == "four sources arrived")
        #expect(await probe.arrivals == 4)
    }

    @Test("television, live and bracketed edition labels do not hide the song")
    func chineseEditionNames() {
        #expect(
            OnlineLyrics.canonicalTitle("如果有来生（天赐的声音·纯享版）")
                == OnlineLyrics.canonicalTitle("如果有来生"))
        #expect(
            OnlineLyrics.canonicalTitle("如果有来生 Live")
                == OnlineLyrics.canonicalTitle("如果有来生"))
    }

    @Test("traditional player metadata matches simplified Chinese catalogues")
    func traditionalChineseMetadata() async throws {
        let client = OnlineLyrics { request in
            let url = try #require(request.url)
            let body: String
            switch (url.host, url.path) {
            case ("c.y.qq.com", let path) where path.contains("client_search"):
                body =
                    """
                    {"data":{"song":{"list":[{
                      "songmid":"traditional","songname":"年少心动雨季",
                      "albumname":"年少心动雨季","interval":265,
                      "singer":[{"name":"黄霄云"}]
                    }]}}}
                    """
            case ("c.y.qq.com", _):
                body = #"{"lyric":"[00:01.00]first\n[00:04.00]second"}"#
            case ("lrclib.net", _):
                body = "[]"
            case ("music.163.com", _):
                body = #"{"result":{"songs":[]}}"#
            case ("api.lyrics.ovh", _):
                body = #"{"lyrics":"plain"}"#
            default:
                body = "{}"
            }
            return (Data(body.utf8), response(for: request))
        }
        let match = try #require(
            try await client.fetch(
                .init(
                    title: "年少心動雨季", artist: "黃霄雲",
                    album: "年少心動雨季", duration: 265)))
        #expect(match.source == .qqMusic)
        #expect(match.parsed?.lines.count == 2)
    }

    @Test("cache names identify the database and timing format")
    func cacheNames() {
        let directory = URL(fileURLWithPath: "/tmp/lyrics")
        let query = OnlineLyrics.Query(
            title: "满天星辰不及你", artist: "ycccc", album: "", duration: 216)
        let url = OnlineLyrics.cacheURL(
            for: query, source: .qqMusic, extension: "lrc", in: directory)
        #expect(url.lastPathComponent.contains("[QQ Music]"))
        #expect(url.pathExtension == "lrc")
    }

    @Test("a timed answer cancels slow fallbacks instead of waiting six seconds")
    func timedAnswerReturnsEarly() async throws {
        let client = OnlineLyrics { request in
            let url = try #require(request.url)
            let body: String
            if url.host == "c.y.qq.com", url.path.contains("client_search") {
                body =
                    """
                    {"data":{"song":{"list":[{
                      "songmid":"fast","songname":"年少心动雨季",
                      "albumname":"年少心动雨季","interval":265,
                      "singer":[{"name":"黄霄雲"}]
                    }]}}}
                    """
            } else if url.host == "c.y.qq.com" {
                body = #"{"lyric":"[00:01.00]first\n[00:04.00]second"}"#
            } else {
                try await Task.sleep(for: .seconds(6))
                body = url.host == "api.lyrics.ovh" ? #"{"lyrics":"late"}"# : "[]"
            }
            return (Data(body.utf8), response(for: request))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let match = try #require(
            try await client.fetch(
                .init(
                    title: "年少心动雨季", artist: "黄霄雲",
                    album: "年少心动雨季", duration: 265)))
        let elapsed = start.duration(to: clock.now)
        #expect(match.source == .qqMusic)
        // The full suite deliberately saturates the cooperative executor with
        // audio work. Leave scheduler headroom while staying below the
        // six-second sleepers, which is the regression this number catches.
        #expect(elapsed < .seconds(5), "lookup took \(elapsed)")
    }
}

@Suite("Source-independent music recognition")
struct MusicRecognitionTests {
    @Test("a catalogue signature receives every captured sample at the stated rate")
    func audioBuffer() throws {
        let samples: [Float] = [0.125, -0.25, 0.5, -1]
        let buffer = try #require(
            MusicRecognition.buffer(samples: samples, sampleRate: 48_000))
        #expect(buffer.frameLength == 4)
        #expect(buffer.format.sampleRate == 48_000)
        #expect(buffer.format.channelCount == 1)
        let channel = try #require(buffer.floatChannelData?[0])
        #expect((0..<4).map { channel[$0] } == samples)
        #expect(
            MusicRecognition.describe(
                NSError(domain: "com.apple.ShazamCore", code: 102))
                == .catalogueAccessNotEnabled)
    }
}
