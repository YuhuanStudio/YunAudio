import AppKit
import CoreGraphics

/// The soft edge the karaoke sweep is lit through.
///
/// The mask that reveals the bright copy of a lyric used to be a plain
/// rectangle, so the boundary between sung and unsung was a vertical line —
/// and that line lands in the middle of whichever glyph is being sung, lighting
/// its left half and not its right. Every player worth copying fades that
/// boundary instead, which is what makes the sweep read as light crossing the
/// words rather than as a wipe passing over them.
///
/// Kept apart from the view because the interesting part is the image, and an
/// image can be asserted: that the leading edge really is opaque, that the
/// trailing edge really is clear, and that the mirrored copy is the same fade
/// the other way round for a right-to-left row.
enum LyricFillFeather {

    /// One solid column, so the stretchable middle of the image has something
    /// to stretch. Anything wider is pixels that never appear on screen.
    static let solidColumns = 1

    /// How wide the fade is, for words of a given size.
    ///
    /// Proportional rather than fixed: the same eighteen points that fade a
    /// character on the compact inspector fade a third of one on a stage set
    /// for a room, and the fade wants to stay about that — a fraction of a
    /// letter, so a letter is never lit at both ends at once. Bounded at the
    /// small end because below about ten points a fade is a fringe, and at the
    /// large end because a fade wider than a character stops saying which
    /// character is being sung.
    static func width(forPointSize pointSize: CGFloat) -> CGFloat {
        min(46, max(10, (pointSize * 0.42).rounded()))
    }

    /// The part of the image `contentsCenter` may stretch.
    ///
    /// The fade is a fixed cap at the leading end; everything behind it is one
    /// column repeated. Stretching the whole image would open the fade from
    /// nothing at the first word to the width of the row at the last, which is
    /// the defect this exists to avoid rather than a softer version of it.
    static func stretchableRegion(feather: CGFloat, mirrored: Bool) -> CGRect {
        let total = CGFloat(columns(feather: feather))
        let unit = CGFloat(solidColumns) / total
        // The solid column sits behind the fade, so which end it is depends on
        // which way the row is read.
        return CGRect(
            x: mirrored ? 1 - unit : 0, y: 0, width: unit, height: 1)
    }

    static func columns(feather: CGFloat) -> Int {
        solidColumns + max(1, Int(feather.rounded()))
    }

    /// The mask itself: opaque behind the sweep, clear ahead of it.
    ///
    /// One pixel tall. The mask is stretched to the height of the row it
    /// reveals, and nothing about the fade varies vertically, so a taller image
    /// would be the same column repeated at the cost of carrying it.
    @MainActor static func image(feather: CGFloat, mirrored: Bool) -> CGImage? {
        let key = Key(columns: columns(feather: feather), mirrored: mirrored)
        if let cached = cache[key] { return cached }
        let made = draw(key)
        cache[key] = made
        return made
    }

    private struct Key: Hashable {
        let columns: Int
        let mirrored: Bool
    }

    /// Two sizes at most in a session — the stage's and the inspector's — and
    /// the image is rebuilt on every line otherwise, which is a bitmap and a
    /// gradient per line of every song.
    @MainActor private static var cache: [Key: CGImage?] = [:]

    private static func draw(_ key: Key) -> CGImage? {
        let width = key.columns
        guard width > solidColumns,
            let context = CGContext(
                data: nil, width: width, height: 1, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let opaque = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let clear = CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        let solid =
            key.mirrored
            ? CGRect(x: width - solidColumns, y: 0, width: solidColumns, height: 1)
            : CGRect(x: 0, y: 0, width: solidColumns, height: 1)
        context.setFillColor(opaque)
        context.fill(solid)
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [opaque, clear] as CFArray,
                locations: [0, 1])
        else { return nil }
        let fade =
            key.mirrored
            ? CGRect(x: 0, y: 0, width: width - solidColumns, height: 1)
            : CGRect(x: solidColumns, y: 0, width: width - solidColumns, height: 1)
        context.saveGState()
        context.clip(to: fade)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: key.mirrored ? fade.maxX : fade.minX, y: 0),
            end: CGPoint(x: key.mirrored ? fade.minX : fade.maxX, y: 0),
            options: [])
        context.restoreGState()
        return context.makeImage()
    }
}
