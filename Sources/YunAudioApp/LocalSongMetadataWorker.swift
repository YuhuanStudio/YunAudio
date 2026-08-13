import AVFoundation
import Foundation

struct LocalSongMetadataRequest: Sendable {
    let generation: UInt64
    let url: URL
    let timeout: Duration

    init(
        generation: UInt64,
        url: URL,
        timeout: Duration = LocalSongMetadataLoader.defaultTimeout
    ) {
        self.generation = generation
        self.url = url
        self.timeout = timeout
    }
}

struct LocalSongMetadataSnapshot: Sendable, Equatable {
    let generation: UInt64
    let url: URL
    let title: String?
    let artist: String?
    let album: String?
    let artwork: Data?
    let rejectedOversizedValue: Bool
    let timedOut: Bool
}

/// Uses AVFoundation's supported asynchronous metadata loading surface.
///
/// `AVURLAsset.commonMetadata` and each metadata item's synchronous value
/// accessors are deprecated because they may perform I/O on the caller. Loading
/// them here lets a song open immediately under its filename, then adopts tags
/// only if this request is still the current file.
enum LocalSongMetadataLoader {
    static let defaultTimeout: Duration = .seconds(2)
    static let maximumMetadataItems = 256
    static let maximumTextCharacters = 4_096
    static let maximumTextBytes = 16 * 1_024
    static let maximumArtworkBytes = 8 * 1_024 * 1_024

    static func load(_ request: LocalSongMetadataRequest) async -> LocalSongMetadataSnapshot {
        let deadline = ExternalIODeadline(timeout: request.timeout)
        do {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: request.url)
            let allItems = try await asset.load(.commonMetadata)
            try Task.checkCancellation()
            guard !deadline.hasExpired else { return timedOut(request) }
            let items = Array(allItems.prefix(maximumMetadataItems))
            var rejected = allItems.count > maximumMetadataItems

            func item(for key: AVMetadataKey) -> AVMetadataItem? {
                AVMetadataItem.metadataItems(
                    from: items, withKey: key, keySpace: .common
                ).first
            }

            func text(_ key: AVMetadataKey) async throws -> String? {
                guard let item = item(for: key) else { return nil }
                let value = try await item.load(.stringValue)
                try Task.checkCancellation()
                guard !deadline.hasExpired else { throw MetadataDeadlineReached() }
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let trimmed, !trimmed.isEmpty else { return nil }
                guard trimmed.count <= maximumTextCharacters,
                    trimmed.utf8.count <= maximumTextBytes
                else {
                    rejected = true
                    return nil
                }
                return trimmed
            }

            let title = try await text(.commonKeyTitle)
            let artist = try await text(.commonKeyArtist)
            let album = try await text(.commonKeyAlbumName)
            var artwork: Data?
            if let item = item(for: .commonKeyArtwork) {
                let value = try await item.load(.dataValue)
                try Task.checkCancellation()
                guard !deadline.hasExpired else { return timedOut(request) }
                if let value, value.count <= maximumArtworkBytes {
                    artwork = value
                } else if value != nil {
                    rejected = true
                }
            }
            return LocalSongMetadataSnapshot(
                generation: request.generation, url: request.url,
                title: title, artist: artist, album: album, artwork: artwork,
                rejectedOversizedValue: rejected, timedOut: false)
        } catch is MetadataDeadlineReached {
            return timedOut(request)
        } catch {
            return LocalSongMetadataSnapshot(
                generation: request.generation, url: request.url,
                title: nil, artist: nil, album: nil, artwork: nil,
                rejectedOversizedValue: false,
                timedOut: !Task.isCancelled && deadline.hasExpired)
        }
    }

    private struct MetadataDeadlineReached: Error {}

    private static func timedOut(
        _ request: LocalSongMetadataRequest
    ) -> LocalSongMetadataSnapshot {
        LocalSongMetadataSnapshot(
            generation: request.generation, url: request.url,
            title: nil, artist: nil, album: nil, artwork: nil,
            rejectedOversizedValue: false, timedOut: true)
    }
}

@MainActor
final class LocalSongMetadataWorker {
    private let lane:
        LatestAsyncExternalWorkLane<LocalSongMetadataRequest, LocalSongMetadataSnapshot>

    init(
        load:
            @escaping @Sendable (LocalSongMetadataRequest) async -> LocalSongMetadataSnapshot =
            LocalSongMetadataLoader.load,
        publish: @escaping @MainActor @Sendable (LocalSongMetadataSnapshot) -> Void
    ) {
        lane = LatestAsyncExternalWorkLane(apply: load, publish: publish)
    }

    var statistics:
        LatestAsyncExternalWorkLane<
            LocalSongMetadataRequest, LocalSongMetadataSnapshot
        >.Statistics
    { lane.statistics }

    @discardableResult
    func submit(_ request: LocalSongMetadataRequest) -> Bool { lane.submit(request) }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }
}
