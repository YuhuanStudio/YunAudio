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
@MainActor
enum ControlServer {

    /// Brings the socket up, or says why it did not.
    ///
    /// Returns nil rather than trapping. A control socket that failed to bind is
    /// a feature that is unavailable, not a reason for the audio router to
    /// refuse to launch — and the one likely cause, another copy already
    /// listening, is a state the user can fix once they are told about it.
    static func start(model: RouterModel) -> ControlListener? {
        let listener = ControlListener()
        do {
            try listener.start { request in answer(request, model: model) }
        } catch let error as ControlError {
            FileHandle.standardError.write(Data("yunaudio: \(error.message)\n".utf8))
            return nil
        } catch {
            FileHandle.standardError.write(Data("yunaudio: control socket: \(error)\n".utf8))
            return nil
        }
        return listener
    }

    /// The strings here are protocol, not interface: they are read by another
    /// program and go into an agent's reasoning about what to try next, so they
    /// stay in English and stay stable rather than going through `loc()`.
    static func answer(_ request: ControlRequest, model: RouterModel) -> ControlReply {
        switch request {
        case .perform(let command):
            guard let outcome = model.perform(command) else {
                // Nil is how the model says "there is no such thing". Naming
                // which kind of thing matters: an agent told a scene is missing
                // should list the scenes, not give up on the whole application.
                switch command {
                case .preset(let name):
                    return .failure(
                        "There is no scene called \"\(name)\". "
                            + "Call yunaudio_list_names for the ones that exist.")
                case .config(let name):
                    return .failure(
                        "There is no setup called \"\(name)\". "
                            + "Call yunaudio_list_names for the ones that exist.")
                default:
                    return .failure("That command could not be carried out.")
                }
            }
            return .message(outcome)
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
