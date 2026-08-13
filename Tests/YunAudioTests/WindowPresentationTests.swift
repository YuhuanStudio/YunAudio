import Testing
import YunDesign

@testable import YunAudioApp

@Suite("Window presentation")
struct WindowPresentationTests {
    @Test("Dock reopen with a presenter does not let AppKit choose Settings")
    func dockReopenUsesMainWindow() {
        #expect(
            !MainWindowReopenPolicy.appKitShouldChooseWindow(
                hasPresenter: true))
    }

    @Test("AppKit remains the fallback before the scene has mounted")
    func dockReopenBeforeInjectionFallsBack() {
        #expect(
            MainWindowReopenPolicy.appKitShouldChooseWindow(
                hasPresenter: false))
    }

    @Test("integrated chrome keeps a twelve-point internal top margin")
    func integratedChromeHasBreathingRoom() {
        #expect(WindowChrome.headerTopClearance == 12)
        #expect(WindowChrome.headerTopClearance > 4)
    }

    @Test("flat windows are opaque and glass windows retain transparency")
    func windowBackingMatchesTheDrawingStyle() {
        #expect(WindowChrome.requiresOpaqueBacking(style: .flat))
        #expect(!WindowChrome.requiresOpaqueBacking(style: .glass))
    }

    @Test("the shared chrome contract actually removes AppKit's reserved row")
    func windowChromeUsesFullSizeContent() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/WindowChrome.swift",
            encoding: .utf8)

        #expect(source.contains("window.styleMask.insert(.fullSizeContentView)"))
        #expect(source.contains("window.titleVisibility = .hidden"))
        #expect(source.contains("window.titlebarAppearsTransparent = true"))
        #expect(source.contains("window.frame.height - content.frame.height"))
    }

    /// KTV is absent by design. `ignoresSafeArea` was measured not to reach the
    /// region an `NSHostingView` derives from `fullSizeContentView` — with the
    /// region in place `safeAreaInsets` reads zero, and thirty-two points along
    /// the top edge stayed pure black however the modifier was placed. The stage
    /// clears the region instead; see `ktvClearsItsSafeAreaOneLevelDown`.
    @Test("every owned window accepts the integrated title-bar row")
    func rootsIgnoreTheTitleBarSafeArea() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        for file in ["MainWindow", "PreferencesWindow"] {
            let source = try String(
                contentsOfFile: root + "Sources/YunAudioApp/\(file).swift",
                encoding: .utf8)
            #expect(
                source.contains(".ignoresSafeArea(.container, edges: .top)"),
                "\(file) still lets SwiftUI reserve the title-bar safe area")
        }
    }

    /// The stage may clear its safe-area region, but never as the content view.
    ///
    /// This is written against what went wrong rather than against how it was
    /// put right. `host.safeAreaRegions = []` on a hosting view that *is* the
    /// window's content view invalidated constraints against
    /// `fullSizeContentView` on every pass: the window climbed to 1136 points
    /// for a 720-point request and AppKit threw `NSGenericException`. What was
    /// on screen was a partial layout — a transparent band along the top and a
    /// cut-off button — and the previous version of this test passed throughout,
    /// because it only asked whether the source contained the same strings the
    /// implementation contained.
    @Test("the KTV stage clears its safe area one level below the content view")
    func ktvClearsItsSafeAreaOneLevelDown() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/KTVWindow.swift",
            encoding: .utf8)

        // Cleared — it is the only thing that reaches the hosting view's own
        // region, and so the only thing that lets the artwork paint the row.
        #expect(source.contains("host.safeAreaRegions = []"))

        // Held below a plain container, sized by autoresizing rather than by
        // constraints, so there is nothing left to diverge.
        #expect(source.contains("container.addSubview(host)"))
        #expect(source.contains("host.autoresizingMask = [.width, .height]"))
        #expect(
            !source.contains("window.contentView = host"),
            "the hosting view is the content view again — this is the 1136-point window")

        // Opaque and black. A clear window background is what made the region
        // the stage had not painted show the desktop rather than the stage.
        #expect(!source.contains("window.isOpaque = false"))
        #expect(!source.contains("window.backgroundColor = .clear"))
        #expect(source.contains("window.backgroundColor = .black"))

        // Sized by its container, not by a reader that excludes the title bar.
        #expect(!source.contains("stageBackground(size: proxy.size)"))
        #expect(source.contains("stageBackground()"))
    }
}
