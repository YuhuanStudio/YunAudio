import Foundation
import Testing
import YunAudioMedia

@testable import YunAudioApp

/// How many slow fallbacks were allowed to finish.
///
/// An actor rather than a counter with a lock: the stubs run on whatever
/// executor the client's tasks are on, and a data race in a test is a test that
/// fails for reasons nobody can reproduce.
actor SlowFallbackTally {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Suite("Multiple independent lyric sources")
struct OnlineLyricsTests {
    private func response(
        for request: URLRequest, status: Int = 200
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: nil)!
    }

    @Test("an explicitly configured Musixmatch provider joins the same race")
    func musixmatchJoinsRace() async throws {
        actor Probe {
            var coreCalls = 0
            var musixmatchCalls = 0

            func coreCalled() {
                coreCalls += 1
            }

            func musixmatchCalled() {
                musixmatchCalls += 1
            }
        }
        let probe = Probe()
        let musixmatch = MusixmatchSubtitleAdapter(apiKey: "unit-test-token") { request in
            await probe.musixmatchCalled()
            let body =
                """
                {"message":{
                  "header":{"status_code":200,"region":"TW"},
                  "body":{"subtitle":{
                    "restricted":0,
                    "subtitle_body":"[00:18.96]晚风里藏着\\n[00:25.65]满天的星辰",
                    "lyrics_copyright":"Lyrics © Publisher",
                    "script_tracking_url":"https://tracking.musixmatch.com/script",
                    "pixel_tracking_url":"https://tracking.musixmatch.com/pixel.gif"
                  }}
                }}
                """
            return (Data(body.utf8), response(for: request))
        }
        let client = OnlineLyrics(musixmatch: musixmatch) { request in
            await probe.coreCalled()
            let url = try #require(request.url)
            let body: String
            let status: Int
            switch url.host {
            case "lrclib.net":
                body = "[]"
                status = 200
            case "c.y.qq.com":
                body = #"{"data":{"song":{"list":[]}}}"#
                status = 200
            case "music.163.com":
                body = #"{"result":{"songs":[]}}"#
                status = 200
            case "api.lyrics.ovh":
                body = "{}"
                status = 404
            default:
                Issue.record("unexpected core request \(url)")
                body = "{}"
                status = 500
            }
            return (Data(body.utf8), response(for: request, status: status))
        }

        let match = try #require(
            try await client.fetch(
                .init(
                    title: "年少心动雨季", artist: "黄霄雲",
                    album: "天赐的声音", duration: 265)))
        #expect(match.source == .musixmatch)
        #expect(match.parsed?.lines.count == 2)
        #expect(match.providerMetadata?.copyright == "Lyrics © Publisher")
        #expect(match.providerMetadata?.scriptTrackingURL?.host == "tracking.musixmatch.com")
        #expect(match.providerMetadata?.pixelTrackingURL?.lastPathComponent == "pixel.gif")
        #expect(match.providerMetadata?.region == "TW")
        #expect(await probe.coreCalls == 4)
        #expect(await probe.musixmatchCalls == 1)
    }

    @Test("an adapter without a key never joins or calls its transport")
    func unconfiguredMusixmatchIsAbsent() async throws {
        actor Probe {
            var musixmatchCalls = 0

            func musixmatchCalled() {
                musixmatchCalls += 1
            }
        }
        let probe = Probe()
        let musixmatch = MusixmatchSubtitleAdapter(apiKey: nil) { request in
            await probe.musixmatchCalled()
            return (Data(), response(for: request))
        }
        let client = OnlineLyrics(musixmatch: musixmatch) { request in
            let url = try #require(request.url)
            let body: String
            switch url.host {
            case "lrclib.net":
                body = "[]"
            case "c.y.qq.com":
                body = #"{"data":{"song":{"list":[]}}}"#
            case "music.163.com":
                body = #"{"result":{"songs":[]}}"#
            case "api.lyrics.ovh":
                body = #"{"lyrics":"keyless fallback"}"#
            default:
                body = "{}"
            }
            return (Data(body.utf8), response(for: request))
        }
        let match = try #require(
            try await client.fetch(
                .init(title: "Song", artist: "Singer", album: "", duration: 200)))
        #expect(match.source == .lyricsOvh)
        #expect(await probe.musixmatchCalls == 0)
    }

    @Test("the live provider is enabled only by a non-empty session environment key")
    func liveMusixmatchEntry() {
        #expect(OnlineLyrics.liveMusixmatch(environment: [:]) == nil)
        #expect(
            OnlineLyrics.liveMusixmatch(
                environment: ["MUSIXMATCH_API_KEY": " "]) == nil)
        let adapter = OnlineLyrics.liveMusixmatch(
            environment: ["MUSIXMATCH_API_KEY": "session-token"])
        #expect(adapter?.isConfigured == true)
        #expect(OnlineLyrics.musixmatchAdapter(apiKey: " session-token ")?.isConfigured == true)
        #expect(OnlineLyrics.musixmatchAdapter(apiKey: " ") == nil)
        #expect(OnlineLyrics(musixmatch: adapter).isMusixmatchConfigured)
        #expect(!OnlineLyrics(musixmatch: nil).isMusixmatchConfigured)
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

    @Test("Spotify punctuation still finds the exact QQ Music edition")
    func qqEditionPunctuation() async throws {
        let client = OnlineLyrics { request in
            let url = try #require(request.url)
            let body: String
            let status: Int
            switch (url.host, url.path) {
            case ("c.y.qq.com", let path) where path.contains("client_search"):
                body =
                    """
                    {"data":{"song":{"list":[{
                      "songmid":"001KRONb1Gw4eo","songname":"慢冷 (深情版)",
                      "albumname":"慢冷（深情版）","interval":231,
                      "singer":[{"name":"en (王翊恩)"}]
                    }]}}}
                    """
                status = 200
            case ("c.y.qq.com", let path) where path.contains("lyric"):
                body = #"{"lyric":"[00:12.00]第一句\n[00:18.00]第二句"}"#
                status = 200
            case ("lrclib.net", _):
                body = "[]"
                status = 200
            case ("music.163.com", _):
                body = #"{"result":{"songs":[]}}"#
                status = 200
            case ("api.lyrics.ovh", _):
                body = "{}"
                status = 404
            default:
                Issue.record("unexpected request \(url)")
                body = "{}"
                status = 500
            }
            return (Data(body.utf8), response(for: request, status: status))
        }

        let match = try #require(
            try await client.fetch(
                .init(
                    title: "慢冷 - 深情版", artist: "en 王翊恩",
                    album: "慢冷（深情版）", duration: 231)))

        #expect(match.source == .qqMusic)
        #expect(match.trackName == "慢冷 (深情版)")
        #expect(match.artistName == "en (王翊恩)")
        #expect(match.parsed?.lines.count == 2)
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

    @Test("NetEase falls back from word timing to its standard LRC timeline")
    func netEaseStandardTimelineFallback() async throws {
        let client = OnlineLyrics { request in
            let url = try #require(request.url)
            let body: String
            let status: Int
            switch (url.host, url.path) {
            case ("music.163.com", let path) where path.contains("search"):
                body =
                    """
                    {"result":{"songs":[{
                      "id":42,"name":"年少心动雨季","duration":265000,
                      "album":{"name":"年少心动雨季"},
                      "artists":[{"name":"黄霄雲"}]
                    }]}}
                    """
                status = 200
            case ("music.163.com", let path) where path.contains("lyric"):
                body =
                    """
                    {
                      "klyric":{"lyric":"[18960,640](0,320)word(320,320)timing"},
                      "lrc":{"lyric":"[00:18.96]first line\\n[00:25.65]second line"}
                    }
                    """
                status = 200
            case ("lrclib.net", _):
                body = "[]"
                status = 200
            case ("c.y.qq.com", _):
                body = #"{"data":{"song":{"list":[]}}}"#
                status = 200
            case ("api.lyrics.ovh", _):
                body = "{}"
                status = 404
            default:
                Issue.record("unexpected request \(url)")
                body = "{}"
                status = 500
            }
            return (Data(body.utf8), response(for: request, status: status))
        }

        let match = try #require(
            try await client.fetch(
                .init(
                    title: "年少心动雨季", artist: "黄霄雲",
                    album: "年少心动雨季", duration: 265)))
        #expect(match.source == .netEase)
        #expect(match.parsed?.lines.count == 2)
        #expect(abs((match.parsed?.lines.first?.time ?? 0) - 18.96) < 0.001)
    }

    @Test("a timed instrumental placeholder is not accepted as lyrics")
    func instrumentalPlaceholderIsRejected() async throws {
        let client = OnlineLyrics { request in
            let url = try #require(request.url)
            let body: String
            let status: Int
            switch (url.host, url.path) {
            case ("c.y.qq.com", let path) where path.contains("client_search"):
                body =
                    """
                    {"data":{"song":{"list":[{
                      "songmid":"instrumental","songname":"年少心动雨季",
                      "albumname":"年少心动雨季","interval":265,
                      "singer":[{"name":"黄霄雲"}]
                    }]}}}
                    """
                status = 200
            case ("c.y.qq.com", _):
                body = #"{"lyric":"[00:00.00]此歌曲为没有填词的纯音乐，请您欣赏"}"#
                status = 200
            case ("lrclib.net", _):
                body = "[]"
                status = 200
            case ("music.163.com", _):
                body = #"{"result":{"songs":[]}}"#
                status = 200
            case ("api.lyrics.ovh", _):
                body = "{}"
                status = 404
            default:
                body = "{}"
                status = 500
            }
            return (Data(body.utf8), response(for: request, status: status))
        }

        let match = try await client.fetch(
            .init(
                title: "年少心动雨季", artist: "黄霄雲",
                album: "年少心动雨季", duration: 265))
        #expect(match == nil)
    }

    @Test("cancelling a lookup cancels all four provider requests")
    func cancellationReachesProviders() async throws {
        actor Probe {
            var arrivals = 0
            var cancellations = 0
            var waiters: [CheckedContinuation<Void, Never>] = []

            func arrive() {
                arrivals += 1
                guard arrivals == 4 else { return }
                let waiting = waiters
                waiters.removeAll()
                for waiter in waiting { waiter.resume() }
            }

            func waitForAll() async {
                guard arrivals < 4 else { return }
                await withCheckedContinuation { waiters.append($0) }
            }

            func cancelled() {
                cancellations += 1
            }
        }

        let probe = Probe()
        let client = OnlineLyrics { request in
            await probe.arrive()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                await probe.cancelled()
                throw CancellationError()
            }
            return (Data(), response(for: request))
        }
        let lookup = Task {
            try await client.fetch(
                .init(
                    title: "年少心动雨季", artist: "黄霄雲",
                    album: "年少心动雨季", duration: 265))
        }
        await probe.waitForAll()
        lookup.cancel()

        do {
            _ = try await lookup.value
            Issue.record("a cancelled lookup returned normally")
        } catch is CancellationError {
            // The cancellation is the expected answer.
        }
        #expect(await probe.cancellations == 4)
    }

    @Test("the model does not detach provider requests from song cancellation")
    func modelLookupIsStructured() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift", encoding: .utf8)
        let start = try #require(source.range(of: "private func startLyricsLookup"))
        let end = try #require(
            source.range(
                of: "private static func lyricsIdentity",
                range: start.upperBound..<source.endIndex))
        let implementation = source[start.lowerBound..<end.lowerBound]
        #expect(implementation.contains("let client = OnlineLyrics("))
        #expect(implementation.contains("OnlineLyrics.musixmatchAdapter("))
        #expect(implementation.contains("apiKey: musixmatchSessionKey"))
        #expect(implementation.contains("client.fetch(query)"))
        #expect(!implementation.contains("OnlineLyrics.live.fetch(query)"))
        #expect(!implementation.contains("let match = try await Task.detached"))
        #expect(implementation.contains("OnlineLyrics.cacheAttributionURL(for: url)"))
        #expect(implementation.contains("match.cacheAttribution"))
    }

    @Test("cache names identify the database and timing format")
    func cacheNames() {
        let directory = URL(fileURLWithPath: "/tmp/lyrics")
        let query = OnlineLyrics.Query(
            title: "满天星辰不及你", artist: "ycccc", album: "", duration: 216)
        let qqURL = OnlineLyrics.cacheURL(
            for: query, source: .qqMusic, extension: "lrc", in: directory)
        let musixmatchURL = OnlineLyrics.cacheURL(
            for: query, source: .musixmatch, extension: "lrc", in: directory)
        #expect(qqURL.lastPathComponent.contains("[QQ Music]"))
        #expect(qqURL.pathExtension == "lrc")
        #expect(musixmatchURL.lastPathComponent.contains("[Musixmatch]"))
        #expect(musixmatchURL.pathExtension == "lrc")
        #expect(!musixmatchURL.absoluteString.contains("unit-test-token"))
        #expect(OnlineLyrics.cachedSource(for: musixmatchURL) == .musixmatch)
    }

    @Test("a cache sidecar restores attribution without credentials or tracking")
    func cacheAttributionRoundTrip() throws {
        let scriptURL = try #require(
            URL(string: "https://tracking.musixmatch.com/script?token=do-not-store"))
        let pixelURL = try #require(
            URL(string: "https://tracking.musixmatch.com/pixel.gif?key=do-not-store"))
        let match = try #require(
            OnlineLyrics.Match(
                source: .musixmatch,
                trackName: "年少心動雨季",
                artistName: "黃霄雲",
                albumName: "天賜的聲音",
                duration: 265,
                synchronised: "[00:18.96]晚風裡藏著",
                plain: nil,
                providerMetadata: .init(
                    copyright: " Lyrics © Publisher ",
                    scriptTrackingURL: scriptURL,
                    pixelTrackingURL: pixelURL,
                    region: " TW ")))

        let data = try OnlineLyrics.encodeCacheAttribution(match.cacheAttribution)
        let replayed = try OnlineLyrics.decodeCacheAttribution(data)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(replayed.provider == .musixmatch)
        #expect(replayed.copyright == "Lyrics © Publisher")
        #expect(replayed.region == "TW")
        #expect(Set(object.keys) == ["provider", "copyright", "region"])
        let serialised = String(decoding: data, as: UTF8.self)
        #expect(!serialised.contains("tracking"))
        #expect(!serialised.contains("do-not-store"))

        let lyricsURL = URL(fileURLWithPath: "/tmp/年少心動雨季.lrc")
        #expect(
            OnlineLyrics.cacheAttributionURL(for: lyricsURL).lastPathComponent
                == "年少心動雨季.lrc.attribution.json")
    }

    @Test("the router restores only attribution matching the cached provider")
    @MainActor
    func routerRestoresCacheAttribution() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YunAudio-attribution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let query = OnlineLyrics.Query(
            title: "年少心動雨季", artist: "黃霄雲",
            album: "天賜的聲音", duration: 265)
        let lyricsURL = OnlineLyrics.cacheURL(
            for: query, source: .musixmatch, extension: "lrc", in: directory)
        let sidecarURL = OnlineLyrics.cacheAttributionURL(for: lyricsURL)
        let expected = OnlineLyrics.CacheAttribution(
            provider: .musixmatch,
            copyright: "Lyrics © Publisher",
            region: "TW")
        try OnlineLyrics.encodeCacheAttribution(expected)
            .write(to: sidecarURL, options: .atomic)

        try "[00:01.00]line".write(
            to: lyricsURL, atomically: true, encoding: .utf8)
        let track = NowPlaying.Track(
            application: "Test", title: query.title, artist: query.artist,
            album: query.album, position: 0, duration: query.duration,
            isPlaying: false, identity: "cache-attribution")
        func loadAttribution() -> OnlineLyrics.CacheAttribution? {
            NowPlayingResourceLoader.load(
                NowPlayingResourceRequest(
                    generation: 0, track: track, directory: directory,
                    needsArtwork: false)
            ).attribution
        }

        #expect(loadAttribution() == expected)

        let mismatched = OnlineLyrics.CacheAttribution(
            provider: .qqMusic, copyright: "Wrong catalogue", region: "CN")
        try OnlineLyrics.encodeCacheAttribution(mismatched)
            .write(to: sidecarURL, options: .atomic)
        #expect(loadAttribution() == nil)
    }

    @Test("untrusted attribution sidecars are bounded")
    func cacheAttributionBounds() {
        let oversized = Data(
            repeating: 0x20,
            count: OnlineLyrics.CacheAttribution.maximumEncodedBytes + 1)
        #expect(throws: OnlineLyrics.Failure.responseTooLarge) {
            try OnlineLyrics.decodeCacheAttribution(oversized)
        }

        let attribution = OnlineLyrics.CacheAttribution(
            provider: .musixmatch,
            copyright: String(
                repeating: "a",
                count: OnlineLyrics.CacheAttribution.maximumCopyrightLength + 1),
            region: "TW")
        #expect(throws: OnlineLyrics.Failure.badResponse) {
            try OnlineLyrics.encodeCacheAttribution(attribution)
        }
    }

    @Test("a second play keeps the online provider attached to its cache")
    @MainActor
    func cachedProviderSurvivesRelaunch() {
        let directory = URL(fileURLWithPath: "/tmp/lyrics")
        let query = OnlineLyrics.Query(
            title: "年少心動雨季", artist: "黃霄雲",
            album: "天賜的聲音", duration: 265)
        let cached = OnlineLyrics.cacheURL(
            for: query, source: .netEase, extension: "lrc", in: directory)
        let musixmatch = OnlineLyrics.cacheURL(
            for: query, source: .musixmatch, extension: "lrc", in: directory)
        let userFile = directory.appendingPathComponent("黃霄雲 - 年少心動雨季.lrc")

        #expect(OnlineLyrics.cachedSource(for: cached) == .netEase)
        #expect(OnlineLyrics.cachedSource(for: musixmatch) == .musixmatch)
        #expect(RouterModel.lyricsStatus(forLocalURL: cached) == .online)
        #expect(OnlineLyrics.cachedSource(for: userFile) == nil)
        #expect(RouterModel.lyricsStatus(forLocalURL: userFile) == .local)
        #expect(
            RouterModel.lyricsSourceName(forLocalURL: cached)
                != RouterModel.lyricsSourceName(forLocalURL: userFile))

        let track = NowPlaying.Track(
            application: "NetEaseMusic", title: query.title, artist: query.artist,
            album: query.album, position: 0, duration: query.duration, isPlaying: true)
        #expect(
            RouterModel.bestFileName(
                for: track,
                names: [cached.lastPathComponent, userFile.lastPathComponent],
                extensions: ["lrc"]) == userFile.lastPathComponent)
        #expect(
            RouterModel.bestFileName(
                for: track, names: [cached.lastPathComponent], extensions: ["lrc"])
                == cached.lastPathComponent)
    }

    @Test("a timed answer cancels slow fallbacks instead of waiting six seconds")
    func timedAnswerReturnsEarly() async throws {
        let slowFallbacksThatFinished = SlowFallbackTally()
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
                // Reached only if the sleep was *not* cancelled, which is the
                // regression this test exists for. Counting it is stronger than
                // timing the whole lookup and immune to the scheduler: the old
                // assertion was a wall clock against a saturated executor, and
                // it started crying wolf the moment the suite grew.
                await slowFallbacksThatFinished.increment()
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
        // The claim, stated as itself: no slow fallback ran to completion,
        // because the fast answer cancelled them. The clock is kept only as a
        // sanity bound well clear of the six-second sleepers — it is evidence,
        // not the assertion.
        #expect(await slowFallbacksThatFinished.count == 0)
        // The clock is printed, not asserted. It measures the machine: under a
        // full parallel suite the *fast* path is starved too, so a bound tight
        // enough to catch a regression is loose enough to fail on a busy
        // laptop. Two attempts at a number both cried wolf; the count above is
        // the claim, and this is evidence beside it.
        print("timed answer returned in \(elapsed)")
    }

    @Test("a complete exact timeline wins the quality grace")
    func completeTimelineWinsQualityGrace() async throws {
        let completeTimeline = (0..<63).map { line in
            let seconds = 12 + Double(line) * 4
            return String(
                format: "[%02d:%05.2f]line %02d",
                Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60), line)
        }.joined(separator: "\n")
        let escapedTimeline = completeTimeline.replacingOccurrences(of: "\n", with: "\\n")
        // No sleeps anywhere, deliberately. This half asserts that the full
        // sixty-three-line timeline outranks the two-line fragment, which is
        // `strongest`'s decision and has nothing to do with the clock. Timing
        // it as well made it a race between a timer, which fires on time, and
        // a stubbed response, whose continuation does not once the suite has
        // saturated the executor — it failed about once a run and passed
        // alone. Whether the grace is bounded is the test below.
        let client = OnlineLyrics { request in
            let url = try #require(request.url)
            let body: String
            let status: Int
            switch (url.host, url.path) {
            case ("c.y.qq.com", let path) where path.contains("client_search"):
                body =
                    """
                    {"data":{"song":{"list":[{
                      "songmid":"fast-fragment","songname":"年少心动雨季",
                      "albumname":"年少心动雨季","interval":265,
                      "singer":[{"name":"黄霄雲"}]
                    }]}}}
                    """
                status = 200
            case ("c.y.qq.com", _):
                body = #"{"lyric":"[00:18.96]first\n[00:25.65]second"}"#
                status = 200
            case ("music.163.com", let path) where path.contains("search"):
                body =
                    """
                    {"result":{"songs":[{
                      "id":63,"name":"年少心动雨季","duration":265000,
                      "album":{"name":"年少心动雨季"},
                      "artists":[{"name":"黄霄雲"}]
                    }]}}
                    """
                status = 200
            case ("music.163.com", let path) where path.contains("lyric"):
                body = #"{"lrc":{"lyric":"\#(escapedTimeline)"}}"#
                status = 200
            case ("lrclib.net", _), ("api.lyrics.ovh", _):
                body = url.host == "lrclib.net" ? "[]" : #"{"lyrics":"late"}"#
                status = 200
            default:
                Issue.record("unexpected request \(url)")
                body = "{}"
                status = 500
            }
            return (Data(body.utf8), response(for: request, status: status))
        }

        let match = try #require(
            try await client.fetch(
                .init(
                    title: "年少心动雨季", artist: "黄霄雲",
                    album: "年少心动雨季", duration: 265)))

        #expect(match.source == .netEase)
        #expect(match.parsed?.lines.count == 63)
        #expect((match.parsed?.lines.last?.time ?? 0) > 250)
    }

    @Test("the grace does not wait for a provider that never answers")
    func theGraceIsBounded() async throws {
        let deadProvidersThatFinished = SlowFallbackTally()
        // The other half, with nothing to race. One provider answers timed
        // words immediately; the rest sleep for six seconds. The grace is a
        // tenth of a second, so the call must return in a small fraction of
        // the six — and a timer that fires late can only make this later, so
        // the bound is the assertion that means something.
        let client = OnlineLyrics(qualityGrace: .milliseconds(100)) { request in
            let url = try #require(request.url)
            let body: String
            switch url.host {
            case "c.y.qq.com" where url.path.contains("search"):
                body = """
                    {"data":{"song":{"list":[{
                      "songmid":"prompt","songname":"年少心动雨季",
                      "albumname":"年少心动雨季","interval":265,
                      "singer":[{"name":"黄霄雲"}]
                    }]}}}
                    """
            case "c.y.qq.com":
                body = #"{"lyric":"[00:18.96]first\n[00:25.65]second"}"#
            default:
                try await Task.sleep(for: .seconds(6))
                // Reached only if the grace waited for a provider that never
                // answers, which is the regression. Counting it says that
                // directly; the wall clock only said it on an idle machine.
                await deadProvidersThatFinished.increment()
                body = "[]"
            }
            return (Data(body.utf8), response(for: request, status: 200))
        }

        let clock = ContinuousClock()
        let start = clock.now
        let match = try await client.fetch(
            .init(title: "年少心动雨季", artist: "黄霄雲", album: "年少心动雨季", duration: 265))
        let elapsed = start.duration(to: clock.now)

        #expect(match?.source == .qqMusic)
        // The claim, stated as itself: the grace did not wait for a provider
        // that never answers. The clock is printed as evidence and no longer
        // asserted — under a full parallel suite the *fast* path is starved
        // too, so any bound tight enough to catch the regression is loose
        // enough to fail on a busy machine. This is the second test in this
        // file to learn that.
        #expect(await deadProvidersThatFinished.count == 0)
        print("quality grace returned in \(elapsed)")
    }
}

