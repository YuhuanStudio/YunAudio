import AppKit
import Foundation
import MediaPlayer
import YunDesign

private enum NowPlayingSystemServiceAction: Sendable {
    case publish(NowPlayingBroadcast, artwork: Data?, identity: String?)
    case resign
}

private struct NowPlayingSystemServiceRequest: Sendable {
    let action: NowPlayingSystemServiceAction
    let timeout: Duration
}

struct NowPlayingSystemServiceResult: Equatable, Sendable {
    let broadcast: NowPlayingBroadcast?
    let applied: Bool
    let timedOut: Bool
    let rejectedOversizedArtwork: Bool
}

/// Bounded ImageIO preparation for the system's small now-playing tile.
enum NowPlayingArtworkDecoder {
    static let maximumInputBytes = 8 * 1_024 * 1_024
    static let maximumPixelSize = 512

    static func decode(_ data: Data?) -> DecodedSongArtwork? {
        guard let data, data.count <= maximumInputBytes else { return nil }
        return SongArtworkDecoder.decode(data, maxPixelSize: maximumPixelSize)
    }
}

private enum NowPlayingSystemCommand: Sendable {
    case play
    case pause
    case toggle
    case next
    case previous
    case seek(Double)
}

/// Sole owner of MediaPlayer's process-global singletons.
///
/// MediaPlayer has no asynchronous publication or cancellation surface. All
/// calls therefore stay on one utility queue, including final target removal,
/// while commands cross back as value actions through the main run loop.
private final class NowPlayingSystemServiceOwner: @unchecked Sendable {
    private let receive: @MainActor @Sendable (NowPlayingSystemCommand) -> Void
    private var handlers: [MPRemoteCommand: Any] = [:]
    private var handlersAreInstalled = false
    private var hasArtworkIdentity = false
    private var artworkIdentity: String?
    private var artwork: MPMediaItemArtwork?

    init(receive: @escaping @MainActor @Sendable (NowPlayingSystemCommand) -> Void) {
        self.receive = receive
    }

    func apply(
        _ request: NowPlayingSystemServiceRequest,
        context: SoleLatestSystemServiceWorker<
            NowPlayingSystemServiceRequest, NowPlayingSystemServiceResult
        >.Context
    ) -> NowPlayingSystemServiceResult {
        let deadline = ExternalIODeadline(timeout: request.timeout)
        switch request.action {
        case .publish(let broadcast, let data, let identity):
            let oversized = (data?.count ?? 0) > NowPlayingArtworkDecoder.maximumInputBytes
            if !hasArtworkIdentity || identity != artworkIdentity
                || (artwork == nil && data != nil)
            {
                let decoded = NowPlayingArtworkDecoder.decode(data)
                guard context.shouldContinue, !deadline.hasExpired else {
                    return result(
                        broadcast: broadcast, applied: false, deadline: deadline,
                        oversized: oversized)
                }
                artwork = decoded.map { decoded in
                    let image = NSImage(
                        cgImage: decoded.image,
                        size: NSSize(
                            width: decoded.image.width, height: decoded.image.height))
                    return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                }
                artworkIdentity = identity
                hasArtworkIdentity = true
            }

            guard context.shouldContinue, !deadline.hasExpired else {
                return result(
                    broadcast: broadcast, applied: false, deadline: deadline,
                    oversized: oversized)
            }
            installHandlersIfNeeded()
            guard context.shouldContinue, !deadline.hasExpired else {
                return result(
                    broadcast: broadcast, applied: false, deadline: deadline,
                    oversized: oversized)
            }
            publish(broadcast)
            return result(
                broadcast: broadcast, applied: true, deadline: deadline,
                oversized: oversized)

        case .resign:
            guard context.shouldContinue, !deadline.hasExpired else {
                return result(
                    broadcast: nil, applied: false, deadline: deadline,
                    oversized: false)
            }
            clearPublishedSong()
            return result(
                broadcast: nil, applied: true, deadline: deadline,
                oversized: false)
        }
    }

    func standDown() {
        for (command, token) in handlers { command.removeTarget(token) }
        handlers.removeAll()
        handlersAreInstalled = false
        clearPublishedSong()
    }

    private func publish(_ broadcast: NowPlayingBroadcast) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: broadcast.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: broadcast.elapsed,
            // Zero rather than one while paused stops the system advancing it.
            MPNowPlayingInfoPropertyPlaybackRate: broadcast.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if !broadcast.artist.isEmpty { info[MPMediaItemPropertyArtist] = broadcast.artist }
        if !broadcast.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = broadcast.album }
        if broadcast.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = broadcast.duration
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        let centre = MPNowPlayingInfoCenter.default()
        centre.nowPlayingInfo = info
        // A playing state with no information creates a visible empty tile.
        centre.playbackState = broadcast.isPlaying ? .playing : .paused

        let commandCentre = MPRemoteCommandCenter.shared()
        commandCentre.nextTrackCommand.isEnabled = broadcast.canSkipForward
        commandCentre.previousTrackCommand.isEnabled = broadcast.canSkipBackward
        commandCentre.changePlaybackPositionCommand.isEnabled = broadcast.duration > 0
    }

    private func clearPublishedSong() {
        let centre = MPNowPlayingInfoCenter.default()
        centre.nowPlayingInfo = nil
        centre.playbackState = .stopped
        hasArtworkIdentity = false
        artworkIdentity = nil
        artwork = nil
    }

    private func installHandlersIfNeeded() {
        guard !handlersAreInstalled else { return }
        handlersAreInstalled = true
        let centre = MPRemoteCommandCenter.shared()
        add(centre.playCommand, action: .play)
        add(centre.pauseCommand, action: .pause)
        add(centre.togglePlayPauseCommand, action: .toggle)
        add(centre.nextTrackCommand, action: .next)
        add(centre.previousTrackCommand, action: .previous)
        let position = centre.changePlaybackPositionCommand
        position.isEnabled = true
        handlers[position] = position.addTarget { [receive] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            MainRunLoopDelivery.perform { receive(.seek(position)) }
            return .success
        }
    }

    private func add(_ command: MPRemoteCommand, action: NowPlayingSystemCommand) {
        command.isEnabled = true
        handlers[command] = command.addTarget { [receive] _ in
            MainRunLoopDelivery.perform { receive(action) }
            return .success
        }
    }

    private func result(
        broadcast: NowPlayingBroadcast?, applied: Bool,
        deadline: ExternalIODeadline, oversized: Bool
    ) -> NowPlayingSystemServiceResult {
        NowPlayingSystemServiceResult(
            broadcast: broadcast, applied: applied,
            timedOut: deadline.hasExpired,
            rejectedOversizedArtwork: oversized)
    }
}

