import Foundation
import YunAudioEngine

struct LocalSongResourceRequest: Sendable {
    let generation: UInt64
    let url: URL
    let embeddedArtwork: Data?
    let timeout: Duration

    init(
        generation: UInt64,
        url: URL,
        embeddedArtwork: Data?,
        timeout: Duration = LocalSongResourceLoader.defaultTimeout
    ) {
        self.generation = generation
        self.url = url
        self.embeddedArtwork = embeddedArtwork
        self.timeout = timeout
    }
}

struct LocalSongResourceSnapshot: Sendable, Equatable {
    let generation: UInt64
    let url: URL
    let lyrics: Lyrics?
    let lyricsURL: URL?
    let melody: MidiMelody?
    let artworkURL: URL?
    let filesRead: Int
    let bytesRead: Int
    let rejectedOversizedInput: Bool
    let timedOut: Bool
}

/// Reads the exact-name assets beside one local song under numeric ceilings.
///
/// This intentionally does no directory listing. A downloaded backing-track
/// folder can contain hundreds of thousands of files or live on a stalled
/// network volume; the five expected lyric, tune and cover names are enough.
/// Embedded artwork is written from this owner too, so no filesystem call from
/// adopting a song can stall MainActor.
enum LocalSongResourceLoader {
    static let defaultTimeout: Duration = .milliseconds(750)
    static let maximumLyricsBytes = 2 * 1_024 * 1_024
    static let maximumMelodyBytes = 8 * 1_024 * 1_024
    static let maximumArtworkBytes = 8 * 1_024 * 1_024
    static let maximumTotalBytes = 18 * 1_024 * 1_024
    static let maximumFiles = 8

    static func load(
        _ request: LocalSongResourceRequest,
        fileSystem: BoundedFileSystem = .system,
        artworkDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("YunAudio-artwork", isDirectory: true)
    ) -> LocalSongResourceSnapshot {
        let deadline = ExternalIODeadline(timeout: request.timeout)
        let stem = request.url.deletingPathExtension()
        var filesRead = 0
        var bytesRead = 0
        var rejectedOversizedInput = false
        var timedOut = false

        func read(_ url: URL, maximumBytes: Int) -> Data? {
            guard filesRead < maximumFiles, !deadline.hasExpired else {
                timedOut = timedOut || deadline.hasExpired
                rejectedOversizedInput = rejectedOversizedInput || filesRead >= maximumFiles
                return nil
            }
            switch fileSystem.readFile(url, maximumBytes, deadline) {
            case .data(let data):
                guard data.count <= maximumTotalBytes - min(bytesRead, maximumTotalBytes)
                else {
                    rejectedOversizedInput = true
                    return nil
                }
                filesRead += 1
                bytesRead += data.count
                return data
            case .unavailable:
                return nil
            case .tooLarge:
                rejectedOversizedInput = true
                return nil
            case .timedOut:
                timedOut = true
                return nil
            }
        }

        var lyrics: Lyrics?
        var lyricsURL: URL?
        for suffix in ["lrc", "LRC"] where lyrics == nil {
            let url = stem.appendingPathExtension(suffix)
            if let data = read(url, maximumBytes: maximumLyricsBytes),
                let text = String(data: data, encoding: .utf8),
                let parsed = Lyrics.parse(text)
            {
                lyrics = parsed
                lyricsURL = url
            }
        }

        var melody: MidiMelody?
        for suffix in ["mid", "midi"] where melody == nil {
            if let data = read(
                stem.appendingPathExtension(suffix), maximumBytes: maximumMelodyBytes)
            {
                melody = MidiMelody.parse(data)
            }
        }

        var artworkURL: URL?
        for suffix in ["jpg", "jpeg", "png", "heic", "webp"] where artworkURL == nil {
            let url = stem.appendingPathExtension(suffix)
            switch fileSystem.itemExists(url, deadline) {
            case .exists(true):
                artworkURL = url
            case .timedOut:
                timedOut = true
            case .exists(false):
                break
            }
        }

        if artworkURL == nil, let artwork = request.embeddedArtwork {
            if artwork.count > maximumArtworkBytes {
                rejectedOversizedInput = true
            } else if !deadline.hasExpired {
                artworkURL = materialiseArtwork(
                    artwork, in: artworkDirectory, deadline: deadline)
                timedOut = deadline.hasExpired
            } else {
                timedOut = true
            }
        }

        return LocalSongResourceSnapshot(
            generation: request.generation, url: request.url,
            lyrics: lyrics, lyricsURL: lyricsURL, melody: melody,
            artworkURL: artworkURL, filesRead: filesRead, bytesRead: bytesRead,
            rejectedOversizedInput: rejectedOversizedInput,
            timedOut: timedOut || deadline.hasExpired)
    }

    private static func materialiseArtwork(
        _ data: Data, in directory: URL, deadline: ExternalIODeadline
    ) -> URL? {
        guard !deadline.hasExpired else { return nil }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let file = directory.appendingPathComponent("\(data.count)-\(hash).img")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard !deadline.hasExpired,
            (try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)) != nil,
            !deadline.hasExpired,
            (try? data.write(to: file, options: .atomic)) != nil,
            !deadline.hasExpired
        else { return nil }
        return file
    }
}

final class LocalSongResourceWorker: @unchecked Sendable {
    private let lane:
        LatestExternalWorkLane<LocalSongResourceRequest, LocalSongResourceSnapshot>

    init(
        fileSystem: BoundedFileSystem = .system,
        publish: @escaping @MainActor @Sendable (LocalSongResourceSnapshot) -> Void
    ) {
        lane = LatestExternalWorkLane(
            queue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.local-song-resources", qos: .utility),
            apply: { LocalSongResourceLoader.load($0, fileSystem: fileSystem) },
            publish: publish)
    }

    @discardableResult
    func submit(_ request: LocalSongResourceRequest) -> Bool { lane.submit(request) }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }
}
