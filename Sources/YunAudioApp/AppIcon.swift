import AppKit

/// The application mark, loaded once.
///
/// An accessory application has no Dock icon, so the status item, the window
/// header and the About panel are the only places the mark is ever seen.
/// Loading it through a single accessor keeps that from being three slightly
/// different lookups, one of which silently returns nil.
enum YunAppIcon {
    static let image: NSImage? = {
        guard let url = AppResources.bundle.url(forResource: "Icon", withExtension: "png"),
            let loaded = NSImage(contentsOf: url)
        else { return nil }
        // Template rendering is deliberately off here: this is the colour
        // artwork, and the one place that wants a monochrome silhouette — the
        // menu bar — builds its own from the alpha channel rather than asking
        // for this one to be flattened.
        loaded.isTemplate = false
        return loaded
    }()

    /// Where the ink actually sits inside the artwork file, as a fraction of it.
    ///
    /// The mark is a portrait shape saved in a square file, and it is not
    /// centred in it: measured, the ink runs x 121…397 and y 6…509 of 512. So
    /// drawing the *file* into a square box does not put the *feather* in that
    /// box. At the size the menu bar uses that came to a mark sitting 1.4 points
    /// left of centre with its tip hard against the top edge and no margin at
    /// all — which is why the old glyph looked as though it were falling out of
    /// the top of the menu bar.
    ///
    /// Measured from the artwork rather than written down, because a constant
    /// here is a constant that goes quietly wrong the first time somebody
    /// replaces the PNG — and replacing the PNG is meant to be the easy way to
    /// change this application's mark.
    static let inkBounds: NSRect = image.map(inkBounds(of:)) ?? wholeFile

    /// What every failure path in the scan returns. Drawing the whole file is
    /// the old, wrong placement — but it is the one that still shows the mark,
    /// and a mark placed badly beats no mark at all.
    private static let wholeFile = NSRect(x: 0, y: 0, width: 1, height: 1)

    /// The alpha bounding box, normalised, with a bottom-left origin.
    ///
    /// Drawn into a bitmap of our own making rather than read out of whatever
    /// representation the file happens to carry: sample order, premultiplication
    /// and colour space all vary by encoder, and none of that is worth guessing
    /// about to find four numbers.
    private static func inkBounds(of image: NSImage) -> NSRect {
        // 256 is far finer than any use of the result — the mark is drawn at 18
        // points in the menu bar — and keeps the scan under a millisecond.
        let side = 256
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return wholeFile }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = rep.bitmapData else { return wholeFile }

        // Anything fainter than this is the artwork's own antialiased edge, and
        // including it would grow the box by a pixel of nothing.
        let threshold: UInt8 = 10
        var minX = side, maxX = -1, minRow = side, maxRow = -1
        for row in 0..<side {
            let base = row * rep.bytesPerRow
            for column in 0..<side where pixels[base + column * 4 + 3] > threshold {
                if column < minX { minX = column }
                if column > maxX { maxX = column }
                if row < minRow { minRow = row }
                if row > maxRow { maxRow = row }
            }
        }
        guard maxX >= minX, maxRow >= minRow else { return wholeFile }
        let scale = CGFloat(side)
        return NSRect(
            x: CGFloat(minX) / scale,
            // Bitmap rows run downwards and every drawing call here does not.
            y: CGFloat(side - 1 - maxRow) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxRow - minRow + 1) / scale)
    }

    /// Height over width of the ink, so a caller can size a box for it.
    static var inkAspect: CGFloat { inkBounds.width / max(inkBounds.height, 0.0001) }

    /// Draws the mark so that its *ink* lands exactly on `target`.
    ///
    /// Every other placement in this application goes through here. Drawing the
    /// file directly is the mistake this exists to stop being made a fourth
    /// time.
    static func draw(inkFitting target: NSRect, fraction: CGFloat = 1) {
        guard let image else { return }
        let bounds = inkBounds
        let width = target.width / bounds.width
        let height = target.height / bounds.height
        image.draw(
            in: NSRect(
                x: target.minX - bounds.minX * width,
                y: target.minY - bounds.minY * height,
                width: width, height: height),
            from: .zero, operation: .sourceOver, fraction: fraction)
    }

    /// The mark with the file's own padding taken off, for the places that hand
    /// it to SwiftUI.
    ///
    /// `Image(nsImage:).aspectRatio(contentMode: .fit)` fits the *file*, and the
    /// file is a square with a portrait mark sitting off-centre in it — so a
    /// header asking for eighteen points square got a mark that was neither
    /// eighteen points nor centred. Trimming once, here, means the same
    /// placement rule holds everywhere the mark is drawn.
    ///
    /// The size below is only the drawing space: AppKit re-renders through the
    /// handler at whatever scale it is asked for, so this stays sharp however
    /// large the caller's frame is.
    static let trimmed: NSImage = {
        let height: CGFloat = 512
        let size = NSSize(width: height * inkAspect, height: height)
        return NSImage(size: size, flipped: false) { rect in
            draw(inkFitting: rect)
            return true
        }
    }()

    /// A box of the given height, centred on a point, with the ink's own aspect.
    static func inkBox(height: CGFloat, centredAt centre: NSPoint) -> NSRect {
        let width = height * inkAspect
        return NSRect(
            x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
    }
}

