import AppKit
import ImageIO
import SwiftUI
import YunDesign

/// Renders the panel to PNGs so its layout and colours can actually be looked
/// at. Reading the view code is not verification.
@MainActor
enum PanelRenderer {
    static func write(to directory: String, model: RouterModel) {
        verifyPipeline()
        model.prepareForRendering()
        // Flat only. A material has nothing to be a material over in an
        // offscreen rasteriser: rendered here, every glass card comes out as
        // near-nothing and the capture shows an empty window. Glass is judged
        // from the live window capture, which has a real backdrop.
        YunTheme.shared.style = .flat
        write(directory: directory, model: model, suffix: "")
    }

    private static func write(directory: String, model: RouterModel, suffix: String) {
        render(
            PanelView(model: model, forcesRoutedLayout: true),
            basename: "panel\(suffix)", directory: directory)
        // The preferences window scrolls, and a ScrollView has no intrinsic
        // height offscreen — without an explicit size it renders as an empty
        // pane. Pinned to the window's minimum size.
        // Every tab, not only the one that opens. Three of the four had never
        // been looked at in either appearance — the whole point of this being
        // a tabbed inspector is that most of it is off screen most of the
        // time, which is exactly the condition under which a layout defect
        // survives.
        for tab in MainWindow.Inspector.allCases where tab != .sound {
            render(
                MainWindow(model: model, initialInspector: tab, isRendering: true),
                basename: "window-\(tab.rawValue)\(suffix)", directory: directory,
                size: CGSize(width: 1060, height: 1480))
        }
        render(
            MainWindow(model: model, isRendering: true),
            basename: "window\(suffix)", directory: directory,
            // Taller than the window's minimum so the whole layout is visible
            // at once. The columns scroll in the running app; here they do not,
            // and a clipped capture hides exactly the defects this exists to
            // find.
            // Tall enough for the whole layout. It was 860, and the content
            // outgrew that some time ago: the capture clipped its own top, so
            // the window header and the inspector's tab bar were missing from
            // every design check without anything saying so. A capture that
            // silently crops is worse than no capture.
            // It outgrew 1180 the same way when the Sound tab became three
            // labelled regions: the header went at the top and the reverb row
            // off the bottom. An over-tall capture costs white space; a short
            // one costs the check.
            // Sized for the Sound tab with every stage switched on, because
            // that is the tallest this window gets and it is a state a scene
            // preset can put it in with one click — each enabled stage adds its
            // knobs. The capture inherits whatever was last persisted, so the
            // height cannot be chosen for the empty case.
            size: CGSize(width: 1060, height: 1900))

        for section in PreferencesWindow.Section.allCases {
            render(
                PreferencesWindow(model: model, initialSection: section, isRendering: true),
                basename: "prefs-\(section.rawValue)\(suffix)",
                directory: directory,
                // Wide as the window's minimum, so a control that does not fit
                // is seen here; taller than it, because the panes scroll in the
                // running app and a capture that crops hides the last card in
                // every section from the only check that looks at colour.
                size: CGSize(width: 620, height: 700))
        }
    }

    /// Set when anything could not be written, so the process can exit
    /// non-zero. A verification tool that reports success while producing
    /// nothing is worse than one that is missing.
    private nonisolated(unsafe) static var failed = false

    /// False when any file could not be written.
    static var wroteEverything: Bool { !failed }

    private static func render(
        _ view: some View, basename: String, directory: String, size: CGSize? = nil
    ) {
        for scheme in [ColorScheme.light, .dark] {
            let name = "\(basename)-\(scheme == .light ? "light" : "dark").png"
            // The rendered tree is wrapped in the same background the glass
            // shell sits on, so contrast is judged against a real surface
            // rather than transparency.
            let sized =
                size.map { AnyView(view.frame(width: $0.width, height: $0.height)) }
                ?? AnyView(view)
            let content =
                sized
                .environment(\.colorScheme, scheme)
                .background(
                    scheme == .light
                        ? Color(hex: 0xF2F2F4) : Color(hex: 0x0C0C0E))

            let renderer = ImageRenderer(content: content)
            renderer.scale = scale
            // ImageRenderer resolves dynamic NSColor against the process
            // appearance, not the environment, so the appearance is switched
            // for the duration of the render.
            let previous = NSApp?.appearance
            NSApp?.appearance = NSAppearance(
                named: scheme == .light ? .aqua : .darkAqua)
            defer { NSApp?.appearance = previous }

            guard let png = pngData(from: renderer) else {
                FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
                continue
            }
            print(write(png, named: name, to: directory))
        }
    }

