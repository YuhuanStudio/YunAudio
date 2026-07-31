import Foundation

/// What the operating system should be told about the song on this stage.
///
/// The application already reads other players' now-playing state, at 73 ms an
/// Apple event, to put words on the screen. This is the mirror of that and the
/// half that was missing: since the songs became ours to play, nothing told
/// macOS we were playing them. The media keys, Control Centre and the button on
/// a pair of AirPods all went to whichever application *had* said so — usually
/// one that was not making any sound.
///
/// A pure value because the decisions in it are the arguable part and none of
/// them needs `MediaPlayer` to check: whether to claim at all, what the buttons
/// should be allowed to do, and — the one that costs real work if it is wrong —
/// when a republish is warranted. The system extrapolates the playhead from a
/// rate and an anchor, so telling it the position twenty times a second is
/// twenty times the work for a number it already had.
struct NowPlayingBroadcast: Equatable, Sendable {

    var title: String
    var artist: String
    var album: String
    /// Seconds. Zero when the song's length is not known, which is what the
    /// system reads as "no scrubber".
    var duration: Double
    var elapsed: Double
    var isPlaying: Bool

    /// Whether ⏭ has somewhere to go. False leaves the button dimmed rather
    /// than present and inert, which is the difference between a control that
    /// is off and one that is broken.
    var canSkipForward: Bool
    var canSkipBackward: Bool

    /// Whether the artwork is worth attaching, kept separate from the data so
    /// the decision can be asserted without a picture.
    var hasArtwork: Bool

    /// How far the playhead may drift from what was last published before it is
    /// worth saying again.
    ///
    /// The system moves the position itself from the rate, so a drift smaller
    /// than this is one it has already accounted for. Larger means something
    /// moved the playhead — a seek, a key change re-scheduling from where the
    /// song is, the queue starting the next song — and the lock screen showing
    /// the previous song's position is worse than a republish.
    static let driftWorthPublishing: Double = 1.0

    /// What to tell the system, or nil to resign.
    ///
    /// Nil is the important half. This application shows the words for songs
    /// playing in Safari, Spotify and QQ Music, and claiming to be the now
    /// playing application while *watching* one would take the media keys away
    /// from the player that is actually making the sound — pressing pause would
    /// pause a song we are not playing. So: only a song this application opened
    /// itself.
    static func forOurOwnSong(
        title: String, artist: String, album: String,
        duration: Double, elapsed: Double, isPlaying: Bool,
        hasQueuedSong: Bool, repeatsOne: Bool, hasPreviousSong: Bool,
        hasArtwork: Bool
    ) -> NowPlayingBroadcast {
        NowPlayingBroadcast(
            title: title, artist: artist, album: album,
            duration: max(0, duration.isFinite ? duration : 0),
            // Clamped into the song. A player node counts on past the end while
            // the tail drains, and a lock screen showing 4:31 of a 4:12 song
            // reads as the application having lost track of it.
            elapsed: clamp(elapsed, within: duration),
            isPlaying: isPlaying,
            // 重唱 counts: with it on, ⏭ has somewhere to go even at the end of
            // the list, because where it goes is the top of this song.
            canSkipForward: hasQueuedSong || repeatsOne,
            // Always something, because ⏮ on every transport ever built
            // restarts the song when there is nothing before it, and a dimmed
            // button would be a worse lie than a useful one.
            canSkipBackward: hasPreviousSong || duration > 0,
            hasArtwork: hasArtwork)
    }

    private static func clamp(_ elapsed: Double, within duration: Double) -> Double {
        guard elapsed.isFinite else { return 0 }
        let floored = max(0, elapsed)
        guard duration > 0, duration.isFinite else { return floored }
        return min(floored, duration)
    }

    /// Whether the system needs telling again.
    ///
    /// Everything except the playhead is compared exactly, because those are
    /// the fields somebody sees standing still if they go stale. The playhead
    /// is compared against a tolerance, since the system advances it itself and
    /// republishing every frame would be the same cost as the polling this
    /// application went to some trouble to avoid.
    func needsPublishing(after previous: NowPlayingBroadcast?) -> Bool {
        guard let previous else { return true }
        if title != previous.title || artist != previous.artist
            || album != previous.album || duration != previous.duration
            || isPlaying != previous.isPlaying
            || canSkipForward != previous.canSkipForward
            || canSkipBackward != previous.canSkipBackward
            || hasArtwork != previous.hasArtwork
        {
            return true
        }
        return abs(elapsed - previous.elapsed) >= Self.driftWorthPublishing
    }
}
