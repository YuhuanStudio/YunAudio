import AppKit
import Foundation
import MediaPlayer
import YunDesign

/// Tells macOS that the song on this stage is ours, and takes the buttons back.
///
/// Everything `MediaPlayer` needs and nothing that can be decided without it —
/// what to say lives in `NowPlayingBroadcast`, which is a value and is asserted
/// as one. This is the part that has to touch a framework: two singletons, an
/// artwork object that is expensive enough to be worth not rebuilding, and a
/// set of command handlers that must be removed as carefully as they were
/// added.
///
/// **Claiming is not free to get wrong.** The now playing application is a
/// system-wide singleton: whoever holds it owns the media keys, the Control
/// Centre tile and the button on a pair of AirPods. Holding it while merely
/// showing the words for a song playing in Safari would mean pressing pause
/// paused nothing anybody could hear. So it is claimed only for a song this
/// application opened, and given straight back when that song is closed.
@MainActor
final class NowPlayingStage {

    /// What the buttons do. Held rather than passed each time because
    /// `MPRemoteCommandCenter` keeps its targets until they are removed, and
    /// adding a second one per publish is how a single press becomes four.
    struct Commands {
        var play: () -> Void
        var pause: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (Double) -> Void
    }

    private var commands: Commands?
    private var published: NowPlayingBroadcast?
    /// Which song the attached artwork belongs to. Building an
    /// `MPMediaItemArtwork` decodes the picture, so it is done once per song
    /// rather than once per position update.
    private var artworkIdentity: String?
    private var attachedArtwork: MPMediaItemArtwork?
    private var handlers: [MPRemoteCommand: Any] = [:]

    /// Registers the handlers. Called once; calling it again replaces them
    /// rather than stacking a second set.
    func takeCommands(_ commands: Commands) {
        removeHandlers()
        self.commands = commands
        let centre = MPRemoteCommandCenter.shared()

        add(centre.playCommand) { [weak self] _ in
            self?.commands?.play()
            return .success
        }
        add(centre.pauseCommand) { [weak self] _ in
            self?.commands?.pause()
            return .success
        }
        // The one the headphone button and the space bar on a Bluetooth remote
        // actually send. Without it, a single press does nothing on hardware
        // that never sends play or pause separately.
        add(centre.togglePlayPauseCommand) { [weak self] _ in
            guard let self, let commands = self.commands else { return .commandFailed }
            if self.published?.isPlaying == true { commands.pause() } else { commands.play() }
            return .success
        }
        add(centre.nextTrackCommand) { [weak self] _ in
            self?.commands?.next()
            return .success
        }
        add(centre.previousTrackCommand) { [weak self] _ in
            self?.commands?.previous()
            return .success
        }
        add(centre.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self?.commands?.seek(event.positionTime)
            return .success
        }
    }

    /// Says what is playing, or gives the buttons back when there is nothing of
    /// ours to control.
    ///
    /// - Parameters:
    ///   - broadcast: Nil to resign.
    ///   - artwork: The cover, and `identity` naming which song it belongs to
    ///     so it is only decoded when that changes.
    func publish(_ broadcast: NowPlayingBroadcast?, artwork: Data?, identity: String?) {
        guard let broadcast else {
            resign()
            return
        }
        // The gate that keeps this off the twenty-times-a-second path. The
        // system advances the playhead itself from the rate published below, so
        // saying it again every frame is work for a number it already has.
        guard broadcast.needsPublishing(after: published) else { return }

        if identity != artworkIdentity {
            artworkIdentity = identity
            attachedArtwork = Self.artwork(from: artwork)
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: broadcast.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: broadcast.elapsed,
            // Zero rather than one while paused, which is what stops the lock
            // screen carrying on without us.
            MPNowPlayingInfoPropertyPlaybackRate: broadcast.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if !broadcast.artist.isEmpty { info[MPMediaItemPropertyArtist] = broadcast.artist }
        if !broadcast.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = broadcast.album }
        // Only when it is known. A duration of zero published as a duration
        // draws a scrubber that cannot be dragged anywhere.
        if broadcast.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = broadcast.duration
        }
        if let attachedArtwork { info[MPMediaItemPropertyArtwork] = attachedArtwork }

        let centre = MPNowPlayingInfoCenter.default()
        centre.nowPlayingInfo = info
        // Set after the information, not before: a state of playing with no
        // song attached is a moment of "YunAudio — nothing" on the lock screen.
        centre.playbackState = broadcast.isPlaying ? .playing : .paused

        let commandCentre = MPRemoteCommandCenter.shared()
        commandCentre.nextTrackCommand.isEnabled = broadcast.canSkipForward
        commandCentre.previousTrackCommand.isEnabled = broadcast.canSkipBackward
        commandCentre.changePlaybackPositionCommand.isEnabled = broadcast.duration > 0

        published = broadcast
    }

    /// Hands the media keys back.
    ///
    /// Both halves matter. Clearing the information without moving the state to
    /// stopped leaves a silent entry in Control Centre; moving the state
    /// without clearing the information leaves the title of a song that is no
    /// longer open.
    func resign() {
        guard published != nil else { return }
        let centre = MPNowPlayingInfoCenter.default()
        centre.nowPlayingInfo = nil
        centre.playbackState = .stopped
        published = nil
        artworkIdentity = nil
        attachedArtwork = nil
    }

    private func add(
        _ command: MPRemoteCommand,
        _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        handlers[command] = command.addTarget { event in
            // The command centre documents main-thread delivery and every
            // handler here reaches straight into the model, so the common path
            // runs the press immediately. The other branch is not defensive
            // decoration: a press answered `.success` and then dropped is the
            // one bug in a transport control nobody can reproduce, so an
            // unexpected thread hops rather than trips a precondition in
            // somebody's living room.
            guard Thread.isMainThread else {
                DispatchQueue.main.async { _ = onTheMainThread { handler(event) } }
                return .success
            }
            return onTheMainThread { handler(event) }
        }
    }

    private func removeHandlers() {
        for (command, token) in handlers { command.removeTarget(token) }
        handlers.removeAll()
    }

    private static func artwork(from data: Data?) -> MPMediaItemArtwork? {
        guard let data, let image = NSImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Detaches the handlers and gives the keys back.
    ///
    /// Explicit rather than a `deinit`. The command centre holds the targets,
    /// so they must be removed by somebody — but `deinit` is not reliably on
    /// the main thread, and reaching the main actor from one means the dynamic
    /// executor check this application removed everywhere else for faulting.
    /// See `onTheMainThread`.
    func standDown() {
        resign()
        removeHandlers()
        commands = nil
    }
}