/// The application icon: the mark on a rounded body, which is the form macOS
/// expects in the Dock, in Finder and in an About panel.
///
/// Drawn rather than stored. A `.icns` built by scaling one bitmap into ten
/// slots is soft in the large ones and mushy in the small ones; drawing each
/// slot at its own resolution keeps the body's edge and its shadow crisp at
/// every size. It also means the icon has *settings* rather than being an
/// opaque file — see `styles`.
enum YunIconBadge {

    /// One look. Adding another is one entry in `styles`, and
    /// `./App/make-icon.sh --style <name>` will build it.
    struct Style: Sendable {
        let name: String
        let top: NSColor
        let bottom: NSColor
        /// The rim that keeps a pale body from disappearing into a pale
        /// background, and a dark one from looking like a hole.
        let hairline: NSColor
        /// Whether the mark needs lifting off the body behind it.
        let liftsMark: Bool
    }

    static let styles: [Style] = [
        Style(
            name: "graphite",
            top: NSColor(srgbRed: 0.157, green: 0.153, blue: 0.176, alpha: 1),
            bottom: NSColor(srgbRed: 0.075, green: 0.075, blue: 0.090, alpha: 1),
            hairline: NSColor(white: 1, alpha: 0.14), liftsMark: false),
        Style(
            name: "paper",
            top: NSColor(white: 1.0, alpha: 1),
            bottom: NSColor(srgbRed: 0.945, green: 0.941, blue: 0.960, alpha: 1),
            hairline: NSColor(white: 0, alpha: 0.10), liftsMark: true),
        Style(
            name: "mist",
            top: NSColor(srgbRed: 0.976, green: 0.957, blue: 0.988, alpha: 1),
            bottom: NSColor(srgbRed: 0.902, green: 0.937, blue: 0.988, alpha: 1),
            hairline: NSColor(white: 0, alpha: 0.08), liftsMark: true),
    ]

    /// Named rather than positional so that reordering `styles` cannot silently
    /// change what gets built.
    static let fallbackStyle = "graphite"

    static func style(named name: String?) -> Style {
        guard let name, let match = styles.first(where: { $0.name == name })
        else { return styles.first(where: { $0.name == fallbackStyle }) ?? styles[0] }
        return match
    }

    // The proportions are Apple's own icon grid, expressed against a 1024
    // canvas: a body of 824 leaving 100 all round for the shadow. Anything
    // drawn edge to edge sits a visible step proud of every neighbour in the
    // Dock.
    private static let canvas: CGFloat = 1024
    private static let bodyInset: CGFloat = 100
    /// How much of the body's height the mark takes. The mark is a narrow
    /// portrait shape, so a fraction that would crowd a square logo still
    /// leaves this one plenty of air either side.
    private static let markHeight: CGFloat = 0.80

