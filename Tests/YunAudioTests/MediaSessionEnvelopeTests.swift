import Foundation
import Testing

@testable import YunAudioMedia

@Suite("QQ Music and NetEase Media Session envelopes")
struct MediaSessionEnvelopeTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func envelope(
        pageURL: String = "https://y.qq.com/n/ryqq/songDetail/example",
        contextID: String = "chromium:tab-17",
        sequence: UInt64 = 4,
        observedAtMilliseconds: Double = 1_000_000,
        title: String = "年少心动雨季",
        artworkURL: String? = "https://y.gtimg.cn/music/photo_new/T002R300x300.jpg",
        state: String = "playing"
    ) throws -> Data {
        var metadata: [String: Any] = [
            "title": title,
            "artist": "黄霄雲",
            "album": "天赐的声音",
        ]
        if let artworkURL {
            metadata["artworkURL"] = artworkURL
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessionID": "browser-launch-7",
                "contextID": contextID,
                "sequence": sequence,
                "observedAtMilliseconds": observedAtMilliseconds,
                "pageURL": pageURL,
                "metadata": metadata,
                "playback": [
                    "state": state,
                    "position": 18.96,
                    "duration": 265,
                    "rate": 1,
                ],
                // Page content cannot promote itself to a privileged source.
                "source": "accessibility",
            ])
    }

    @Test("QQ Music metadata becomes a validated source-independent snapshot")
    func qqMusic() throws {
        let parsed = try MediaSessionEnvelopeParser.parse(
            envelope(),
            now: now)

        #expect(parsed.site == .qqMusic)
        #expect(parsed.pageURL.host == "y.qq.com")
        #expect(parsed.snapshot.title == "年少心动雨季")
        #expect(parsed.snapshot.artist == "黄霄雲")
        #expect(parsed.snapshot.position == 18.96)
        #expect(parsed.snapshot.duration == 265)
        #expect(parsed.snapshot.state == .playing)
        #expect(parsed.snapshot.source == .mediaSession)
    }

    @Test("NetEase accepts standard paused state and a relative cover")
    func netEase() throws {
        let parsed = try MediaSessionEnvelopeParser.parse(
            envelope(
                pageURL: "https://music.163.com/#/song?id=123",
                contextID: "firefox:tab-3",
                artworkURL: "/images/cover.jpg",
                state: "paused"),
            now: now)

        #expect(parsed.site == .netEaseCloudMusic)
        #expect(parsed.snapshot.contextID == "firefox:tab-3")
        #expect(parsed.snapshot.state == .paused)
        #expect(
            parsed.snapshot.artworkURL?.absoluteString
                == "https://music.163.com/images/cover.jpg")
    }

    @Test("spoofed, insecure and credential-bearing page origins are refused")
    func pageOriginBoundary() throws {
        for pageURL in [
            "http://y.qq.com/n/ryqq/songDetail/example",
            "https://evil-y.qq.com/song",
            "https://music.163.com.evil.example/song",
            "https://person:secret@music.163.com/song",
            "file:///Users/person/private.html",
        ] {
            #expect(throws: MediaSessionEnvelopeError.self) {
                try MediaSessionEnvelopeParser.parse(
                    envelope(pageURL: pageURL),
                    now: now)
            }
        }
    }

    @Test("hostile artwork and repeated sequence never enter the resolver")
    func hostileFields() throws {
        #expect(
            throws: MediaSessionEnvelopeError.invalidSnapshot(
                .invalidURL("artworkURL"))
        ) {
            try MediaSessionEnvelopeParser.parse(
                envelope(artworkURL: "file:///Users/person/private.jpg"),
                now: now)
        }
        #expect(
            throws: MediaSessionEnvelopeError.invalidSnapshot(.oldSequence)
        ) {
            try MediaSessionEnvelopeParser.parse(
                envelope(sequence: 4),
                now: now,
                lastSequence: 4)
        }
    }

    @Test("the native bridge bounds both payload bytes and observation age")
    func payloadAndTimeBounds() throws {
        let oversized = Data(
            repeating: 0x20,
            count: MediaSessionEnvelopeParser.maximumEncodedBytes + 1)
        #expect(throws: MediaSessionEnvelopeError.responseTooLarge) {
            try MediaSessionEnvelopeParser.parse(oversized, now: now)
        }
        #expect(
            throws: MediaSessionEnvelopeError.invalidSnapshot(.stale)
        ) {
            try MediaSessionEnvelopeParser.parse(
                envelope(observedAtMilliseconds: 984_999),
                now: now)
        }
    }

    @Test("two independently playing sites stay ambiguous")
    func multipleSitesRemainAmbiguous() throws {
        let qq = try MediaSessionEnvelopeParser.parse(
            envelope(contextID: "chromium:tab-1"),
            now: now)
        let netEase = try MediaSessionEnvelopeParser.parse(
            envelope(
                pageURL: "https://music.163.com/#/song?id=123",
                contextID: "chromium:tab-2"),
            now: now)
        var resolver = MediaSnapshotResolver()

        #expect(
            resolver.ingest([qq.snapshot, netEase.snapshot], now: now)
                == .ambiguous(contextIDs: ["chromium:tab-1", "chromium:tab-2"]))
    }
}
