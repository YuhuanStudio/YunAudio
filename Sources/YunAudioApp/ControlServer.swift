import Foundation
import YunAudioControl

/// The value-only surface the control socket can admit on MainActor.
///
/// JavaScript is deliberately represented by a callback. A socket worker owns
/// one absolute deadline and must never make MainActor wait for the JavaScript
/// owner which, in turn, calls MainActor for `yun.*` requests.
@MainActor
protocol ControlCommandTarget: AnyObject {
    var scriptStatus: JSONValue { get }
    var scriptPresetNames: [String] { get }
    var scriptConfigNames: [String] { get }

    func submitRemoteCommand(
        _ command: RemoteCommand, deadline: ScriptService.Deadline?,
        completion: @escaping @MainActor @Sendable (ScriptService.CommandOutcome) -> Void
    )
}

extension RouterModel: ControlCommandTarget {}

/// The application's answering end of the control socket.
///
/// Status and names are immutable snapshots by the time they leave MainActor.
/// Commands perform only bounded model admission there. JavaScript evaluation,
/// HAL work and filesystem work all remain on their dedicated owners.
@MainActor
enum ControlServer {
    private(set) static var startError: String?

    /// Admits listener startup without binding or probing a stale socket on MainActor.
    static func start(
        model: RouterModel,
        completion: ControlListenerLifecycleOwner.StartCompletion? = nil
    ) -> ControlListenerLifecycleOwner {
        let owner = ControlListenerLifecycleOwner()
        start(owner, model: model, completion: completion)
        return owner
    }

    /// Restarts the same lifecycle owner after AppKit refuses termination.
    /// Its serial queue quarantines any late bind from the revoked generation
    /// before this generation is allowed to touch the socket path.
    static func start(
        _ owner: ControlListenerLifecycleOwner, model: RouterModel,
        completion: ControlListenerLifecycleOwner.StartCompletion? = nil
    ) {
        startError = nil
        owner.start(
            handler: { request, deadline, reply in
                answer(request, deadline: deadline, model: model, reply: reply)
            },
            completion: { result in
                switch result {
                case .started, .queued, .alreadyRunning:
                    startError = nil
                case .superseded:
                    break
                case .failed(let message):
                    startError = message
                    NonBlockingDiagnostic.write("yunaudio: control socket: \(message)\n")
                }
                completion?(result)
            })
    }

    /// Answers exactly once, either immediately for a snapshot/refusal or from
    /// the asynchronous script completion guarded by the listener's deadline.
    static func answer(
        _ request: ControlRequest, deadline: ControlRequestDeadline,
        model: any ControlCommandTarget, reply: @escaping ControlListener.Reply
    ) {
        switch request {
        case .perform(let command):
            model.submitRemoteCommand(command, deadline: ScriptService.Deadline(deadline)) {
                outcome in
                reply(controlReply(for: outcome, command: command, model: model))
            }
        case .status:
            reply(.status(model.scriptStatus))
        case .names:
            reply(
                .names(
                    scenes: model.scriptPresetNames,
                    setups: model.scriptConfigNames))
        }
    }

    /// Protocol strings stay stable English because another process consumes
    /// them; user-facing script diagnostics have already been localised by the
    /// model before crossing this boundary.
    private static func controlReply(
        for outcome: ScriptService.CommandOutcome, command: RemoteCommand,
        model: any ControlCommandTarget
    ) -> ControlReply {
        guard outcome.failed else {
            return .message(outcome.message ?? "Command completed.")
        }
        if let message = outcome.message { return .failure(message) }
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
}
