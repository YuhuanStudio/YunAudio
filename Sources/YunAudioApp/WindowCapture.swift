import AppKit
import ImageIO
import SwiftUI
import YunDesign

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

    static func write(to directory: String, model: RouterModel? = nil) async {
        guard let window = mainWindow() else {
            FileHandle.standardError.write(Data("no window to photograph\n".utf8))
            return
        }

        // Both looks. Glass can only be judged here — an offscreen rasteriser
        // gives a material no backdrop, so every glass card renders as nothing.
        for style in YunStyle.allCases {
            YunTheme.shared.style = style
            photograph(
                window, sizes: sizes, into: directory,
                suffix: style == .flat ? "" : "-glass")
        }
        YunTheme.shared.style = .flat

        // Every tab, because five of the six had never been photographed. The
        // offscreen renderer cycles them by building a fresh view per tab; the
        // live window is built once by the scene, so whatever tab it opened on
        // was the only one anybody ever saw a photograph of — and a tab nobody
        // photographs is a tab where anything can be wrong. It is where the
        // scripting panel turned out to have no tab at all, and where six tabs
        // turned out not to fit across the column.
        //
        // One appearance each rather than two: what these are for is layout —
        // clipping, overflow, a control that does not fit — and the colour
        // question is already answered by the two full passes above.
        if let model {
            let wasShowing = model.inspectorTab
            for tab in MainWindow.Inspector.allCases {
                model.inspectorTab = tab
                settle(turns: 12)
                photograph(
                    window, sizes: [("tab-\(tab.rawValue)", CGSize(width: 980, height: 600))],
                    into: directory, appearances: [.darkAqua])
            }
            model.inspectorTab = wasShowing
        }

        // The state that matters most is the one nothing else can show: meters
        // moving, the status strip carrying real numbers, a mixer with strips
        // in it. Every capture until now was of an idle window, which is the
        // state a user spends the least time looking at.
        guard let model, model.selectedDestination != nil, !model.isRunning else { return }
        model.start()
        for _ in 0..<80 where !model.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard model.isRunning else {
            FileHandle.standardError.write(
                Data("could not start routing — no running capture\n".utf8))
            return
        }
        // Long enough for the meters to have something in them.
        try? await Task.sleep(for: .seconds(2))
        model.toggleRecording()
        try? await Task.sleep(for: .seconds(2))

        photograph(
            window, sizes: [("running", CGSize(width: 1180, height: 900))],
            into: directory)

        model.toggleRecording()
        if let url = model.recordingURL { try? FileManager.default.removeItem(at: url) }
        model.stop()
    }

    private static func photograph(
        _ window: NSWindow, sizes: [(name: String, size: CGSize)], into directory: String,
        suffix: String = "", appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
    ) {
        for (label, size) in sizes {
            window.setContentSize(size)
            for scheme in appearances {
                let isLight = scheme == .aqua
                let name = "live-\(label)\(suffix)-\(isLight ? "light" : "dark").png"

                // Retried because an appearance change does not always reach
                // the view tree within one settle: the second size came out
                // dark in both passes, which is a capture that looks like a
                // design decision. Cheap to check, so it is checked.
                var png: Data?
                for attempt in 0..<4 {
                    NSApp.appearance = NSAppearance(named: scheme)
                    window.appearance = NSAppearance(named: scheme)
                    settle(turns: 8 + attempt * 8)
                    png = capture(window)
                    if let png, matches(png, isLight: isLight) { break }
                    png = nil
                }

                guard let png else {
                    let appearance = isLight ? "light" : "dark"
                    let message =
                        "\(name) never came out in the \(appearance) appearance"
                        + " — not written\n"
                    FileHandle.standardError.write(Data(message.utf8))
                    continue
                }
                // Through the renderer's writer, which creates the directory and
                // reports a failure rather than announcing a file it did not
                // write. See `PanelRenderer.write(_:named:to:)`.
                print(
                    PanelRenderer.write(png, named: name, to: directory)
                        .replacingOccurrences(of: "wrote ", with: "photographed "))
            }
        }
        NSApp.appearance = nil
    }

    /// Whether a capture is actually in the appearance it claims.
    ///
    /// The window's background is near-white in one and near-black in the
    /// other, so one pixel well inside the content settles it. Sampled below
    /// the title bar, which is translucent and would answer for neither.
    private static func matches(_ png: Data, isLight: Bool) -> Bool {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        // A point a little way down the left edge: past the title bar, which is
        // translucent and would answer for neither appearance, and inside the
        // window's own background rather than any card.
        guard
            let sampled = PixelProbe.sample(
                image, at: CGPoint(x: 6, y: Double(image.height) - 120))
        else { return false }
        return isLight ? sampled.r > 160 : sampled.r < 96
    }
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "YunAudio" && $0.contentView != nil }
    }

    /// Lets the layout, the appearance change and the window server catch up.
    ///
    /// A capture taken in the same turn as `setContentSize` photographs the old
    /// layout, which is a subtle enough lie to be worse than a failure.
    private static func settle(turns: Int = 8) {
        for _ in 0..<turns {
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
