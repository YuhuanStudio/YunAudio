import AppKit
import SwiftUI
import YunDesign

/// Makes the title bar part of the application's surface.
///
/// Hiding the title alone leaves AppKit's 32-point title-bar row above the
/// content. That was the dark empty strip visible in every real-window
/// photograph: the traffic lights occupied it, then YunAudio began again below
/// it. `fullSizeContentView` is the part that actually gives those points back.
@MainActor
enum WindowChrome {
    /// Breathing room above the live main-window controls.
    ///
    /// Four points put the wordmark visibly against the window edge once the
    /// reserved title-bar row was removed. Twelve keeps the integrated surface
    /// while restoring the same optical margin as the rest of the interface.
    nonisolated static let headerTopClearance: CGFloat = 12

    /// Vertical room a left-edge control needs below the traffic lights.
    nonisolated static let controlClearance: CGFloat = 28

    nonisolated static func requiresOpaqueBacking(style: YunStyle) -> Bool {
        style == .flat
    }

    static func integrate(_ window: NSWindow, style: YunStyle = YunTheme.shared.style) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if requiresOpaqueBacking(style: style) {
            // A SwiftUI background can be visually solid while the WindowServer
            // still composites the whole window as an alpha surface. Measured
            // over 480 real AppKit moves, making the flat surface genuinely
            // opaque cut movement p99 from 5.39 ms to 1.61 ms and max from
            // 17.89 ms to 4.25 ms.
            window.isOpaque = true
            window.backgroundColor = NSColor(Yun.Palette.windowBackground)
        } else {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }

    /// Whether the content reaches the frame rather than starting below chrome.
    static func isIntegrated(_ window: NSWindow, tolerance: CGFloat = 1) -> Bool {
        guard let content = window.contentView else { return false }
        return window.styleMask.contains(.fullSizeContentView)
            && window.titleVisibility == .hidden
            && window.titlebarAppearsTransparent
            && abs(window.frame.height - content.frame.height) <= tolerance
    }
}

/// Reaches the AppKit window that owns a SwiftUI scene.
///
/// `Window` has no modifier for `fullSizeContentView`; `.hiddenTitleBar` hides
/// the title but still reserves its row. This zero-sized attachment applies the
/// same contract as the AppKit-owned settings and KTV windows.
struct WindowChromeInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        Attachment()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        WindowChrome.integrate(window)
    }

    private final class Attachment: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            WindowChrome.integrate(window)
        }
    }
}
