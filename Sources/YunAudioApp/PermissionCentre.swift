import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import Observation
import YunAudioHAL
import YunDesign

/// One permission surface for every protected capability the application uses.
///
/// Reading these values never opens a device or changes CoreAudio's topology.
/// The two audio request APIs live behind methods called only by buttons in the
/// permissions pane; normal launch must not manufacture consent by touching
/// capture hardware.
@MainActor
@Observable
final class PermissionCentre {
    enum State: Equatable {
        case allowed
        case needsRequest
        case notDetermined
        case unavailable

        var title: String {
            switch self {
            case .allowed: loc("Allowed")
            case .needsRequest: loc("Needs access")
            case .notDetermined: loc("Not checked")
            case .unavailable: loc("Unavailable")
            }
        }
    }

    enum Destination {
        case automation
        case microphone
        case systemAudio

        var settingsURL: URL? {
            let anchor =
                switch self {
                case .automation: "Privacy_Automation"
                case .microphone: "Privacy_Microphone"
                case .systemAudio: "Privacy_ScreenCapture"
                }
            return URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        }
    }

    static let shared = PermissionCentre()

    private(set) var microphone: State = .notDetermined
    /// CoreAudio has no passive process-tap preflight API. This is deliberately
    /// only the result of an explicit request made during this process.
    private(set) var systemAudio: State = .notDetermined
    private(set) var automation: [String: State] = [:]
    private(set) var requestInFlight: Set<String> = []

    private init() {
        refreshSafeStatuses()
    }

    /// Refreshes only APIs that cannot enumerate or open capture hardware.
    func refreshSafeStatuses() {
        microphone = Self.microphoneState(
            AVCaptureDevice.authorizationStatus(for: .audio))
        for target in NowPlaying.installedAutomationTargets {
            automation[target.bundleID] = Self.automationState(
                NowPlaying.automationPermissionStatus(for: target.bundleID))
        }
    }

    func automationState(for bundleID: String) -> State {
        automation[bundleID] ?? .notDetermined
    }

    /// Records a real feature attempt, which is stronger evidence than the
    /// settings probe because the tap was built for the selected application.
    func recordSystemAudioAttempt(succeeded: Bool) {
        systemAudio = succeeded ? .allowed : .needsRequest
    }

    /// Requests one player's Automation grant after a direct button press.
    func requestAutomation(for bundleID: String) {
        guard !requestInFlight.contains(bundleID) else { return }
        requestInFlight.insert(bundleID)
        Task {
            let status = await Task.detached(priority: .utility) {
                NowPlaying.requestAutomationPermission(for: bundleID)
            }.value
            automation[bundleID] = Self.automationState(status)
            requestInFlight.remove(bundleID)
            FirstLaunchPermissions.markAttempted(bundleID: bundleID)
        }
    }

    /// Requests microphone capture after a direct button press.
    func requestMicrophone() {
        let key = "microphone"
        guard !requestInFlight.contains(key) else { return }
        requestInFlight.insert(key)
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = allowed ? .allowed : .needsRequest
            requestInFlight.remove(key)
        }
    }

    /// Requests system-audio capture after a direct button press.
    ///
    /// Creating a short-lived private tap is the only API macOS provides for
    /// this grant. Keeping it here makes the user action that permits the
    /// topology change explicit and auditable.
    func requestSystemAudio() {
        let key = "system-audio"
        guard !requestInFlight.contains(key) else { return }
        requestInFlight.insert(key)
        Task {
            let status = await Task.detached(priority: .utility) {
                ProcessTap.requestCaptureAccess()
            }.value
            systemAudio = status == noErr ? .allowed : .needsRequest
            requestInFlight.remove(key)
        }
    }

    func openSettings(_ destination: Destination) {
        guard let url = destination.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func microphoneState(
        _ status: AVAuthorizationStatus
    ) -> State {
        switch status {
        case .authorized: .allowed
        case .notDetermined: .notDetermined
        case .denied, .restricted: .needsRequest
        @unknown default: .unavailable
        }
    }

    nonisolated static func automationState(_ status: OSStatus) -> State {
        switch status {
        case noErr: .allowed
        case OSStatus(errAEEventNotPermitted),
            OSStatus(errAEEventWouldRequireUserConsent):
            .needsRequest
        default: .unavailable
        }
    }
}
