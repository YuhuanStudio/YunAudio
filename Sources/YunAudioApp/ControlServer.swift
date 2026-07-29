import Foundation
import YunAudioControl

/// The application's answering end of the control socket.
///
/// The URL scheme can already ask for anything in `RemoteCommand`, so this
/// exists for the half a URL cannot do: saying what happened, and being asked
/// what is true. That is most of the value to anything driving this without a
/// person watching — an agent that has muted the microphone and cannot read
/// back that it is muted has not really muted it, it has merely sent something.
///
/// Deliberately the same three questions the scripting object model answers, and
/// for the same reason: `ScriptTarget` is the definition of what can be read,
/// and a second, larger definition here would be a second thing to keep in step.
///
/// This answers `yunaudio-cli` as well as `yunaudio-mcp`. It did not always —
/// the command line had a distributed-notification channel of its own — and the
/// three things that channel knew and this did not are all here now: a sentence
/// that reports a failure is not a success (`lastCommandFailed`), a refused
/// name comes back with the names that exist, and `answer` is written against
/// `ScriptTarget` so all of it can be asserted against a stub rather than
/// against a live router.
@MainActor
enum ControlServer {

    /// Brings the socket up, or says why it did not.
    ///
    /// Returns nil rather than trapping. A control socket that failed to bind is
    /// a feature that is unavailable, not a reason for the audio router to
    /// refuse to launch — and the one likely cause, another copy already
    /// listening, is a state the user can fix once they are told about it.
    /// Why the socket is not there, when it is not.
    ///
    /// Kept, because the comment above promised the user would be told and the
    /// only telling was `stderr` — which nobody reads for an `LSUIElement`
    /// application launched from the Finder. So the state the user could fix
    /// once told about it was one they were never told about, and the symptom
    /// is `yunaudio-cli` and `yunaudio-mcp` saying the application is not
    /// running while it is plainly on screen.
    private(set) static var startError: String?

    static func start(model: RouterModel) -> ControlListener? {
        let listener = ControlListener()
        do {
            try listener.start { request in answer(request, model: model) }
        } catch let error as ControlError {
            startError = error.message
            FileHandle.standardError.write(Data("yunaudio: \(error.message)\n".utf8))
            return nil
        } catch {
            startError = "\(error)"
            FileHandle.standardError.write(Data("yunaudio: control socket: \(error)\n".utf8))
            return nil
        }
        startError = nil
        return listener
    }

    /// The strings here are protocol, not interface: they are read by another
    /// program and go into an agent's reasoning about what to try next, so they
    /// stay in English and stay stable rather than going through `loc()`.
    static func answer(_ request: ControlRequest, model: any ScriptTarget) -> ControlReply {
        switch request {
        case .perform(let command):
            guard let outcome = model.perform(command) else {
                // Nil is how the model says "there is no such thing". Naming
                // which kind of thing matters: an agent told a scene is missing
                // should list the scenes, not give up on the whole application.
                // The list travels with the refusal rather than in a follow-up
                // question, so neither front end has to ask twice to say
                // something useful.
                switch command {
                case .preset(let name):
                    return .failure(
                        "There is no scene called \"\(name)\".",
                        alternatives: model.scriptPresetNames)
                case .config(let name):
                    return .failure(
                        "There is no setup called \"\(name)\".",
                        alternatives: model.scriptConfigNames)
                default:
                    return .failure("That command could not be carried out.")
                }
            }
            // A sentence is not an outcome. `perform` answers a script that
            // threw with the interpreter's error, and a recording that would
            // not start with the reason it would not — both true sentences
            // about something that did not work, and indistinguishable from a
            // command that ran if only the text crosses. Read here, straight
            // after `perform`, which is the only moment it means anything.
            return model.lastCommandFailed ? .failure(outcome) : .message(outcome)
        case .status:
            guard let status = JSONValue(any: model.scriptStatus) else {
                return .failure("The status contains a value that cannot be sent as JSON.")
            }
            return .status(status)
        case .names:
            return .names(scenes: model.scriptPresetNames, setups: model.scriptConfigNames)
        }
    }
}
