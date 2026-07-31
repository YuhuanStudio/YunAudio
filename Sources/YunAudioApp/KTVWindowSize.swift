import Foundation

/// How large the stage opens the first time, and where.
///
/// It used to be 1080 by 720, centred — a number chosen once against whatever
/// display was in front of somebody, and then applied to every display since.
/// On the 5K panel this application is developed against that is a small tile
/// in the middle of a very large screen, which is the opposite of what a stage
/// is for.
///
/// A pure value because the arithmetic is the part that can be wrong and needs
/// no window to check: a laptop screen, an ultrawide, a portrait display, and a
/// screen barely larger than the minimum size all have to produce something
/// somebody would not immediately resize.
enum KTVWindowSize {

    /// The proportion of the usable screen the stage takes.
    ///
    /// Not the whole thing: a stage that opens edge to edge reads as having
    /// gone full screen by itself, and the one thing worse than a window too
    /// small is one somebody has to work out how to get out of.
    static let fraction: CGFloat = 0.72

    /// Height as a proportion of width. Close to the 3:2 the artwork, the words
    /// and the transport were laid out against; wider than 16:9, because the
    /// words need vertical room more than the picture needs horizontal.
    static let aspect: CGFloat = 0.66

    static let minimum = CGSize(width: 820, height: 620)

    /// The flattest the stage is allowed to be, as height over width.
    ///
    /// The saved frame on this machine was **1180 × 520** — the old minimum
    /// height, against a width nearly two and a quarter times it. That is a
    /// letterbox, and it is what the stage opened as: the artwork on the left
    /// and the words on the right both had to fit a strip, so the picture
    /// shrank and the words lost every line but three.
    ///
    /// 0.52 is a shade flatter than 2:1, which leaves room for somebody who
    /// genuinely wants a wide stage on an ultrawide while refusing the shape
    /// that makes the layout meaningless.
    static let minimumAspect: CGFloat = 0.52
    /// Beyond this the words stop reading as a column and start reading as a
    /// wall — the measure is limited inside the stage anyway, so extra width
    /// buys margin rather than content.
    static let maximumWidth: CGFloat = 1800

    /// The size to open at on a screen with this much usable room.
    ///
    /// - Parameter visible: `NSScreen.visibleFrame.size` — what is left after
    ///   the menu bar and the Dock, which is the only area a window can
    ///   actually occupy.
    static func size(forVisible visible: CGSize) -> CGSize {
        // A screen smaller than the minimum is not a reason to refuse to open;
        // it is a reason to take what there is. Somebody on a small external
        // display gets a stage that fits it rather than one hanging off the
        // bottom.
        let widthCeiling = max(minimum.width, min(maximumWidth, visible.width))
        let width = min(widthCeiling, max(minimum.width, visible.width * fraction))

        let heightCeiling = max(minimum.height, visible.height * 0.9)
        let height = min(heightCeiling, max(minimum.height, width * aspect))

        // Rounded to whole points. A half-point frame makes AppKit lay the
        // window out on a fractional grid, and every hairline inside it stops
        // landing on a pixel.
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// Centred within the usable area, in screen coordinates.
    ///
    /// Slightly above centre, the way every application that opens a document
    /// window does: an exactly centred window sits low, because the eye reads
    /// the gap under it as larger than the gap above.
    static func frame(inVisible visible: CGRect) -> CGRect {
        let wanted = size(forVisible: visible.size)
        let x = visible.minX + ((visible.width - wanted.width) / 2).rounded()
        let slack = visible.height - wanted.height
        let y = visible.minY + (slack * 0.55).rounded()
        return CGRect(x: x, y: y, width: wanted.width, height: wanted.height)
    }

    /// A size a drag is allowed to produce.
    ///
    /// Applied while resizing rather than after, so the window never passes
    /// through a shape the layout cannot use — a clamp applied afterwards makes
    /// the frame jump back under the pointer, which reads as the window
    /// fighting you.
    static func clamp(_ size: CGSize) -> CGSize {
        let width = max(minimum.width, size.width)
        let floor = max(minimum.height, width * minimumAspect)
        return CGSize(width: width, height: max(floor, size.height))
    }

    /// The key AppKit stores an autosaved frame under.
    ///
    /// Read rather than assumed, because the question being asked is "has this
    /// person ever placed this window", and `setFrameAutosaveName` answers
    /// whether the *name* was accepted, not whether a frame came back.
    static func autosaveDefaultsKey(for name: String) -> String {
        "NSWindow Frame \(name)"
    }
}
