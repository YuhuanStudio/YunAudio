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
    static func resolve(width: CGFloat, height: CGFloat) -> KTVLyricMetrics {
        // Width decides the type size: the measure is the size times the
        // characters that fit on a line, so inverting that gives the size at
        // which a full line exactly fills the column. Height then caps it, so a
        // wide short stage does not set type too large to show a line above and
        // a line below.
        let fromWidth = width / charactersPerLine
        let fromHeight = height / 9
        let current = min(
            largestCurrent, max(smallestCurrent, min(fromWidth, fromHeight)))
        let neighbour = (current * 0.78).rounded()
        let spacing = (current * 0.85).rounded()

        // Each neighbour costs its own height plus the gap above it. Solve for
        // how many fit in the half of the column above the centre line, and the
        // same below — the current line is anchored at the centre, so the two
        // halves are budgeted separately.
        let perNeighbour = neighbour * 1.35 + spacing
        let half = max(0, (height - current * 1.4) / 2)
        let fit = Int((half / perNeighbour).rounded(.down))

        // At least one either side while there is any room at all: a stage that
        // shows only the line being sung is a teleprompter, not a lyric sheet —
        // the next line is what a singer is actually reading.
        let behind = max(min(fit, 3), height > current * 3 ? 1 : 0)
        let ahead = max(min(fit + 1, 4), height > current * 3 ? 1 : 0)

        return KTVLyricMetrics(
            currentSize: current.rounded(),
            neighbourSize: neighbour,
            spacing: spacing,
            linesBehind: behind,
            linesAhead: ahead,
            measure: (current * charactersPerLine).rounded())
    }

    /// Offsets to draw, in order, with the line being sung at zero.
    var offsets: [Int] { Array(-linesBehind...linesAhead) }
}