    private static let scale: CGFloat = 2

    /// Writes one capture and says what actually happened.
    ///
    /// It used to be `try? png.write(to: url)` followed unconditionally by
    /// `print("wrote …")`, and the directory was never created — so the
    /// documented invocation on a machine that has not run this before wrote
    /// nothing at all and reported twenty files. A capture harness that lies
    /// about having produced captures is worse than no harness: the design
    /// check it exists for then passes by reading yesterday's images, or none.
    static func write(_ png: Data, named name: String, to directory: String) -> String {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        do {
            try png.write(to: url)
            return "wrote \(url.path)"
        } catch {
            // Recorded as well as reported, so the process can exit non-zero.
            // A design check whose output is missing must not look like one
            // that passed — printing the reason is only half of saying so.
            failed = true
            return "could not write \(url.path): \(error.localizedDescription)"
        }
    }

    /// Sends a known colour through the real capture path and checks it comes
    /// back unchanged.
    ///
    /// The previous pipeline corrupted every colour in every window capture and
    /// said nothing: one wide-gamut application icon in the tree was enough to
    /// push `ImageRenderer` into a sixteen-bit backing store, and the TIFF round
    /// trip then flattened that half-transparent over grey, mapping every value
    /// through `0.49·v + 0.11`. A capture that lies is worse than no capture,
    /// because its whole purpose is judging colour, and a uniform wash reads as
    /// a design choice rather than a bug.
    ///
    /// The probe includes an icon, since that is what triggered it, and it
    /// checks the pipeline rather than any particular view — a view's own
    /// corner pixel is a legitimate design decision and cannot be asserted on.
    private static func verifyPipeline() {
        let probe = Color(hex: 0x3B82F6)
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app")
        let renderer = ImageRenderer(
            content: ZStack {
                probe
                Image(nsImage: icon).resizable().frame(width: 8, height: 8)
            }
            .frame(width: 40, height: 40))
        renderer.scale = scale

        guard let png = pngData(from: renderer),
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let sampled = PixelProbe.sample(image, at: CGPoint(x: 2, y: 2))
        else {
            FileHandle.standardError.write(Data("the capture pipeline failed\n".utf8))
            return
        }

        let drift = max(
            abs(Int(sampled.r) - 0x3B), abs(Int(sampled.g) - 0x82),
            abs(Int(sampled.b) - 0xF6))
        guard drift > 2 else { return }
        FileHandle.standardError.write(
            Data(
                String(
                    format:
                        "⚠︎ the capture pipeline is altering colour: #3B82F6 came back as #%02X%02X%02X. Every capture below is unreliable.\n",
                    sampled.r, sampled.g, sampled.b
                ).utf8))
    }

    /// Rasterises into a context this code owns, in sRGB, at eight bits.
    ///
    /// The obvious route — `renderer.nsImage`, `tiffRepresentation`,
    /// `NSBitmapImageRep` — is wrong, and wrong in the worst way: silently.
    /// One application icon in the view is enough to push `ImageRenderer` into
    /// a sixteen-bit wide-gamut backing store, and the TIFF round trip then
    /// converts that to `NSCalibratedRGB` by compositing it half-transparent
    /// over grey. Every colour in the capture came out as `0.49·v + 0.11`: a
    /// near-white background read as mid grey, near-black text as dark grey.
    ///
    /// That made the captures worse than useless, because the whole point of
    /// them is to judge colour, and a uniform wash looks like a design choice
    /// rather than a bug. Owning the context removes the conversion entirely.
    private static func pngData<Content: View>(from renderer: ImageRenderer<Content>) -> Data? {
        // `render` hands the context to a closure and returns nothing, so the
        // result comes back out through a captured variable.
        var result: Data?
        renderer.render(rasterizationScale: scale) { size, draw in
            let width = Int((size.width * scale).rounded())
            let height = Int((size.height * scale).rounded())
            guard width > 0, height > 0,
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }

            // Scale only. The closure flips the context itself, so flipping it
            // here as well hands back a capture that is upside down — which is
            // obvious in a screenshot and was, at least, caught immediately.
            context.scaleBy(x: scale, y: scale)
            draw(context)

            guard let image = context.makeImage() else { return }
            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data, "public.png" as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            result = data as Data
        }
        return result
    }
}

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
