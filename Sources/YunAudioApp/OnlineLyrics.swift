import Foundation
import YunAudioEngine
import YunAudioMedia

/// Independent public lyric sources, asked together and ranked locally.
///
/// The providers are deliberately independent rather than wrappers around one
/// index. Chinese releases and television performances are often absent from
/// western catalogues, while an outage at one community service must not turn
/// every song into "not found".
struct OnlineLyrics: Sendable {
    private static let jsonFormat = "json"
    private static let trueFlag = "true"
    /// How long a first timed answer waits to see whether a better one lands.
    ///
    /// Injectable, and the reason is a test that lied. Asserting both halves of
    /// this — that the grace lets a fuller timeline win, *and* that it does not
    /// wait for a dead provider — against one fixed duration makes the check a
    /// race between a timer, which fires on time, and a stubbed response, whose
    /// continuation does not when the suite has saturated the executor. It
    /// failed roughly once a run and passed alone, which is the shape of a
    /// gatekeeper that will one day be ignored while it is telling the truth.
    /// Two tests, two graces, no race.
    static let defaultQualityGrace: Duration = .milliseconds(225)

    struct Query: Sendable, Equatable {
        let title: String
        let artist: String
        let album: String
        let duration: Double
        /// Everyone on the track, for reading a duet file's singer markers. A
        /// name is only taken for a marker when the track names that performer,
        /// so a short list leaves the second singer's name drawn as a lyric.
        var performers: [String] = []
    }

    enum Source: String, CaseIterable, Codable, Sendable, Equatable {
        case lrclib = "LRCLIB"
        case qqMusic = "QQ Music"
        case netEase = "NetEase Cloud Music"
        case lyricsOvh = "lyrics.ovh"
        case musixmatch = "Musixmatch"
    }

    struct ProviderMetadata: Sendable, Equatable {
        let copyright: String?
        let scriptTrackingURL: URL?
        let pixelTrackingURL: URL?
        let region: String?
    }

    /// Persistable attribution beside cached lyrics.
    ///
    /// Tracking URLs are deliberately absent: a cache is opened on every
    /// replay and must not become either a tracking request queue or a durable
    /// record of provider-specific request data.
    struct CacheAttribution: Codable, Sendable, Equatable {
        static let maximumEncodedBytes = 8 * 1_024
        static let maximumCopyrightLength = 2_048
        static let maximumRegionLength = 32

        let provider: Source
        let copyright: String?
        let region: String?

