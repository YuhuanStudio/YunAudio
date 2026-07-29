import AVFoundation
import Foundation
import YunAudioHAL

/// Asks for the three protected resources YunAudio actually uses, once.
///
/// macOS has no combined permission sheet. Each prompt is owned by the API it
/// protects, so they are requested serially: microphone, system audio, then
/// Automation for each installed music player. Serial prompts are less likely
/// to obscure one another, and marking completion only at the end means
/// quitting halfway through resumes the sequence on the next launch.
enum FirstLaunchPermissions {
    static let currentVersion = 1
    private static let versionKey = "firstLaunchPermissionsVersion"

    @MainActor
    static func requestIfNeeded(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard
            shouldRequest(
                storedVersion: defaults.integer(forKey: versionKey),
                environment: environment)
        else { return }

        let players = NowPlaying.installedPlayerBundleIDs
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            _ = await Task.detached(priority: .utility) {
                ProcessTap.requestCaptureAccess()
            }.value
            for bundleID in players {
                _ = await Task.detached(priority: .utility) {
                    NowPlaying.requestAutomationPermission(for: bundleID)
                }.value
            }
            defaults.set(currentVersion, forKey: versionKey)
        }
    }

    static func shouldRequest(
        storedVersion: Int, environment: [String: String]
    ) -> Bool {
        guard storedVersion < currentVersion else { return false }
        return
            environment["YUNAUDIO_RENDER"] == nil
            && environment["YUNAUDIO_FLOWCHECK"] == nil
            && environment["YUNAUDIO_SCREENSHOT"] == nil
            && environment["YUNAUDIO_ICON"] == nil
    }
}
