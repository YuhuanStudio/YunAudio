import AppKit
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

    /// The height one drawn row occupies, as a multiple of its point size.
    ///
    /// Measured from the font the stage actually draws with, rather than
    /// guessed. The budget used to fold this together with an allowance for
    /// wrapping into a single 1.35, which could only ever be checked against
    /// itself — the invariant test asserting the column fits was computed from
    /// the same number it was testing. Split apart, each half can be wrong on
    /// its own and be seen to be.
    static let rowHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: 100, weight: .bold)
        return (font.ascender - font.descender + font.leading) / 100
    }()

    /// Rows a line of words takes, on average, when the song is not known.
    ///
    /// The fallback, not the answer. `budget(for:)` measures the song that is
    /// actually loaded; this is what the column uses before one is. 1.14 is
    /// what 年少心動雨季 and 往事只能回味 come to between them — one line in
    /// seven wraps.
    static let rowsPerLine: CGFloat = 1.14

    /// Width of a string in ems, near enough to decide whether it wraps.
    ///
    /// Chinese, Japanese and Korean set one character to the em, which is what
    /// makes `charactersPerLine` a measure at all. Latin does not: a
    /// pronunciation row is three or four times as many characters as the line
    /// it transcribes and would otherwise be counted as three or four times as
    /// wide. 0.5 is the average advance of lower-case Latin in this family,
    /// and a space is narrower again.
    static func ems(_ text: String) -> CGFloat {
        var total: CGFloat = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x20, 0xA0: total += 0.26
            case 0x1100...0x11FF, 0x2E80...0xA4CF, 0xA960...0xA97F,
                0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFE30...0xFE4F,
                0xFF00...0xFF60, 0xFFE0...0xFFE6:
                total += 1
            default: total += 0.5
            }
        }
        return total
    }

    /// Rows a string takes at a measure this many ems wide. Never fewer than one.
    static func rows(_ text: String, measureInEms: CGFloat) -> CGFloat {
        guard measureInEms > 0 else { return 1 }
        return max(1, (ems(text) / measureInEms).rounded(.up))
    }

    /// What one line of a particular song really costs, in point-size multiples.
    ///
    /// The last allowance in this file turned into a measurement. Which lines
    /// wrap is a fact about the words, and the words are loaded — so the column
    /// can count instead of assuming, and a song of long lines gets a budget
    /// for long lines rather than for the average of two songs somebody once
    /// looked at.
    ///
    /// The extra rows wrap too, and that is the part an allowance was always
    /// going to miss: a pronunciation row is roughly three Latin characters per
    /// Chinese one, so at 0.68 of the size it passes the measure on any line
    /// over about fourteen characters and takes two rows, not one.
    static func budget(
        for lines: [(words: String, romanisation: String?, translation: String?)]
    ) -> (rowsPerLine: CGFloat, extraRows: CGFloat) {
        guard !lines.isEmpty else { return (rowsPerLine, 0) }
        var words: CGFloat = 0
        var extras: CGFloat = 0
        for line in lines {
            words += rows(line.words, measureInEms: charactersPerLine)
            if let romanisation = line.romanisation {
                // Its own rows are its own size: two rows of 0.68 type is 1.36
                // point-size multiples, not two.
                extras += rows(
                    romanisation, measureInEms: charactersPerLine / romanisationScale)
                    * romanisationScale
            }
            if let translation = line.translation {
                extras += rows(
                    translation, measureInEms: charactersPerLine / translationScale)
                    * translationScale
            }
        }
        let count = CGFloat(lines.count)
        return (words / count, extras / count)
    }

    /// A width that splits a row evenly instead of leaving a short last one.
    ///
    /// Measured before it was built, which is why it is this small. Across
    /// 年少心動雨季 and 往事只能回味 — eighteen lines — **no Chinese line reaches
    /// the twenty-two-character measure at all**, and no pronunciation row
    /// passes its own. The reading-width cap is simply wider than song lyrics
    /// are. So the elaborate thing this was going to be — a `NSAttributedString`
    /// layout path breaking on punctuation and word boundaries — would have
    /// been built for a case that does not occur, and is not here.
    ///
    /// What does occur, once in four: an English translation of 32 ems against
    /// a 28-em measure, leaving 「of rain」 alone on a row. Giving that row a
    /// 16-em width instead splits it in half. Arithmetic, no layout engine, and
    /// a no-op for every row that already fits.
    static func balancedMeasure(ems: CGFloat, measureInEms: CGFloat) -> CGFloat {
        guard measureInEms > 0, ems > measureInEms else { return measureInEms }
        let rows = (ems / measureInEms).rounded(.up)
        // Never below half the measure: a row narrowed past that is no longer
        // being balanced, it is being turned into a column.
        return max(measureInEms / 2, (ems / rows).rounded(.up))
    }

    /// The same, in points, for a row drawn at this size inside this column.
    func balancedWidth(for text: String, pointSize: CGFloat) -> CGFloat {
        guard pointSize > 0 else { return measure }
        let inEms = Self.balancedMeasure(
            ems: Self.ems(text), measureInEms: measure / pointSize)
        return min(measure, (inEms * pointSize).rounded())
    }

    /// The sizes the stage draws the two sub-rows at, relative to a line.
    static let romanisationScale: CGFloat = 0.68
    static let translationScale: CGFloat = 0.78

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
    ///   - rowsPerLine: Rows a line of *this* song takes, from `budget(for:)`.
    ///   - reservedHeight: Height the column has already promised to something
    ///     that is not a line — the attribution above the words. Budgeted
    ///     because it is drawn: without it the band above the sung line was one
    ///     label taller than its share, and at a large word size the label went
    ///     off the top of the window.
    static func resolve(
        width: CGFloat, height fullHeight: CGFloat, scale: CGFloat = 1,
        extraRowsPerLine: CGFloat = 0, rowsPerLine: CGFloat = rowsPerLine,
        reservedHeight: CGFloat = 0
    ) -> KTVLyricMetrics {
        let height = max(0, fullHeight - max(0, reservedHeight))
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
        // Every row is `rowHeight` times its own point size, the extra rows
        // included: pronunciation at 0.68 of the neighbour size occupies 0.68
        // × `rowHeight`, not 0.68.
        let extra = max(0, extraRowsPerLine)
        let perNeighbour = neighbour * rowHeight * (max(1, rowsPerLine) + extra) + spacing
        // Less the two gaps the stage puts either side of the sung line: they
        // are drawn, so they are spent, and a budget that ignores them is a
        // budget that overflows by exactly that much.
        let half = max(0, (height - current * rowHeight * (max(1, rowsPerLine) + extra) - spacing * 2) / 2)
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
        let lineBlock = current * rowHeight * (max(1, rowsPerLine) + extra)
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