@Suite("Session-only lyric provider key")
struct SessionLyricKeyTests {
    @Test("the launch default is trimmed, bounded and absent without an environment key")
    @MainActor
    func keyBoundary() {
        #expect(RouterModel.initialMusixmatchSessionKey(environment: [:]).isEmpty)
        #expect(
            RouterModel.initialMusixmatchSessionKey(
                environment: ["MUSIXMATCH_API_KEY": " session-token \n"])
                == "session-token")

        let oversized = String(
            repeating: "k",
            count: RouterModel.maximumMusixmatchSessionKeyLength + 50)
        let bounded = RouterModel.boundedMusixmatchSessionKey(oversized)
        #expect(bounded.count == RouterModel.maximumMusixmatchSessionKeyLength)
    }

    @Test("the secure setting is session-only and absent from persistence and diagnostics")
    func sourceBoundary() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let router = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let persistStart = try #require(router.range(of: "private func persist()"))
        let persistEnd = try #require(
            router.range(
                of: "// MARK: Devices",
                range: persistStart.upperBound..<router.endIndex))
        let persistence = router[persistStart.lowerBound..<persistEnd.lowerBound]
        #expect(!persistence.contains("musixmatchSessionKey"))

        let storedPreferences = try String(
            contentsOfFile: root + "Sources/YunAudioApp/Preferences.swift",
            encoding: .utf8)
        #expect(!storedPreferences.contains("musixmatchSessionKey"))

        let preferencesWindow = try String(
            contentsOfFile: root + "Sources/YunAudioApp/PreferencesWindow.swift",
            encoding: .utf8)
        #expect(preferencesWindow.contains("loc(\"Official Musixmatch API key\")"))
        #expect(preferencesWindow.contains("model.setMusixmatchSessionKey"))
        #expect(preferencesWindow.contains("model.clearMusixmatchSessionKey()"))
        #expect(preferencesWindow.contains("model.isMusixmatchSessionConfigured"))

        let diagnosticsStart = try #require(
            preferencesWindow.range(of: "private var diagnosticsSection"))
        let diagnosticsEnd = try #require(
            preferencesWindow.range(
                of: "private var aboutSection",
                range: diagnosticsStart.upperBound..<preferencesWindow.endIndex))
        let diagnostics = preferencesWindow[
            diagnosticsStart.lowerBound..<diagnosticsEnd.lowerBound]
        #expect(!diagnostics.contains("musixmatchSessionKey"))
    }

    @Test("the session key never enters lyric cache names or sidecars")
    func cacheBoundary() throws {
        let secret = "session-secret-that-must-not-be-cached"
        let directory = URL(fileURLWithPath: "/tmp/lyrics")
        let query = OnlineLyrics.Query(
            title: "年少心動雨季",
            artist: "黃霄雲",
            album: "天賜的聲音",
            duration: 265)
        let lyricsURL = OnlineLyrics.cacheURL(
            for: query,
            source: .musixmatch,
            extension: "lrc",
            in: directory)
        let sidecar = try OnlineLyrics.encodeCacheAttribution(
            .init(
                provider: .musixmatch,
                copyright: "Lyrics © Publisher",
                region: "TW"))

        #expect(!lyricsURL.absoluteString.contains(secret))
        #expect(!String(decoding: sidecar, as: UTF8.self).contains(secret))

        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/OnlineLyrics.swift",
            encoding: .utf8)
        let cacheStart = try #require(source.range(of: "static func cacheURL("))
        let cacheEnd = try #require(
            source.range(
                of: "static func cachedSource(",
                range: cacheStart.upperBound..<source.endIndex))
        let cacheName = source[cacheStart.lowerBound..<cacheEnd.lowerBound]
        #expect(!cacheName.contains("apiKey"))
        #expect(!cacheName.contains("musixmatchSessionKey"))
    }
}

