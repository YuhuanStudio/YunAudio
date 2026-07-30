import Foundation
import Testing

@testable import YunAudioMedia

@Suite("Validated external media snapshots")
struct MediaSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func snapshot(
        sessionID: String = "browser-launch-1",
        contextID: String = "youtube:tab-1",
        sequence: UInt64 = 1,
        observedAt: Date? = nil,
        title: String = "年少心动雨季",
        duration: TimeInterval? = 265,
        position: TimeInterval? = 18.96,
        playbackRate: Double = 1,
        state: MediaPlaybackState = .playing,
        artworkURL: URL? = URL(string: "https://i.ytimg.com/cover.jpg")
    ) -> MediaSnapshot {
        MediaSnapshot(
            sessionID: sessionID,
            contextID: contextID,
            sequence: sequence,
            observedAt: observedAt ?? now,
            title: title,
            artist: "黃霄雲",
            album: "天賜的聲音",
            artworkURL: artworkURL,
            duration: duration,
            position: position,
            playbackRate: playbackRate,
            state: state,
            source: .mediaSession)
    }

    @Test("artwork accepts only bounded web URLs")
    func artworkBoundary() throws {
        for rawURL in [
            "file:///Users/person/Pictures/private.jpg",
            "data:image/png;base64,AAAA",
            "javascript:alert(1)",
            "ftp://example.com/cover.jpg",
            "https:///missing-host.jpg",
            "https://person:secret@example.com/cover.jpg",
        ] {
            #expect(throws: MediaSnapshotValidationError.invalidURL("artworkURL")) {
                try snapshot(artworkURL: URL(string: rawURL)).validated(now: now)
            }
        }

        let longURL =
            "https://example.com/"
            + String(repeating: "a", count: MediaSnapshot.maximumArtworkURLLength)
        #expect(throws: MediaSnapshotValidationError.invalidURL("artworkURL")) {
            try snapshot(artworkURL: URL(string: longURL)).validated(now: now)
        }
        let valid = try snapshot(
            artworkURL: URL(string: "http://example.com/cover.jpg")
        ).validated(now: now)
        #expect(valid.artworkURL?.scheme == "http")
    }

    @Test("a valid snapshot is trimmed and round-trips through JSON")
    func validRoundTrip() throws {
        var input = snapshot(title: "  年少心动雨季\n")
        input.sessionID = " browser-launch-1 "
        input.contextID = " youtube:tab-1 "
        input.artist = " 黃霄雲 "
        input.album = " "

        let valid = try input.validated(now: now)
        #expect(valid.sessionID == "browser-launch-1")
        #expect(valid.contextID == "youtube:tab-1")
        #expect(valid.title == "年少心动雨季")
        #expect(valid.artist == "黃霄雲")
        #expect(valid.album == nil)

        let encoded = try JSONEncoder().encode(valid)
        let decoded = try JSONDecoder().decode(MediaSnapshot.self, from: encoded)
        #expect(decoded == valid)
    }

    @Test("unbounded or non-finite page values never enter the model")
    func rejectsHostileNumbersAndText() {
        var input = snapshot()
        input.title = String(repeating: "a", count: MediaSnapshot.maximumTextLength + 1)
        #expect(throws: MediaSnapshotValidationError.self) {
            try input.validated(now: now)
        }

        for value in [Double.nan, .infinity, -.infinity] {
            input = snapshot(playbackRate: value)
            #expect(throws: MediaSnapshotValidationError.self) {
                try input.validated(now: now)
            }

            input = snapshot(duration: value)
            #expect(throws: MediaSnapshotValidationError.self) {
                try input.validated(now: now)
            }

            input = snapshot(position: value)
            #expect(throws: MediaSnapshotValidationError.self) {
                try input.validated(now: now)
            }
        }

        #expect(throws: MediaSnapshotValidationError.self) {
            try snapshot(position: 267).validated(now: now)
        }
        #expect(throws: MediaSnapshotValidationError.self) {
            try snapshot(playbackRate: 17).validated(now: now)
        }
        #expect(throws: MediaSnapshotValidationError.emptyField("sessionID")) {
            try snapshot(sessionID: " ").validated(now: now)
        }
    }

    @Test("stale, far-future and repeated sequence numbers are refused")
    func rejectsTimeAndSequenceRegression() throws {
        #expect(throws: MediaSnapshotValidationError.stale) {
            try snapshot(observedAt: now.addingTimeInterval(-15.001)).validated(now: now)
        }
        #expect(throws: MediaSnapshotValidationError.fromFuture) {
            try snapshot(observedAt: now.addingTimeInterval(5.001)).validated(now: now)
        }
        #expect(throws: MediaSnapshotValidationError.oldSequence) {
            try snapshot(sequence: 7).validated(now: now, lastSequence: 7)
        }
        #expect(throws: MediaSnapshotValidationError.oldSequence) {
            try snapshot(sequence: 6).validated(now: now, lastSequence: 7)
        }
        #expect(throws: MediaSnapshotValidationError.outOfRange("sequence")) {
            try snapshot(sequence: MediaSnapshot.maximumSequence + 1)
                .validated(now: now)
        }
        #expect(try snapshot(sequence: 8).validated(now: now, lastSequence: 7).sequence == 8)
    }

    @Test("two playing tabs report only IDs instead of choosing either artwork")
    func multipleTabsAreAmbiguous() {
        var resolver = MediaSnapshotResolver()
        let result = resolver.ingest(
            [
                snapshot(
                    contextID: "youtube:tab-9",
                    artworkURL: URL(string: "https://example.com/private-nine.jpg")),
                snapshot(
                    contextID: "youtube:tab-2",
                    artworkURL: URL(string: "https://example.com/private-two.jpg")),
            ],
            now: now)
        #expect(
            result
                == .ambiguous(contextIDs: ["youtube:tab-2", "youtube:tab-9"]))
    }

    @Test("separately arriving tab events still expose an ambiguity")
    func separatelyArrivingTabsAreAmbiguous() {
        var resolver = MediaSnapshotResolver()
        #expect(
            resolver.ingest(
                [snapshot(contextID: "youtube:tab-1")],
                now: now)
                == .selected(snapshot(contextID: "youtube:tab-1")))
        #expect(
            resolver.ingest(
                [snapshot(contextID: "youtube:tab-2")],
                now: now)
                == .ambiguous(contextIDs: ["youtube:tab-1", "youtube:tab-2"]))

        let stopped = snapshot(
            contextID: "youtube:tab-2",
            sequence: 2,
            state: .stopped)
        #expect(
            resolver.ingest([stopped], now: now)
                == .selected(snapshot(contextID: "youtube:tab-1")))
    }

    @Test("normalising context IDs cannot turn one tab into two candidates")
    func contextIsNormalisedBeforeGrouping() {
        var resolver = MediaSnapshotResolver()
        let result = resolver.ingest(
            [
                snapshot(contextID: " youtube:tab-1 ", sequence: 1),
                snapshot(contextID: "youtube:tab-1", sequence: 2),
            ],
            now: now)
        #expect(result == .selected(snapshot(contextID: "youtube:tab-1", sequence: 2)))
    }

    @Test("the active tab wins and old events cannot roll it back")
    func selectionAndSequence() {
        var resolver = MediaSnapshotResolver()
        let selected = resolver.ingest(
            [
                snapshot(contextID: "youtube:tab-1", sequence: 4),
                snapshot(
                    contextID: "youtube:tab-2",
                    sequence: 9,
                    state: .paused),
            ],
            now: now)
        #expect(selected == .selected(snapshot(contextID: "youtube:tab-1", sequence: 4)))
        let first = MediaStreamIdentity(
            sessionID: "browser-launch-1",
            contextID: "youtube:tab-1")
        let second = MediaStreamIdentity(
            sessionID: "browser-launch-1",
            contextID: "youtube:tab-2")
        #expect(resolver.latestSequences[first] == 4)
        #expect(resolver.latestSequences[second] == 9)

        let rolledBack = resolver.ingest(
            [snapshot(contextID: "youtube:tab-1", sequence: 3)],
            now: now)
        #expect(rolledBack == .selected(snapshot(contextID: "youtube:tab-1", sequence: 4)))
        #expect(resolver.latestSequences[first] == 4)
    }

    @Test("a new browser session can restart sequence numbers without stale state")
    func sessionRestart() {
        var resolver = MediaSnapshotResolver()
        _ = resolver.ingest(
            [
                snapshot(
                    sessionID: "browser-launch-1",
                    sequence: MediaSnapshot.maximumSequence)
            ],
            now: now)
        let restarted = snapshot(
            sessionID: "browser-launch-2",
            sequence: 0)
        #expect(resolver.ingest([restarted], now: now) == .selected(restarted))
        let delayedOldSession = snapshot(
            sessionID: "browser-launch-1",
            sequence: MediaSnapshot.maximumSequence)
        #expect(
            resolver.ingest([delayedOldSession], now: now)
                == .selected(restarted))
        #expect(
            resolver.latestSequences
                == [
                    MediaStreamIdentity(
                        sessionID: "browser-launch-2",
                        contextID: "youtube:tab-1"): 0
                ])
    }

    @Test("retained tabs expire at the same fifteen-second boundary")
    func retainedTabsExpire() {
        var resolver = MediaSnapshotResolver()
        _ = resolver.ingest([snapshot()], now: now)
        #expect(
            resolver.ingest([], now: now.addingTimeInterval(15))
                == .selected(snapshot()))
        #expect(
            resolver.ingest([], now: now.addingTimeInterval(15.001))
                == .unavailable)
    }

    @Test("only the newest event from one context is considered")
    func newestInBatchWins() {
        var resolver = MediaSnapshotResolver()
        let result = resolver.ingest(
            [
                snapshot(contextID: "qq:tab-1", sequence: 2, state: .paused),
                snapshot(contextID: "qq:tab-1", sequence: 5),
                snapshot(contextID: "qq:tab-1", sequence: 3, state: .stopped),
            ],
            now: now)
        #expect(result == .selected(snapshot(contextID: "qq:tab-1", sequence: 5)))
        #expect(
            resolver.latestSequences[
                MediaStreamIdentity(
                    sessionID: "browser-launch-1",
                    contextID: "qq:tab-1")
            ] == 5)
    }
}

