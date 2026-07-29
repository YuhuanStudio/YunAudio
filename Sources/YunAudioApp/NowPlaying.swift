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
    nonisolated private static let players = [
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
    nonisolated static func current() -> Track? {
        var paused: Track?
        for (name, bundleID) in players {
            guard
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .isEmpty == false
            else { continue }
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

    /// The script is one round trip returning a delimited string rather than
    /// six round trips returning six values: each one is an Apple event with a
    /// process hop at both ends, and a lyrics view asks about once a second.
    nonisolated private static func read(name: String) -> Track? {
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
            & "\u{1F}" & ((duration of theTrack) as text) & "\u{1F}" & playerStatus
                    end if
                end if
            end tell
            return ""
            """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let text = result.stringValue, !text.isEmpty else { return nil }

        let fields = text.components(separatedBy: "\u{1F}")
        guard fields.count == 6 else { return nil }
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
            isPlaying: fields[5] == "playing")
    }

    /// True when either player is installed at all, so the interface can say
    /// something better than an empty panel.
    static var hasAPlayer: Bool {
        players.contains { _, bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
    }
}
