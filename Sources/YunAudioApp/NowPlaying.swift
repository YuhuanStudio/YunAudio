import AppKit
import Foundation

/// What the music players on this Mac are playing, and where they are in it.
///
/// **AppleScript, deliberately.** The obvious route is `MediaRemote`, which is
/// what every "now playing" utility on this platform reaches for — and it is
/// private, Apple has already restricted it once, and an application that
/// breaks on a point release is worse than one that never offered the feature.
/// Neither Apple Music nor Spotify publishes a public API for reading what the
/// desktop app is doing, but both ship a scripting dictionary, which is
/// documented, supported, and has worked unchanged for twenty years.
///
/// What it costs is a permission prompt the first time — "YunAudio wants to
/// control Music" — and that prompt is honest about what is happening, which a
/// private framework would not have been.
@MainActor
enum NowPlaying {

    struct Track: Equatable, Sendable {
        var application: String
        var title: String
        var artist: String
        var album: String
        /// Seconds into the track, at the moment it was read.
        var position: Double
        var duration: Double
        var isPlaying: Bool
        /// `id of current track`, so a change of song is noticed without asking
        /// what the song is. Empty when the player would not say.
        var identity: String = ""

        /// What a lyrics file for this would be called, near enough to match on.
        var searchKey: String {
            "\(artist) \(title)"
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// Bundle identifiers, in the order they are asked.
    ///
    /// Music first because a Mac has it whether or not anybody uses it, and a
    /// stopped player answers quickly.
    private static let players = [
        ("Music", "com.apple.Music"),
        ("Spotify", "com.spotify.client"),
    ]

    /// What is loaded in a player, preferring one that is actually playing.
    ///
    /// A paused track still has words worth reading — somebody stopping to
    /// look at the next line is the ordinary case, not an edge one — so paused
    /// counts, and only loses to a player that is playing.
    ///
    /// Only running applications are asked. Sending an Apple event to a bundle
    /// identifier that is not running *launches it*, which would mean opening
    /// Spotify because somebody looked at a lyrics panel.
    static func current() -> Track? {
        var paused: Track?
        for (name, bundleID) in players {
            guard isRunning(bundleID) else { continue }
            guard let track = read(name: name) else { continue }
            if track.isPlaying { return track }
            if paused == nil { paused = track }
        }
        return paused
    }

    /// Where the asking happens.
    ///
    /// Serial, and only ever this one thread: `NSAppleScript` is documented as
    /// safe to use from a single thread at a time, and one ask is in flight at
    /// a time anyway.
    nonisolated private static let queue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.now-playing", qos: .utility)

    /// The same question, asked somewhere the interface is not waiting.
    ///
    /// **Measured on this machine, with Spotify running: 62 ms for one
    /// `current()`** — essentially all of it waiting for the player to answer
    /// an Apple event, not arithmetic here. On the main actor that is fifteen
    /// frames; on the poll, which asked every tick, it was 1.24 seconds of work
    /// per second of wall clock, so the interface simply stopped and the poll
    /// fell behind everything else it had to do. It is not only this
    /// application's problem either: the player is answering an event every
    /// fifty milliseconds, on its own main thread, which is why the thing
    /// somebody notices going slow is sometimes Spotify.
    ///
    /// - Parameter completion: Called on the main actor with what was playing,
    ///   or nil when no player had anything loaded.
    static func currentAsynchronously(
        _ completion: @escaping @MainActor @Sendable (Track?) -> Void
    ) {
        queue.async {
            let track = current()
            Task { @MainActor in completion(track) }
        }
    }

    // MARK: The cheap half

    /// Where a player has got to, without asking anything that costs.
    struct Position: Sendable, Equatable {
        var application: String
        /// `id of current track`. Empty when the player would not say, in which
        /// case a change of song is noticed by the metadata instead.
        var identity: String
        var seconds: Double
        var isPlaying: Bool
    }

    /// Asks only for where the song is and whether it is still the same song.
    ///
    /// Split from the metadata because the two cost wildly different amounts
    /// and are wanted at wildly different rates. **AppleScript sends one Apple
    /// event per property access**, not one per script — the comment that used
    /// to sit here claimed the opposite and it was wrong. Measured against a
    /// running Spotify on this machine, the six-property read is 61.4 ms at the
    /// median and this three-property one is 20.7 ms. The name and the album do
    /// not change while a song plays; the position does, and between answers it
    /// is arithmetic. See `TrackClock`.
    ///
    /// - Parameter application: Which player answered last, asked first so the
    ///   ordinary case is one round trip rather than one per installed player.
    /// - Returns: The playing player if there is one, else a paused one, else
    ///   nil when no player is running or none has a track loaded.
    /// The same question, asked somewhere the interface is not waiting.
    ///
    /// The cheap read is 20.7 ms and the expensive one 61.4, and both are spent
    /// inside somebody else's process waiting for its main thread. Twenty
    /// milliseconds on the main actor is a frame gone, twice a second, for as
    /// long as the panel is open — and it is not only this application's
    /// problem, because the player is answering the events.
    ///
    /// Both halves are done here, so the decision "has the song changed, and do
    /// I therefore need the expensive read" is made off the main actor too
    /// rather than costing a second hop to make it.
    ///
    /// - Parameters:
    ///   - application: Which player answered last, asked first.
    ///   - identity: The song this caller already knows about, so the metadata
    ///     is only fetched when it is a different one.
    ///   - completion: Called on the main actor with the position, the track
    ///     when it changed, and the two clock readings the round trip sat
    ///     between.
    static func positionAsynchronously(
        preferring application: String?, knownIdentity identity: String?,
        _ completion: @escaping @MainActor @Sendable (Position?, Track?, Double) -> Void
    ) {
        queue.async {
            let before = DispatchTime.now().uptimeNanoseconds
            let position = position(preferring: application)
            // The midpoint of the round trip, taken here rather than by the
            // caller: with the ask on another thread the caller cannot see
            // either end of it, and anchoring at the moment the answer is
            // delivered would put every extrapolation a whole hop behind the
            // music, permanently and in the same direction.
            let middle =
                (Double(before) + Double(DispatchTime.now().uptimeNanoseconds)) / 2e9
            var track: Track?
            if let position,
                identity == nil || (!position.identity.isEmpty && position.identity != identity)
            {
                track = self.track(from: position.application)
            }
            let carried = track
            Task { @MainActor in completion(position, carried, middle) }
        }
    }

    static func position(preferring application: String?) -> Position? {
        var paused: Position?
        for (name, bundleID) in ordered(preferring: application) {
            guard isRunning(bundleID) else { continue }
            guard let found = readPosition(name: name) else { continue }
            if found.isPlaying { return found }
            if paused == nil { paused = found }
        }
        return paused
    }

    private static func readPosition(name: String) -> Position? {
        let source = """
            tell application "\(name)"
                if it is running then
                    set playerStatus to (player state as text)
                    if playerStatus is "playing" or playerStatus is "paused" then
                        return ((id of current track) as text) & "\u{1F}" \
            & (player position as text) & "\u{1F}" & playerStatus
                    end if
                end if
            end tell
            return ""
            """
        guard let text = run(source) else { return nil }
        let fields = text.components(separatedBy: "\u{1F}")
        guard fields.count == 3 else { return nil }
        return Position(
            application: name, identity: fields[0],
            seconds: Double(fields[1]) ?? 0, isPlaying: fields[2] == "playing")
    }

    /// The expensive half: what the song actually is.
    ///
    /// Asked when the track identity changes and not otherwise. Four more
    /// property accesses, which measured 40 ms on top of the cheap read.
    static func track(from application: String) -> Track? {
        read(name: application)
    }

    /// Running applications first, then the rest of the list in its own order.
    private static func ordered(preferring application: String?) -> [(String, String)] {
        guard let application,
            let index = players.firstIndex(where: { $0.0 == application })
        else { return players }
        return [players[index]]
            + players.enumerated().filter { $0.offset != index }.map(\.element)
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Compiles and runs a script, or nil when it errored or answered nothing.
    private static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let text = result.stringValue, !text.isEmpty else { return nil }
        return text
    }

    private static func read(name: String) -> Track? {
        // The variable names are long on purpose. `st` and `t` are both
        // reserved in AppleScript — `t` is an abbreviation the parser claims —
        // and the failure is "expected expression but found st", pointing at a
        // line that is obviously fine.
        let source = """
            tell application "\(name)"
                if it is running then
                    set playerStatus to (player state as text)
                    if playerStatus is "playing" or playerStatus is "paused" then
                        set theTrack to current track
                        return (name of theTrack) & "\u{1F}" & (artist of theTrack) \
            & "\u{1F}" & (album of theTrack) & "\u{1F}" & (player position as text) \
            & "\u{1F}" & ((duration of theTrack) as text) & "\u{1F}" & playerStatus \
            & "\u{1F}" & ((id of theTrack) as text)
                    end if
                end if
            end tell
            return ""
            """
        guard let text = run(source) else { return nil }

        let fields = text.components(separatedBy: "\u{1F}")
        guard fields.count == 7 else { return nil }
        // Spotify reports duration in milliseconds and Music in seconds —
        // measured, not assumed: Spotify answered 242660 for a four-minute
        // track. The tell is the magnitude, because no song is five hours long.
        var duration = Double(fields[4]) ?? 0
        if duration > 3600 * 5 { duration /= 1000 }
        return Track(
            application: name,
            title: fields[0],
            artist: fields[1],
            album: fields[2],
            position: Double(fields[3]) ?? 0,
            duration: duration,
            isPlaying: fields[5] == "playing",
            identity: fields[6])
    }

    /// True when either player is installed at all, so the interface can say
    /// something better than an empty panel.
    static var hasAPlayer: Bool {
        players.contains { _, bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
    }
}
