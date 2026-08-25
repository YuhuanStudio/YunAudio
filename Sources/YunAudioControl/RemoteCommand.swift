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
///
/// This lives in its own module rather than in the application because
/// `yunaudio-cli` and `yunaudio-mcp` are separate processes onto the same
/// verbs, and one executable
/// target cannot read a type defined in another. The alternative was a second
/// copy of the list inside the tool, which is the thing the whole arrangement
/// exists to avoid. One member could not come with it: `title` needs `loc()`,
/// and pulling the design system into a command-line tool to reach it costs
/// more than the extension in `RemoteCommand+Title.swift` does.
public enum RemoteCommand: Equatable, Sendable {
    /// Nil means toggle: what a button without a light has to ask for.
    case routing(Bool?)
    case mute(Bool?)
    case record(Bool?)
    case transcribe(Bool?)
    /// The KTV stage window. The one surface with no way in but a mouse — which
    /// is how a screenshot of it with the scoring on turned out to be
    /// impossible to take without somebody sitting at the machine.
    case stage(Bool?)
    /// Scoring the singing. Same reason.
    case score(Bool?)
    /// The echo canceller.
    ///
    /// Here for the same reason `stage` and `score` are: it is a switch of real
    /// weight with no way in but a mouse. It takes the microphone out of the
    /// router's own aggregate, which costs the clock lock, bit exactness and a
    /// buffer of latency each way — and the one remaining hypothesis for
    /// coreaudiod degrading until the machine needs a reboot is about the
    /// aggregate this switch creates. Testing that means turning it on and off
    /// on a machine with nobody sitting at it.
    case echo(Bool?)
    /// A saved scene, by the name it was saved under.
    case preset(String)
    /// A saved whole-machine arrangement, likewise.
    case config(String)
    /// A script, as source. The one command that is not a fixed verb, and the
    /// reason the vocabulary can stay small: anything a script can express does
    /// not need its own noun here.
    case script(String)

    /// The scheme this application answers to.
    public static let scheme = "yunaudio"

    /// Reads a command out of a URL, or nothing if it is not one.
    ///
    /// Deliberately strict. A URL arriving from outside is somebody else's
    /// string, and guessing what an unrecognised one meant is how a mute
    /// becomes a stop.
    public static func parse(_ url: URL) -> RemoteCommand? {
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
        case "stage", "ktv":
            return state(verb).map(RemoteCommand.stage)
        case "score", "scoring":
            return state(verb).map(RemoteCommand.score)
        case "echo", "aec":
            return state(verb).map(RemoteCommand.echo)
        case "config", "setup":
            let name = rest.joined(separator: "/")
            return name.isEmpty ? nil : .config(name)
        case "script", "run":
            // Percent-decoded by `URL` already; what arrives is the source.
            let source = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            guard !source.isEmpty else { return nil }
            return .script(source)
        case "preset", "scene":
            // Percent-decoded and joined, because a scene can be called
            // "Voice call" and a URL cannot carry the space raw.
            let name = rest.joined(separator: "/")
            return name.isEmpty ? nil : .preset(name)
        default:
            return nil
        }
    }

    /// The URL that produces this command.
    ///
    /// The inverse of `parse`, and it is here so that anything wanting to
    /// *store* a command — a MIDI binding, for one — can keep the URL rather
    /// than a second encoding of the same list.
    public var url: URL {
        switch self {
        case .routing(let state): Self.url("routing", state)
        case .mute(let state): Self.url("mute", state)
        case .record(let state): Self.url("record", state)
        case .transcribe(let state): Self.url("transcribe", state)
        case .stage(let state): Self.url("stage", state)
        case .score(let state): Self.url("score", state)
        case .echo(let state): Self.url("echo", state)
        case .config(let name): Self.url("config", name)
        case .preset(let name): Self.url("preset", name)
        case .script(let source): Self.url("script", source)
        }
    }

    private static func url(_ noun: String, _ state: Bool?) -> URL {
        // A bare noun is the toggle, which is what a physical button wants and
        // is the shorter of the two forms besides.
        guard let state else { return URL(string: "\(scheme)://\(noun)")! }
        return URL(string: "\(scheme)://\(noun)/\(state ? "on" : "off")")!
    }

    private static func url(_ noun: String, _ name: String) -> URL {
        let escaped =
            name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return URL(string: "\(scheme)://\(noun)/\(escaped)")!
    }

    /// The commands worth putting a physical button on, in the toggle form a
    /// button without a light has to ask for.
    ///
    /// Scenes and setups are deliberately not here: they are named by the user
    /// and there can be any number of them, so they belong in a list built from
    /// what is actually saved rather than in a fixed one.
    public static let bindable: [RemoteCommand] = [
        .routing(nil), .mute(nil), .record(nil), .transcribe(nil),
    ]

    /// Turns a verb into on, off, or toggle. Double-optional: the outer level
    /// says whether the verb was understood at all, the inner one carries the
    /// toggle.
    ///
    /// Shared with the command line, which accepts the same words for the same
    /// reason: somebody who has typed `yunaudio://mute/on` should not have to
    /// learn that the terminal spells it differently.
    static func state(_ verb: String?) -> Bool?? {
        switch verb {
        case nil, "toggle": .some(nil)
        case "on", "start", "1", "true", "yes": .some(true)
        case "off", "stop", "0", "false", "no": .some(false)
        default: nil
        }
    }
}