@Suite("Chinese and English music titles")
struct MusicTitleTests {
    @Test("television and release labels do not become part of the song")
    func editionLabels() {
        #expect(MusicTitle.canonical("如果有来生（天赐的声音·纯享版）") == "如果有来生")
        #expect(MusicTitle.canonical("如果有來生【天賜的聲音·純享版】") == "如果有來生")
        #expect(MusicTitle.canonical("年少心动雨季 Official Music Video") == "年少心动雨季")
        #expect(MusicTitle.canonical("Olive") == "Olive")
        #expect(MusicTitle.canonical("Live") == "Live")
        #expect(MusicTitle.canonical("天赐的声音") == "天赐的声音")
        #expect(MusicTitle.canonical("Song (Olive)") == "Song (Olive)")
        #expect(MusicTitle.canonical("Song (Delivery)") == "Song (Delivery)")
    }

    @Test("simplified and traditional metadata share one matching key")
    func simplifiedAndTraditional() {
        #expect(MusicTitle.matchingKey("年少心动雨季") == MusicTitle.matchingKey("年少心動雨季"))
        #expect(MusicTitle.matchingKey("黄霄云") == MusicTitle.matchingKey("黃霄雲"))
    }

    @Test("site suffixes are removed before an explicit-order parse")
    func pageTitleParsing() {
        #expect(
            MusicTitle.parse(
                "年少心動雨季 — 黃霄雲 - YouTube",
                order: .titleThenArtist)
                == ParsedMusicTitle(title: "年少心動雨季", artist: "黃霄雲"))
        #expect(
            MusicTitle.parse(
                "Adele - Easy On Me | YouTube",
                order: .artistThenTitle)
                == ParsedMusicTitle(title: "Easy On Me", artist: "Adele"))
    }

    @Test("a title without a profile never invents an artist")
    func noInventedArtist() {
        #expect(
            MusicTitle.parse("年少心动雨季 - YouTube", order: .titleThenArtist)
                == ParsedMusicTitle(title: "年少心动雨季", artist: nil))
    }
}

