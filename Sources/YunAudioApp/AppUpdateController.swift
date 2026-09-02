import AppKit
import Foundation
import Observation
import Sparkle
import YunDesign

/// Owns application updates without giving the audio engine another lifecycle.
///
/// Sparkle ultimately asks AppKit to terminate before replacing the bundle. That
/// deliberately goes through `TerminationObserver`, so an update cannot cut a
/// route out from under Core Audio: the ordinary teardown fence decides when the
/// process is safe to replace.
@MainActor
@Observable
final class AppUpdateController: NSObject, SPUUpdaterDelegate {
    enum InstallationLocation: Equatable {
        case applications
        case userApplications
        case readOnlyVolume
        case appTranslocation
        case elsewhere

        var canReplaceInPlace: Bool {
            self == .applications || self == .userApplications
        }
    }

    static let shared = AppUpdateController()
    static let repositoryURL = URL(string: "https://github.com/YuhuanStudio/YunAudio")!
    static let releasesURL = URL(
        string: "https://github.com/YuhuanStudio/YunAudio/releases/latest")!

    private(set) var isAvailable = false
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var installationLocation: InstallationLocation = .elsewhere
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var feedVerificationCompletion: ((Error?) -> Void)?

    override init() {
        super.init()
    }

    /// Starts only for an ordinary bundled application launch.
    ///
    /// Render, screenshot, bundle and flow evidence must never contact an update
    /// server or display Sparkle's permission prompt. Keeping the admission here
    /// makes adding another synthetic launch fail closed through `ModelPolicy`.
    func start(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) {
        let policy = AppStartup.modelPolicy(environment: environment)
        let verifiesFeed = environment["YUNAUDIO_UPDATE_CHECK"] != nil
        guard controller == nil,
            policy.kind == .production || (verifiesFeed && policy.kind == .syntheticEvidence),
            bundle.bundleURL.pathExtension == "app"
        else { return }

        let values = try? bundle.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        installationLocation = Self.installationLocation(
            bundleURL: bundle.bundleURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            volumeIsReadOnly: values?.volumeIsReadOnly == true)

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        canCheckObservation = updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
        automaticCheckObservation = updater.observe(
            \.automaticallyChecksForUpdates, options: [.initial, .new]
        ) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.automaticallyChecksForUpdates = value }
        }
        controller.startUpdater()
        isAvailable = true
    }

    /// Downloads and verifies the appcast without presenting update UI.
    func verifyFeed(_ completion: @escaping (Error?) -> Void) {
        guard feedVerificationCompletion == nil, let updater = controller?.updater else {
            completion(AppUpdateError.updaterUnavailable)
            return
        }
        feedVerificationCompletion = completion
        updater.checkForUpdateInformation()
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard updateCheck == .updateInformation, let completion = feedVerificationCompletion
        else { return }
        feedVerificationCompletion = nil
        let sparkleError = error as NSError?
        // A current or newer local build is proof that Sparkle downloaded,
        // parsed and authenticated the feed. Sparkle models that ordinary
        // answer as error 1001 because its user-facing operation found nothing
        // to install; this model-free verifier asks whether the feed is valid.
        let verifiedCurrentFeed =
            sparkleError?.domain == SUSparkleErrorDomain
            && sparkleError?.code == 1001  // SUNoUpdateError in Sparkle's SUErrors.h.
        completion(verifiedCurrentFeed ? nil : error)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }

    func openReleases() {
        NSWorkspace.shared.open(Self.releasesURL)
    }

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    func reportIssue(
        bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo
    ) {
        guard let url = Self.issueURL(bundle: bundle, processInfo: processInfo) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func installationLocation(
        bundleURL: URL, homeDirectory: URL,
        volumeIsReadOnly: Bool
    ) -> InstallationLocation {
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return .appTranslocation }
        if volumeIsReadOnly { return .readOnlyVolume }
        if path.hasPrefix("/Applications/") { return .applications }
        let userApplications =
            homeDirectory
            .appending(path: "Applications", directoryHint: .isDirectory)
            .standardizedFileURL.path + "/"
        return path.hasPrefix(userApplications) ? .userApplications : .elsewhere
    }

    /// A report starts with reproducible identity and no machine-owned detail.
    ///
    /// Device names, routes, song titles and diagnostics are deliberately absent.
    /// The person can decide which of those belongs in the issue after GitHub opens.
    static func issueURL(
        bundle: Bundle, processInfo: ProcessInfo
    ) -> URL? {
        let version =
            bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build =
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        return issueURL(
            version: version, build: build,
            operatingSystem: processInfo.operatingSystemVersionString,
            title: loc("YunAudio problem: "))
    }

    nonisolated static func issueURL(
        version: String, build: String, operatingSystem: String,
        title: String
    ) -> URL? {
        var components = URLComponents(
            string: "https://github.com/YuhuanStudio/YunAudio/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(
                name: "body",
                value: """
                    YunAudio: \(version) (\(build))
                    macOS: \(operatingSystem)

                    What happened?


                    What did you expect?


                    How can it be reproduced?

                    """),
        ]
        return components?.url
    }
}

private enum AppUpdateError: LocalizedError {
    case updaterUnavailable

    var errorDescription: String? {
        switch self {
        case .updaterUnavailable: "The updater is unavailable in this process."
        }
    }
}
