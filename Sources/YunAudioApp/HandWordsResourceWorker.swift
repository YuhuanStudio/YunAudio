import Foundation
import YunAudioEngine

struct HandWordsResourceRequest: Sendable {
    let generation: UInt64
    let url: URL
    let timeout: Duration

    init(
        generation: UInt64,
        url: URL,
        timeout: Duration = HandWordsResourceLoader.defaultTimeout
    ) {
        self.generation = generation
        self.url = url
        self.timeout = timeout
    }
}

enum HandWordsResourceFailure: Sendable, Equatable {
    case unreadable
    case lyricsTooLarge
    case timedOut
    case noTimedLyrics
}

struct HandWordsResourceSnapshot: Sendable, Equatable {
    let generation: UInt64
    let url: URL
    let lyrics: Lyrics?
    let melody: MidiMelody?
    let artworkURL: URL?
    let failure: HandWordsResourceFailure?
    let filesInspected: Int
    let filesRead: Int
    let bytesRead: Int
    let rejectedOversizedSidecar: Bool
    let timedOutBesideLyrics: Bool
}

/// Reads one selected lyric and its exact-name sidecars under fixed limits.
///
/// A selected file may be on a disconnected network volume. Deadlines cannot
/// interrupt a filesystem call already inside the kernel, so one serial owner
/// remains with that call and later requests coalesce behind it. MainActor is
/// never the waiter, and a late answer is revoked by the lane generation.
enum HandWordsResourceLoader {
    static let defaultTimeout: Duration = .milliseconds(750)
    static let maximumLyricsBytes = 2 * 1_024 * 1_024
    static let maximumMelodyBytes = MidiMelody.maximumFileBytes
    static let maximumTotalBytes = maximumLyricsBytes + maximumMelodyBytes
    static let maximumFilesInspected = 8
    static let maximumFilesRead = 3

    static func load(
        _ request: HandWordsResourceRequest,
        fileSystem: BoundedFileSystem = .system
    ) -> HandWordsResourceSnapshot {
        let deadline = ExternalIODeadline(timeout: request.timeout)
        var filesInspected = 0
        var filesRead = 0
        var bytesRead = 0

        func snapshot(
            lyrics: Lyrics? = nil,
            melody: MidiMelody? = nil,
            artworkURL: URL? = nil,
            failure: HandWordsResourceFailure? = nil,
            rejectedOversizedSidecar: Bool = false,
            timedOutBesideLyrics: Bool = false
        ) -> HandWordsResourceSnapshot {
            HandWordsResourceSnapshot(
                generation: request.generation,
                url: request.url,
                lyrics: lyrics,
                melody: melody,
                artworkURL: artworkURL,
                failure: failure,
                filesInspected: filesInspected,
                filesRead: filesRead,
                bytesRead: bytesRead,
                rejectedOversizedSidecar: rejectedOversizedSidecar,
                timedOutBesideLyrics: timedOutBesideLyrics)
        }

        filesInspected += 1
        let lyricsData: Data
        switch fileSystem.readFile(request.url, maximumLyricsBytes, deadline) {
        case .data(let data):
            filesRead += 1
            bytesRead = saturatingAdd(bytesRead, data.count, ceiling: maximumTotalBytes)
            lyricsData = data
        case .unavailable:
            return snapshot(failure: .unreadable)
        case .tooLarge:
            return snapshot(failure: .lyricsTooLarge)
        case .timedOut:
            return snapshot(failure: .timedOut)
        }
        guard !deadline.hasExpired else { return snapshot(failure: .timedOut) }
        guard let text = String(data: lyricsData, encoding: .utf8) else {
            return snapshot(failure: .unreadable)
        }
        guard let lyrics = Lyrics.parse(text) else {
            return snapshot(failure: .noTimedLyrics)
        }

        let stem = request.url.deletingPathExtension()
        var melody: MidiMelody?
        var rejectedOversizedSidecar = false
        var timedOutBesideLyrics = false
        for suffix in ["mid", "midi"] where melody == nil {
            guard filesInspected < maximumFilesInspected, !deadline.hasExpired else {
                timedOutBesideLyrics = timedOutBesideLyrics || deadline.hasExpired
                break
            }
            filesInspected += 1
            switch fileSystem.readFile(
                stem.appendingPathExtension(suffix), maximumMelodyBytes, deadline)
            {
            case .data(let data):
                guard filesRead < maximumFilesRead,
                    data.count <= maximumTotalBytes - min(bytesRead, maximumTotalBytes)
                else {
                    rejectedOversizedSidecar = true
                    continue
                }
                filesRead += 1
                bytesRead = saturatingAdd(bytesRead, data.count, ceiling: maximumTotalBytes)
                melody = MidiMelody.parse(data)
            case .unavailable:
                break
            case .tooLarge:
                rejectedOversizedSidecar = true
            case .timedOut:
                timedOutBesideLyrics = true
            }
        }

        var artworkURL: URL?
        for suffix in ["jpg", "jpeg", "png", "heic", "webp"] where artworkURL == nil {
            guard filesInspected < maximumFilesInspected, !deadline.hasExpired else {
                timedOutBesideLyrics = timedOutBesideLyrics || deadline.hasExpired
                break
            }
            filesInspected += 1
            let candidate = stem.appendingPathExtension(suffix)
            switch fileSystem.itemExists(candidate, deadline) {
            case .exists(true):
                artworkURL = candidate
            case .exists(false):
                break
            case .timedOut:
                timedOutBesideLyrics = true
            }
        }

        return snapshot(
            lyrics: lyrics,
            melody: melody,
            artworkURL: artworkURL,
            rejectedOversizedSidecar: rejectedOversizedSidecar && melody == nil,
            timedOutBesideLyrics: timedOutBesideLyrics || deadline.hasExpired)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int, ceiling: Int) -> Int {
        guard lhs < ceiling, rhs > 0 else { return min(max(lhs, 0), ceiling) }
        return lhs + min(rhs, ceiling - lhs)
    }
}

final class HandWordsResourceWorker: @unchecked Sendable {
    private let lane:
        LatestExternalWorkLane<HandWordsResourceRequest, HandWordsResourceSnapshot>

    init(
        fileSystem: BoundedFileSystem = .system,
        publish: @escaping @MainActor @Sendable (HandWordsResourceSnapshot) -> Void
    ) {
        lane = LatestExternalWorkLane(
            queue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.hand-words-resources", qos: .utility),
            apply: { HandWordsResourceLoader.load($0, fileSystem: fileSystem) },
            publish: publish)
    }

    var statistics:
        LatestExternalWorkLane<
            HandWordsResourceRequest, HandWordsResourceSnapshot
        >.Statistics
    {
        lane.statistics
    }

    @discardableResult
    func submit(_ request: HandWordsResourceRequest) -> Bool { lane.submit(request) }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }
}
