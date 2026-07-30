import Foundation

public enum MediaPlaybackState: String, Codable, Sendable {
    case playing
    case paused
    case stopped
}

public enum MediaSnapshotSource: String, Codable, Sendable {
    case mediaSession
    case mediaElement
    case pageTitle
    case accessibility
}

public enum MediaSnapshotValidationError: Error, Equatable, Sendable {
    case emptyField(String)
    case fieldTooLong(String, maximum: Int)
    case nonFinite(String)
    case outOfRange(String)
    case invalidURL(String)
    case stale
    case fromFuture
    case oldSequence
}

public struct MediaStreamIdentity: Codable, Equatable, Hashable, Sendable {
    public var sessionID: String
    public var contextID: String

    public init(sessionID: String, contextID: String) {
        self.sessionID = sessionID
        self.contextID = contextID
    }
}

public struct MediaSnapshot: Codable, Equatable, Sendable {
    public static let maximumTextLength = 512
    public static let maximumContextLength = 128
    public static let maximumArtworkURLLength = 2_048
    public static let maximumSequence: UInt64 = 9_007_199_254_740_991
    public static let defaultStaleAfter: TimeInterval = 15

    public var sessionID: String
    public var contextID: String
    public var sequence: UInt64
    public var observedAt: Date
    public var title: String
    public var artist: String?
    public var album: String?
    public var artworkURL: URL?
    public var duration: TimeInterval?
    public var position: TimeInterval?
    public var playbackRate: Double
    public var state: MediaPlaybackState
    public var source: MediaSnapshotSource

    public init(
        sessionID: String,
        contextID: String,
        sequence: UInt64,
        observedAt: Date,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        position: TimeInterval? = nil,
        playbackRate: Double = 1,
        state: MediaPlaybackState,
        source: MediaSnapshotSource
    ) {
        self.sessionID = sessionID
        self.contextID = contextID
        self.sequence = sequence
        self.observedAt = observedAt
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
        self.position = position
        self.playbackRate = playbackRate
        self.state = state
        self.source = source
    }

    public func validated(
        now: Date,
        lastSequence: UInt64? = nil,
        staleAfter: TimeInterval = defaultStaleAfter
    ) throws -> MediaSnapshot {
        guard staleAfter.isFinite, staleAfter > 0 else {
            throw MediaSnapshotValidationError.outOfRange("staleAfter")
        }
        guard observedAt.timeIntervalSince1970.isFinite else {
            throw MediaSnapshotValidationError.nonFinite("observedAt")
        }
        let age = now.timeIntervalSince(observedAt)
        guard age.isFinite else {
            throw MediaSnapshotValidationError.nonFinite("age")
        }
        guard age >= -5 else { throw MediaSnapshotValidationError.fromFuture }
        guard age <= staleAfter else { throw MediaSnapshotValidationError.stale }
        if let lastSequence, sequence <= lastSequence {
            throw MediaSnapshotValidationError.oldSequence
        }

        guard sequence <= Self.maximumSequence else {
            throw MediaSnapshotValidationError.outOfRange("sequence")
        }

        var result = self
        result.sessionID = try Self.required(
            sessionID, field: "sessionID", maximum: Self.maximumContextLength)
        result.contextID = try Self.required(
            contextID, field: "contextID", maximum: Self.maximumContextLength)
        result.title = try Self.required(
            title, field: "title", maximum: Self.maximumTextLength)
        result.artist = try Self.optional(artist, field: "artist")
        result.album = try Self.optional(album, field: "album")
        if let artworkURL {
            let text = artworkURL.absoluteString
            guard text.count <= Self.maximumArtworkURLLength,
                let scheme = artworkURL.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                artworkURL.host?.isEmpty == false,
                artworkURL.user == nil,
                artworkURL.password == nil
            else {
                throw MediaSnapshotValidationError.invalidURL("artworkURL")
            }
        }

        guard playbackRate.isFinite else {
            throw MediaSnapshotValidationError.nonFinite("playbackRate")
        }
        guard playbackRate > 0, playbackRate <= 16 else {
            throw MediaSnapshotValidationError.outOfRange("playbackRate")
        }
        if let duration {
            guard duration.isFinite else {
                throw MediaSnapshotValidationError.nonFinite("duration")
            }
            guard duration > 0 else {
                throw MediaSnapshotValidationError.outOfRange("duration")
            }
        }
        if let position {
            guard position.isFinite else {
                throw MediaSnapshotValidationError.nonFinite("position")
            }
            guard position >= 0 else {
                throw MediaSnapshotValidationError.outOfRange("position")
            }
            if let duration, position > duration + 1 {
                throw MediaSnapshotValidationError.outOfRange("position")
            }
        }
        return result
    }

