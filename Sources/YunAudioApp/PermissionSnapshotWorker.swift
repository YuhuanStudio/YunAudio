import AppKit
import AVFoundation
import Foundation
import ServiceManagement

struct PermissionSafeStatusRequest: Sendable {
    let timeout: Duration

    init(timeout: Duration = PermissionSafeStatusProbe.defaultTimeout) {
        self.timeout = timeout
    }
}

struct PermissionSafeStatusSnapshot: Equatable, Sendable {
    let microphone: PermissionCentre.State
    let loginItem: PermissionCentre.State
    let automationTargets: [NowPlaying.AutomationTarget]
    let completedSystemCalls: Int
    let timedOut: Bool
    let wasRevoked: Bool
}

/// Injectable boundary around TCC, LaunchServices and ServiceManagement reads.
struct PermissionSystemServiceOperations: @unchecked Sendable {
    let microphoneState: @Sendable () -> PermissionCentre.State
    let loginItemState: @Sendable () -> PermissionCentre.State
    let isApplicationInstalled: @Sendable (String) -> Bool

    static let system = PermissionSystemServiceOperations(
        microphoneState: {
            PermissionCentre.microphoneState(
                AVCaptureDevice.authorizationStatus(for: .audio))
        },
        loginItemState: {
            PermissionCentre.loginItemState(LoginItem.readState())
        },
        isApplicationInstalled: { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        })
}

/// One bounded snapshot of protected and system-registered capabilities.
///
/// None of these APIs promises bounded latency. The deadline therefore decides
/// whether an answer is publishable, while the sole worker retains ownership if
/// a call returns late. At most eight known automation targets are examined; a
/// registry cannot turn this status card into an unbounded scan.
///
/// Automation state deliberately is not preflighted here. On macOS 27 build
/// 26A5421a, `AEDeterminePermissionToAutomateTarget` never returned for a live
/// Spotify 1.2.98.301. Combining that call with installation discovery erased
/// the Music result already in hand and left this sole worker occupied forever.
/// Actual Apple events now provide the permission answer at the feature boundary.
enum PermissionSafeStatusProbe {
    static let defaultTimeout: Duration = .milliseconds(750)
    static let maximumAutomationTargets = 8

    static func inspect(
        _ request: PermissionSafeStatusRequest,
        candidates: [NowPlaying.AutomationTarget] = NowPlaying.automationTargetCandidates,
        operations: PermissionSystemServiceOperations = .system,
        shouldContinue: @Sendable () -> Bool = { true }
    ) -> PermissionSafeStatusSnapshot {
        let deadline = ExternalIODeadline(timeout: request.timeout)
        var completed = 0

        func interruption() -> PermissionSafeStatusSnapshot? {
            if !shouldContinue() {
                return stopped(
                    completedSystemCalls: completed, timedOut: false, wasRevoked: true)
            }
            if deadline.hasExpired {
                return stopped(
                    completedSystemCalls: completed, timedOut: true, wasRevoked: false)
            }
            return nil
        }

        if let interruption = interruption() { return interruption }
        let microphone = operations.microphoneState()
        completed += 1
        if let interruption = interruption() { return interruption }

        let loginItem = operations.loginItemState()
        completed += 1
        if let interruption = interruption() { return interruption }

        var targets: [NowPlaying.AutomationTarget] = []
        for candidate in candidates.prefix(maximumAutomationTargets) {
            if let interruption = interruption() { return interruption }
            let installed = operations.isApplicationInstalled(candidate.bundleID)
            completed += 1
            if let interruption = interruption() { return interruption }
            guard installed else { continue }
            targets.append(candidate)
        }
        return PermissionSafeStatusSnapshot(
            microphone: microphone, loginItem: loginItem,
            automationTargets: targets,
            completedSystemCalls: completed, timedOut: false, wasRevoked: false)
    }

    private static func stopped(
        completedSystemCalls: Int, timedOut: Bool, wasRevoked: Bool
    ) -> PermissionSafeStatusSnapshot {
        PermissionSafeStatusSnapshot(
            microphone: .notDetermined, loginItem: .notDetermined,
            automationTargets: [],
            completedSystemCalls: completedSystemCalls,
            timedOut: timedOut, wasRevoked: wasRevoked)
    }
}

final class PermissionSafeStatusWorker: @unchecked Sendable {
    private let lane:
        SoleLatestSystemServiceWorker<
            PermissionSafeStatusRequest, PermissionSafeStatusSnapshot
        >

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.permission-status", qos: .utility),
        candidates: [NowPlaying.AutomationTarget] = NowPlaying.automationTargetCandidates,
        operations: PermissionSystemServiceOperations = .system,
        publish: @escaping @MainActor @Sendable (PermissionSafeStatusSnapshot) -> Void
    ) {
        lane = SoleLatestSystemServiceWorker(
            queue: queue,
            apply: { request, context in
                PermissionSafeStatusProbe.inspect(
                    request, candidates: candidates, operations: operations,
                    shouldContinue: { context.shouldContinue })
            },
            didTimeOut: \.timedOut,
            publish: publish)
    }

    var statistics:
        SoleLatestSystemServiceWorker<
            PermissionSafeStatusRequest, PermissionSafeStatusSnapshot
        >.Statistics
    { lane.statistics }

    @discardableResult
    func submit(_ request: PermissionSafeStatusRequest = PermissionSafeStatusRequest()) -> Bool
    {
        lane.submit(request)
    }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }
}