        init(provider: Source, copyright: String?, region: String?) {
            self.provider = provider
            self.copyright =
                copyright?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            self.region =
                region?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let provider = try container.decode(Source.self, forKey: .provider)
            let copyright = try container.decodeIfPresent(String.self, forKey: .copyright)
            let region = try container.decodeIfPresent(String.self, forKey: .region)
            guard
                copyright?.count ?? 0 <= Self.maximumCopyrightLength,
                region?.count ?? 0 <= Self.maximumRegionLength
            else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "cache attribution field exceeds its bound"))
            }
            self.init(provider: provider, copyright: copyright, region: region)
        }
    }

    struct Match: Sendable, Equatable {
        let source: Source
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: Double?
        let synchronised: String?
        let plain: String?
        let parsed: Lyrics?
        let providerMetadata: ProviderMetadata?

        init?(
            source: Source, trackName: String, artistName: String,
            albumName: String, duration: Double?, synchronised: String?,
            plain: String?, parsed validatedParsed: Lyrics? = nil,
            providerMetadata: ProviderMetadata? = nil
        ) {
            let synchronised = synchronised?.nonEmpty
            let parsed = validatedParsed ?? synchronised.flatMap { Lyrics.parse($0) }
            let acceptedSynchronised =
                parsed != nil && synchronised.map(OnlineLyrics.isInstrumentalLyrics) != true
                ? synchronised : nil
            // Cleaned here rather than at the point of drawing, so ranking
            // judges the words that would actually appear: a candidate whose
            // untimed field is nothing but a credit block has nothing to show
            // and must not outrank an index that does.
            let plain = plain?.nonEmpty.flatMap { Lyrics.plainWords(from: $0) }
            let acceptedPlain =
                plain.map(OnlineLyrics.isInstrumentalLyrics) == true ? nil : plain
            guard acceptedSynchronised != nil || acceptedPlain != nil else { return nil }

            self.source = source
            self.trackName = trackName
            self.artistName = artistName
            self.albumName = albumName
            self.duration = duration
            self.synchronised = acceptedSynchronised
            self.plain = acceptedPlain
            // Parsing is linear in every character. A successful answer used
            // to be parsed while ranking, again on the main actor when adopted,
            // and a third time to choose its cache extension.
            self.parsed = acceptedSynchronised == nil ? nil : parsed
            self.providerMetadata = providerMetadata
        }

        /// The text worth keeping between launches.
        var cacheText: String? {
            if parsed != nil, let synchronised { return synchronised }
            return plain
        }

        var cacheExtension: String { parsed == nil ? "txt" : "lrc" }

        var cacheAttribution: CacheAttribution {
            CacheAttribution(
                provider: source,
                copyright: providerMetadata?.copyright,
                region: providerMetadata?.region)
        }
    }

    enum Failure: Error, Equatable {
        case badResponse
        case responseTooLarge
        case rateLimited
        case server(Int)
    }

    typealias Loader =
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct LRCLIBCandidate: Decodable {
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: Double
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private struct LyricsOvhReply: Decodable {
        let lyrics: String
    }

    private struct QQSearchReply: Decodable {
        struct Payload: Decodable {
            struct Songs: Decodable {
                struct Song: Decodable {
                    struct Singer: Decodable {
                        let name: String
                    }

                    let songmid: String
                    let songname: String
                    let albumname: String
                    let interval: Double
                    let singer: [Singer]
                }

                let list: [Song]
            }

            let song: Songs
        }

        let data: Payload
    }

    private struct QQLyricsReply: Decodable {
        let lyric: String?
    }

    private struct NetEaseSearchReply: Decodable {
        struct Result: Decodable {
            struct Song: Decodable {
                struct Album: Decodable {
                    let name: String
                }

                struct Artist: Decodable {
                    let name: String
                }

                let id: Int
                let name: String
                let duration: Double
                let album: Album
                let artists: [Artist]
            }

            let songs: [Song]?
        }

        let result: Result?
    }

    private struct NetEaseLyricsReply: Decodable {
        struct Part: Decodable {
            let lyric: String
        }

        let lrc: Part?
        let klyric: Part?
        /// The same song in another language. Requested since this was
        /// written — `tv=-1` in the query — and discarded ever since.
        let tlyric: Part?
    }

    /// Query-side normalisation is invariant across every candidate.
    ///
    /// A search currently returns fifteen candidates per provider. Computing
    /// both Chinese transliterations inside `matches` repeated the same two
    /// CoreFoundation transforms up to forty-five times for one lookup.
    private struct WantedMatch: Sendable {
        let title: String
        let latinTitle: String
        let fullTitle: String
        let latinFullTitle: String
        let isBacking: Bool
        let artist: String
        let latinArtist: String
        let duration: Double
        /// Carried through so the chosen answer can be attributed before it is
        /// returned. See `strongest(in:wanted:)`.
        let performers: [String]

        init(_ query: Query) {
            title = OnlineLyrics.canonicalTitle(query.title)
            latinTitle = OnlineLyrics.transliterated(title)
            fullTitle = OnlineLyrics.normalised(query.title)
            latinFullTitle = OnlineLyrics.transliterated(query.title)
            isBacking = OnlineLyrics.isBackingTitle(query.title)
            artist = OnlineLyrics.normalised(query.artist)
            latinArtist = OnlineLyrics.transliterated(query.artist)
            duration = query.duration
            performers = query.performers
        }
    }

    private struct LRCLIBSelection {
        let candidate: LRCLIBCandidate
        let synchronised: String?
        let plain: String?
        let parsed: Lyrics?
    }

    private enum Attempt: Sendable {
        case answer(Match?)
        case failed(Failure)
        case qualityGraceExpired
    }

    private struct MatchQuality: Comparable {
        let hasUsefulWords: Bool
        let isTimed: Bool
        let exactTitle: Bool
        let exactArtist: Bool
        let exactDuration: Bool
        let coverage: Double
        let lineCount: Int
        let durationError: Double
        let sourcePreference: Int

        static func < (lhs: MatchQuality, rhs: MatchQuality) -> Bool {
            if lhs.hasUsefulWords != rhs.hasUsefulWords {
                return !lhs.hasUsefulWords
            }
            if lhs.isTimed != rhs.isTimed {
                return !lhs.isTimed
            }
            if lhs.exactTitle != rhs.exactTitle {
                return !lhs.exactTitle
            }
            if lhs.exactArtist != rhs.exactArtist {
                return !lhs.exactArtist
            }
            if lhs.exactDuration != rhs.exactDuration {
                return !lhs.exactDuration
            }
            if lhs.coverage != rhs.coverage {
                return lhs.coverage < rhs.coverage
            }
            if lhs.lineCount != rhs.lineCount {
                return lhs.lineCount < rhs.lineCount
            }
            if lhs.durationError != rhs.durationError {
                return lhs.durationError > rhs.durationError
            }
            return lhs.sourcePreference < rhs.sourcePreference
        }
    }

    private let loader: Loader
    private let musixmatch: MusixmatchSubtitleAdapter?
    private let qualityGrace: Duration

    init(
        musixmatch: MusixmatchSubtitleAdapter? = nil,
        qualityGrace: Duration = OnlineLyrics.defaultQualityGrace,
        loader: @escaping Loader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.musixmatch = musixmatch?.isConfigured == true ? musixmatch : nil
        self.qualityGrace = qualityGrace
        self.loader = loader
    }

    var isMusixmatchConfigured: Bool { musixmatch != nil }

    /// A beta-session opt-in: the key is read once from the launch environment
    /// and never copied into preferences, cache names or diagnostic output.
    /// Relaunching without the variable returns to the four keyless providers.
    static func liveMusixmatch(
        environment: [String: String]
    ) -> MusixmatchSubtitleAdapter? {
        musixmatchAdapter(apiKey: environment["MUSIXMATCH_API_KEY"])
    }

    static func musixmatchAdapter(apiKey: String?) -> MusixmatchSubtitleAdapter? {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else { return nil }
        return MusixmatchSubtitleAdapter(apiKey: key) { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, response)
        }
    }

    /// Asks every database concurrently and returns the strongest answer.
    ///
    /// A timed result starts a short grace period rather than winning the race
    /// outright. Two timestamped lines are evidence that a provider has an
    /// answer, not that it has the complete answer: another catalogue commonly
    /// returns the full sixty-line timeline a fraction of a second later.
    /// One dead service still does not hide a valid answer from the others.
    func fetch(_ query: Query) async throws -> Match? {
        let wanted = WantedMatch(query)
        return try await withThrowingTaskGroup(
            of: Attempt.self, returning: Match?.self
        ) { group in
            var operations: [@Sendable () async -> Attempt] = [
                { await attempt { try await fetchLRCLIB(query, wanted: wanted) } },
                { await attempt { try await fetchQQMusic(query, wanted: wanted) } },
                { await attempt { try await fetchNetEase(query, wanted: wanted) } },
                { await attempt { try await fetchLyricsOvh(query) } },
            ]
            if musixmatch != nil {
                operations.append {
                    await attempt { try await fetchMusixmatch(query) }
                }
            }
            for operation in operations {
                group.addTask(operation: operation)
            }
            let providerCount = operations.count

            var answers: [Match] = []
            var failures: [Failure] = []
            var notFound = 0
            var providerCompletions = 0
            var graceStarted = false
            let grace = qualityGrace
            while let result = try await group.next() {
                try Task.checkCancellation()
                switch result {
                case let .answer(match):
                    providerCompletions += 1
                    guard let match else {
                        notFound += 1
                        break
                    }
                    answers.append(match)
                    if match.parsed != nil, !graceStarted {
                        graceStarted = true
                        group.addTask {
                            try await Task.sleep(for: grace)
                            return .qualityGraceExpired
                        }
                    }
                case let .failed(failure):
                    providerCompletions += 1
                    failures.append(failure)
                case .qualityGraceExpired:
                    group.cancelAll()
                    return strongest(in: answers, wanted: wanted)
                }
                if providerCompletions == providerCount, !answers.isEmpty {
                    group.cancelAll()
                    return strongest(in: answers, wanted: wanted)
                }
            }
            if let answer = strongest(in: answers, wanted: wanted) { return answer }
            // At least one database genuinely answered "not found"; another
            // database being down does not turn that into a global outage.
            if notFound > 0 { return nil }
            if failures.allSatisfy({ $0 == .rateLimited }) { throw Failure.rateLimited }
            if let failure = failures.first { throw failure }
            return nil
        }
    }

    /// Every answer that came back, best first.
    ///
    /// `fetch` returns one; this keeps the rest, because when the best answer
    /// is the wrong song — a cover, a live take, a different edit — nothing
    /// else in the application can help and every reopen picks the same one
    /// again. The alternatives were already fetched and were being discarded.
    ///
    /// Behind a lock rather than bare: this is written on whichever executor
    /// ran the search and read on the main actor, and changing songs quickly
    /// enough leaves two searches overlapping — cancellation is a request, not
    /// a barrier.
    private nonisolated(unsafe) static var answers: [Match] = []
    private static let answersLock = NSLock()

    static var lastAnswers: [Match] {
        get {
            answersLock.lock()
            defer { answersLock.unlock() }
            return answers
        }
        set {
            answersLock.lock()
            answers = newValue
            answersLock.unlock()
        }
    }

    private func strongest(in answers: [Match], wanted: WantedMatch) -> Match? {
        Self.lastAnswers =
            answers
            .filter { $0.parsed != nil }
            .sorted { quality(of: $0, wanted: wanted) > quality(of: $1, wanted: wanted) }
            .map { attributed($0, performers: wanted.performers) ?? $0 }
        guard
            let best = answers.max(by: {
                quality(of: $0, wanted: wanted) < quality(of: $1, wanted: wanted)
            })
        else { return nil }
        return attributed(best, performers: wanted.performers)
    }

    /// Re-reads the winner's own `.lrc` now that the cast is known.
    ///
    /// Each provider parses as it decodes, before there is anything to compare
    /// answers against, and none of them is given the performer list. Doing it
    /// here instead means one re-read of one file rather than threading the list
    /// through five decoders — and the text is the same text, so a duet marker
    /// the first pass left as a lyric becomes an attribution rather than a line
    /// of its own. Without it 「黃霄雲」 was sung.
    private func attributed(_ match: Match, performers: [String]) -> Match? {
        guard !performers.isEmpty, let raw = match.synchronised,
            let reparsed = Lyrics.parse(raw, performers: performers),
            reparsed != match.parsed
        else { return match }
        return Match(
            source: match.source, trackName: match.trackName,
            artistName: match.artistName, albumName: match.albumName,
            duration: match.duration, synchronised: raw, plain: match.plain,
            parsed: reparsed, providerMetadata: match.providerMetadata)
            ?? match
    }

    private func quality(of match: Match, wanted: WantedMatch) -> MatchQuality {
        let candidateTitle = Self.canonicalTitle(match.trackName)
        let candidateFullTitle = Self.normalised(match.trackName)
        let exactTitle =
            candidateTitle == wanted.title
            || Self.transliterated(candidateTitle) == wanted.latinTitle
            || candidateFullTitle == wanted.fullTitle
            || Self.transliterated(match.trackName) == wanted.latinFullTitle
        let candidateArtist = Self.normalised(match.artistName)
        let exactArtist =
            wanted.artist.isEmpty || candidateArtist == wanted.artist
            || Self.transliterated(match.artistName) == wanted.latinArtist
        // An unavailable player duration is not evidence for or against a
        // candidate. Treating it as zero made the shortest recording win the
        // final tie whenever recognition could identify a title but not its
        // complete running time.
        let durationError =
            wanted.duration > 0
            ? match.duration.map { abs($0 - wanted.duration) } ?? .infinity
            : 0
        let exactDuration = wanted.duration <= 0 || durationError <= 2

        var firstTime = Double.infinity
        var lastTime = -Double.infinity
        var lineCount = 0
        if let parsed = match.parsed {
            for line in parsed.lines {
                guard
                    line.text.nonEmpty != nil,
                    !Self.isPlaceholderLine(line.text)
                else { continue }
                lineCount += 1
                firstTime = min(firstTime, line.time)
                lastTime = max(lastTime, line.time)
            }
        }
        let referenceDuration =
            wanted.duration > 0 ? wanted.duration : match.duration ?? 0
        let coverage =
            referenceDuration > 0 && lineCount > 1
            ? min(1, max(0, (lastTime - firstTime) / referenceDuration))
            : 0
        let hasUsefulWords =
            lineCount > 0
            || (match.parsed == nil
                && match.plain.map {
                    !$0.isEmpty && !Self.isInstrumentalLyrics($0)
                } == true)

        return MatchQuality(
            hasUsefulWords: hasUsefulWords,
            isTimed: match.parsed != nil,
            exactTitle: exactTitle,
            exactArtist: exactArtist,
            exactDuration: exactDuration,
            coverage: coverage,
            lineCount: lineCount,
            durationError: durationError,
            sourcePreference: Self.sourcePreference(match.source))
    }

    private static func sourcePreference(_ source: Source) -> Int {
        switch source {
        case .musixmatch: 5
        case .lrclib: 4
        case .qqMusic: 3
        case .netEase: 2
        case .lyricsOvh: 1
        }
    }

    private func attempt(
        _ operation: @escaping @Sendable () async throws -> Match?
    ) async -> Attempt {
        do {
            return .answer(try await operation())
        } catch is CancellationError {
            return .failed(.badResponse)
        } catch let failure as Failure {
            return .failed(failure)
        } catch {
            return .failed(.badResponse)
        }
    }

    private func fetchMusixmatch(_ query: Query) async throws -> Match? {
        guard let musixmatch else { return nil }
        do {
            let subtitle = try await musixmatch.fetch(
                title: query.title,
                artist: query.artist,
                duration: query.duration > 0 ? query.duration : nil)
            return Match(
                source: .musixmatch,
                trackName: query.title,
                artistName: query.artist,
                albumName: query.album,
                duration: query.duration > 0 ? query.duration : nil,
                synchronised: subtitle.rawLRC,
                plain: subtitle.rawLRC,
                providerMetadata: ProviderMetadata(
                    copyright: subtitle.attribution.copyright,
                    scriptTrackingURL: subtitle.tracking.scriptURL,
                    pixelTrackingURL: subtitle.tracking.pixelURL,
                    region: subtitle.region))
        } catch MusixmatchSubtitleFailure.missingSubtitle,
            MusixmatchSubtitleFailure.restricted(region: _)
        {
            return nil
        } catch MusixmatchSubtitleFailure.rateLimited(retryAfter: _) {
            throw Failure.rateLimited
        } catch let MusixmatchSubtitleFailure.serviceStatus(status) {
            if status == 404 { return nil }
            throw Failure.server(status)
        } catch {
            throw Failure.badResponse
        }
    }

    private func fetchLRCLIB(_ query: Query, wanted: WantedMatch) async throws -> Match? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
            URLQueryItem(name: "album_name", value: query.album),
        ]
        guard let url = components?.url else { throw Failure.badResponse }
        let candidates: [LRCLIBCandidate] = try await decode(
            [LRCLIBCandidate].self, from: request(url))
        guard let best = bestLRCLIBMatch(candidates, wanted: wanted) else { return nil }
        return Match(
            source: .lrclib, trackName: best.candidate.trackName,
            artistName: best.candidate.artistName,
            albumName: best.candidate.albumName, duration: best.candidate.duration,
            synchronised: best.synchronised, plain: best.plain, parsed: best.parsed)
    }

    private func fetchLyricsOvh(_ query: Query) async throws -> Match? {
        guard
            let artist = query.artist.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed),
            let title = query.title.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://api.lyrics.ovh/v1/\(artist)/\(title)")
        else { throw Failure.badResponse }
        do {
            let reply: LyricsOvhReply = try await decode(
                LyricsOvhReply.self, from: request(url))
            guard let plain = reply.lyrics.nonEmpty else { return nil }
            return Match(
                source: .lyricsOvh, trackName: query.title, artistName: query.artist,
                albumName: query.album, duration: nil, synchronised: nil, plain: plain)
        } catch Failure.server(404) {
            return nil
        }
    }

    private func fetchQQMusic(_ query: Query, wanted: WantedMatch) async throws -> Match? {
        var search = URLComponents(
            string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")
        search?.queryItems = [
            URLQueryItem(name: "w", value: "\(query.title) \(query.artist)"),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: "15"),
            URLQueryItem(name: "format", value: Self.jsonFormat),
        ]
        guard let searchURL = search?.url else { throw Failure.badResponse }
        let result: QQSearchReply = try await decode(
            QQSearchReply.self, from: request(searchURL, referer: "https://y.qq.com/"))
        guard
            let song = result.data.song.list
                .filter({
                    matches(
                        title: $0.songname,
                        artist: $0.singer.map(\.name).joined(separator: " "),
                        duration: $0.interval, wanted: wanted)
                })
                .min(by: {
                    abs($0.interval - query.duration) < abs($1.interval - query.duration)
                })
        else { return nil }

        var lyric = URLComponents(
            string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")
        lyric?.queryItems = [
            URLQueryItem(name: "songmid", value: song.songmid),
            URLQueryItem(name: "format", value: Self.jsonFormat),
            URLQueryItem(name: "nobase64", value: "1"),
        ]
        guard let lyricURL = lyric?.url else { throw Failure.badResponse }
        let reply: QQLyricsReply = try await decode(
            QQLyricsReply.self, from: request(lyricURL, referer: "https://y.qq.com/"))
        guard let words = reply.lyric?.nonEmpty else { return nil }
        return Match(
            source: .qqMusic, trackName: song.songname,
            artistName: song.singer.map(\.name).joined(separator: " / "),
            albumName: song.albumname, duration: song.interval,
            synchronised: words, plain: words)
    }

    private func fetchNetEase(_ query: Query, wanted: WantedMatch) async throws -> Match? {
        var search = URLComponents(string: "https://music.163.com/api/search/get/web")
        search?.queryItems = [
            URLQueryItem(name: "s", value: "\(query.title) \(query.artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "total", value: Self.trueFlag),
            URLQueryItem(name: "limit", value: "15"),
        ]
        guard let searchURL = search?.url else { throw Failure.badResponse }
        let result: NetEaseSearchReply = try await decode(
            NetEaseSearchReply.self, from: request(searchURL))
        guard
            let song = (result.result?.songs ?? [])
                .filter({
                    matches(
                        title: $0.name, artist: $0.artists.map(\.name).joined(separator: " "),
                        duration: $0.duration / 1_000, wanted: wanted)
                })
                .min(by: {
                    abs($0.duration / 1_000 - query.duration)
                        < abs($1.duration / 1_000 - query.duration)
                })
        else { return nil }

        var lyric = URLComponents(string: "https://music.163.com/api/song/lyric")
        lyric?.queryItems = [
            URLQueryItem(name: "id", value: String(song.id)),
            URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "kv", value: "-1"),
            URLQueryItem(name: "tv", value: "-1"),
        ]
        guard let lyricURL = lyric?.url else { throw Failure.badResponse }
        let reply: NetEaseLyricsReply = try await decode(
            NetEaseLyricsReply.self, from: request(lyricURL))
        var plain: String?
        for words in [reply.klyric?.lyric.nonEmpty, reply.lrc?.lyric.nonEmpty].compactMap({
            $0
        }) {
            guard !Self.isInstrumentalLyrics(words) else { continue }
            if plain == nil { plain = words }
            if let parsed = Lyrics.parse(words) {
                let translated =
                    reply.tlyric?.lyric.nonEmpty.map(parsed.withTranslation) ?? parsed
                return Match(
                    source: .netEase, trackName: song.name,
                    artistName: song.artists.map(\.name).joined(separator: " / "),
                    albumName: song.album.name, duration: song.duration / 1_000,
                    synchronised: words, plain: words, parsed: translated)
            }
        }
        return Match(
            source: .netEase, trackName: song.name,
            artistName: song.artists.map(\.name).joined(separator: " / "),
            albumName: song.album.name, duration: song.duration / 1_000,
            synchronised: nil, plain: plain)
    }

    private func request(_ url: URL, referer: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(
            "YunAudio/1.0 (https://github.com/YuhuanStudio/YunAudio)",
            forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        return request
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type, from request: URLRequest
    ) async throws -> Value {
        let (data, response) = try await loader(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        if http.statusCode == 429 { throw Failure.rateLimited }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.server(http.statusCode)
        }
        guard data.count <= 2 * 1_024 * 1_024 else { throw Failure.responseTooLarge }
        return try JSONDecoder().decode(type, from: data)
    }

    private func bestLRCLIBMatch(
        _ candidates: [LRCLIBCandidate], wanted: WantedMatch
    ) -> LRCLIBSelection? {
        var best: LRCLIBSelection?
        for candidate in candidates {
            guard
                matches(
                    title: candidate.trackName, artist: candidate.artistName,
                    duration: candidate.duration, wanted: wanted)
            else { continue }
            let synchronised = candidate.syncedLyrics?.nonEmpty
            let parsed = synchronised.flatMap { Lyrics.parse($0) }
            let acceptedSynchronised =
                parsed != nil
                    && synchronised.map(Self.isInstrumentalLyrics) != true
                ? synchronised : nil
            // Cleaned before it is ranked, not after. A candidate whose
            // untimed field is nothing but a credit block has nothing to show,
            // and uncleaned it could still win on duration — then `Match.init`
            // cleaned it to nil, found no timed words either, and returned nil
            // for the whole provider, discarding a second candidate that had
            // real words.
            let acceptedPlain =
                candidate.plainLyrics?.nonEmpty
                .flatMap { Lyrics.plainWords(from: $0) }
                .flatMap { Self.isInstrumentalLyrics($0) ? nil : $0 }
            guard acceptedSynchronised != nil || acceptedPlain != nil else { continue }
            let selection = LRCLIBSelection(
                candidate: candidate, synchronised: acceptedSynchronised,
                plain: acceptedPlain,
                parsed: acceptedSynchronised == nil ? nil : parsed)
            guard let current = best else {
                best = selection
                continue
            }
            let selectionTimed = selection.parsed != nil
            let currentTimed = current.parsed != nil
            if selectionTimed != currentTimed {
                if selectionTimed { best = selection }
            } else if abs(candidate.duration - wanted.duration)
                < abs(current.candidate.duration - wanted.duration)
            {
                best = selection
            }
        }
        return best
    }

    /// Loose enough for live/TV edition suffixes, strict enough not to attach
    /// another recording merely because a search engine ranked it highly.
    private func matches(
        title: String, artist: String, duration: Double, wanted: WantedMatch
    ) -> Bool {
        let candidateTitle = Self.canonicalTitle(title)
        let candidateFullTitle = Self.normalised(title)
        let candidateIsBacking = Self.isBackingTitle(title)
        let durationIsExact =
            wanted.duration > 0 && abs(duration - wanted.duration) <= 3
        let titleFits =
            candidateTitle == wanted.title
            || Self.transliterated(candidateTitle) == wanted.latinTitle
            || candidateFullTitle == wanted.fullTitle
            || Self.transliterated(title) == wanted.latinFullTitle
            || (min(candidateTitle.count, wanted.title.count) >= 4
                && (candidateTitle.contains(wanted.title)
                    || wanted.title.contains(candidateTitle)))
            // A character or two apart, with the running time already agreeing
            // to within three seconds. 「來不及愛妳」 and 「来不及爱你」 are one
            // song: neither the characters nor the pinyin fallback matched it,
            // because Foundation reads 妳 as "nai" against 你 as "ni", and ICU's
            // Hant-Hans leaves 妳 alone — it is a character in its own right,
            // not a traditional form of 你. A variant table would have to be
            // extended for whichever character came next; a distance does not.
            || Self.simplified(candidateTitle) == Self.simplified(wanted.title)
            || (durationIsExact
                && Self.isNearly(
                    Self.simplified(candidateTitle), Self.simplified(wanted.title)))
        let candidateArtist = Self.normalised(artist)
        let candidateArtistLatin = Self.transliterated(artist)
        let artistFits =
            wanted.artist.isEmpty || candidateArtist.isEmpty
            || candidateArtist.contains(wanted.artist)
            || wanted.artist.contains(candidateArtist)
            || candidateArtistLatin.contains(wanted.latinArtist)
            || wanted.latinArtist.contains(candidateArtistLatin)
        let durationFits = wanted.duration <= 0 || abs(duration - wanted.duration) <= 12
        return titleFits && artistFits && durationFits
            && (wanted.isBacking || !candidateIsBacking)
    }

    /// One script, so that a traditional title and a simplified one compare.
    ///
    /// ICU owns the systematic half of this: 來→来, 愛→爱, and every other pair
    /// nobody should be maintaining by hand. What it does not own is 妳, which
    /// is a character in its own right rather than a traditional form of 你, so
    /// it survives the transform — that residue is what `isNearly` is for.
    static func simplified(_ value: String) -> String {
        value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value
    }

    /// Whether two titles differ by little enough to be the same song.
    ///
    /// Only ever consulted once the running time already agrees to the second,
    /// so this decides between "the same song written differently" and "a
    /// different song of the same length by the same artist" — and one edit in
    /// five characters is the former. Four characters minimum, because at three
    /// a single edit is a third of the title and 「慢冷」 would reach 「慢熱」.
    static func isNearly(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs)
        let b = Array(rhs)
        guard a.count >= 4, b.count >= 4 else { return lhs == rhs }
        let longest = max(a.count, b.count)
        // A quarter of the longer title, so five characters tolerate one edit
        // and eight tolerate two.
        let budget = max(1, longest / 4)
        guard abs(a.count - b.count) <= budget else { return false }
        return editDistance(a, b, upTo: budget) <= budget
    }

    /// Levenshtein, abandoned as soon as it passes `upTo`.
    ///
    /// Two rows rather than a matrix, because this runs against every candidate
    /// of every provider and the titles are short enough that allocating a
    /// square of them would be the expensive part.
    private static func editDistance(
        _ a: [Character], _ b: [Character], upTo limit: Int
    ) -> Int {
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
                rowBest = min(rowBest, current[j])
            }
            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func canonicalTitle(_ value: String) -> String {
        var value = value
        for pair in [("(", ")"), ("（", "）"), ("[", "]"), ("【", "】")] {
            while let opening = value.range(of: pair.0),
                let closing = value.range(
                    of: pair.1, range: opening.upperBound..<value.endIndex)
            {
                value.removeSubrange(opening.lowerBound..<closing.upperBound)
            }
        }
        for suffix in [
            "officialmusicvideo", "officialvideo", "lyricsvideo", "完整版", "纯享版",
            "純享版", "现场版", "現場版", "live",
        ] {
            let folded = normalised(value)
            guard folded.hasSuffix(normalised(suffix)) else { continue }
            value = String(value.dropLast(min(value.count, suffix.count)))
        }
        return normalised(value)
    }

    static func isBackingTitle(_ value: String) -> Bool {
        let title = normalised(value)
        return ["伴奏", "纯音乐", "純音樂", "instrumental", "karaoke", "offvocal"]
            .contains { title.contains(normalised($0)) }
    }

    /// True for the placeholder LRC some catalogues return for an instrumental.
    ///
    /// Its timestamps make it look like the strongest possible answer to the
    /// provider race, so title matching alone is insufficient: releases often
    /// omit "伴奏" from the searchable title even when the lyric body says
    /// there are no words.
    static func isInstrumentalLyrics(_ value: String) -> Bool {
        let compact = normalised(value)
        if [
            "此歌曲为没有填词的纯音乐请您欣赏",
            "此歌曲為沒有填詞的純音樂請您欣賞",
            "该歌曲为纯音乐请欣赏",
            "該歌曲為純音樂請欣賞",
            "纯音乐请欣赏",
            "純音樂請欣賞",
            "暂无歌词",
            "暫無歌詞",
        ].contains(where: compact.contains) {
            return true
        }

        let bodies = value.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            var line = raw[...]
            while line.first == "[", let close = line.firstIndex(of: "]") {
                line = line[line.index(after: close)...]
            }
            return normalised(String(line)).nonEmpty
        }
        let placeholders = Set(["instrumental", "musiconly", "纯音乐", "純音樂"])
        return !bodies.isEmpty && bodies.allSatisfy(placeholders.contains)
    }

    private static func isPlaceholderLine(_ value: String) -> Bool {
        let compact = normalised(value)
        return switch compact {
        case "", "instrumental", "musiconly", "纯音乐", "純音樂", "暂无歌词", "暫無歌詞":
            true
        default:
            false
        }
    }

    static func normalised(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// A secondary comparison for simplified/traditional variants. Foundation
    /// transliterates 黃 and 黄 to the same Latin form; maintaining a partial
    /// hand-written conversion table would silently fail on whichever
    /// character the table forgot next.
    private static func transliterated(_ value: String) -> String {
        normalised(value.applyingTransform(.toLatin, reverse: false) ?? value)
    }

    static func cacheURL(
        for query: Query, source: Source, extension suffix: String, in directory: URL
    ) -> URL {
        let raw = "\(query.artist) - \(query.title)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let safe =
            raw.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
            .trimmingCharacters(in: .whitespaces)
        return directory.appendingPathComponent(
            "\(String(safe.prefix(180))) [\(source.rawValue)].\(suffix)")
    }

    /// Which provider produced a cache file, or nil for a user's own file.
    static func cachedSource(for url: URL) -> Source? {
        let stem = url.deletingPathExtension().lastPathComponent
        return Source.allCases.first {
            stem.hasSuffix(" [\($0.rawValue)]")
        }
    }

    static func cacheAttributionURL(for lyricsURL: URL) -> URL {
        lyricsURL.appendingPathExtension("attribution.json")
    }

    static func encodeCacheAttribution(_ attribution: CacheAttribution) throws -> Data {
        guard
            attribution.copyright?.count ?? 0 <= CacheAttribution.maximumCopyrightLength,
            attribution.region?.count ?? 0 <= CacheAttribution.maximumRegionLength
        else {
            throw Failure.badResponse
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(attribution)
        guard data.count <= CacheAttribution.maximumEncodedBytes else {
            throw Failure.responseTooLarge
        }
        return data
    }

    static func decodeCacheAttribution(_ data: Data) throws -> CacheAttribution {
        guard data.count <= CacheAttribution.maximumEncodedBytes else {
            throw Failure.responseTooLarge
        }
        return try JSONDecoder().decode(CacheAttribution.self, from: data)
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
