import Foundation
import YunAudioEngine

/// Independent public lyric sources, asked together and ranked locally.
///
/// The providers are deliberately independent rather than wrappers around one
/// index. Chinese releases and television performances are often absent from
/// western catalogues, while an outage at one community service must not turn
/// every song into "not found".
struct OnlineLyrics: Sendable {
    private static let jsonFormat = "json"
    private static let trueFlag = "true"

    struct Query: Sendable, Equatable {
        let title: String
        let artist: String
        let album: String
        let duration: Double
    }

    enum Source: String, Sendable, Equatable {
        case lrclib = "LRCLIB"
        case qqMusic = "QQ Music"
        case netEase = "NetEase Cloud Music"
        case lyricsOvh = "lyrics.ovh"
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

        init(
            source: Source, trackName: String, artistName: String,
            albumName: String, duration: Double?, synchronised: String?,
            plain: String?
        ) {
            self.source = source
            self.trackName = trackName
            self.artistName = artistName
            self.albumName = albumName
            self.duration = duration
            self.synchronised = synchronised
            self.plain = plain
            // Parsing is linear in every character. A successful answer used
            // to be parsed while ranking, again on the main actor when adopted,
            // and a third time to choose its cache extension.
            self.parsed = synchronised.flatMap(Lyrics.parse)
        }

        /// The text worth keeping between launches.
        var cacheText: String? {
            if let synchronised, Lyrics.parse(synchronised) != nil { return synchronised }
            return plain?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }

        var cacheExtension: String { parsed == nil ? "txt" : "lrc" }
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
    }

    private enum Attempt: Sendable {
        case answer(Match?)
        case failed(Failure)
    }

    private let loader: Loader

    init(
        loader: @escaping Loader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.loader = loader
    }

    static let live = OnlineLyrics()

    /// Asks every database concurrently and returns the strongest answer.
    ///
    /// A timed result always wins. Otherwise LRCLIB wins a tie because it can
    /// identify the exact recording by duration; lyrics.ovh is a title/artist
    /// fallback. One dead service does not hide a valid answer from the others.
    func fetch(_ query: Query) async throws -> Match? {
        try await withThrowingTaskGroup(of: Attempt.self) { group in
            group.addTask { await attempt { try await fetchLRCLIB(query) } }
            group.addTask { await attempt { try await fetchQQMusic(query) } }
            group.addTask { await attempt { try await fetchNetEase(query) } }
            group.addTask { await attempt { try await fetchLyricsOvh(query) } }

            var answers: [Match] = []
            var failures: [Failure] = []
            var notFound = 0
            while let result = try await group.next() {
                try Task.checkCancellation()
                switch result {
                case let .answer(match):
                    guard let match else {
                        notFound += 1
                        continue
                    }
                    // Nothing stronger can arrive than a validated timeline.
                    // Cancelling the three slower requests is both latency and
                    // courtesy to free community services.
                    if match.parsed != nil {
                        group.cancelAll()
                        return match
                    }
                    answers.append(match)
                case let .failed(failure):
                    failures.append(failure)
                }
            }
            if let lrclib = answers.first(where: { $0.source == .lrclib }) {
                return lrclib
            }
            if let any = answers.first { return any }
            // At least one database genuinely answered "not found"; another
            // database being down does not turn that into a global outage.
            if notFound > 0 { return nil }
            if failures.allSatisfy({ $0 == .rateLimited }) { throw Failure.rateLimited }
            if let failure = failures.first { throw failure }
            return nil
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

    private func fetchLRCLIB(_ query: Query) async throws -> Match? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
            URLQueryItem(name: "album_name", value: query.album),
        ]
        guard let url = components?.url else { throw Failure.badResponse }
        let candidates: [LRCLIBCandidate] = try await decode(
            [LRCLIBCandidate].self, from: request(url))
        guard let best = bestLRCLIBMatch(candidates, query: query) else { return nil }
        return Match(
            source: .lrclib, trackName: best.trackName, artistName: best.artistName,
            albumName: best.albumName, duration: best.duration,
            synchronised: best.syncedLyrics?.nonEmpty, plain: best.plainLyrics?.nonEmpty)
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

    private func fetchQQMusic(_ query: Query) async throws -> Match? {
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
                        duration: $0.interval, query: query)
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
            synchronised: Lyrics.parse(words) == nil ? nil : words, plain: words)
    }

    private func fetchNetEase(_ query: Query) async throws -> Match? {
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
                        duration: $0.duration / 1_000, query: query)
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
        guard let words = reply.klyric?.lyric.nonEmpty ?? reply.lrc?.lyric.nonEmpty else {
            return nil
        }
        return Match(
            source: .netEase, trackName: song.name,
            artistName: song.artists.map(\.name).joined(separator: " / "),
            albumName: song.album.name, duration: song.duration / 1_000,
            synchronised: Lyrics.parse(words) == nil ? nil : words, plain: words)
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
        _ candidates: [LRCLIBCandidate], query: Query
    ) -> LRCLIBCandidate? {
        return
            candidates
            .filter {
                let hasWords =
                    $0.syncedLyrics?.nonEmpty != nil || $0.plainLyrics?.nonEmpty != nil
                return hasWords
                    && matches(
                        title: $0.trackName, artist: $0.artistName,
                        duration: $0.duration, query: query)
            }
            .min {
                let leftTimed = Lyrics.parse($0.syncedLyrics ?? "") != nil
                let rightTimed = Lyrics.parse($1.syncedLyrics ?? "") != nil
                if leftTimed != rightTimed { return leftTimed && !rightTimed }
                return abs($0.duration - query.duration) < abs($1.duration - query.duration)
            }
    }

    /// Loose enough for live/TV edition suffixes, strict enough not to attach
    /// another recording merely because a search engine ranked it highly.
    private func matches(
        title: String, artist: String, duration: Double, query: Query
    ) -> Bool {
        let wantedTitle = Self.canonicalTitle(query.title)
        let candidateTitle = Self.canonicalTitle(title)
        let queryIsBacking = Self.isBackingTitle(query.title)
        let candidateIsBacking = Self.isBackingTitle(title)
        let titleFits =
            candidateTitle == wantedTitle
            || Self.transliterated(candidateTitle) == Self.transliterated(wantedTitle)
            || (min(candidateTitle.count, wantedTitle.count) >= 4
                && (candidateTitle.contains(wantedTitle)
                    || wantedTitle.contains(candidateTitle)))
        let wantedArtist = Self.normalised(query.artist)
        let candidateArtist = Self.normalised(artist)
        let wantedArtistLatin = Self.transliterated(query.artist)
        let candidateArtistLatin = Self.transliterated(artist)
        let artistFits =
            wantedArtist.isEmpty || candidateArtist.isEmpty
            || candidateArtist.contains(wantedArtist) || wantedArtist.contains(candidateArtist)
            || candidateArtistLatin.contains(wantedArtistLatin)
            || wantedArtistLatin.contains(candidateArtistLatin)
        let durationFits = query.duration <= 0 || abs(duration - query.duration) <= 12
        return titleFits && artistFits && durationFits
            && (queryIsBacking || !candidateIsBacking)
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
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
