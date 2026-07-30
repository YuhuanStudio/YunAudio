import Foundation

/// The first-launch guide to protected capabilities.
///
/// Kept as a pure list because a future protected feature must make an explicit
/// decision here. The first ordinary launch opens Settings → Permissions, then
/// serialises every missing grant. Verification modes never enter this path.
/// The microphone step asks TCC only; it does not enumerate or open a capture
/// device, so a Continuity microphone cannot be woken by the guide.
enum FirstLaunchPermissions {
    // Version 2 only presented the page, despite the feature's name. Advance so
    // existing installations receive the actual first-run request sequence.
    static let currentGuideVersion = 3
    private static let guideVersionKey = "permissionGuideVersion"

    enum Capability: CaseIterable {
        case microphone
        case systemAudio
        case musicAutomation
    }

    static let automaticallyRequested = Set(Capability.allCases)

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
        open: () -> Bool,
        request: (@escaping @MainActor () -> Void) -> Void,
        markPresented: @escaping @MainActor () -> Void
    ) -> Bool {
        guard
            shouldPresentGuide(
                storedVersion: storedVersion, environment: environment)
        else { return false }
        guard open() else { return false }
        // Completion, not task creation, advances the version. Quitting while a
        // prompt is still pending must let the next launch resume the sequence.
        request(markPresented)
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
            request: { completion in
                PermissionCentre.shared.requestAll(onComplete: completion)
            },
            markPresented: {
                defaults.set(currentGuideVersion, forKey: guideVersionKey)
            })
    }
}