    public var streamIdentity: MediaStreamIdentity {
        MediaStreamIdentity(sessionID: sessionID, contextID: contextID)
    }

    private static func required(
        _ value: String,
        field: String,
        maximum: Int
    ) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw MediaSnapshotValidationError.emptyField(field)
        }
        guard value.count <= maximum else {
            throw MediaSnapshotValidationError.fieldTooLong(field, maximum: maximum)
        }
        return value
    }

    private static func optional(_ value: String?, field: String) throws -> String? {
        guard let rawValue = value else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maximumTextLength else {
            throw MediaSnapshotValidationError.fieldTooLong(
                field, maximum: maximumTextLength)
        }
        return trimmed
    }
}

public enum MediaSnapshotResolution: Equatable, Sendable {
    case unavailable
    case selected(MediaSnapshot)
    case ambiguous(contextIDs: [String])
}

public struct MediaSnapshotResolver: Sendable {
    public private(set) var latestSequences: [MediaStreamIdentity: UInt64] = [:]
    private var snapshotsByStream: [MediaStreamIdentity: MediaSnapshot] = [:]
    private var activeSessionByContext: [String: String] = [:]
    private var retiredSessionsByContext: [String: Set<String>] = [:]

    public init() {}

    public mutating func ingest(
        _ snapshots: [MediaSnapshot],
        now: Date,
        staleAfter: TimeInterval = MediaSnapshot.defaultStaleAfter
    ) -> MediaSnapshotResolution {
        for rawSnapshot in snapshots {
            guard
                let snapshot = try? rawSnapshot.validated(
                    now: now, staleAfter: staleAfter)
            else { continue }
            let identity = snapshot.streamIdentity
            if retiredSessionsByContext[identity.contextID]?.contains(identity.sessionID)
                == true
            {
                continue
            }
            if let lastSequence = latestSequences[identity],
                snapshot.sequence <= lastSequence
            {
                continue
            }
            if let oldSession = activeSessionByContext[identity.contextID],
                oldSession != identity.sessionID
            {
                retiredSessionsByContext[identity.contextID, default: []]
                    .insert(oldSession)
                let oldIdentity = MediaStreamIdentity(
                    sessionID: oldSession,
                    contextID: identity.contextID)
                latestSequences.removeValue(forKey: oldIdentity)
                snapshotsByStream.removeValue(forKey: oldIdentity)
            }
            activeSessionByContext[identity.contextID] = identity.sessionID
            latestSequences[identity] = snapshot.sequence
            if snapshot.state == .stopped {
                snapshotsByStream.removeValue(forKey: identity)
            } else {
                snapshotsByStream[identity] = snapshot
            }
        }

        snapshotsByStream = snapshotsByStream.filter {
            (try? $0.value.validated(now: now, staleAfter: staleAfter)) != nil
        }
        let valid = Array(snapshotsByStream.values)
        let playing = valid.filter { $0.state == .playing }
        if playing.count > 1 {
            return .ambiguous(contextIDs: playing.map(\.contextID).sorted())
        }
        if let playing = playing.first {
            return .selected(playing)
        }
        let paused = valid.filter { $0.state == .paused }.sorted {
            if $0.observedAt != $1.observedAt {
                return $0.observedAt > $1.observedAt
            }
            return $0.contextID < $1.contextID
        }
        return paused.first.map(MediaSnapshotResolution.selected) ?? .unavailable
    }
}
