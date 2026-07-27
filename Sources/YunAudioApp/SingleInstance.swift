import AppKit

/// Stops a second copy of the application from running.
///
/// An accessory app has no Dock icon and no window until one is opened, so a
/// duplicate is invisible except as a second icon in the menu bar — which is
/// exactly how it gets left running. Launching again should raise what is
/// already there rather than add to it.
@MainActor
enum SingleInstance {
    /// Returns false when another copy already owns the menu bar, after asking
    /// it to show itself.
    static func claim() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? "com.yuhuanstudio.yunaudio"
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == identifier
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        guard !others.isEmpty else { return true }

        // Hand the user over to the copy that is already running rather than
        // failing silently, which would look like the app refusing to launch.
        others.first?.activate()
        return false
    }
}
