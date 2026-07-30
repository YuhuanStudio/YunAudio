import Foundation

/// Public music sites whose Media Session metadata the native bridge accepts.
public enum MediaSessionSite: String, Codable, Equatable, Sendable {
    case qqMusic
    case netEaseCloudMusic
}

public enum MediaSessionEnvelopeError: Error, Equatable, Sendable {
    case responseTooLarge
    case invalidPayload
    case unsupportedVersion(Int)
    case invalidPageURL
    case unsupportedSite
    case invalidSnapshot(MediaSnapshotValidationError)
}

public struct ParsedMediaSessionEnvelope: Equatable, Sendable {
    public let site: MediaSessionSite
    public let pageURL: URL
    public let snapshot: MediaSnapshot
}

/// Parses the small JSON message sent by a future browser content bridge.
///
/// This boundary consumes only the browser's standard Media Session fields.
/// It neither inspects windows through Accessibility nor imports private
/// MediaRemote APIs, so adding the transport later cannot silently broaden the
/// application's permission surface.
public enum MediaSessionEnvelopeParser {
    public static let supportedVersion = 1
    public static let maximumEncodedBytes = 64 * 1_024
    public static let maximumPageURLLength = 2_048

    public static func parse(
        _ data: Data,
        now: Date,
        lastSequence: UInt64? = nil,
        staleAfter: TimeInterval = MediaSnapshot.defaultStaleAfter
    ) throws -> ParsedMediaSessionEnvelope {
        guard data.count <= maximumEncodedBytes else {
            throw MediaSessionEnvelopeError.responseTooLarge
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw MediaSessionEnvelopeError.invalidPayload
        }
        guard envelope.version == supportedVersion else {
            throw MediaSessionEnvelopeError.unsupportedVersion(envelope.version)
        }

        let (pageURL, site) = try validatedPageURL(envelope.pageURL)
        guard envelope.observedAtMilliseconds.isFinite else {
            throw MediaSessionEnvelopeError.invalidPayload
        }
        let observedAt = Date(
            timeIntervalSince1970: envelope.observedAtMilliseconds / 1_000)
        let state: MediaPlaybackState
        switch envelope.playback.state {
        case "playing":
            state = .playing
        case "paused":
            state = .paused
        case "none":
            state = .stopped
        default:
            throw MediaSessionEnvelopeError.invalidPayload
        }

        let artworkURL: URL?
        if let rawArtwork = envelope.metadata.artworkURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawArtwork.isEmpty
        {
            guard
                rawArtwork.count <= MediaSnapshot.maximumArtworkURLLength,
                let resolved = URL(string: rawArtwork, relativeTo: pageURL)?.absoluteURL
            else {
                throw MediaSessionEnvelopeError.invalidPayload
            }
            artworkURL = resolved
        } else {
            artworkURL = nil
        }

        let rawSnapshot = MediaSnapshot(
            sessionID: envelope.sessionID,
            contextID: envelope.contextID,
            sequence: envelope.sequence,
            observedAt: observedAt,
            title: envelope.metadata.title,
            artist: envelope.metadata.artist,
            album: envelope.metadata.album,
            artworkURL: artworkURL,
            duration: envelope.playback.duration,
            position: envelope.playback.position,
            playbackRate: envelope.playback.rate ?? 1,
            state: state,
            source: .mediaSession)
        do {
            let snapshot = try rawSnapshot.validated(
                now: now,
                lastSequence: lastSequence,
                staleAfter: staleAfter)
            return ParsedMediaSessionEnvelope(
                site: site,
                pageURL: pageURL,
                snapshot: snapshot)
        } catch let error as MediaSnapshotValidationError {
            throw MediaSessionEnvelopeError.invalidSnapshot(error)
        } catch {
            throw MediaSessionEnvelopeError.invalidPayload
        }
    }

    private static func validatedPageURL(
        _ rawValue: String
    ) throws -> (URL, MediaSessionSite) {
        guard rawValue.count <= maximumPageURLLength,
            let url = URL(string: rawValue),
            url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(),
            !host.isEmpty,
            url.user == nil,
            url.password == nil
        else {
            throw MediaSessionEnvelopeError.invalidPageURL
        }

        let site: MediaSessionSite
        if host == "y.qq.com" || host.hasSuffix(".y.qq.com") {
            site = .qqMusic
        } else if host == "music.163.com" || host.hasSuffix(".music.163.com") {
            site = .netEaseCloudMusic
        } else {
            throw MediaSessionEnvelopeError.unsupportedSite
        }
        return (url, site)
    }

    private struct Envelope: Decodable {
        let version: Int
        let sessionID: String
        let contextID: String
        let sequence: UInt64
        let observedAtMilliseconds: Double
        let pageURL: String
        let metadata: Metadata
        let playback: Playback
    }

    private struct Metadata: Decodable {
        let title: String
        let artist: String?
        let album: String?
        let artworkURL: String?
    }

    private struct Playback: Decodable {
        let state: String
        let position: Double?
        let duration: Double?
        let rate: Double?
    }
}
