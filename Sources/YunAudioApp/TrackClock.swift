import Foundation

/// One compositor correction on the song's monotonic timeline.
///
/// The anchor is deliberately a value rather than a timer. A view can recover
/// the exact current position from it whenever it is configured, while Core
/// Animation carries every frame between sparse player answers.
struct LyricPlaybackAnchor: Sendable, Equatable {
    let lineIndex: Int?
    let lineStart: Double
    let lineEnd: Double
    let position: Double
    let trueAt: Double
    let isPlaying: Bool
    let revision: UInt64

    /// Position on the song clock at a later monotonic instant.
    nonisolated func position(at uptime: Double) -> Double {
        guard isPlaying else { return position }
        return position + max(0, uptime - trueAt)
    }

    /// Overall fill through this line at a monotonic instant.
    nonisolated func progress(at uptime: Double) -> Double {
        guard lineIndex != nil else { return 0 }
        guard lineEnd > lineStart else { return 1 }
        let value = (position(at: uptime) - lineStart) / (lineEnd - lineStart)
        return max(0, min(1, value.isFinite ? value : 0))
    }
}

/// Where the song has got to, between the rare moments a player will say.
///
/// **The words and the player are on two different clocks, and the difference
/// is not small.** A lyric line is stamped in seconds from the start of the
/// recording; the only thing that knows where the recording has got to is the
/// player, and the only supported way to ask it is an Apple event. Measured on
/// this machine against a running Spotify, median of twenty-one calls each:
///
/// | what the script asks for | median |
/// |---|---|
/// | `player state` | 2.8 ms |
/// | + `player position` | 11.2 ms |
/// | + `id of current track` | 20.7 ms |
/// | + name, artist, album, duration | 61.4 ms |
///
/// AppleScript sends **one Apple event per property access**, not one per
/// script, which is why that table is a straight line rather than flat — the
/// comment that used to sit on the reader claimed the opposite. The interface
/// polls every 50 ms, so the full read on every poll was 123% of a poll period
/// spent, synchronously, on the main thread, asking a question whose answer
/// advances at one second per second. That is why the highlight could not sweep
/// however the animation was written: the run loop never had 50 ms to spare.
///
/// So the player is asked about once a second and the moments in between are
/// arithmetic on the monotonic clock. A song plays at one second a second; the
/// only things that can falsify that are a pause and a seek, and both are what
/// the once-a-second answer is for.
struct TrackClock: Sendable, Equatable {

    /// What the player last said, in seconds from the start of the track.
    private(set) var reported: Double = 0
    /// The moment that was true, on `DispatchTime` seconds.
    private(set) var reportedAt: Double = 0
    private(set) var isPlaying: Bool = false
    /// False before any player has answered, which is not the same as a song
    /// sitting paused at zero.
    private(set) var isValid: Bool = false
    /// How far past the end the clock may not run. Zero means unknown.
    var duration: Double = 0

    /// How far the extrapolation had strayed when the player last answered.
    ///
    /// Kept because it is the only honest check on the whole idea: if freewheeling
    /// for a second put the words somewhere the player disagrees with, this says
    /// so in seconds rather than leaving somebody to watch the screen and guess.
    private(set) var lastCorrection: Double = 0

    /// Takes an answer from the player.
    ///
    /// - Parameters:
    ///   - seconds: Where the player says it is.
    ///   - playing: Whether it is moving.
    ///   - trueAt: When that was true, in `DispatchTime` seconds. The middle of
    ///     the round trip rather than its end: the answer is somewhere inside
    ///     those twenty milliseconds and the middle is the unbiased guess.
    mutating func adopt(_ seconds: Double, isPlaying playing: Bool, trueAt: Double) {
        lastCorrection = isValid ? seconds - position(at: trueAt) : 0
        reported = seconds
        reportedAt = trueAt
        isPlaying = playing
        isValid = true
    }

    /// Where the song is now.
    ///
    /// - Parameter now: `DispatchTime` seconds.
    /// - Returns: Seconds from the start of the track.
    func position(at now: Double) -> Double {
        guard isValid else { return 0 }
        guard isPlaying else { return reported }
        // Clamped forwards only. A monotonic clock cannot run backwards, but
        // the arithmetic can be asked about a moment before the anchor — the
        // pump and the read are not ordered — and a negative elapsed would
        // walk the highlight back up the page.
        let elapsed = max(0, now - reportedAt)
        let position = reported + elapsed
        // Past the end the player has already stopped and simply not been asked
        // yet, so freewheeling on would run the words off the bottom of a song
        // that had finished.
        guard duration > 0 else { return position }
        return min(position, duration)
    }

    /// Forgets everything, for a panel closing or a player quitting.
    mutating func stop() {
        self = TrackClock()
    }
}
