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
        let current = ProcessInfo.processInfo.processIdentifier
        let other = NSRunningApplication.runningApplications(
            withBundleIdentifier: identifier
        ).first {
            isOtherProcessIdentifier(
                current: current, candidate: $0.processIdentifier)
        }
        guard let other else { return true }

        // Hand the user over to the copy that is already running rather than
        // failing silently, which would look like the app refusing to launch.
        other.activate()
        return false
    }

    /// Finds a different process without depending on AppKit state.
    ///
    /// Kept as values so the launch boundary can be exercised without starting
    /// another application. The candidates have already been narrowed by
    /// Launch Services to this bundle identifier.
    nonisolated static func isOtherProcessIdentifier(
        current: pid_t, candidate: pid_t
    ) -> Bool {
        candidate != current
    }
}
