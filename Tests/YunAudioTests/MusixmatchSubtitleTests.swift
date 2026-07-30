import Foundation
import Testing

@testable import YunAudioMedia

@Suite("Official Musixmatch subtitle adapter")
struct MusixmatchSubtitleTests {
    private func response(
        for request: URLRequest,
        status: Int = 200,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers)!
    }

    private func adapter(
        status: Int = 200,
        headers: [String: String]? = nil,
        body: String
    ) -> MusixmatchSubtitleAdapter {
        MusixmatchSubtitleAdapter(apiKey: "unit-test-token") { request in
            (Data(body.utf8), response(for: request, status: status, headers: headers))
        }
    }

    @Test("Chinese metadata is URL encoded with official matcher parameters")
    func encodedRequest() async throws {
        actor Probe {
            var request: URLRequest?

            func capture(_ request: URLRequest) {
                self.request = request
            }
        }
        let probe = Probe()
        let client = MusixmatchSubtitleAdapter(apiKey: "unit-test-token") { request in
            await probe.capture(request)
            return (
                Data(Self.successBody.utf8),
                response(for: request)
            )
        }

        _ = try await client.fetch(
            title: "年少心动雨季",
            artist: "黄霄雲",
            duration: 265.4,
            maximumDurationDeviation: 3)
        let request = try #require(await probe.request)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { items[item.name] = value }
        }

        #expect(components.scheme == "https")
        #expect(components.host == "api.musixmatch.com")
        #expect(components.path == "/ws/1.1/matcher.subtitle.get")
        #expect(items["q_track"] == "年少心动雨季")
        #expect(items["q_artist"] == "黄霄雲")
        #expect(items["subtitle_format"] == "lrc")
        #expect(items["f_subtitle_length"] == "265")
        #expect(items["f_subtitle_length_max_deviation"] == "3")
        #expect(items["apikey"] == "unit-test-token")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("duration filters are omitted together when duration is unknown")
    func unknownDuration() async throws {
        actor Probe {
            var request: URLRequest?

            func capture(_ request: URLRequest) {
                self.request = request
            }
        }
        let probe = Probe()
        let client = MusixmatchSubtitleAdapter(apiKey: "unit-test-token") { request in
            await probe.capture(request)
            return (
                Data(Self.successBody.utf8),
                response(for: request)
            )
        }
        _ = try await client.fetch(title: "Song", artist: "Singer")
        let request = try #require(await probe.request)
        let names = Set(
            URLComponents(
                url: try #require(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems?.map(\.name) ?? [])
        #expect(!names.contains("f_subtitle_length"))
        #expect(!names.contains("f_subtitle_length_max_deviation"))
    }

    @Test("invalid duration is rejected before transport or integer conversion")
    func invalidDuration() async {
        actor Probe {
            var calls = 0

            func called() {
                calls += 1
            }
        }
        let probe = Probe()
        let client = MusixmatchSubtitleAdapter(apiKey: "unit-test-token") { request in
            await probe.called()
            return (Data(), response(for: request))
        }
        for duration in [Double.nan, .infinity, -.infinity, -1, 86_401] {
            await #expect(throws: MusixmatchSubtitleFailure.invalidQuery) {
                try await client.fetch(
                    title: "Song",
                    artist: "Singer",
                    duration: duration)
            }
        }
        #expect(await probe.calls == 0)
    }

    @Test("a Chinese LRC keeps attribution, tracking and region without caching")
    func chineseFixture() async throws {
        let result = try await adapter(body: Self.successBody).fetch(
            title: "年少心动雨季",
            artist: "黄霄雲")

        #expect(result.rawLRC == "[00:18.96]晚风里藏着 多少精灵")
        #expect(result.attribution.copyright == "Lyrics © Example Publisher")
        #expect(result.tracking.scriptURL?.host == "tracking.musixmatch.com")
        #expect(result.tracking.pixelURL?.lastPathComponent == "pixel.gif")
        #expect(result.region == "TW")
    }

    @Test("a restricted subtitle reports its region and exposes no lyric body")
    func restricted() async {
        let body =
            """
            {"message":{
              "header":{"status_code":200,"requested_country":"CN"},
              "body":{"subtitle":{
                "restricted":1,
                "subtitle_body":"must not escape",
                "lyrics_copyright":"copyright",
                "script_tracking_url":"https://tracking.musixmatch.com/script",
                "pixel_tracking_url":"https://tracking.musixmatch.com/pixel.gif"
              }}
            }}
            """
        await #expect(throws: MusixmatchSubtitleFailure.restricted(region: "CN")) {
            try await adapter(body: body).fetch(title: "Song", artist: "Singer")
        }
    }

    @Test("HTTP and service-level rate limits are explicit")
    func rateLimits() async {
        await #expect(throws: MusixmatchSubtitleFailure.rateLimited(retryAfter: 17)) {
            try await adapter(
                status: 429,
                headers: ["Retry-After": "17"],
                body: "{}"
            ).fetch(title: "Song", artist: "Singer")
        }
        let body = #"{"message":{"header":{"status_code":429},"body":{}}}"#
        await #expect(throws: MusixmatchSubtitleFailure.rateLimited(retryAfter: nil)) {
            try await adapter(body: body).fetch(title: "Song", artist: "Singer")
        }
    }

    @Test("non-success API status is not misreported as missing lyrics")
    func serviceStatus() async {
        let body = #"{"message":{"header":{"status_code":401},"body":{}}}"#
        await #expect(throws: MusixmatchSubtitleFailure.serviceStatus(401)) {
            try await adapter(body: body).fetch(title: "Song", artist: "Singer")
        }
    }

    @Test("without an injected key the transport is never reached")
    func missingKey() async {
        actor Probe {
            var calls = 0

            func called() {
                calls += 1
            }
        }
        let probe = Probe()
        let client = MusixmatchSubtitleAdapter(apiKey: nil) { request in
            await probe.called()
            return (Data(), response(for: request))
        }

        await #expect(throws: MusixmatchSubtitleFailure.missingAPIKey) {
            try await client.fetch(title: "Song", artist: "Singer")
        }
        #expect(await probe.calls == 0)
    }

    private static let successBody =
        """
        {"message":{
          "header":{"status_code":200,"region":"TW"},
          "body":{"subtitle":{
            "restricted":0,
            "subtitle_body":"[00:18.96]晚风里藏着 多少精灵",
            "lyrics_copyright":"Lyrics © Example Publisher",
            "script_tracking_url":"https://tracking.musixmatch.com/script",
            "pixel_tracking_url":"https://tracking.musixmatch.com/pixel.gif"
          }}
        }}
        """
}
