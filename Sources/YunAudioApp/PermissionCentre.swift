import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import Observation
import ServiceManagement
import YunAudioHAL
import YunDesign

/// One permission surface for every protected capability the application uses.
///
/// Reading these values never opens a device or changes CoreAudio's topology.
/// The first-launch guide and the buttons in the permissions pane are the only
/// callers of the request APIs. Asking for microphone access does not open a
/// device; system-audio consent has no standalone API, so that step creates and
/// immediately destroys a private process tap without starting IO.
@MainActor
@Observable
final class PermissionCentre {
    /// Injectable process-service boundary for deterministic launch assertions.
    struct SafeStatusService {
        let submit: @MainActor (PermissionSafeStatusRequest) -> Bool
        let invalidate: @MainActor () -> Void
        let shutdown: @MainActor () -> Void

        static func live(
            receive: @escaping @MainActor @Sendable (PermissionSafeStatusSnapshot) -> Void
        ) -> SafeStatusService {
            let worker = PermissionSafeStatusWorker(publish: receive)
            return SafeStatusService(
                submit: { worker.submit($0) },
                invalidate: { worker.invalidate() },
                shutdown: { worker.shutdown() })
        }
    }

    enum RequestStep: Equatable {
        case microphone
        case systemAudio
        case automation(bundleID: String)
    }

    enum State: Equatable, Sendable {
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
        case loginItems

        var settingsURL: URL? {
            switch self {
            case .automation:
                URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
            case .microphone:
                URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
            case .systemAudio:
                URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
            case .loginItems:
                URL(
                    string:
                        "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
            }
        }
    }

    static let shared = PermissionCentre(
        startupPolicy: AppStartup.modelPolicy(
            environment: ProcessInfo.processInfo.environment))

    private(set) var microphone: State = .notDetermined
    /// CoreAudio has no passive process-tap preflight API. This is deliberately
    /// only the result of an explicit request made during this process.
    private(set) var systemAudio: State = .notDetermined
    private(set) var automationTargets: [NowPlaying.AutomationTarget] = []
    private(set) var automation: [String: State] = [:]
    private(set) var loginItem: State = .notDetermined
    private(set) var requestInFlight: Set<String> = []
    private(set) var safeStatusSnapshotTimedOut = false
    private var hasCompletedSafeStatusSnapshot = false
    private var requestAllWaitsForSnapshot = false
    private var deferredRequestAllCompletion: (@MainActor () -> Void)?
    @ObservationIgnored private var safeStatusService: SafeStatusService?
    private let startupPolicy: AppStartup.ModelPolicy
    private(set) var safeStatusProbeSubmissions = 0

    init(
        startupPolicy: AppStartup.ModelPolicy,
        makeSafeStatusService:
            @MainActor (
                @escaping @MainActor @Sendable (PermissionSafeStatusSnapshot) -> Void
            ) -> SafeStatusService = SafeStatusService.live
    ) {
        self.startupPolicy = startupPolicy
        if startupPolicy.startsLiveServicesAfterLaunch {
            safeStatusService = makeSafeStatusService { [weak self] snapshot in
                self?.receiveSafeStatus(snapshot)
            }
        }
        refreshSafeStatuses()
    }

    /// Refreshes only APIs that cannot enumerate or open capture hardware.
    func refreshSafeStatuses() {
        guard startupPolicy.startsLiveServicesAfterLaunch,
            let safeStatusService,
            safeStatusService.submit(PermissionSafeStatusRequest())
        else { return }
        safeStatusProbeSubmissions &+= 1
    }