    /// The body outline.
    ///
    /// A macOS icon body is not a rounded rectangle: its corners flow into the
    /// sides rather than meeting them at a tangent, and the seam is visible at
    /// 512 points if you use the wrong one. A superellipse of degree five is the
    /// usual approximation, and unlike a magic corner radius it has no seam to
    /// get wrong in the first place.
    static func body(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let a = rect.width / 2, b = rect.height / 2
        let exponent = 2.0 / 5.0
        // Enough segments that the curve is smooth at 1024 and cheap enough not
        // to matter at 16.
        let steps = 512
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let cosine = cos(angle), sine = sin(angle)
            let point = NSPoint(
                x: rect.midX + a * CGFloat(copysign(pow(abs(cosine), exponent), cosine)),
                y: rect.midY + b * CGFloat(copysign(pow(abs(sine), exponent), sine)))
            if step == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }

    /// Draws the whole icon into the current context, filling a square of `size`.
    static func draw(size: CGFloat, style: Style) {
        let scale = size / canvas
        let body = NSRect(
            x: bodyInset * scale, y: bodyInset * scale,
            width: (canvas - 2 * bodyInset) * scale,
            height: (canvas - 2 * bodyInset) * scale)
        let shape = self.body(in: body)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.shadowBlurRadius = 26 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.setClip()
        NSGradient(starting: style.top, ending: style.bottom)?.draw(in: body, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        if style.liftsMark {
            // A pale mark on a pale body has no edge of its own; without this
            // the icon reads as an empty tile at 32 points.
            NSGraphicsContext.saveGraphicsState()
            let lift = NSShadow()
            lift.shadowColor = NSColor(white: 0, alpha: 0.16)
            lift.shadowBlurRadius = 18 * scale
            lift.shadowOffset = NSSize(width: 0, height: -6 * scale)
            lift.set()
            YunAppIcon.draw(
                inkFitting: YunAppIcon.inkBox(
                    height: body.height * markHeight,
                    centredAt: NSPoint(x: body.midX, y: body.midY)))
            NSGraphicsContext.restoreGraphicsState()
        } else {
            YunAppIcon.draw(
                inkFitting: YunAppIcon.inkBox(
                    height: body.height * markHeight,
                    centredAt: NSPoint(x: body.midX, y: body.midY)))
        }

        style.hairline.setStroke()
        shape.lineWidth = 2 * scale
        shape.stroke()
    }

    /// The icon at one size, as a bitmap in a colour space that does not depend
    /// on which display happened to be attached.
    static func bitmap(size: Int, style: Style) -> NSBitmapImageRep? {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: size * 4, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw(size: CGFloat(size), style: style)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The icon for use on screen, redrawn by AppKit at whatever backing scale
    /// it is asked for — which is what keeps it sharp in an About panel on a
    /// Retina display and on the projector it is mirrored to.
    static func image(size: CGFloat, style: Style) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            draw(size: size, style: style)
            return true
        }
    }

    /// The slot names `iconutil` insists on, each with the pixel size it must be.
    static let iconsetSlots: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    /// Writes a complete `.iconset` directory. Returns false if any slot could
    /// not be written — an icon build that half-succeeded must not look like one
    /// that worked.
    static func writeIconset(to directory: String, style: Style) -> Bool {
        let url = URL(fileURLWithPath: directory)
        guard
            (try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)) != nil
        else { return false }
        var wroteEverything = true
        for slot in iconsetSlots {
            guard let rep = bitmap(size: slot.pixels, style: style),
                let data = rep.representation(using: .png, properties: [:]),
                (try? data.write(to: url.appendingPathComponent("\(slot.name).png"))) != nil
            else {
                FileHandle.standardError.write(
                    Data("yunaudio: could not write \(slot.name)\n".utf8))
                wroteEverything = false
                continue
            }
        }
        return wroteEverything
    }
}
