import Foundation

/// Reads a command line into the same vocabulary a URL carries.
///
/// A pure function over an array of strings, and separate from the tool that
/// calls it, because that is what makes it testable: argument handling is
/// exactly the kind of code that is written once, looks obviously right, and
/// turns `mute off` into a toggle for a year. There is a test per verb.
///
/// Forgiving about case and about which of the accepted words for on and off
/// somebody reached for — `RemoteCommand.state` already decides that, and it
/// decides it once for the URL scheme, MIDI, the scripting interface and this.
public enum ControlArguments {

    /// What a line asked for.
    public enum Outcome: Equatable, Sendable {
        /// Send this to the application.
        case perform(RemoteCommand)
        /// Ask what it is doing. Not a `RemoteCommand`, deliberately: that type
        /// is what this application can be *asked to do*, and reading state is
        /// not doing anything.
        case status
        /// Say this and stop. The line named one of these verbs and got it
        /// wrong, which is a different thing from naming another verb entirely.
        case complaint(String)
        /// Nothing here is a control verb — the measuring half of the tool
        /// should have a look.
        case notMine
    }

    /// The verbs this half of the tool answers to.
    public static let verbs = [
        "start", "stop", "toggle", "routing", "mute", "record", "transcribe",
        "preset", "config", "script", "status",
    ]

    /// The words for on and off, for a message that has to list them.
    static let states = "on, off or toggle"

    public static func parse(_ arguments: [String]) -> Outcome {
        guard let verb = arguments.first?.lowercased() else { return .notMine }
        let rest = Array(arguments.dropFirst())

        switch verb {
        // The three that read as sentences on their own. `yunaudio-cli start`
        // is the line somebody will actually type; `routing on` is the same
        // thing spelled the way the URL spells it, and both work.
        case "start": return bare(verb, rest, .routing(true))
        case "stop": return bare(verb, rest, .routing(false))
        case "toggle": return bare(verb, rest, .routing(nil))
        case "status": return bare(verb, rest, nil)

        // `route` is deliberately not an alias here, though the URL scheme
        // accepts it: `yunaudio-cli route <in> <out> <seconds>` is the
        // measuring verb that opens the hardware itself, and it was in the
        // documentation years before this half of the tool existed.
        case "routing": return switched(verb, rest, RemoteCommand.routing)
        case "mute": return switched(verb, rest, RemoteCommand.mute)
        case "record", "recording": return switched(verb, rest, RemoteCommand.record)
        case "transcribe", "transcript":
            return switched(verb, rest, RemoteCommand.transcribe)

        case "preset", "scene": return named(verb, rest, "scene", RemoteCommand.preset)
        case "config", "setup": return named(verb, rest, "setup", RemoteCommand.config)
        case "script", "run": return named(verb, rest, "script", RemoteCommand.script)

        default: return .notMine
        }
    }

    /// A verb that takes nothing after it.
    ///
    /// Refused rather than ignored. `yunaudio-cli stop recording` reads like an
    /// instruction and means "stop routing"; carrying on with the extra word
    /// dropped would do something the person did not ask for.
    private static func bare(
        _ verb: String, _ rest: [String], _ command: RemoteCommand?
    ) -> Outcome {
        guard rest.isEmpty else {
            return .complaint(
                "\(verb) takes nothing after it, and got \"\(rest.joined(separator: " "))\".")
        }
        return command.map(Outcome.perform) ?? .status
    }

    /// A verb that takes on, off, or nothing for toggle.
    private static func switched(
        _ verb: String, _ rest: [String], _ make: (Bool?) -> RemoteCommand
    ) -> Outcome {
        guard rest.count <= 1 else {
            return .complaint("\(verb) takes one word — \(states) — and got \(rest.count).")
        }
        // Never nil when the word is: `state` reads a missing verb as a toggle.
        let word = rest.first ?? ""
        guard let state = RemoteCommand.state(rest.first?.lowercased()) else {
            // The one collision worth naming. `record` was the harness verb
            // that captured a few seconds to a file, so `record 5` is a line
            // somebody's notes will still have in them.
            let capture =
                verb.hasPrefix("record") && Double(word) != nil
                ? " To capture \(word) seconds to a file, that is now `capture \(word)`."
                : ""
            return .complaint("\(verb): \"\(word)\" is not \(states).\(capture)")
        }
        return .perform(make(state))
    }

    /// A verb that takes a name, or a script, and needs one.
    ///
    /// Joined with spaces rather than requiring quotes: a scene really is
    /// called "Voice call", and refusing that unless somebody quoted it would
    /// be a tool being difficult about its own data.
    private static func named(
        _ verb: String, _ rest: [String], _ kind: String, _ make: (String) -> RemoteCommand
    ) -> Outcome {
        let name = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return .complaint(
                "\(verb) needs the \(kind) to \(kind == "script" ? "run" : "use").")
        }
        return .perform(make(name))
    }
}
