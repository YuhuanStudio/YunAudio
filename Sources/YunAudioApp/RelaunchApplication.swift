import AppKit
import Foundation
import YunDesign

/// Quits this copy and opens a fresh one.
///
/// There is exactly one situation that needs this, and it is not a
/// convenience. When a synchronous Core Audio constructor fails to return, the
/// construction lane keeps the wedged worker and quarantines itself for the
/// life of the process — correctly, since a call still in flight may be holding
/// memory nobody can account for. Every route this copy could ever build is
/// gone from that moment, and no setting, retry or Stop can bring it back.
///
/// Telling somebody to quit and reopen the application is asking them to do by
/// hand something the application can do perfectly well, in the one case where
/// every other control in the window is inert.
@MainActor
enum RelaunchApplication {

    /// Starts the replacement first, then terminates.
    ///
    /// This order, deliberately. `NSWorkspace` will not open a second instance
    /// of an application that is already running unless asked to, and the
    /// window this is pressed from belongs to the copy about to go — so a
    /// terminate-then-open would need something outside the process to do the
    /// opening, and there is nothing outside the process.
    static func now(
        bundleURL: URL = Bundle.main.bundleURL,
        open: @escaping @MainActor (URL, @escaping @MainActor (Bool) -> Void) -> Void =
            Self.openAnotherInstance,
        quit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        open(bundleURL) { started in
            // Quitting regardless is wrong: a copy that failed to relaunch and
            // then quit leaves somebody with nothing at all, which is worse
            // than the broken copy they had — that one at least still shows the
            // notice explaining itself.
            guard started else { return }
            quit()
        }
    }

    private static func openAnotherInstance(
        _ bundleURL: URL, completion: @escaping @MainActor (Bool) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        // Otherwise this is a no-op: the copy asking is still running, and
        // `NSWorkspace` would simply activate it.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) {
            _, error in
            // The completion arrives off the main actor; the caller's work —
            // terminating — has to be on it.
            let started = error == nil
            Task { @MainActor in completion(started) }
        }
    }
}