/// Tells macOS that the song on this stage is ours, and takes the buttons back.
///
/// The MainActor half only decides desired value state. Image decoding and every
/// `MediaPlayer` singleton call belong to one first/latest utility owner, so a
/// slow Control Centre service cannot hold the UI or grow a worker queue.
@MainActor
final class NowPlayingStage {
    static let defaultSystemServiceTimeout: Duration = .milliseconds(500)

    /// What the buttons do. Updating these does not stack MediaPlayer targets;
    /// the sole owner installs one value-action bridge on first publication.
    struct Commands {
        var play: () -> Void
        var pause: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (Double) -> Void
    }

    private var commands: Commands?
    private var desiredBroadcast: NowPlayingBroadcast?
    private var desiredArtworkIdentity: String?
    private(set) var published: NowPlayingBroadcast?
    private(set) var lastSystemServiceTimedOut = false
    private(set) var rejectedOversizedArtwork = false
    private var hasStoodDown = false
    private lazy var systemServiceOwner = NowPlayingSystemServiceOwner { [weak self] action in
        self?.receive(action)
    }
    private lazy var systemServiceWorker:
        SoleLatestSystemServiceWorker<
            NowPlayingSystemServiceRequest, NowPlayingSystemServiceResult
        > = {
            let owner = systemServiceOwner
            return SoleLatestSystemServiceWorker(
                queue: DispatchQueue(
                    label: "com.yuhuanstudio.yunaudio.now-playing-system-service",
                    qos: .utility),
                apply: { request, context in owner.apply(request, context: context) },
                didTimeOut: \.timedOut,
                publish: { [weak self] result in
                    self?.receive(result)
                })
        }()

    init() {}

    func takeCommands(_ commands: Commands) { self.commands = commands }

    /// Schedules the latest system value without waiting for MediaPlayer.
    func publish(_ broadcast: NowPlayingBroadcast?, artwork: Data?, identity: String?) {
        guard let broadcast else {
            resign()
            return
        }
        guard
            broadcast.needsPublishing(after: desiredBroadcast)
                || identity != desiredArtworkIdentity
        else { return }
        let accepted = systemServiceWorker.submit(
            NowPlayingSystemServiceRequest(
                action: .publish(broadcast, artwork: artwork, identity: identity),
                timeout: Self.defaultSystemServiceTimeout))
        guard accepted else { return }
        desiredBroadcast = broadcast
        desiredArtworkIdentity = identity
    }

    /// Hands the system tile back asynchronously while retaining media commands.
    func resign() {
        guard desiredBroadcast != nil || published != nil else { return }
        let accepted = systemServiceWorker.submit(
            NowPlayingSystemServiceRequest(
                action: .resign, timeout: Self.defaultSystemServiceTimeout))
        guard accepted else { return }
        desiredBroadcast = nil
        desiredArtworkIdentity = nil
    }

    /// Permanently closes publication after AppKit accepts termination.
    func standDown() {
        guard !hasStoodDown else { return }
        hasStoodDown = true
        commands = nil
        desiredBroadcast = nil
        desiredArtworkIdentity = nil
        published = nil
        // Target removal is ordered behind any MediaPlayer call already inside
        // the owner. AppKit never waits for that external singleton to return.
        let owner = systemServiceOwner
        systemServiceWorker.shutdown(after: { owner.standDown() })
    }

    /// Gives back a terminated song while keeping this live process reusable.
    func relinquishPublishedSongAfterRefusedTermination() { resign() }

    private func receive(_ result: NowPlayingSystemServiceResult) {
        lastSystemServiceTimedOut = result.timedOut
        rejectedOversizedArtwork = result.rejectedOversizedArtwork
        if result.applied {
            published = result.broadcast
        } else if result.timedOut {
            // The desired-value gate must describe what reached the singleton,
            // not merely what entered its queue. Let the next poll retry a call
            // which returned after its publication budget.
            desiredBroadcast = published
            desiredArtworkIdentity = nil
        }
    }

    private func receive(_ action: NowPlayingSystemCommand) {
        guard let commands else { return }
        switch action {
        case .play: commands.play()
        case .pause: commands.pause()
        case .toggle:
            if desiredBroadcast?.isPlaying == true { commands.pause() } else { commands.play() }
        case .next: commands.next()
        case .previous: commands.previous()
        case .seek(let seconds): commands.seek(seconds)
        }
    }
}
