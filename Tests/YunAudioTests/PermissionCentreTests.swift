import AVFoundation
import ApplicationServices
import Foundation
import Testing

@testable import YunAudioApp

@Suite("Permission centre")
struct PermissionCentreTests {
    @MainActor
    @Test("synthetic permission centres submit exactly zero system probes")
    func syntheticStatusDiscoveryPolicy() {
        var ownerConstructions = 0
        var probeSubmissions = 0
        let centre = PermissionCentre(
            startupPolicy: AppStartup.ModelPolicy(kind: .syntheticEvidence),
            makeSafeStatusService: { _ in
                ownerConstructions += 1
                return PermissionCentre.SafeStatusService(
                    submit: { _ in
                        probeSubmissions += 1
                        return true
                    },
                    invalidate: {},
                    shutdown: {})
            })

        centre.refreshSafeStatuses()
        centre.refreshSafeStatuses()

        #expect(ownerConstructions == 0)
        #expect(probeSubmissions == 0)
        #expect(centre.safeStatusProbeSubmissions == 0)
    }

    @MainActor
    @Test("synthetic permission controls retain zero prompt ownership")
    func syntheticPromptPolicy() {
        let centre = PermissionCentre(
            startupPolicy: AppStartup.ModelPolicy(kind: .syntheticEvidence),
            makeSafeStatusService: { _ in
                Issue.record("synthetic policy constructed a system-service owner")
                return PermissionCentre.SafeStatusService(
                    submit: { _ in true }, invalidate: {}, shutdown: {})
            })
        var completions = 0

        #expect(!centre.requestAll { completions += 1 })
        centre.requestMicrophone()
        centre.requestSystemAudio()
        centre.requestAutomation(for: "com.apple.Music")
        centre.openSettings(.microphone)

        #expect(completions == 1)
        #expect(centre.requestInFlightCountForDiagnostics == 0)
        #expect(centre.safeStatusProbeSubmissions == 0)
    }

    @MainActor
    @Test("authorised permission centres retain launch and explicit refresh probes")
    func authorisedStatusDiscoveryPolicy() {
        for kind in [
            AppStartup.ModelPolicy.Kind.production,
            AppStartup.ModelPolicy.Kind.liveVerification,
        ] {
            var ownerConstructions = 0
            var probeSubmissions = 0
            let centre = PermissionCentre(
                startupPolicy: AppStartup.ModelPolicy(kind: kind),
                makeSafeStatusService: { _ in
                    ownerConstructions += 1
                    return PermissionCentre.SafeStatusService(
                        submit: { _ in
                            probeSubmissions += 1
                            return true
                        },
                        invalidate: {},
                        shutdown: {})
                })

            #expect(ownerConstructions == 1)
            #expect(probeSubmissions == 1)
            #expect(centre.safeStatusProbeSubmissions == 1)

            centre.refreshSafeStatuses()
            #expect(ownerConstructions == 1)
            #expect(probeSubmissions == 2)
            #expect(centre.safeStatusProbeSubmissions == 2)
        }
    }

    @Test("microphone status maps without opening a capture device")
    func microphoneStates() {
        #expect(PermissionCentre.microphoneState(.authorized) == .allowed)
        #expect(PermissionCentre.microphoneState(.notDetermined) == .notDetermined)
        #expect(PermissionCentre.microphoneState(.denied) == .needsRequest)
        #expect(PermissionCentre.microphoneState(.restricted) == .needsRequest)
    }

