import AVFoundation
import ApplicationServices
import Foundation
import Testing

@testable import YunAudioApp

@Suite("Permission centre")
struct PermissionCentreTests {
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

    @Test("normal launch source contains no audio permission API")
    func launchPathStaysAudioFree() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let launch = try String(
            contentsOfFile: root + "Sources/YunAudioApp/FirstLaunchPermissions.swift",
            encoding: .utf8)

        for forbidden in [
            "AVCaptureDevice", "requestAccess(for: .audio)",
            "requestCaptureAccess()", "AudioHardwareCreateProcessTap",
            "requestAutomationPermission", "AEDeterminePermission",
        ] {
            #expect(!launch.contains(forbidden), "launch contains \(forbidden)")
        }
        let app = try String(
            contentsOfFile: root + "Sources/YunAudioApp/YunAudioApp.swift",
            encoding: .utf8)
        #expect(!app.contains("FirstLaunchPermissions.request"))
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
        #expect(request.ranges(of: "AudioHardwareDestroyProcessTap(tapID)").count == 1)
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
