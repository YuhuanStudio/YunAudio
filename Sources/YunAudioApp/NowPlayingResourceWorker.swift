import Foundation
import YunAudioEngine

struct NowPlayingResourceRequest: Sendable {
    let generation: UInt64
    let track: NowPlaying.Track
    let directory: URL?
    let needsArtwork: Bool
    let timeout: Duration

    init(
        generation: UInt64,
        track: NowPlaying.Track,
        directory: URL?,
        needsArtwork: Bool,
        timeout: Duration = NowPlayingResourceLoader.defaultTimeout
    ) {
        self.generation = generation
        self.track = track
        self.directory = directory
        self.needsArtwork = needsArtwork
        self.timeout = timeout
    }
}

struct NowPlayingResourceSnapshot: Sendable, Equatable {
    let generation: UInt64
    let trackIdentity: String
    let timedLyrics: Lyrics?
    let timedLyricsURL: URL?
    let plainLyrics: String?
    let plainLyricsURL: URL?
    let attribution: OnlineLyrics.CacheAttribution?
    let melody: MidiMelody?
    let artworkURL: URL?
    let directoryEntries: Int
    let filesRead: Int
    let bytesRead: Int
    let reachedLimit: Bool
    let timedOut: Bool
}

/// Reads all local resources for one player track from one bounded directory scan.
///
/// The old adoption path listed the same directory independently for timed words,
/// plain words, MIDI and artwork, then read each file without a byte ceiling on
/// MainActor. This loader lists once, reads at most three content files plus one
/// attribution sidecar, and returns only immutable values.
enum NowPlayingResourceLoader {
    static let defaultTimeout: Duration = .milliseconds(750)
    static let maximumDirectoryEntries = 4_096
    static let maximumDirectoryNameBytes = 2 * 1_024 * 1_024
    static let maximumMetadataCharacters = 1_024
    static let maximumLyricsBytes = 2 * 1_024 * 1_024
    static let maximumPlainLyricsBytes = 2 * 1_024 * 1_024
    static let maximumMelodyBytes = 8 * 1_024 * 1_024
    static let maximumAttributionBytes = 8 * 1_024
    static let maximumTotalBytes = 12 * 1_024 * 1_024
    static let maximumFiles = 4

    static func load(
        _ request: NowPlayingResourceRequest,
        fileSystem: BoundedFileSystem = .system
    ) -> NowPlayingResourceSnapshot {
        guard let directory = request.directory else {
            return empty(request)
        }
        let deadline = ExternalIODeadline(timeout: request.timeout)
        let listing = fileSystem.listDirectory(
            directory, maximumDirectoryEntries, maximumDirectoryNameBytes, deadline)
        guard listing.isAvailable else {
            return snapshot(
                request, listing: listing, reachedLimit: listing.reachedLimit,
                timedOut: listing.timedOut)
        }

        let timedName = bestFileName(
            for: request.track, names: listing.names, extensions: ["lrc"])
        let plainName = bestFileName(
            for: request.track, names: listing.names, extensions: ["txt"])
        let melodyName = bestFileName(
            for: request.track, names: listing.names, extensions: ["mid", "midi"])
        let artworkName =
            request.needsArtwork
            ? bestFileName(
                for: request.track, names: listing.names,
                extensions: ["jpg", "jpeg", "png", "heic", "webp"])
            : nil

        var filesRead = 0
        var bytesRead = 0
        var reachedLimit = listing.reachedLimit
        var timedOut = listing.timedOut

        func read(_ url: URL, maximumBytes: Int) -> Data? {
            guard filesRead < maximumFiles, !deadline.hasExpired else {
                reachedLimit = true
                timedOut = timedOut || deadline.hasExpired
                return nil
            }
            switch fileSystem.readFile(url, maximumBytes, deadline) {
            case .data(let data):
                guard data.count <= maximumTotalBytes - min(bytesRead, maximumTotalBytes)
                else {
                    reachedLimit = true
                    return nil
                }
                filesRead += 1
                bytesRead += data.count
                return data
            case .unavailable:
                return nil
            case .tooLarge:
                reachedLimit = true
                return nil
            case .timedOut:
                timedOut = true
                reachedLimit = true
                return nil
            }
        }

        var timedLyrics: Lyrics?
        var timedURL: URL?
        if let timedName {
            let url = directory.appendingPathComponent(timedName)
            if let data = read(url, maximumBytes: maximumLyricsBytes),
                let text = String(data: data, encoding: .utf8),
                let parsed = Lyrics.parse(text)
            {
                timedLyrics = parsed
                timedURL = url
            }
        }

        var plainLyrics: String?
        var plainURL: URL?
        if timedLyrics == nil, let plainName {
            let url = directory.appendingPathComponent(plainName)
            if let data = read(url, maximumBytes: maximumPlainLyricsBytes),
                let text = String(data: data, encoding: .utf8)
            {
                // Cleaned on the way out, not only on the way in. What an index
                // calls its untimed field is routinely the same `.lrc`
                // document, and a cache written before this was understood is
                // still on disk — a trim alone put `[00:00.00-1] 作词 : …` back
                // on the stage on every replay.
                if let words = Lyrics.plainWords(from: text) {
                    plainLyrics = words
                    plainURL = url
                }
            }
        }

        var attribution: OnlineLyrics.CacheAttribution?
        if let wordsURL = timedURL ?? plainURL,
            let source = OnlineLyrics.cachedSource(for: wordsURL),
            let data = read(
                OnlineLyrics.cacheAttributionURL(for: wordsURL),
                maximumBytes: maximumAttributionBytes),
            let decoded = try? OnlineLyrics.decodeCacheAttribution(data),
            decoded.provider == source
        {
            attribution = decoded
        }

        var melody: MidiMelody?
        if let melodyName,
            let data = read(
                directory.appendingPathComponent(melodyName),
                maximumBytes: maximumMelodyBytes)
        {
            melody = MidiMelody.parse(data)
        }

        return NowPlayingResourceSnapshot(
            generation: request.generation, trackIdentity: request.track.identity,
            timedLyrics: timedLyrics, timedLyricsURL: timedURL,
            plainLyrics: plainLyrics, plainLyricsURL: plainURL,
            attribution: attribution, melody: melody,
            artworkURL: artworkName.map(directory.appendingPathComponent),
            directoryEntries: listing.names.count, filesRead: filesRead,
            bytesRead: bytesRead, reachedLimit: reachedLimit,
            timedOut: timedOut || deadline.hasExpired)
    }