    @Test("Automation preflight has one actionable denied state")
    func automationStates() {
        #expect(PermissionCentre.automationState(noErr) == .allowed)
        #expect(
            PermissionCentre.automationState(OSStatus(errAEEventNotPermitted))
                == .needsRequest)
        #expect(
            PermissionCentre.automationState(
                OSStatus(errAEEventWouldRequireUserConsent))
                == .needsRequest)
        #expect(
            PermissionCentre.automationState(OSStatus(procNotFound))
                == .notDetermined)
        #expect(PermissionCentre.automationState(OSStatus(-50)) == .unavailable)
    }

    @Test("protected settings remain four distinct routes")
    func privacyDestinations() throws {
        let automation = try #require(
            PermissionCentre.Destination.automation.settingsURL?.absoluteString)
        let microphone = try #require(
            PermissionCentre.Destination.microphone.settingsURL?.absoluteString)
        let systemAudio = try #require(
            PermissionCentre.Destination.systemAudio.settingsURL?.absoluteString)
        let loginItems = try #require(
            PermissionCentre.Destination.loginItems.settingsURL?.absoluteString)

        #expect(Set([automation, microphone, systemAudio, loginItems]).count == 4)
        #expect(automation.contains("Privacy_Automation"))
        #expect(microphone.contains("Privacy_Microphone"))
        #expect(systemAudio.contains("Privacy_ScreenCapture"))
        #expect(loginItems.contains("LoginItems-Settings.extension"))
    }

    @Test("first launch delegates to the central sequence without opening a device")
    func launchPathUsesOnlyThePermissionCentre() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let launch = try String(
            contentsOfFile: root + "Sources/YunAudioApp/FirstLaunchPermissions.swift",
            encoding: .utf8)

        for forbidden in [
            "AVCaptureDevice", "requestAccess(for: .audio)",
            "requestCaptureAccess()", "AudioHardwareCreateProcessTap",
            "requestAutomationPermission", "AEDeterminePermission",
            "AudioDeviceStart", "AVCaptureDevice.default",
        ] {
            #expect(!launch.contains(forbidden), "launch contains \(forbidden)")
        }
        #expect(launch.ranges(of: "PermissionCentre.shared.requestAll").count == 1)
        let app = try String(
            contentsOfFile: root + "Sources/YunAudioApp/YunAudioApp.swift",
            encoding: .utf8)
        #expect(!app.contains("PermissionCentre.shared.requestAll()"))
    }

    @Test("login item approval maps into the same settings surface")
    func loginItemStates() {
        #expect(PermissionCentre.loginItemState(.enabled) == .allowed)
        #expect(PermissionCentre.loginItemState(.requiresApproval) == .needsRequest)
        #expect(PermissionCentre.loginItemState(.notRegistered) == .notDetermined)
        #expect(PermissionCentre.loginItemState(.unavailable) == .unavailable)
    }

    @Test("player reads preflight Automation without prompting")
    func playerReadsDoNotInventConsent() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/NowPlaying.swift",
            encoding: .utf8)

        #expect(
            source.contains(
                "let permission = automationPermissionStatus(for: bundleID)"))
        #expect(source.contains("guard permission == noErr else"))
        #expect(
            source.contains(
                "determineAutomationPermission(for: bundleID, askingUser: false)"))
    }

    @Test("the first-launch guide cannot re-enter status installation")
    func guideFollowsStatusItemGuard() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/YunAudioApp.swift",
            encoding: .utf8)
        let status = try #require(
            source.range(of: "termination.statusItem = StatusItemController"))
        let guardRange = try #require(
            source.range(of: "guard termination.statusItem == nil else { return }"))
        let guide = try #require(
            source.range(
                of: "FirstLaunchPermissions.presentGuideIfNeeded(model: model)"))

        #expect(guardRange.lowerBound < status.lowerBound)
        #expect(status.lowerBound < guide.lowerBound)
    }

    @MainActor
    @Test("the first-launch guide records only after every request completes")
    func guideRecordsSuccessfulPresentation() {
        var storedVersion = 0
        var events: [String] = []
        var canOpen = false
        var finishRequest: (@MainActor () -> Void)?

        func present() -> Bool {
            FirstLaunchPermissions.completeGuidePresentationIfNeeded(
                storedVersion: storedVersion,
                environment: [:],
                open: {
                    events.append("open")
                    return canOpen
                },
                request: { completion in
                    events.append("request")
                    finishRequest = completion
                },
                markPresented: {
                    events.append("mark")
                    storedVersion = FirstLaunchPermissions.currentGuideVersion
                })
        }

        #expect(!present())
        #expect(storedVersion == 0)
        #expect(events == ["open"])

        canOpen = true
        #expect(present())
        #expect(storedVersion == 0)
        #expect(events == ["open", "open", "request"])

        finishRequest?()
        #expect(storedVersion == FirstLaunchPermissions.currentGuideVersion)
        #expect(events == ["open", "open", "request", "mark"])

        #expect(!present())
        #expect(events == ["open", "open", "request", "mark"])
    }

    @MainActor
    @Test("request all serialises only the missing grants in prompt order")
    func requestAllIsSequential() async {
        let music = NowPlaying.AutomationTarget(
            name: "Music", bundleID: "com.apple.Music")
        let spotify = NowPlaying.AutomationTarget(
            name: "Spotify", bundleID: "com.spotify.client")
        let plan = PermissionCentre.requestPlan(
            microphone: .notDetermined,
            systemAudio: .needsRequest,
            automationTargets: [music, spotify],
            automationStates: [
                music.bundleID: .allowed,
                spotify.bundleID: .notDetermined,
            ])

        #expect(
            plan == [
                .microphone,
                .systemAudio,
                .automation(bundleID: spotify.bundleID),
            ])

        var completed: [PermissionCentre.RequestStep] = []
        await PermissionCentre.executeRequestPlan(plan) { step in
            completed.append(step)
        }
        #expect(completed == plan)

        #expect(
            PermissionCentre.requestPlan(
                microphone: .unavailable,
                systemAudio: .unavailable,
                automationTargets: [music, spotify],
                automationStates: [
                    music.bundleID: .unavailable,
                    spotify.bundleID: .unavailable,
                ]
            ).isEmpty)
    }

    @Test("the first screen owns the only automatic-looking permission action")
    func firstScreenUsesOneExplicitSequence() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let permissions = try String(
            contentsOfFile: root + "Sources/YunAudioApp/PermissionCentre.swift",
            encoding: .utf8)
        let preferences = try String(
            contentsOfFile: root + "Sources/YunAudioApp/PreferencesWindow.swift",
            encoding: .utf8)
        let launch = try String(
            contentsOfFile: root + "Sources/YunAudioApp/FirstLaunchPermissions.swift",
            encoding: .utf8)

        #expect(preferences.ranges(of: "permissions.requestAll()").count == 1)
        #expect(preferences.ranges(of: "loc(\"Request all access\")").count == 1)
        #expect(permissions.contains("AVCaptureDevice.requestAccess(for: .audio)"))
        #expect(permissions.contains("ProcessTap.requestCaptureAccess()"))
        #expect(permissions.contains("NowPlaying.requestAutomationPermission(for: bundleID)"))
        #expect(
            FirstLaunchPermissions.automaticallyRequested
                == Set(FirstLaunchPermissions.Capability.allCases))
        #expect(launch.ranges(of: "PermissionCentre.shared.requestAll").count == 1)
        #expect(!launch.contains("requestMicrophone()"))
        #expect(!launch.contains("requestSystemAudio()"))
    }

    @Test("automatic routing cannot become a deferred permission prompt")
    func autoStartPermissionGate() {
        #expect(
            FirstLaunchPermissions.canAutoStartWithoutRequest(
                microphoneIsAllowed: true,
                capturesApplications: false,
                cancelsEcho: false))
        for blocked in [
            (false, false, false),
            (true, true, false),
            (true, false, true),
            (false, true, true),
        ] {
            #expect(
                !FirstLaunchPermissions.canAutoStartWithoutRequest(
                    microphoneIsAllowed: blocked.0,
                    capturesApplications: blocked.1,
                    cancelsEcho: blocked.2))
        }
    }

    @Test("a missing tap can never be reported as permission granted")
    func missingPermissionTapIsNotSuccess() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioHAL/ProcessTap.swift",
            encoding: .utf8)
        let start = try #require(
            source.range(of: "public static func requestCaptureAccess()"))
        let end = try #require(
            source.range(
                of: "static func capturePermissionDescription()",
                range: start.upperBound..<source.endIndex))
        let request = source[start.lowerBound..<end.lowerBound]

        #expect(request.contains("guard tapID != kAudioObjectUnknown"))
        #expect(request.contains("status == noErr ? kAudioHardwareUnspecifiedError : status"))
        #expect(request.contains("requestRawDestruction("))
        #expect(request.contains("status == noErr ? destroyStatus : status"))
    }

    @Test("all three TCC prompts ship in every interface language")
    func usageDescriptionsAreLocalised() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let keys = [
            "NSMicrophoneUsageDescription",
            "NSAudioCaptureUsageDescription",
            "NSAppleEventsUsageDescription",
        ]
        for language in ["en", "zh-Hant", "zh-Hans"] {
            let table = try String(
                contentsOfFile:
                    root + "App/Resources/\(language).lproj/InfoPlist.strings",
                encoding: .utf8)
            #expect(keys.allSatisfy(table.contains))
            #expect(table.ranges(of: "UsageDescription").count == 3)
        }

        let builder = try String(
            contentsOfFile: root + "App/build-app.sh", encoding: .utf8)
        #expect(builder.contains("for LOCALISATION in App/Resources/*.lproj"))
        #expect(
            builder.contains(
                "cp -R \"${LOCALISATION}\" \"${BUNDLE}/Contents/Resources/\""))
    }
}
