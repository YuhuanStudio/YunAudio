import Foundation
import Testing
import YunDesign

@testable import YunAudioApp

@Suite("Settings entry")
struct SettingsEntryTests {
    @Test("the main-window gear uses the retained settings presenter")
    func mainWindowUsesRetainedPresenter() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/MainWindow.swift",
            encoding: .utf8)
        let headerStart = try #require(source.range(of: "private var header: some View"))
        let headerEnd = try #require(
            source.range(
                of: "private func deviceRow(",
                range: headerStart.upperBound..<source.endIndex))
        let header = source[headerStart.lowerBound..<headerEnd.lowerBound]

        #expect(header.ranges(of: "SettingsWindow.open(model: model)").count == 1)
        #expect(header.ranges(of: "SettingsLink {").count == 0)
        #expect(header.ranges(of: ".keyboardShortcut(\",\", modifiers: [.command])").count == 1)
        #expect(header.ranges(of: "loc(\"Settings\")").count == 1)
    }

    @Test("the settings-window check never requests first-launch permissions")
    func settingsCheckSkipsPermissions() {
        #expect(FirstLaunchPermissions.automaticallyRequested.isEmpty)
        #expect(
            !FirstLaunchPermissions.shouldPresentGuide(
                storedVersion: 0,
                environment: ["YUNAUDIO_SETTINGS_CHECK": "1"]))
    }

    @Test("the retained settings graph is detached while its window is closed")
    func settingsWindowRetainsStateWithoutRetainingHiddenWork() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/PreferencesWindow.swift",
            encoding: .utf8)
        let presenterStart = try #require(source.range(of: "enum SettingsWindow"))
        let presenterEnd = try #require(
            source.range(
                of: "struct PreferencesWindow",
                range: presenterStart.upperBound..<source.endIndex))
        let presenter = source[presenterStart.lowerBound..<presenterEnd.lowerBound]

        #expect(presenter.contains("private static var host: NSViewController?"))
        #expect(presenter.contains("private static var delegate: Delegate?"))
        #expect(presenter.contains("window.contentViewController = host"))
        #expect(presenter.contains("controller.window?.contentViewController = host"))
        #expect(
            presenter.contains(
                "(notification.object as? NSWindow)?.contentViewController = nil"))
        #expect(source.ranges(of: "BodyCount.tick(\"PreferencesWindow\")").count == 1)
    }

    @Test("permissions are one navigable settings section")
    func permissionsHaveOneSettingsHome() throws {
        #expect(PreferencesWindow.Section.allCases.contains(.permissions))
        #expect(PreferencesWindow.Section.permissions.title == loc("Permissions"))

        let root = PreferencesCompletenessTests.sourceRootForTests
        let preferences = try String(
            contentsOfFile: root + "Sources/YunAudioApp/PreferencesWindow.swift",
            encoding: .utf8)
        let singing = try String(
            contentsOfFile: root + "Sources/YunAudioApp/SingingPanel.swift",
            encoding: .utf8)

        #expect(preferences.contains("permissions.requestMicrophone()"))
        #expect(preferences.contains("permissions.requestSystemAudio()"))
        #expect(preferences.contains("permissions.requestAutomation(for: target.bundleID)"))
        #expect(
            singing.contains(
                "SettingsWindow.open(model: model, initialSection: .permissions)"))
        #expect(!singing.contains("Privacy_Automation"))
    }
}