    /// Pure asset matching used by the worker and retained for deterministic tests.
    static func bestFileName(
        for track: NowPlaying.Track,
        names: [String],
        extensions: [String]
    ) -> String? {
        let titleField = String(track.title.prefix(maximumMetadataCharacters))
        let artistField = String(track.artist.prefix(maximumMetadataCharacters))
        let wanted = normalised("\(artistField) \(titleField)")
        let title = normalised(titleField)
        let artist = normalised(artistField)
        guard !title.isEmpty else { return nil }
        let admittedExtensions = Set(extensions.map { $0.lowercased() })
        let candidates = names.filter {
            admittedExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }
        let userFiles = candidates.filter {
            OnlineLyrics.cachedSource(for: URL(fileURLWithPath: $0)) == nil
        }
        let downloaded = candidates.filter {
            OnlineLyrics.cachedSource(for: URL(fileURLWithPath: $0)) != nil
        }

        func best(in candidates: [String]) -> String? {
            let ordered = candidates.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            return ordered.first { normalised($0).contains(wanted) }
                ?? ordered.first {
                    let file = normalised($0)
                    return file.contains(title) && !artist.isEmpty && file.contains(artist)
                }
                ?? ordered.first { normalised($0).contains(title) }
        }
        return best(in: userFiles) ?? best(in: downloaded)
    }

    private static func normalised(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func empty(
        _ request: NowPlayingResourceRequest
    ) -> NowPlayingResourceSnapshot {
        snapshot(
            request,
            listing: BoundedDirectorySnapshot(
                names: [], isAvailable: false, reachedLimit: false, timedOut: false),
            reachedLimit: false, timedOut: false)
    }

    private static func snapshot(
        _ request: NowPlayingResourceRequest,
        listing: BoundedDirectorySnapshot,
        reachedLimit: Bool,
        timedOut: Bool
    ) -> NowPlayingResourceSnapshot {
        NowPlayingResourceSnapshot(
            generation: request.generation, trackIdentity: request.track.identity,
            timedLyrics: nil, timedLyricsURL: nil, plainLyrics: nil,
            plainLyricsURL: nil, attribution: nil, melody: nil, artworkURL: nil,
            directoryEntries: listing.names.count, filesRead: 0, bytesRead: 0,
            reachedLimit: reachedLimit, timedOut: timedOut)
    }
}

final class NowPlayingResourceWorker: @unchecked Sendable {
    private let lane:
        LatestExternalWorkLane<NowPlayingResourceRequest, NowPlayingResourceSnapshot>

    init(
        fileSystem: BoundedFileSystem = .system,
        publish: @escaping @MainActor @Sendable (NowPlayingResourceSnapshot) -> Void
    ) {
        lane = LatestExternalWorkLane(
            queue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.now-playing-resources", qos: .utility),
            apply: { NowPlayingResourceLoader.load($0, fileSystem: fileSystem) },
            publish: publish)
    }

    var statistics:
        LatestExternalWorkLane<
            NowPlayingResourceRequest, NowPlayingResourceSnapshot
        >.Statistics
    { lane.statistics }

    @discardableResult
    func submit(_ request: NowPlayingResourceRequest) -> Bool { lane.submit(request) }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }
}
