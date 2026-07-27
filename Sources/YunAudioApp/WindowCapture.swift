import AppKit
import ImageIO
import SwiftUI

/// Photographs the real window, as the window server draws it.
///
/// `PanelRenderer` builds a view tree offscreen and rasterises it. That is
/// useful for judging colour and spacing, but it is structurally blind to
/// everything the window itself contributes: the title bar and its traffic
/// lights, the title the scene puts there, where the content is clipped when the
/// window is at its minimum size, whether a scroll view actually scrolls. Two
/// defects lived in exactly that blind spot — a title drawn twice, and content
/// bleeding past the footer — and neither could appear in an offscreen capture
/// no matter how carefully it was read.
///
/// So this captures the window's own theme frame instead, which is the view the
/// title bar belongs to. No screen recording permission is involved: the
/// process is drawing its own window into a bitmap it owns.
@MainActor
enum WindowCapture {

    /// Sizes worth photographing. The minimum is where a layout breaks, and it
    /// is the one size an offscreen render will never be asked for, because
    /// offscreen renders are given whatever height makes them look complete.
    private static let sizes: [(name: String, size: CGSize)] = [
        ("min", CGSize(width: 980, height: 600)),
        ("tall", CGSize(width: 1180, height: 900)),
    ]

    static func write(to directory: String) {
        guard let window = mainWindow() else {
            FileHandle.standardError.write(Data("no window to photograph\n".utf8))
            return
        }

        for (label, size) in sizes {
            window.setContentSize(size)
            for scheme in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: scheme)
                settle()

                let name =
                    "live-\(label)-\(scheme == .aqua ? "light" : "dark").png"
                guard let png = capture(window) else {
                    FileHandle.standardError.write(Data("failed to capture \(name)\n".utf8))
                    continue
                }
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                try? png.write(to: url)
                print("photographed \(url.path)")
            }
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "YunAudio" && $0.contentView != nil }
    }

    /// Lets the layout, the appearance change and the window server catch up.
    ///
    /// A capture taken in the same turn as `setContentSize` photographs the old
    /// layout, which is a subtle enough lie to be worse than a failure.
    private static func settle() {
        for _ in 0..<8 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private static func capture(_ window: NSWindow) -> Data? {
        // The theme frame, not the content view: the title bar, its traffic
        // lights and the window's own corner rounding all belong to it, and
        // those are precisely what an offscreen render cannot show.
        guard let frame = window.contentView?.superview else { return nil }
        frame.displayIfNeeded()

        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
        else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)

        guard let image = bitmap.cgImage else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