@Suite("Hand-run lyric fallback")
struct HandRunLyricsTests {
    @Test("a Chinese title and artist become a stopped, bounded manual track")
    @MainActor
    func trackConstruction() throws {
        let track = try #require(
            RouterModel.handRunTrack(
                title: "  年少心動雨季\n",
                artist: " 黃霄雲 "))

        #expect(track.title == "年少心動雨季")
        #expect(track.artist == "黃霄雲")
        #expect(track.position == 0)
        #expect(track.duration == 0)
        #expect(!track.isPlaying)
        #expect(track.identity == "hand:黃霄雲\u{1F}年少心動雨季")

        let longTitle = String(
            repeating: "雨",
            count: RouterModel.maximumHandLyricsFieldLength + 50)
        let bounded = try #require(
            RouterModel.handRunTrack(
                title: "\n\(longTitle) ",
                artist: String(
                    repeating: "歌",
                    count: RouterModel.maximumHandLyricsFieldLength + 50)))
        #expect(bounded.title.count == RouterModel.maximumHandLyricsFieldLength)
        #expect(bounded.artist.count == RouterModel.maximumHandLyricsFieldLength)
        #expect(RouterModel.handRunTrack(title: " \n ", artist: "Nobody") == nil)
    }

    @Test("manual lookup adopts locally first and retry does not exclude hand-run")
    func lookupStructure() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift", encoding: .utf8)
        let lookupStart = try #require(
            source.range(of: "func findWordsByTitle("))
        let lookupEnd = try #require(
            source.range(
                of: "private static func boundedHandLyricsField",
                range: lookupStart.upperBound..<source.endIndex))
        let lookup = source[lookupStart.lowerBound..<lookupEnd.lowerBound]
        let handRun = try #require(lookup.range(of: "isHandRun = true"))
        let adoption = try #require(lookup.range(of: "adopt(track)"))

        #expect(handRun.lowerBound < adoption.lowerBound)
        #expect(lookup.contains("guard let track = Self.handRunTrack"))
        #expect(!lookup.contains("NowPlaying.current"))
        #expect(!lookup.contains("Accessibility"))
        #expect(!lookup.contains("microphone"))

        let adoptStart = try #require(source.range(of: "private func adopt("))
        let adoptEnd = try #require(
            source.range(
                of: "private func startLyricsLookup",
                range: adoptStart.upperBound..<source.endIndex))
        let adoptionFlow = source[adoptStart.lowerBound..<adoptEnd.lowerBound]
        let localRead = try #require(
            adoptionFlow.range(of: "nowPlayingResourceWorker.submit"))
        let onlineStart = try #require(adoptionFlow.range(of: "startLyricsLookup"))
        #expect(localRead.lowerBound < onlineStart.lowerBound)

        let retryStart = try #require(source.range(of: "func retryLyricsLookup()"))
        let retryEnd = try #require(
            source.range(
                of: "private func followTheWords",
                range: retryStart.upperBound..<source.endIndex))
        let retry = source[retryStart.lowerBound..<retryEnd.lowerBound]
        #expect(retry.contains("startLyricsLookup(for: track)"))
        #expect(!retry.contains("!isHandRun"))
    }

    @Test("the collapsible form and source list follow runtime configuration")
    func interfaceStructure() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/SingingPanel.swift",
            encoding: .utf8)
        // The search form itself is shared with the stage now — see
        // `KTVWordsSourcing`, which exists because the one case it is for, words
        // that did not resolve, could not be repaired from the window where
        // somebody sees them wrong. What is asserted here is that the panel
        // still reaches it, and that the form is still a form.
        let sourcing = try String(
            contentsOfFile: root + "Sources/YunAudioApp/KTVWordsSourcing.swift",
            encoding: .utf8)
        #expect(source.contains("KTVWordsSourcing(model: model, scale: .inspector)"))
        #expect(sourcing.contains("@State private var isExpanded"))
        #expect(sourcing.contains("field(loc(\"Song title\")"))
        #expect(sourcing.contains("field(loc(\"Artist (optional)\")"))
        #expect(sourcing.contains("model.findWordsByTitle(title, artist: artist)"))
        #expect(source.contains("model.isMusixmatchSessionConfigured"))
        #expect(!source.contains("OnlineLyrics.live.isMusixmatchConfigured"))
        #expect(
            source.contains(
                "Searching LRCLIB, QQ Music, NetEase, lyrics.ovh and Musixmatch…"))
        #expect(
            source.contains(
                "Searching LRCLIB, QQ Music, NetEase and lyrics.ovh…"))
        #expect(
            source.contains(
                "No words were found in LRCLIB, QQ Music, NetEase, lyrics.ovh or Musixmatch."
            ))
        #expect(
            source.contains(
                "No words were found in LRCLIB, QQ Music, NetEase or lyrics.ovh."
            ))
    }
}

