import Foundation

/// The first-launch guide to protected capabilities.
///
/// Kept as a pure list because a future protected feature must make an explicit
/// decision here. An empty list is the contract: opening YunAudio never asks
/// TCC for microphone, system audio, Automation or anything else. The first
/// ordinary launch opens Settings → Permissions once. One explicit action there
/// serialises every missing grant; each grant also remains individually
/// requestable.
enum FirstLaunchPermissions {
    // Version 1 could mark itself complete before a settings window existed.
    // Advance once so affected installations receive the repaired guide.
    static let currentGuideVersion = 2
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

    /// Presents once, but only records a presentation that became visible.
    ///
    /// Marking before `open` meant one failed window order permanently skipped
    /// the guide. The closure boundary keeps the ordering independently
    /// measurable without constructing an application or touching TCC.
    @discardableResult
    static func completeGuidePresentationIfNeeded(
        storedVersion: Int, environment: [String: String],
        open: () -> Bool, markPresented: () -> Void
    ) -> Bool {
        guard
            shouldPresentGuide(
                storedVersion: storedVersion, environment: environment)
        else { return false }
        guard open() else { return false }
        markPresented()
        return true
    }

    @MainActor
    static func presentGuideIfNeeded(
        model: RouterModel, defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        completeGuidePresentationIfNeeded(
            storedVersion: defaults.integer(forKey: guideVersionKey),
            environment: environment,
            open: {
                SettingsWindow.open(model: model, initialSection: .permissions)
            },
            markPresented: {
                defaults.set(currentGuideVersion, forKey: guideVersionKey)
            })
    }
}