@Suite("Accompaniment query and candidate ranking")
struct AccompanimentTests {
    @Test("the query contains the recording and multilingual backing terms")
    func query() {
        let query = AccompanimentSearch.query(title: "年少心动雨季", artist: "黄霄雲")
        #expect(query.hasPrefix("年少心动雨季 黄霄雲 "))
        #expect(query.contains("伴奏"))
        #expect(query.contains("off vocal"))
        #expect(query.contains("karaoke"))
        #expect(query.contains("instrumental"))
    }

    @Test("the YouTube search URL round-trips Chinese through one documented parameter")
    func youtubeURL() throws {
        let url = try #require(
            AccompanimentSearch.youtubeSearchURL(
                title: "年少心动雨季",
                artist: "黄霄雲"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "https")
        #expect(components.host == "www.youtube.com")
        #expect(components.path == "/results")
        #expect(components.queryItems?.count == 1)
        #expect(components.queryItems?.first?.name == "search_query")
        #expect(components.queryItems?.first?.value?.hasPrefix("年少心动雨季 黄霄雲") == true)
    }

    @Test("the builder cannot request playback, captions, media or credentials")
    func youtubePolicyBoundary() throws {
        let url = try #require(
            AccompanimentSearch.youtubeSearchURL(title: "Song", artist: "Singer"))
        let text = url.absoluteString.lowercased()
        for forbidden in [
            "autoplay", "timedtext", "get_video_info", "watch?", "key=", "audio", "caption",
        ] {
            #expect(!text.contains(forbidden), "\(url) contained \(forbidden)")
        }
    }

    @Test("a matching backing track beats official, lyric and live editions")
    func backingWins() throws {
        let candidates = [
            AccompanimentCandidate(
                id: "official",
                title: "年少心动雨季 Official Video Live",
                artist: "黄霄雲",
                duration: 265),
            AccompanimentCandidate(
                id: "lyrics",
                title: "年少心动雨季 Lyrics",
                artist: "黄霄雲",
                duration: 265),
            AccompanimentCandidate(
                id: "mv",
                title: "MV 年少心动雨季",
                artist: "黄霄雲",
                duration: 265),
            AccompanimentCandidate(
                id: "backing",
                title: "年少心动雨季 纯伴奏 Off Vocal",
                artist: "黄霄雲",
                duration: 265),
        ]
        let ranked = AccompanimentSearch.ranked(
            candidates,
            title: "年少心動雨季",
            artist: "黃霄雲",
            duration: 265)

        #expect(ranked.map(\.candidate.id) == ["backing", "lyrics", "mv", "official"])
        #expect(try #require(ranked.first).score >= 300)
        #expect(try #require(ranked.last).score <= 100)
    }

    @Test("duration proximity contributes forty to minus forty points")
    func durationProximity() {
        let candidates = [
            AccompanimentCandidate(id: "exact", title: "Song 伴奏", duration: 200),
            AccompanimentCandidate(id: "near", title: "Song 伴奏", duration: 220),
            AccompanimentCandidate(id: "far", title: "Song 伴奏", duration: 300),
        ]
        let ranked = AccompanimentSearch.ranked(
            candidates,
            title: "Song",
            artist: nil,
            duration: 200)

        #expect(ranked.map(\.candidate.id) == ["exact", "near", "far"])
        #expect(ranked[0].score - ranked[1].score == 20)
        #expect(ranked[1].score - ranked[2].score == 60)
    }

    @Test("Chinese live editions receive the same penalty as English live editions")
    func chineseLivePenalty() throws {
        let ranked = AccompanimentSearch.ranked(
            [
                AccompanimentCandidate(id: "studio", title: "Song 伴奏", duration: 200),
                AccompanimentCandidate(
                    id: "live",
                    title: "Song 伴奏 現場版",
                    duration: 200),
            ],
            title: "Song",
            artist: nil,
            duration: 200)
        #expect(ranked.map(\.candidate.id) == ["studio", "live"])
        #expect(try #require(ranked.first).score - #require(ranked.last).score == 45)
    }

    @Test("equal scores preserve input order and ranking has no playback action")
    func stableAndDataOnly() {
        let candidates = [
            AccompanimentCandidate(id: "z", title: "Song karaoke"),
            AccompanimentCandidate(id: "a", title: "Song karaoke"),
            AccompanimentCandidate(id: "m", title: "Song karaoke"),
        ]
        let ranked = AccompanimentSearch.ranked(
            candidates,
            title: "Song",
            artist: nil,
            duration: nil)
        #expect(ranked.map(\.candidate.id) == ["z", "a", "m"])
        #expect(ranked.map(\.candidate) == candidates)
    }
}
