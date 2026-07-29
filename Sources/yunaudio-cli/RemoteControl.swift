import AppKit
import Foundation
import YunAudioControl

/// Talks to the running application and waits for what it says back.
///
/// The measuring half of this tool opens the hardware itself. This half does
/// not touch it at all: it asks the copy that already owns the route, because
/// two processes driving one aggregate device is the thing the single-instance
/// check exists to prevent.
enum RemoteControl {

    /// Whether there is anybody to talk to.
    ///
    /// Asked before waiting rather than inferred from silence. A four-second
    /// pause before "not running" is a tool that looks broken; the same answer
    /// immediately is a tool that knows what it is doing.
    static var isApplicationRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: RemoteChannel.bundleIdentifier
        ).isEmpty
    }

    /// Sends one request and returns the answer, or nil if none came.
    static func send(_ request: RemoteRequest) -> RemoteReply? {
        guard let payload = request.payload else { return nil }

        // A class because the observer closure has to write where this
        // function can read, and a run loop is not a place to await.
        final class Box { var reply: RemoteReply? }
        let box = Box()

        let centre = DistributedNotificationCenter.default()
        let observer = centre.addObserver(
            forName: RemoteChannel.replyName, object: nil, queue: .main
        ) { notification in
            guard let reply = RemoteReply.from(notification.userInfo),
                // Two terminals asking at once would otherwise each take
                // whichever answer arrived first.
                reply.token == request.token
            else { return }
            box.reply = reply
        }
        defer { centre.removeObserver(observer) }

        centre.postNotificationName(
            RemoteChannel.requestName, object: nil,
            userInfo: [RemoteChannel.payloadKey: payload], deliverImmediately: true)

        // Spun rather than slept: a distributed notification is delivered
        // through the run loop, so a sleeping process never hears the answer.
        let deadline = Date().addingTimeInterval(RemoteChannel.timeout)
        while box.reply == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return box.reply
    }

    /// Runs one line of the control vocabulary. Returns the exit status.
    static func run(_ outcome: ControlArguments.Outcome, printingURL: Bool) -> Int32 {
        switch outcome {
        case .complaint(let message):
            print(message)
            return 2
        case .notMine:
            return 2

        // `--url` on any verb, not just `script`. What somebody wiring a Stream
        // Deck key wants is the URL for the thing they just typed, and that is
        // as true of a scene as it is of a script.
        case .perform(let command) where printingURL:
            let url = command.url.absoluteString
            print(url)
            print("")
            // Single-quoted for the shell, with any single quote in the source
            // escaped the way `sh` requires — a script that uses `'` for its
            // strings is the ordinary case, and a line somebody copies has to
            // work when they paste it.
            print("  open '" + url.replacingOccurrences(of: "'", with: "'\\''") + "'")
            return 0

        case .status where printingURL:
            print("status asks rather than does, so there is no URL for it.")
            return 2

        case .perform(let command):
            return ask(RemoteRequest(url: command.url.absoluteString)) { reply in
                guard let sentence = reply.outcome else {
                    // The one thing worse than "not found" is "not found" with
                    // nothing to try instead.
                    switch command {
                    case .preset(let name): refuse(name, "scene", reply.presets)
                    case .config(let name): refuse(name, "setup", reply.configs)
                    default: print("the application did not understand that.")
                    }
                    return 1
                }
                print(sentence)
                // A sentence is not an exit status. A script that threw prints
                // the interpreter's error and must not look, to the shell that
                // called it, like one that ran.
                return reply.failed ? 1 : 0
            }

        case .status:
            return ask(RemoteRequest()) { reply in
                describe(reply)
                return 0
            }
        }
    }

    /// Sends, and says something a person can act on when nothing comes back.
    private static func ask(
        _ request: RemoteRequest, _ report: (RemoteReply) -> Int32
    ) -> Int32 {
        guard isApplicationRunning else {
            print("YunAudio is not running.")
            print("  open -a YunAudio")
            return 1
        }
        guard let reply = send(request) else {
            print(
                "YunAudio is running but did not answer in "
                    + String(format: "%.0f", RemoteChannel.timeout)
                    + " s. An older build has no command line to answer it.")
            return 1
        }
        return report(reply)
    }

    private static func refuse(_ name: String, _ kind: String, _ known: [String]) {
        print("there is no \(kind) called \"\(name)\".")
        guard !known.isEmpty else { return }
        print("\(kind)s: " + known.joined(separator: ", "))
    }

    /// What the application is doing, as lines somebody can read or `grep`.
    ///
    /// Sorted, because a dictionary's order is not stable between runs and a
    /// status that shuffles cannot be diffed against the last one.
    private static func describe(_ reply: RemoteReply) {
        let width = reply.status.keys.map(\.count).max() ?? 0
        for key in reply.status.keys.sorted() {
            let padding = String(repeating: " ", count: width - key.count)
            print("  \(key)\(padding)  \(reply.status[key]?.described ?? "")")
        }
        if !reply.presets.isEmpty {
            print("\n  scenes  " + reply.presets.joined(separator: ", "))
        }
        if !reply.configs.isEmpty {
            print("  setups  " + reply.configs.joined(separator: ", "))
        }
    }
}
