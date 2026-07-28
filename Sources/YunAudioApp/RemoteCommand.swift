import Foundation

/// Something another program can ask this one to do.
///
/// A URL scheme rather than App Intents, and the reason is not preference. The
/// intents in a Shortcuts library are discovered from metadata Xcode's own
/// build phase extracts; an application assembled by a shell script around a
/// SwiftPM binary produces none, so the intents would compile, run, and never
/// appear anywhere anybody could use them. A URL is understood by Shortcuts,
/// by Stream Deck, by AppleScript and by `open` from a terminal, without a
/// build system having to agree.
///
/// Every command is idempotent where it can be — `mute(true)` twice is muted,
/// not unmuted. Toggles exist because a physical button has no way to know the
/// current state, but anything driving this from a script should prefer the
/// definite form.
enum RemoteCommand: Equatable, Sendable {
    /// Nil means toggle: what a button without a light has to ask for.
    case routing(Bool?)
    case mute(Bool?)
    case record(Bool?)
    case transcribe(Bool?)
    /// A saved scene, by the name it was saved under.
    case preset(String)
    /// A saved whole-machine arrangement, likewise.
    case config(String)

    /// The scheme this application answers to.
    static let scheme = "yunaudio"

    /// Reads a command out of a URL, or nothing if it is not one.
    ///
    /// Deliberately strict. A URL arriving from outside is somebody else's
    /// string, and guessing what an unrecognised one meant is how a mute
    /// becomes a stop.
    static func parse(_ url: URL) -> RemoteCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // The host is the noun and the first path component the verb:
        // yunaudio://mute/on. A bare yunaudio://mute is the toggle, because
        // that is what a one-key binding wants and spelling it out every time
        // would make the common case the long one.
        let noun = (url.host() ?? "").lowercased()
        let rest = url.pathComponents.filter { $0 != "/" }
        let verb = rest.first?.lowercased()

        switch noun {
        case "routing", "route":
            return state(verb).map(RemoteCommand.routing)
        case "mute":
            return state(verb).map(RemoteCommand.mute)
        case "record", "recording":
            return state(verb).map(RemoteCommand.record)
        case "transcribe", "transcript":
            return state(verb).map(RemoteCommand.transcribe)
        case "config", "setup":
            let name = rest.joined(separator: "/")
            return name.isEmpty ? nil : .config(name)
        case "preset", "scene":
            // Percent-decoded and joined, because a scene can be called
            // "Voice call" and a URL cannot carry the space raw.
            let name = rest.joined(separator: "/")
            return name.isEmpty ? nil : .preset(name)
        default:
            return nil
        }
    }

    /// Turns a verb into on, off, or toggle. Double-optional: the outer level
    /// says whether the verb was understood at all, the inner one carries the
    /// toggle.
    private static func state(_ verb: String?) -> Bool?? {
        switch verb {
        case nil, "toggle": .some(nil)
        case "on", "start", "1", "true", "yes": .some(true)
        case "off", "stop", "0", "false", "no": .some(false)
        default: nil
        }
    }
}
