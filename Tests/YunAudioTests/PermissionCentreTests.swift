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
        #expect(PermissionCentre.automationState(OSStatus(-50)) == .unavailable)
    }

    @Test("privacy destinations remain three distinct settings routes")
    func privacyDestinations() throws {
        let automation = try #require(
            PermissionCentre.Destination.automation.settingsURL?.absoluteString)
        let microphone = try #require(
            PermissionCentre.Destination.microphone.settingsURL?.absoluteString)
        let systemAudio = try #require(
            PermissionCentre.Destination.systemAudio.settingsURL?.absoluteString)

        #expect(Set([automation, microphone, systemAudio]).count == 3)
        #expect(automation.contains("Privacy_Automation"))
        #expect(microphone.contains("Privacy_Microphone"))
        #expect(systemAudio.contains("Privacy_ScreenCapture"))
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
        ] {
            #expect(!launch.contains(forbidden), "launch contains \(forbidden)")
        }
        #expect(launch.ranges(of: "requestAutomationPermission(for: bundleID)").count == 1)
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
