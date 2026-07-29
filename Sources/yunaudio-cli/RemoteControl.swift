import AppKit
import Foundation
import YunAudioControl

/// Talks to the running application and prints what it says back.
///
/// The measuring half of this tool opens the hardware itself. This half does
/// not touch it at all: it asks the copy that already owns the route, because
/// two processes driving one aggregate device is the thing the single-instance
/// check exists to prevent.
///
/// Over the control socket, which is the same wire `yunaudio-mcp` uses. This
/// used to post a distributed notification and wait four seconds on a run loop
/// for a reply carrying a token to match against; the socket answers all of
/// that by being a connection. Nothing is listening is `connect` failing, not a
/// timeout; the reply belongs to the request because it came back down the same
/// descriptor; and nothing else on the machine can read the traffic.
enum RemoteControl {

    /// One per process. `ControlClient` opens a connection per request and
    /// closes it, so there is no state here beyond the path.
    private static let client = ControlClient()

    /// Whether the application is there at all, as opposed to there and silent.
    ///
    /// Only consulted once the socket has already refused. `connect` failing is
    /// the answer for almost every caller; this separates the one case where it
    /// is the wrong advice — a build from before the socket existed, sitting in
    /// the menu bar, which "open -a YunAudio" will not fix.
    private static var isApplicationRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: ControlSocket.bundleIdentifier
        ).isEmpty
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
            return ask { report(try client.send(.perform(command))) }

        case .status:
            return ask(status)
        }
    }

    /// Sends, and says something a person can act on when the socket did not
    /// answer.
    private static func ask(_ body: () throws -> Int32) -> Int32 {
        do {
            return try body()
        } catch let error as ControlError {
            switch error {
            // Running and not listening is the one case where "launch it" is
            // wrong advice. It is not hypothetical: it is what every build from
            // before the control socket looks like from here.
            case .notRunning where isApplicationRunning:
                print(
                    "YunAudio is running but is not listening on "
                        + ControlSocket.defaultPath + ".")
                print("An older build has no control socket to answer on.")
            case .notRunning:
                print("YunAudio is not running.")
                print("  open -a YunAudio")
            default:
                print(error.message)
            }
            return 1
        } catch {
            print("\(error)")
            return 1
        }
    }

    /// What the application is doing, and what it has to apply by name.
    ///
    /// Two questions rather than one, because the socket answers one at a time.
    /// The names are worth the second round trip — a person reading the status
    /// is very often about to type `preset <something>` — and a refusal to
    /// answer the second is not a reason to have failed the first, so it is
    /// asked for separately and dropped if it does not come.
    private static func status() throws -> Int32 {
        let reply = try client.send(.status)
        guard case .status(let value) = reply else { return report(reply) }
        describe(value)
        if case .names(let scenes, let setups)? = try? client.send(.names) {
            if !scenes.isEmpty { print("\n  scenes  " + scenes.joined(separator: ", ")) }
            if !setups.isEmpty { print("  setups  " + setups.joined(separator: ", ")) }
        }
        return 0
    }

    /// Prints one reply and decides what the shell is told.
    ///
    /// A sentence is not an exit status. A script that threw prints the
    /// interpreter's error and must not look, to whatever called this, like one
    /// that ran — which is why the application marks that reply a failure
    /// rather than a message.
    private static func report(_ reply: ControlReply) -> Int32 {
        switch reply {
        case .message(let sentence):
            print(sentence)
            return 0
        case .failure(let reason, let alternatives):
            print(reason)
            // The one thing worse than "no such scene" is "no such scene" with
            // nothing to try instead.
            if !alternatives.isEmpty { print("  " + alternatives.joined(separator: ", ")) }
            return 1
        case .status(let value):
            describe(value)
            return 0
        // Nothing here asks for these on their own; it is what an application
        // answering the wrong question would send. Printed rather than treated
        // as impossible, because the far end is another process and a `default`
        // that swallowed it would print nothing at all.
        case .names(let scenes, let setups):
            print("  scenes  " + scenes.joined(separator: ", "))
            print("  setups  " + setups.joined(separator: ", "))
            return 0
        }
    }

    /// What the application is doing, as lines somebody can read or `grep`.
    ///
    /// Sorted, because a dictionary's order is not stable between runs and a
    /// status that shuffles cannot be diffed against the last one.
    private static func describe(_ status: JSONValue) {
        let fields = status.objectValue ?? [:]
        let width = fields.keys.map(\.count).max() ?? 0
        for key in fields.keys.sorted() {
            let padding = String(repeating: " ", count: width - key.count)
            print("  \(key)\(padding)  \(fields[key]?.described ?? "")")
        }
    }
}
