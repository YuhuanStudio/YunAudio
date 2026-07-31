import AppKit
import ImageIO
import SwiftUI
import YunDesign

/// Renders the panel to PNGs so its layout and colours can actually be looked
/// at. Reading the view code is not verification.
@MainActor
enum PanelRenderer {
    static func write(to directory: String, model: RouterModel) {
        failed = false
        verifyPipeline()
        model.prepareForRendering()
        // Flat only. A material has nothing to be a material over in an
        // offscreen rasteriser: rendered here, every glass card comes out as
        // near-nothing and the capture shows an empty window. Glass is judged
        // from the live window capture, which has a real backdrop.
        YunTheme.shared.style = .flat
        write(directory: directory, model: model, suffix: "")
        writeMarks(to: directory)
    }

    /// The menu bar glyph and the application icon, which no window capture
    /// contains.
    ///
    /// Both are eighteen points and 1024 points of the same drawing code, and
    /// neither appears in any of the captures above — the glyph lives in the
    /// menu bar and the icon lives in Finder. So the only way anybody had of
    /// looking at them was to install the application, which meant that in
    /// practice nobody looked at them at all. The tests assert that the states
    /// differ; these say what they look like, which is a different question and
    /// not one a test can answer.
    private static func writeMarks(to directory: String) {
        // Each state, and both halves of the alarm's blink.
        let states: [(String, Float?, Bool, Bool, Bool)] = [
            ("idle", nil, false, false, false),
            ("quiet", 0.02, false, false, false),
            ("speech", 0.25, false, false, false),
            ("loud", 0.85, false, false, false),
            ("muted", nil, true, false, false),
            ("alarm", nil, true, true, false),
            ("alarm dim", nil, true, true, true),
        ]
        // A status item is a template: the menu bar draws it in its own
        // foreground colour. Rendered against both, because a glyph that is
        // legible in one and not the other is the defect this catches.
        for (appearance, background, foreground) in [
            ("light", NSColor.white, NSColor.black),
            ("dark", NSColor(white: 0.13, alpha: 1), NSColor.white),
        ] {
            let magnification: CGFloat = 6
            let cell = 18 * magnification + 12
            let width = Int(cell * CGFloat(states.count))
            let height = Int(18 * magnification + 54)
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .calibratedRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
                let context = NSGraphicsContext(bitmapImageRep: rep)
            else {
                failed = true
                continue
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            background.setFill()
            NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
            for (index, state) in states.enumerated() {
                let x = CGFloat(index) * cell + 6
                // Magnified, to judge the shape; and at the size it is actually
                // seen, which is the only judgement that counts.
                for (origin, size, interpolation) in [
                    (NSPoint(x: x, y: 40), 18 * magnification, NSImageInterpolation.none),
                    (NSPoint(x: x + 18 * magnification / 2 - 9, y: 16), 18, .high),
                ] {
                    NSGraphicsContext.saveGraphicsState()
                    context.imageInterpolation = interpolation
                    context.cgContext.translateBy(x: origin.x, y: origin.y)
                    context.cgContext.scaleBy(x: size / 18, y: size / 18)
                    // In a layer of its own, so that tinting the glyph the way
                    // AppKit tints a template does not also tint the sheet
                    // behind it.
                    context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
                    StatusItemController.drawStatusMark(
                        level: state.1, isMuted: state.2, isSpeakingWhileMuted: state.3,
                        isDim: state.4)
                    // What AppKit does to a template image, done here so the
                    // capture shows what the menu bar shows rather than a black
                    // shape on a black bar.
                    foreground.setFill()
                    NSRect(x: 0, y: 0, width: 18, height: 18).fill(using: .sourceAtop)
                    context.cgContext.endTransparencyLayer()
                    NSGraphicsContext.restoreGraphicsState()
                }
                (state.0 as NSString).draw(
                    at: NSPoint(x: x, y: 2),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 10), .foregroundColor: foreground,
                    ])
            }
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                print(write(png, named: "menu-bar-mark-\(appearance).png", to: directory))
            } else {
                failed = true
            }
        }

        // Every icon style, at the size somebody judges an icon at.
        for style in YunIconBadge.styles {
            guard let rep = YunIconBadge.bitmap(size: 512, style: style),
                let png = rep.representation(using: .png, properties: [:])
            else {
                failed = true
                continue
            }
            print(write(png, named: "app-icon-\(style.name).png", to: directory))
        }
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
        for tab in MainWindow.Inspector.allCases {
            render(
                MainWindow(model: model, initialInspector: tab, isRendering: true),
                basename: "window-\(tab.rawValue)\(suffix)", directory: directory,
                // Sound can contain every processing stage and is substantially
                // taller than the other inspectors. Each view gets its own
                // explicit tab and size: constructing all the non-sound views
                // first used to leave the shared model on Hardware, so the file
                // named `window-light.png` photographed Hardware a second time
                // and Sound was never rendered.
                size: CGSize(
                    width: 1060,
                    height: tab == .sound ? 1900 : 1480))
        }

        // Rendering the compact singing inspector drives its disappearance hook
        // before the later tabs are built, which correctly clears the live
        // singing state. Re-seed the fixture so the standalone stage is judged
        // with the track, artwork and timed words it exists to display.
        model.prepareForRendering()
        render(
            KTVStage(model: model, isRendering: true),
            basename: "ktv\(suffix)",
            directory: directory,
            size: CGSize(width: 1080, height: 720))
        render(
            KTVStage(model: model, isRendering: true),
            basename: "ktv-content\(suffix)",
            directory: directory,
            size: CGSize(width: 1080, height: 1280))
        // One image per arrangement, because the stage now has three and only
        // the first was ever rendered. Both sizes above are wide and tall, so
        // the stage was photographed exclusively in the shape where nothing it
        // gets wrong can show: a 984×670 window carried the track column's
        // progress bar and the score strip outside the frame while every image
        // here was green. See `KTVStageLayout`.
        render(
            KTVStage(model: model, isRendering: true),
            basename: "ktv-short\(suffix)",
            directory: directory,
            size: CGSize(width: 1180, height: 420))
        render(
            KTVStage(model: model, isRendering: true),
            basename: "ktv-narrow\(suffix)",
            directory: directory,
            size: CGSize(width: 720, height: 900))
        // The column taken off the song. A wheel cannot be turned here, so
        // without this seed the browsed state — a centred line that is not
        // the one being sung, the fill still on the line that is, and the way
        // back — would never appear in an image.
        KTVStage.browsedLineForRendering = 2
        render(
            KTVStage(model: model, isRendering: true),
            basename: "ktv-browsing\(suffix)",
            directory: directory,
            size: CGSize(width: 1080, height: 720))
        KTVStage.browsedLineForRendering = nil
        // The count into the singing, which lasts four seconds out of a
        // four-minute song and so appears in no capture taken at a fixed
        // moment. 1:30.5 is inside the fixture's instrumental break, which
        // begins at 1:28 with the words returning at 1:33.15.
        model.renderAt(second: 90.5)
        render(
            KTVStage(model: model, isRendering: true),
            basename: "ktv-count-in\(suffix)",
            directory: directory,
            size: CGSize(width: 1080, height: 720))
        model.prepareForRendering()
        // The words at the size somebody watching from across a room asks
        // for. The window is the same 1080×720, so this image says what the
        // setting does and nothing else.
        KTVStage.lyricScaleForRendering = 1.6
        render(
            KTVStage(model: model, isRendering: true),
            basename: "ktv-large-words\(suffix)",
            directory: directory,
            size: CGSize(width: 1080, height: 720))
        KTVStage.lyricScaleForRendering = nil
        // The scoreboard, which exists only between one song and the next.
        model.renderFinishedPerformance()
        render(
            KTVStage(model: model, isRendering: true),
            basename: "ktv-performance\(suffix)",
            directory: directory,
            size: CGSize(width: 1080, height: 720))
        // And the same scoreboard in the inspector, which is where somebody
        // singing with the stage closed would see it.
        render(
            SingingPanel(model: model)
                .frame(width: 380)
                .background(Yun.Palette.background),
            basename: "singing-performance\(suffix)",
            directory: directory,
            size: CGSize(width: 380, height: 1_200))
        model.dismissPerformance()
        model.prepareForRendering()
        // Two voices, which the usual fixture song does not have. The colours
        // that tell them apart had no image to be judged in until this.
        model.renderDuet()
        render(
            KTVStage(model: model, isRendering: true),
            basename: "ktv-duet\(suffix)",
            directory: directory,
            size: CGSize(width: 1080, height: 720))
        // The same duet in the compact inspector, which is the other place
        // the same song is drawn — and, in the light appearance, the place the
        // stage's dark palette would have been illegible.
        render(
            SingingPanel(model: model)
                .frame(width: 380)
                .background(Yun.Palette.background),
            basename: "singing-duet\(suffix)",
            directory: directory,
            size: CGSize(width: 380, height: 1_100))
        // The floating words, which had never been rendered at all — the one
        // presentation with no image of it, and so the one that quietly fell
        // behind the stage on every feature the stage gained.
        render(
            DesktopLyrics(model: model),
            basename: "desktop-lyrics\(suffix)",
            directory: directory,
            size: CGSize(width: 760, height: 150))
        // And with the transport revealed, which no gate has a pointer to do.
        DesktopLyricsControls.revealForRendering = true
        render(
            DesktopLyrics(model: model),
            basename: "desktop-lyrics-controls\(suffix)",
            directory: directory,
            size: CGSize(width: 760, height: 150))
        DesktopLyricsControls.revealForRendering = false
        model.prepareForRendering()

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
                failed = true
                continue
            }
            if basename.contains("scripting"), containsSystemPlaceholder(png) {
                FileHandle.standardError.write(
                    Data(
                        "\(name) contains AppKit's prohibition placeholder"
                            .appending(" — the editor was not rendered\n").utf8))
                failed = true
            }
            print(write(png, named: name, to: directory))
        }
    }

    /// ImageRenderer substitutes a saturated yellow sheet and red prohibition
    /// mark for AppKit controls it cannot host. It is unmistakable to a person
    /// and used to be completely invisible to the gate.
    private static func containsSystemPlaceholder(_ png: Data) -> Bool {
        guard
            let yellow = PixelProbe.count(
                png,
                where: { red, green, blue in
                    red > 220 && green > 140 && green < 230 && blue < 80
                }),
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return true }
        return yellow > image.width * image.height / 20
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
            failed = true
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
        failed = true
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
