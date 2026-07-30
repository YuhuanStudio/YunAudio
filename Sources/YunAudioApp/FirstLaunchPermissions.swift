import Foundation

/// The first-launch guide to protected capabilities.
///
/// Kept as a pure list because a future protected feature must make an explicit
/// decision here. An empty list is the contract: opening YunAudio never asks
/// TCC for microphone, system audio, Automation or anything else. The first
/// ordinary launch opens Settings → Permissions once, where every request is a
/// separate button press.
enum FirstLaunchPermissions {
    static let currentGuideVersion = 1
    private static let guideVersionKey = "permissionGuideVersion"

    enum Capability: CaseIterable {
        case microphone
        case systemAudio
        case musicAutomation
    }

    static let automaticallyRequested: Set<Capability> = []

    static func canAutoStartWithoutRequest(
        microphoneIsAllowed: Bool, capturesApplications: Bool,
        cancelsEcho: Bool
    ) -> Bool {
        microphoneIsAllowed && !capturesApplications && !cancelsEcho
    }

    static func shouldPresentGuide(
        storedVersion: Int, environment: [String: String]
    ) -> Bool {
        guard storedVersion < currentGuideVersion else { return false }
        return
            environment["YUNAUDIO_RENDER"] == nil
            && environment["YUNAUDIO_FLOWCHECK"] == nil
            && environment["YUNAUDIO_SCREENSHOT"] == nil
            && environment["YUNAUDIO_SETTINGS_CHECK"] == nil
            && environment["YUNAUDIO_ICON"] == nil
    }

    @MainActor
    static func presentGuideIfNeeded(
        model: RouterModel, defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard
            shouldPresentGuide(
                storedVersion: defaults.integer(forKey: guideVersionKey),
                environment: environment)
        else { return }
        // Written before presenting. Closing the window is a completed tour,
        // not an invitation to reopen it on every launch.
        defaults.set(currentGuideVersion, forKey: guideVersionKey)
        SettingsWindow.open(model: model, initialSection: .permissions)
    }
}
