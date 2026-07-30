import Foundation
import Testing

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
        #expect(
            !FirstLaunchPermissions.shouldRequest(
                storedVersion: 0,
                environment: ["YUNAUDIO_SETTINGS_CHECK": "1"]))
    }
}