    /// Whether a Music or Spotify installation was found in the latest complete scan.
    var hasInstalledPlayer: Bool {
        automationTargets.contains {
            $0.bundleID == "com.apple.Music" || $0.bundleID == "com.spotify.client"
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

    static func requestPlan(
        microphone: State, systemAudio: State,
        automationTargets: [NowPlaying.AutomationTarget],
        automationStates: [String: State]
    ) -> [RequestStep] {
        var steps: [RequestStep] = []
        if microphone == .notDetermined || microphone == .needsRequest {
            steps.append(.microphone)
        }
        if systemAudio == .notDetermined || systemAudio == .needsRequest {
            steps.append(.systemAudio)
        }
        steps.append(
            contentsOf: automationTargets.compactMap { target in
                let state = automationStates[target.bundleID] ?? .notDetermined
                return state == .notDetermined || state == .needsRequest
                    ? .automation(bundleID: target.bundleID) : nil
            })
        return steps
    }

    var pendingRequestPlan: [RequestStep] {
        Self.requestPlan(
            microphone: microphone,
            systemAudio: systemAudio,
            automationTargets: automationTargets,
            automationStates: automation)
    }

    var canRequestAll: Bool {
        requestInFlight.isEmpty && !pendingRequestPlan.isEmpty
    }

    var isRequestingAll: Bool {
        requestInFlight.contains("all")
    }

    /// Number of prompts or deferred prompt plans currently owned.
    ///
    /// Exposed only as a number so the synthetic launch test can prove that a
    /// control cannot leave an invisible request behind after machine-service
    /// authority was refused.
    var requestInFlightCountForDiagnostics: Int { requestInFlight.count }

    static func executeRequestPlan(
        _ steps: [RequestStep], perform: (RequestStep) async -> Void
    ) async {
        for step in steps {
            await perform(step)
        }
    }

    /// Requests every first-run capability serially.
    ///
    /// System-audio consent has no passive request API: asking for it creates
    /// and destroys a CoreAudio process tap. No request in this sequence opens
    /// an input device or starts IO.
    @discardableResult
    func requestAll(
        onComplete: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        guard startupPolicy.startsLiveServicesAfterLaunch else {
            onComplete()
            return false
        }
        guard requestInFlight.isEmpty else { return false }
        if hasCompletedSafeStatusSnapshot, pendingRequestPlan.isEmpty {
            onComplete()
            return false
        }
        let key = "all"
        requestInFlight.insert(key)
        guard hasCompletedSafeStatusSnapshot else {
            requestAllWaitsForSnapshot = true
            deferredRequestAllCompletion = onComplete
            refreshSafeStatuses()
            return true
        }
        beginRequestAll(onComplete: onComplete)
        return true
    }

    private func beginRequestAll(onComplete: @escaping @MainActor () -> Void) {
        let key = "all"
        let steps = pendingRequestPlan
        guard !steps.isEmpty else {
            requestInFlight.remove(key)
            onComplete()
            return
        }
        Task {
            await Self.executeRequestPlan(steps) { step in
                switch step {
                case .microphone:
                    await requestMicrophoneAccess()
                case .systemAudio:
                    await requestSystemAudioAccess()
                case .automation(let bundleID):
                    await requestAutomationAccess(for: bundleID)
                }
            }
            requestInFlight.remove(key)
            onComplete()
        }
    }

    /// Requests one player's Automation grant after a direct button press.
    func requestAutomation(for bundleID: String) {
        guard startupPolicy.startsLiveServicesAfterLaunch else { return }
        guard requestInFlight.isEmpty else { return }
        requestInFlight.insert(bundleID)
        Task {
            await requestAutomationAccess(for: bundleID)
            requestInFlight.remove(bundleID)
        }
    }

    /// Requests microphone capture after a direct button press.
    func requestMicrophone() {
        let key = "microphone"
        guard startupPolicy.startsLiveServicesAfterLaunch else { return }
        guard requestInFlight.isEmpty else { return }
        requestInFlight.insert(key)
        Task {
            await requestMicrophoneAccess()
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
        guard startupPolicy.startsLiveServicesAfterLaunch else { return }
        guard requestInFlight.isEmpty else { return }
        requestInFlight.insert(key)
        Task {
            await requestSystemAudioAccess()
            requestInFlight.remove(key)
        }
    }

    private func requestAutomationAccess(for bundleID: String) async {
        let status = await Task.detached(priority: .utility) {
            NowPlaying.requestAutomationPermission(for: bundleID)
        }.value
        automation[bundleID] = Self.automationState(status)
    }

    private func requestMicrophoneAccess() async {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = allowed ? .allowed : .needsRequest
    }

    private func requestSystemAudioAccess() async {
        let status = await Task.detached(priority: .utility) {
            ProcessTap.requestCaptureAccess()
        }.value
        systemAudio = status == noErr ? .allowed : .needsRequest
    }

    func openSettings(_ destination: Destination) {
        guard startupPolicy.startsLiveServicesAfterLaunch else { return }
        guard let url = destination.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Revokes a stale snapshot for a Quit which AppKit may still refuse.
    func invalidateSafeStatusRefresh() { safeStatusService?.invalidate() }

    /// Permanently closes status discovery only after AppKit accepts termination.
    func shutDownSafeStatusRefresh() { safeStatusService?.shutdown() }

    private func receiveSafeStatus(_ snapshot: PermissionSafeStatusSnapshot) {
        guard !snapshot.wasRevoked else { return }
        safeStatusSnapshotTimedOut = snapshot.timedOut
        guard !snapshot.timedOut else {
            if requestAllWaitsForSnapshot {
                requestAllWaitsForSnapshot = false
                deferredRequestAllCompletion = nil
                requestInFlight.remove("all")
            }
            return
        }
        microphone = snapshot.microphone
        loginItem = snapshot.loginItem
        automationTargets = snapshot.automationTargets
        automation = snapshot.automation
        hasCompletedSafeStatusSnapshot = true

        guard requestAllWaitsForSnapshot else { return }
        requestAllWaitsForSnapshot = false
        let completion = deferredRequestAllCompletion ?? {}
        deferredRequestAllCompletion = nil
        beginRequestAll(onComplete: completion)
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
        case OSStatus(procNotFound): .notDetermined
        default: .unavailable
        }
    }

    nonisolated static func loginItemState(_ state: LoginItem.State) -> State {
        switch state {
        case .enabled: .allowed
        case .requiresApproval: .needsRequest
        case .notRegistered: .notDetermined
        case .unavailable: .unavailable
        }
    }
}
