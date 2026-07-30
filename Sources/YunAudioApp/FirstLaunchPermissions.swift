import Foundation

/// Offers each installed music player one independent Automation request.
///
/// macOS has no combined permission sheet. Each prompt is owned by the API it
/// protects. Neither microphone nor system-audio capture is touched here:
/// launching the application is not consent to capture audio, and constructing
/// a process tap briefly changes CoreAudio's topology even when the user has not
/// started a route. Each capture feature owns its request at the point of use.
/// Serial Automation prompts are less likely to obscure one another. Attempts
/// are remembered per bundle identifier, so installing Spotify later still
/// offers its grant and refusing Music never pretends Spotify was handled too.
/// A refused grant can always be retried from Settings → Permissions.
enum FirstLaunchPermissions {
    private static let attemptKeyPrefix = "automationPermissionAttempted."

    @MainActor
    static func requestIfNeeded(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard shouldRequest(in: environment) else { return }
        let players = automaticRequestBundleIDs(
            installed: NowPlaying.installedPlayerBundleIDs,
            attempted: Set(
                NowPlaying.installedPlayerBundleIDs.filter {
                    defaults.bool(forKey: attemptKey(for: $0))
                }))
        guard !players.isEmpty else { return }
        Task {
            for bundleID in players {
                // Written before crossing to TCC. If the application is quit
                // while a sheet is open, the next launch must not immediately
                // put the same sheet back; Settings remains the retry path.
                defaults.set(true, forKey: attemptKey(for: bundleID))
                _ = await Task.detached(priority: .utility) {
                    NowPlaying.requestAutomationPermission(for: bundleID)
                }.value
            }
            PermissionCentre.shared.refreshSafeStatuses()
        }
    }

    static func shouldRequest(in environment: [String: String]) -> Bool {
        return
            environment["YUNAUDIO_RENDER"] == nil
            && environment["YUNAUDIO_FLOWCHECK"] == nil
            && environment["YUNAUDIO_SCREENSHOT"] == nil
            && environment["YUNAUDIO_SETTINGS_CHECK"] == nil
            && environment["YUNAUDIO_ICON"] == nil
    }

    static func automaticRequestBundleIDs(
        installed: [String], attempted: Set<String>
    ) -> [String] {
        installed.filter { !attempted.contains($0) }
    }

    static func markAttempted(
        bundleID: String, defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: attemptKey(for: bundleID))
    }

    static func attemptKey(for bundleID: String) -> String {
        attemptKeyPrefix + bundleID
    }
}
