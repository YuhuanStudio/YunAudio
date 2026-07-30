import Foundation
import Testing

@testable import YunAudioApp

@Suite("Main window opening")
struct MainWindowOpeningTests {
    @Test("the AppKit panel receives the scene opener and activation needs a visible window")
    func openingBoundaryIsExplicit() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let panel = try String(
            contentsOfFile: root + "Sources/YunAudioApp/PanelView.swift",
            encoding: .utf8)
        #expect(!panel.contains("@Environment(\\.openWindow)"))
        #expect(panel.contains("Button(loc(\"Open YunAudio\"), action: openMainWindow)"))

        let app = try String(
            contentsOfFile: root + "Sources/YunAudioApp/YunAudioApp.swift",
            encoding: .utf8)
        #expect(app.contains("private struct MainWindowOpenerInjector: View"))
        let sceneContentStart = try #require(
            app.range(of: "private struct MainWindowOpenerInjector: View"))
        let appStart = try #require(
            app.range(
                of: "@main",
                range: sceneContentStart.upperBound..<app.endIndex))
        let sceneContent = app[sceneContentStart.lowerBound..<appStart.lowerBound]
        #expect(sceneContent.contains("@Environment(\\.openWindow)"))
        #expect(sceneContent.contains(".frame(width: 0, height: 0)"))

        let installStart = try #require(
            app.range(of: "private func injectMainWindowOpener(_ openWindow: OpenWindowAction)")
        )
        let installEnd = try #require(
            app.range(
                of: "var body: some Scene",
                range: installStart.upperBound..<app.endIndex))
        let installation = app[installStart.lowerBound..<installEnd.lowerBound]
        let request = try #require(installation.range(of: "openWindow(id: \"main\")"))
        let yield = try #require(installation.range(of: "await Task.yield()"))
        let visible = try #require(installation.range(of: "&& $0.isVisible"))
        let activation = try #require(installation.range(of: "NSApp.activate("))
        #expect(request.lowerBound < yield.lowerBound)
        #expect(yield.lowerBound < visible.lowerBound)
        #expect(visible.lowerBound < activation.lowerBound)
    }
}
