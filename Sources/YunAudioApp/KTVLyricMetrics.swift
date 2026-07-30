import CoreGraphics

/// Type size, line spacing, how many lines are shown, and how wide a line may
/// get — all derived from the space the words actually have.
///
/// The stage used to hard-code these: 23, 26 and 28 points, a spacing of 25,
/// and exactly six lines regardless of the window. Two things follow from that
/// and both were reported. A wide window left the words at their fixed size
/// pinned to the left edge with the right half of the stage empty, because
/// nothing grew and nothing centred. A short window drew six lines whether or
/// not six fitted, so they overflowed.
///
/// A pure value, so every one of these can be asserted at sizes nobody will
/// drag the window to.
struct KTVLyricMetrics: Equatable, Sendable {
    /// Point size of the line being sung.
    let currentSize: CGFloat
    /// Point size of the lines around it, which are quieter as well as smaller.
    let neighbourSize: CGFloat
    /// Space between one line and the next.
    let spacing: CGFloat
    /// How many lines are drawn before the current one.
    let linesBehind: Int
    /// How many are drawn after it.
    let linesAhead: Int
    /// The widest a line is allowed to be drawn.
    ///
    /// Not the width available: a line of text is read by sweeping the eye back
    /// to the start of the next one, and past about twenty-four Chinese
    /// characters that sweep is long enough to lose the place. Beyond this the
    /// block is centred in what is left rather than stretched across it.
    let measure: CGFloat

    /// Characters per line at the widest, which is what `measure` is expressed
    /// in. Chinese sets one character per em, so the measure is this many times
    /// the point size.
    static let charactersPerLine: CGFloat = 22

    /// The smallest the stage type may become before it stops being a stage.
    static let smallestCurrent: CGFloat = 19

    /// And the largest, so a wall-sized display does not draw four words.
    static let largestCurrent: CGFloat = 54

    /// - Parameters:
    ///   - width: Space the lyric column has, after the stage's own padding.
    ///   - height: Space it has vertically.
    ///   - scale: What the person watching asked for, on top of what the
    ///     window allows. A stage is read from across a room as often as from
    ///     a desk, and the two want different type; deriving from the window
    ///     alone can only ever serve one of them. Defaulted, so the size the
    ///     window implies remains the thing every other test asserts.
    ///   - extraRowsPerLine: Rows a line carries besides the words
    ///     themselves, as a fraction of the neighbour size — pronunciation is
    ///     0.68 of it and a translation 0.78. Counted because they are drawn
    ///     and therefore take height: without them the column budgeted six
    ///     lines and drew eighteen rows, and at any size where the slack ran
    ///     out the first and last were cut off by the window edge.
    static func resolve(
        width: CGFloat, height: CGFloat, scale: CGFloat = 1,
        extraRowsPerLine: CGFloat = 0
    ) -> KTVLyricMetrics {
        // Width decides the type size: the measure is the size times the
        // characters that fit on a line, so inverting that gives the size at
        // which a full line exactly fills the column. Height then caps it, so a
        // wide short stage does not set type too large to show a line above and
        // a line below.
        let fromWidth = width / charactersPerLine
        let fromHeight = height / 9
        let fitted = min(
            largestCurrent, max(smallestCurrent, min(fromWidth, fromHeight)))
        // Applied after the window's own bounds rather than inside them: the
        // caps exist to stop a window drawing four words or a ransom note, and
        // somebody who has asked for larger type has overruled that.
        let current = (fitted * (scale.isFinite && scale > 0 ? scale : 1)).rounded()
        let neighbour = (current * 0.78).rounded()
        let spacing = (current * 0.85).rounded()

        // Each neighbour costs its own height plus the gap above it. Solve for
        // how many fit in the half of the column above the centre line, and the
        // same below — the current line is anchored at the centre, so the two
        // halves are budgeted separately.
        let extra = max(0, extraRowsPerLine)
        let perNeighbour = neighbour * (1.35 + extra) + spacing
        // Less the two gaps the stage puts either side of the sung line: they
        // are drawn, so they are spent, and a budget that ignores them is a
        // budget that overflows by exactly that much.
        let half = max(0, (height - current * (1.4 + extra) - spacing * 2) / 2)
        let fit = Int((half / perNeighbour).rounded(.down))

        // At least one either side while there is room for it — and the room
        // asked for is the room a line actually takes, sub-rows included. The
        // floor used to be `height > current * 3`, which knew nothing about
        // pronunciation or translation rows and nothing about a person having
        // asked for larger type: at 1.6 with both rows on, it insisted on
        // three lines that needed 884 points in a band of 620, and the first
        // and last were cut off by the window edge.
        //
        // The line after is worth more than the line before — it is the one
        // being read — so it is the one that survives to the last.
        let lineBlock = current * (1.4 + extra)
        // The same count each way, capped differently. `fit + 1` ahead was the
        // other half of the overflow: the two halves are budgeted separately
        // and each holds `fit`, so the extra line ahead was one nobody had
        // found room for — five neighbours drawn into a budget of four. Where
        // there is genuine room `fit` exceeds both caps and the asymmetry
        // survives; where there is not, it is the first thing to go.
        // Both gaps either way: the stack keeps its three slots whether or not
        // a band has anything in it, so the two gaps are drawn even when only
        // one band is.
        let gaps = spacing * 2
        let ahead = max(min(fit, 4), height >= lineBlock + gaps + perNeighbour ? 1 : 0)
        let behind = max(min(fit, 3), height >= lineBlock + gaps + perNeighbour * 2 ? 1 : 0)

        return KTVLyricMetrics(
            currentSize: current,
            neighbourSize: neighbour,
            spacing: spacing,
            linesBehind: behind,
            linesAhead: ahead,
            // Never past the column: at a large scale the twenty-two
            // characters no longer fit across it, and a measure wider than the
            // space is a line drawn off the edge.
            measure: min(width, current * charactersPerLine).rounded())
    }

    /// Offsets to draw, in order, with the line being sung at zero.
    var offsets: [Int] { Array(-linesBehind...linesAhead) }
}
