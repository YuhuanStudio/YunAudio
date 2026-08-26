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
        raiseTitleBarAboveContent(window)
        // And again after SwiftUI has finished with the hierarchy.
        //
        // The synchronous call alone did nothing: `integrate` runs from
        // `viewDidMoveToWindow` and from `updateNSView`, and SwiftUI installs
        // or reinstalls its hosting view after both — putting the content back
        // on top of the buttons. One turn later it has settled.
        DispatchQueue.main.async { raiseTitleBarAboveContent(window) }
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

    /// Puts the traffic lights back on top of the content.
    ///
    /// Somebody reported the close, minimise and zoom buttons simply gone. They
    /// were not gone: the window had all three, unhidden, at 9, 29 and 49
    /// points from the left and 26 from the top — exactly where the header's
    /// 28-point inset leaves room for them. They were underneath.
    ///
    /// The theme frame stacked them
    ///
    ///     NSTitlebarContainerView → AppKitWindowHostingView<MainWindow…>
    ///
    /// and later is on top, so SwiftUI's hosting view was covering them. With
    /// `fullSizeContentView` the content is *meant* to reach the frame and the
    /// title bar is *meant* to float over it; that only works if the title bar
    /// is ordered above, and here it was not.
    ///
    /// Nothing in the gate could have caught it. An offscreen render has no
    /// window chrome at all, and a photograph of a dark corner reads as empty
    /// whether the buttons are missing or merely hidden behind something.
    ///
    /// Found through the buttons rather than by class name: a private view's
    /// name is not a contract, and the one thing that is certainly the right
    /// container is the one holding a button the window itself hands over.
    static func raiseTitleBarAboveContent(_ window: NSWindow) {
        guard let content = window.contentView,
            let themeFrame = content.superview,
            let button = window.standardWindowButton(.closeButton)
        else { return }
        var container: NSView? = button
        while let view = container, view.superview !== themeFrame {
            container = view.superview
        }
        guard let container, container !== content else { return }
        guard let titlebarIndex = themeFrame.subviews.firstIndex(of: container),
            let contentIndex = themeFrame.subviews.firstIndex(of: content),
            titlebarIndex < contentIndex
        else { return }
        themeFrame.addSubview(container, positioned: .above, relativeTo: content)
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
