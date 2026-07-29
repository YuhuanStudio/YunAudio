import Foundation
import YunAudioControl

/// Answers the command line.
///
/// The URL handler already carries out every verb; what it cannot do is say
/// anything back, because a URL is a one-way message. A shell script that
/// cannot read the outcome has to guess, and guessing is what `open
/// yunaudio://preset/Voise%20call` looks like when it silently does nothing.
///
/// Held against a `ScriptTarget` rather than against `RouterModel` for the same
/// reason the scripting layer is: the whole surface can then be exercised
/// against a stub, and a reply that reports the wrong state is exactly the kind
/// of defect that looks fine from the outside.
@MainActor
final class RemoteListener {
    private weak var target: (any ScriptTarget)?
    private var observer: (any NSObjectProtocol)?

    /// Builds what to say back.
    ///
    /// Separate from the notification plumbing so it can be asserted directly.
    /// A reply always carries the whole state: the round trip costs the same
    /// either way, and a caller checking what its command did should not have
    /// to ask a second time and hope nothing moved in between.
    static func reply(to request: RemoteRequest, from target: any ScriptTarget) -> RemoteReply {
        // No URL is the question rather than the command, and a question that
        // changes something would be a trap.
        let outcome = request.command.flatMap { target.perform($0) }
        return RemoteReply(
            token: request.token,
            // Nil means the command named a scene or a setup this application
            // does not have; a bare question has no outcome either, and the
            // difference is whether a URL was asked for at all.
            outcome: request.url == nil ? nil : outcome,
            // Asked straight after `perform`, which is the only moment it
            // means anything.
            failed: request.url != nil && target.lastCommandFailed,
            status: target.scriptStatus.compactMapValues(RemoteValue.init),
            presets: target.scriptPresetNames,
            configs: target.scriptConfigNames)
    }

    func start(target: any ScriptTarget) {
        self.target = target
        observer = DistributedNotificationCenter.default().addObserver(
            forName: RemoteChannel.requestName, object: nil, queue: .main
        ) { [weak self] notification in
            // Decoded out here: `Notification` is not `Sendable` and cannot
            // cross into the isolated block, while `RemoteRequest` is and can.
            guard let request = RemoteRequest.from(notification.userInfo) else { return }
            // The notification arrives on the main queue, and everything it
            // touches is main-actor. `assumeIsolated` rather than a `Task`,
            // because a command has to have happened by the time the reply
            // goes out.
            MainActor.assumeIsolated {
                guard let self, let target = self.target else { return }
                let reply = Self.reply(to: request, from: target)
                guard let payload = reply.payload else { return }
                // Delivered immediately rather than coalesced: a tool is
                // sitting on a run loop waiting for exactly this, and the
                // default delivery holds notifications back for an application
                // the system thinks is idle — which an accessory app with no
                // window very often is.
                DistributedNotificationCenter.default().postNotificationName(
                    RemoteChannel.replyName, object: nil,
                    userInfo: [RemoteChannel.payloadKey: payload],
                    deliverImmediately: true)
            }
        }
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }

    // No `deinit`: it is nonisolated and cannot reach a main-actor property, and
    // there is nothing for it to do anyway. The application owns exactly one of
    // these for the life of the process, and the block holds the target weakly,
    // so an observer outliving its listener answers nothing rather than
    // answering wrongly.
}