@Suite("Source-independent music recognition")
struct MusicRecognitionTests {
    @Test("a Chinese local cover follows the same song matching as its words")
    @MainActor
    func localCoverMatching() {
        let track = NowPlaying.Track(
            application: "Spotify", title: "年少心動雨季", artist: "黃霄雲",
            album: "天賜的聲音", position: 0, duration: 265, isPlaying: true)
        let found = RouterModel.bestFileName(
            for: track,
            names: [
                "Unrelated Song.jpg",
                "黃霄雲 - 年少心動雨季.png",
                "年少心動雨季.lrc",
            ],
            extensions: ["jpg", "jpeg", "png", "heic", "webp"])

        #expect(found == "黃霄雲 - 年少心動雨季.png")
    }

    @Test("hand-selected words use an exact-name neighbouring cover")
    @MainActor
    func coverBesideWords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let words = directory.appendingPathComponent("年少心動雨季.lrc")
        let cover = directory.appendingPathComponent("年少心動雨季.png")
        try Data().write(to: words)
        try Data([0]).write(to: cover)

        try "[00:01.00]line".write(to: words, atomically: true, encoding: .utf8)
        let snapshot = HandWordsResourceLoader.load(
            HandWordsResourceRequest(generation: 0, url: words))
        #expect(snapshot.artworkURL == cover)
    }

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

    @Test("signature construction borrows the six-second accumulator")
    func borrowedAudioBuffer() throws {
        let samples: [Float] = [0.125, -0.25, 0.5, -1]
        let buffer = try #require(
            samples.withUnsafeBufferPointer {
                MusicRecognition.buffer(samples: $0, sampleRate: 48_000)
            })
        let channel = try #require(buffer.floatChannelData?[0])
        #expect((0..<4).map { channel[$0] } == samples)

        let queryFrames = Int(MusicRecognition.querySeconds * 48_000)
        #expect(queryFrames == 288_000)
        #expect(queryFrames * MemoryLayout<Float>.stride == 1_152_000)
    }

    @Test("audio after a cooldown boundary starts the next signature")
    func cooldownBoundary() {
        let crossing = MusicRecognition.consumeCooldown(
            sampleCount: 700, cooldownSamples: 500)
        #expect(crossing.discarded == 500)
        #expect(crossing.remaining == 0)

        let stillCooling = MusicRecognition.consumeCooldown(
            sampleCount: 300, cooldownSamples: 500)
        #expect(stillCooling.discarded == 300)
        #expect(stillCooling.remaining == 200)
    }

    @Test("structural lint demand-creates one catalogue owner and resets it in place")
    func catalogueSessionIsDemandDriven() throws {
        // MusicRecognitionWorkerTests executes the real lifetime contract: ten
        // thousand resets retain one entered catalogue await, zero PCM and no
        // late publication. This source lint keeps RouterModel on that same-owner
        // reset policy instead of replacing an await which may never return.
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift", encoding: .utf8)
        #expect(source.contains("private var musicRecognition: MusicRecognition?"))
        #expect(!source.contains("private lazy var musicRecognition"))
        #expect(source.ranges(of: "let service = MusicRecognition {").count == 1)
        #expect(source.ranges(of: "musicRecognition = service").count == 1)

        let clearStart = try #require(source.range(of: "private func clearSinging()"))
        let clearEnd = try #require(
            source.range(
                of: "// MARK: Scoring, and duets",
                range: clearStart.upperBound..<source.endIndex))
        let clear = source[clearStart.lowerBound..<clearEnd.lowerBound]
        #expect(clear.contains("releaseMusicRecognition()"))
        #expect(!clear.contains("recognitionService()"))

        let releaseStart = try #require(
            source.range(of: "private func releaseMusicRecognition()"))
        let releaseEnd = try #require(
            source.range(
                of: "private func receiveTranscript",
                range: releaseStart.upperBound..<source.endIndex))
        let release = source[releaseStart.lowerBound..<releaseEnd.lowerBound]
        #expect(release.contains("musicRecognition?.reset(releasingBuffers: true)"))
        #expect(!release.contains("musicRecognition = nil"))
    }

    @Test("a player answer cannot restart KTV work after the panel closes")
    func latePlayerAnswerIsRejected() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift", encoding: .utf8)
        let askStart = try #require(source.range(of: "private func askThePlayer()"))
        let askEnd = try #require(
            source.range(
                of: "private func receivePosition(",
                range: askStart.upperBound..<source.endIndex))
        let ask = source[askStart.lowerBound..<askEnd.lowerBound]

        #expect(ask.contains("let generation = nowPlayingSessionGeneration"))
        #expect(ask.contains("self.isSingingVisible"))
        #expect(ask.contains("generation == self.nowPlayingSessionGeneration"))

        let clearStart = try #require(source.range(of: "private func clearSinging()"))
        let clearEnd = try #require(
            source.range(
                of: "// MARK: Scoring, and duets",
                range: clearStart.upperBound..<source.endIndex))
        let clear = source[clearStart.lowerBound..<clearEnd.lowerBound]
        #expect(clear.contains("nowPlayingSessionGeneration &+= 1"))
        #expect(clear.contains("isAskingThePlayer = false"))
    }

    @Test("reference signature ranges never become a track duration")
    func matchRangeIsNotDuration() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/MusicRecognition.swift", encoding: .utf8)
        let start = try #require(source.range(of: "case let .match(match):"))
        let end = try #require(
            source.range(
                of: "case .noMatch:",
                range: start.upperBound..<source.endIndex))
        let matchHandler = source[start.lowerBound..<end.lowerBound]

        #expect(!matchHandler.contains("timeRanges.map"))
        #expect(matchHandler.contains("duration: 0"))
        #expect(matchHandler.contains("appleMusicURL: item.appleMusicURL"))
    }

    @Test("a recognised catalogue link survives in the source-independent match")
    func catalogueLinkSurvives() throws {
        let link = try #require(
            URL(string: "https://music.apple.com/tw/album/example/123?i=456"))
        let match = MusicRecognition.Match(
            title: "年少心動雨季",
            artist: "黃霄雲",
            album: "天賜的聲音",
            identity: "shazam:123",
            position: 18.96,
            duration: 0,
            confidence: 0.95,
            artworkURL: nil,
            appleMusicURL: link)

        #expect(match.appleMusicURL == link)
    }

    @Test("an Apple Music destination remains optional on the now-playing track")
    @MainActor
    func catalogueLinkTrackRoundTrip() throws {
        let link = try #require(
            URL(string: "https://music.apple.com/tw/album/example/123?i=456"))
        let linked = NowPlaying.Track(
            application: "QQ Music",
            title: "年少心動雨季",
            artist: "黃霄雲",
            album: "天賜的聲音",
            position: 18.96,
            duration: 265,
            isPlaying: true,
            appleMusicURL: link)
        let unlinked = NowPlaying.Track(
            application: "QQ Music",
            title: "年少心動雨季",
            artist: "黃霄雲",
            album: "天賜的聲音",
            position: 18.96,
            duration: 265,
            isPlaying: true)

        #expect(linked.appleMusicURL == link)
        #expect(unlinked.appleMusicURL == nil)
    }

    @Test("recognition maps the destination and the interface renders it conditionally")
    func catalogueLinkMappingStructure() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let router = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let recognitionStart = try #require(
            router.range(of: "private func receiveMusicRecognition("))
        let recognitionEnd = try #require(
            router.range(
                of: "var nowPlayingProblem:",
                range: recognitionStart.upperBound..<router.endIndex))
        let recognition = router[
            recognitionStart.lowerBound..<recognitionEnd.lowerBound]

        #expect(recognition.contains("appleMusicURL: match.appleMusicURL"))

        let panel = try String(
            contentsOfFile: root + "Sources/YunAudioApp/SingingPanel.swift",
            encoding: .utf8)
        #expect(panel.contains("if let appleMusicURL = track.appleMusicURL"))
        #expect(panel.contains("Button(loc(\"Open in Apple Music\"))"))
        #expect(panel.contains("NSWorkspace.shared.open(appleMusicURL)"))
    }
}
