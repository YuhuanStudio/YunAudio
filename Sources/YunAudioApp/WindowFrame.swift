import AppKit
import SwiftUI

/// Remembers where the window was and how big.
///
/// A window that reopens in the middle of the screen at its default size every
/// launch is a small thing that never stops being irritating, and AppKit will
/// do it for nothing once the frame has a name to be saved under. SwiftUI does
/// not set one for a `Window` scene in an accessory application, so it is set
/// here — from a zero-sized view that reaches its own window, which is the only
/// hook SwiftUI offers onto the `NSWindow` behind a scene.
struct RemembersFrame: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not attached yet during `makeNSView`, so this waits for
        // the view to be in a hierarchy before asking which window it is in.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.setFrameAutosaveName(name)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
