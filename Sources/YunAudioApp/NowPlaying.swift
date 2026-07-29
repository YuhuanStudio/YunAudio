import AppKit
import ApplicationServices
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
        /// Words exposed by the player itself. Music publishes this property;
        /// Spotify's scripting dictionary does not.
        var nativeLyrics: String? = nil
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

    enum QueryFailure: Equatable, Sendable {
        case timedOut(application: String)
        case denied(application: String)
        case failed(application: String, code: Int)
    }

    private struct PositionQuery {
        var position: Position?
        var failure: QueryFailure?
    }

    private struct TrackQuery {
        var track: Track?
        var failure: QueryFailure?
    }

    private struct ScriptReply {
        var text: String?
        var failure: QueryFailure?
    }

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
        _ completion:
            @escaping @MainActor @Sendable (
                Position?, Track?, QueryFailure?, Double
            ) -> Void
    ) {
        queue.async {
            let before = DispatchTime.now().uptimeNanoseconds
            let query = positionQuery(preferring: application)
            let position = query.position
            // The midpoint of the round trip, taken here rather than by the
            // caller: with the ask on another thread the caller cannot see
            // either end of it, and anchoring at the moment the answer is
            // delivered would put every extrapolation a whole hop behind the
            // music, permanently and in the same direction.
            let middle =
                (Double(before) + Double(DispatchTime.now().uptimeNanoseconds)) / 2e9
            var track: Track?
            var failure = query.failure
            if let position,
                identity == nil || (!position.identity.isEmpty && position.identity != identity)
            {
                let query = readTrack(name: position.application)
                track = query.track
                failure = query.failure
            }
            let carried = track
            Task { @MainActor in completion(position, carried, failure, middle) }
        }
    }

    nonisolated static func position(preferring application: String?) -> Position? {
        positionQuery(preferring: application).position
    }

    nonisolated private static func positionQuery(
        preferring application: String?
    ) -> PositionQuery {
        var paused: Position?
        var failure: QueryFailure?
        for (name, bundleID) in ordered(preferring: application) {
            guard isRunning(bundleID) else { continue }
            let query = readPosition(name: name)
            if let queryFailure = query.failure {
                failure = failure ?? queryFailure
                continue
            }
            guard let found = query.position else { continue }
            if found.isPlaying { return PositionQuery(position: found, failure: nil) }
            if paused == nil { paused = found }
        }
        return PositionQuery(position: paused, failure: paused == nil ? failure : nil)
    }

    nonisolated private static func readPosition(name: String) -> PositionQuery {
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
        let reply = run(source, application: name)
        guard let text = reply.text else {
            return PositionQuery(position: nil, failure: reply.failure)
        }
        let fields = text.components(separatedBy: "\u{1F}")
        guard fields.count == 3 else {
            return PositionQuery(
                position: nil, failure: .failed(application: name, code: 0))
        }
        return PositionQuery(
            position: Position(
                application: name, identity: fields[0],
                seconds: Double(fields[1]) ?? 0, isPlaying: fields[2] == "playing"),
            failure: nil)
    }

    /// The expensive half: what the song actually is.
    ///
    /// Asked when the track identity changes and not otherwise. Four more
    /// property accesses, which measured 40 ms on top of the cheap read.
    nonisolated static func track(from application: String) -> Track? {
        read(name: application)
    }

    /// Running applications first, then the rest of the list in its own order.
    nonisolated private static func ordered(
        preferring application: String?
    ) -> [(String, String)] {
        guard let application,
            let index = players.firstIndex(where: { $0.0 == application })
        else { return players }
        return [players[index]]
            + players.enumerated().filter { $0.offset != index }.map(\.element)
    }

    nonisolated private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Compiles and runs a script with a bound on somebody else's main thread.
    ///
    /// Spotify has been observed accepting the Apple event and never replying.
    /// Without the AppleScript timeout, that strands the serial query queue and
    /// `isAskingThePlayer` never clears: one slow answer disables KTV for the
    /// rest of the launch.
    nonisolated private static func run(
        _ source: String, application: String
    ) -> ScriptReply {
        let bounded = boundedScript(source)
        guard let script = NSAppleScript(source: bounded) else {
            return ScriptReply(
                text: nil, failure: .failed(application: application, code: 0))
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error["NSAppleScriptErrorNumber"] as? Int ?? 0
            let failure = queryFailure(application: application, code: code)
            return ScriptReply(text: nil, failure: failure)
        }
        guard let text = result.stringValue, !text.isEmpty else {
            return ScriptReply(text: nil, failure: nil)
        }
        return ScriptReply(text: text, failure: nil)
    }

    nonisolated static func boundedScript(_ source: String) -> String {
        """
        with timeout of 2 seconds
        \(source)
        end timeout
        """
    }

    nonisolated static func queryFailure(
        application: String, code: Int
    ) -> QueryFailure {
        switch code {
        case errAETimeout:
            .timedOut(application: application)
        case errAEEventNotPermitted:
            .denied(application: application)
        default:
            .failed(application: application, code: code)
        }
    }

    nonisolated private static func read(name: String) -> Track? {
        readTrack(name: name).track
    }

    nonisolated private static func readTrack(name: String) -> TrackQuery {
        // The variable names are long on purpose. `st` and `t` are both
        // reserved in AppleScript — `t` is an abbreviation the parser claims —
        // and the failure is "expected expression but found st", pointing at a
        // line that is obviously fine.
        // Spotify has no `lyrics` property. Putting Music's property in a
        // shared script would make Spotify's metadata read fail to compile.
        let nativeLyricsScript =
            name == "Music"
            ? """
            set playerLyricsField to ""
            try
                set playerLyricsField to (lyrics of theTrack) as text
            end try
            """
            : """
            set playerLyricsField to ""
            """
        let source = """
            tell application "\(name)"
                if it is running then
                    set playerStatus to (player state as text)
                    if playerStatus is "playing" or playerStatus is "paused" then
                        set theTrack to current track
                        \(nativeLyricsScript)
                        return (name of theTrack) & "\u{1F}" & (artist of theTrack) \
            & "\u{1F}" & (album of theTrack) & "\u{1F}" & (player position as text) \
            & "\u{1F}" & ((duration of theTrack) as text) & "\u{1F}" & playerStatus \
            & "\u{1F}" & ((id of theTrack) as text) & "\u{1F}" & playerLyricsField
                    end if
                end if
            end tell
            return ""
            """
        let reply = run(source, application: name)
        guard let text = reply.text else {
            return TrackQuery(track: nil, failure: reply.failure)
        }

        let fields = text.components(separatedBy: "\u{1F}")
        guard fields.count == 8 else {
            return TrackQuery(
                track: nil, failure: .failed(application: name, code: 0))
        }
        // Spotify reports duration in milliseconds and Music in seconds —
        // measured, not assumed: Spotify answered 242660 for a four-minute
        // track. The tell is the magnitude, because no song is five hours long.
        var duration = Double(fields[4]) ?? 0
        if duration > 3600 * 5 { duration /= 1000 }
        let nativeLyrics =
            fields[7].trimmingCharacters(in: .whitespacesAndNewlines)
        return TrackQuery(
            track: Track(
                application: name,
                title: fields[0],
                artist: fields[1],
                album: fields[2],
                position: Double(fields[3]) ?? 0,
                duration: duration,
                isPlaying: fields[5] == "playing",
                nativeLyrics: nativeLyrics.isEmpty ? nil : nativeLyrics,
                identity: fields[6]),
            failure: nil)
    }

    /// True when either player is installed at all, so the interface can say
    /// something better than an empty panel.
    static var hasAPlayer: Bool {
        players.contains { _, bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
    }

    static var installedPlayerBundleIDs: [String] {
        players.compactMap { _, bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil
                ? nil : bundleID
        }
    }

    /// Asks TCC for one player's Automation permission without reading a track.
    nonisolated static func requestAutomationPermission(for bundleID: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descriptor = target.aeDesc else { return OSStatus(paramErr) }
        return AEDeterminePermissionToAutomateTarget(
            descriptor, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), true)
    }
}
