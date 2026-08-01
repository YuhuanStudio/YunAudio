import AppKit
import Foundation
import SwiftUI
import Testing

@testable import YunAudioApp

/// The person's say over how large the words are.
@Suite("Lyric size")
struct LyricScaleTests {

    @Test("the window's own size is what one means")
    func oneChangesNothing() {
        let plain = KTVLyricMetrics.resolve(width: 720, height: 620)
        let scaled = KTVLyricMetrics.resolve(width: 720, height: 620, scale: 1)
        #expect(plain == scaled)
    }

    @Test("larger words are larger, and fewer of them fit")
    func largerTypeShowsFewerLines() {
        let plain = KTVLyricMetrics.resolve(width: 720, height: 620)
        let large = KTVLyricMetrics.resolve(width: 720, height: 620, scale: 1.6)

        #expect(large.currentSize > plain.currentSize)
        #expect(large.neighbourSize > plain.neighbourSize)
        // The column does not grow, so something has to give: the lines around
        // the one being sung. A stage that kept six lines at 1.6 would draw
        // them over each other.
        #expect(large.linesBehind + large.linesAhead <= plain.linesBehind + plain.linesAhead)
    }

    @Test("smaller words fit more lines and stay above the floor")
    func smallerTypeShowsMore() {
        let plain = KTVLyricMetrics.resolve(width: 900, height: 800)
        let small = KTVLyricMetrics.resolve(width: 900, height: 800, scale: 0.7)
        #expect(small.currentSize < plain.currentSize)
        #expect(small.currentSize > 0)
    }

    @Test("a line is never measured wider than the column it is drawn in")
    func theMeasureStaysInsideTheColumn() {
        // The whole point of the cap. At 1.8 the twenty-two characters no
        // longer fit across a narrow stage, and a measure wider than the space
        // draws the line off the edge.
        for width in [420.0, 720.0, 1_400.0] as [CGFloat] {
            let metrics = KTVLyricMetrics.resolve(width: width, height: 620, scale: 1.8)
            #expect(metrics.measure <= width)
        }
    }

    @Test("the scale is bounded, and nonsense becomes one")
    func theScaleIsBounded() {
        #expect(RouterModel.boundedLyricScale(1) == 1)
        #expect(RouterModel.boundedLyricScale(99) == 1.8)
        #expect(RouterModel.boundedLyricScale(0.1) == 0.7)
        #expect(RouterModel.boundedLyricScale(0) == 0.7)
        #expect(RouterModel.boundedLyricScale(-3) == 0.7)
        // Not a size, and a NaN reaching a font would take the stage with it.
        #expect(RouterModel.boundedLyricScale(.nan) == 1)
        #expect(RouterModel.boundedLyricScale(.infinity) == 1)
        // Rounded to a twentieth, so eight presses land back on exactly 1.
        #expect(RouterModel.boundedLyricScale(1.234) == 1.25)
    }

    @Test("a nonsense scale cannot reach the type")
    func nonsenseNeverReachesTheFont() {
        for scale in [CGFloat.nan, 0, -4, .infinity] {
            let metrics = KTVLyricMetrics.resolve(width: 720, height: 620, scale: scale)
            #expect(metrics.currentSize.isFinite)
            #expect(metrics.currentSize > 0)
            #expect(metrics.spacing.isFinite)
        }
    }

    @Test("the row height is the font's own, and two routes agree on it")
    func rowHeightIsMeasuredRatherThanGuessed() {
        // SF Bold at 100 points on this platform: ascender 96.68, descender
        // −21.09, leading 0 — so one row is 1.178 times its point size. The
        // budget used to say 1.35, which was that number multiplied by an
        // unstated allowance for wrapping.
        #expect(abs(KTVLyricMetrics.rowHeight - 1.1777) < 0.005)
        // The same number by a different route. One measurement can be a
        // mistake repeated; two that agree are a fact about the font.
        let byLayout =
            NSLayoutManager().defaultLineHeight(
                for: NSFont.systemFont(ofSize: 100, weight: .bold)) / 100
        #expect(abs(KTVLyricMetrics.rowHeight - byLayout) < 0.01)
        // And the two halves still multiply out to roughly what the single
        // folded constant was, which is why this change moves no line on a
        // stage that was already correct.
        #expect(abs(KTVLyricMetrics.rowHeight * KTVLyricMetrics.rowsPerLine - 1.35) < 0.02)
    }

    @Test("a line's width is counted by script, not by character")
    func emsFollowTheScript() {
        // The measure is twenty-two Chinese characters, and Chinese sets one
        // to the em — which is the only reason a character count is a width at
        // all. Counting a pronunciation row the same way would make it three
        // times too wide and cost the column lines it did not need to lose.
        #expect(abs(KTVLyricMetrics.ems("可偏偏时光的橡皮") - 8) < 0.01)
        #expect(KTVLyricMetrics.ems("ke pian pian") < KTVLyricMetrics.ems("可偏偏时光的橡皮"))
        #expect(KTVLyricMetrics.ems("") == 0)
    }

    @Test("a song of short lines gets a budget for short lines")
    func theBudgetFollowsTheSong() {
        let short = KTVLyricMetrics.budget(
            for: (0..<8).map { _ in (words: "痛快的离开", romanisation: nil, translation: nil) })
        #expect(short.rowsPerLine == 1)
        #expect(short.extraRows == 0)

        // Twenty-seven characters is two rows at a twenty-two character
        // measure, every line, and no allowance averaged over two other songs
        // would have said so.
        let long = KTVLyricMetrics.budget(
            for: (0..<8).map { _ in
                (
                    words: "原来年少心动是逆行在一场雨季注定了无法走进同一个晴天里",
                    romanisation: nil, translation: nil
                )
            })
        #expect(long.rowsPerLine == 2)
    }

    @Test("the pronunciation row's own wrapping is counted")
    func extraRowsWrapToo() {
        // Nineteen Chinese characters romanise to seventy-odd Latin ones. At
        // 0.68 of the size that is past the measure, so it is two rows of 0.68
        // — 1.36 — not the 0.68 an allowance assumed.
        let budget = KTVLyricMetrics.budget(for: [
            (
                words: "原来年少心动是逆行在一场雨季注定了无法",
                romanisation:
                    "yuan lai nian shao xin dong shi ni xing zai yi chang yu ji zhu ding le wu fa",
                translation: nil
            )
        ])
        #expect(budget.extraRows > 0.68)
        #expect(abs(budget.extraRows - 1.36) < 0.01)
    }

    @Test("a row that fits is left exactly as it was")
    func balancingIsANoOpWhenItFits() {
        // Which, on real songs, is every Chinese line and every pronunciation
        // row: across 年少心動雨季 and 往事只能回味 not one line reaches the
        // twenty-two-character measure. This must cost them nothing.
        #expect(KTVLyricMetrics.balancedMeasure(ems: 8, measureInEms: 22) == 22)
        #expect(KTVLyricMetrics.balancedMeasure(ems: 22, measureInEms: 22) == 22)
    }

    @Test("a row with a word left over is split in half instead")
    func balancingEvensTheRows() {
        // The one case that does occur: an English translation of 32 ems
        // against a 28-em measure leaves 「of rain」 alone on a second row.
        let width = KTVLyricMetrics.balancedMeasure(ems: 32, measureInEms: 28)
        #expect(width == 16)
        // Still two rows, and now they are the same length.
        #expect((32 / width).rounded(.up) == 2)
    }

    @Test("balancing never narrows a row into a column")
    func balancingHasAFloor() {
        // A pathological row — one very long unbroken token — must not be
        // squeezed to a sliver in pursuit of even rows.
        #expect(KTVLyricMetrics.balancedMeasure(ems: 900, measureInEms: 22) >= 11)
        #expect(KTVLyricMetrics.balancedMeasure(ems: 1, measureInEms: 0) == 0)
    }

    @Test("balanced widths stay inside the column")
    func balancedWidthsNeverExceedTheMeasure() {
        let metrics = KTVLyricMetrics.resolve(width: 720, height: 620)
        for text in [
            "短", "So a young heart moving was walking backwards through a season of rain",
        ] {
            let width = metrics.balancedWidth(
                for: text, pointSize: metrics.neighbourSize * KTVLyricMetrics.translationScale)
            #expect(width <= metrics.measure)
            #expect(width > 0)
        }
    }

    @Test("a song with no words falls back rather than dividing by nothing")
    func anEmptySongUsesTheAllowance() {
        let budget = KTVLyricMetrics.budget(for: [])
        #expect(budget.rowsPerLine == KTVLyricMetrics.rowsPerLine)
        #expect(budget.extraRows == 0)
    }

    @Test("the column never asks for more height than it has")
    func theColumnFitsWhatItIsGiven() {
        // The invariant the overflow broke, at every combination the stage can
        // actually produce. Two rows per line is pronunciation and translation
        // both on, which is the case that failed: at 1.6 the column budgeted
        // four neighbours and drew five, and the first and last lines were cut
        // off by the window edge.
        for width in [420.0, 720.0, 1_080.0, 1_600.0] as [CGFloat] {
            for height in [300.0, 420.0, 620.0, 900.0] as [CGFloat] {
                for scale in [0.7, 1.0, 1.3, 1.8] as [CGFloat] {
                    for extra in [0.0, 0.68, 1.46, 2.14] as [CGFloat] {
                        for rows in [1.0, 1.14, 2.0] as [CGFloat] {
                            let metrics = KTVLyricMetrics.resolve(
                                width: width, height: height, scale: scale,
                                extraRowsPerLine: extra, rowsPerLine: rows)
                            let perNeighbour =
                                metrics.neighbourSize * KTVLyricMetrics.rowHeight
                                * (rows + extra) + metrics.spacing
                            // The two gaps the stage puts either side of the sung
                            // line count against the height like anything else
                            // drawn.
                            let drawn =
                                metrics.currentSize * KTVLyricMetrics.rowHeight
                                * (rows + extra) + metrics.spacing * 2
                                + CGFloat(metrics.linesBehind + metrics.linesAhead)
                                * perNeighbour
                            // A stage too short for even the line being sung is
                            // clipped on purpose — some of the words beats none —
                            // so the invariant is only claimed where a neighbour
                            // was drawn at all.
                            if metrics.linesBehind + metrics.linesAhead > 0 {
                                #expect(
                                    drawn <= height,
                                    Comment(
                                        rawValue:
                                            "\(Int(width))×\(Int(height)) at \(scale)×, "
                                            + "\(rows) rows + \(extra) extra: drew \(Int(drawn))"
                                    ))
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("a short stage at a large size keeps the line being sung whole")
    func theDegenerateCaseStillFits() {
        // The wordsOnly arrangement on a 420-point window, with the words at
        // 1.8 and both sub-rows on: the column has room for the line being
        // sung and nothing else. The invariant test above only claims the fit
        // where a neighbour was drawn, so this is the case it steps over — and
        // it is the one somebody actually reaches by pressing `=` four times
        // on a short window.
        let metrics = KTVLyricMetrics.resolve(
            width: 1_050, height: 290, scale: 1.8, extraRowsPerLine: 1.46,
            rowsPerLine: 1)
        #expect(metrics.linesBehind == 0)
        #expect(metrics.linesAhead == 0)
        let drawn =
            metrics.currentSize * KTVLyricMetrics.rowHeight * (1 + 1.46)
            + metrics.spacing * 2
        #expect(drawn <= 290)
        // And it is still a stage rather than a caption.
        #expect(metrics.currentSize >= KTVLyricMetrics.smallestCurrent)
    }

    @Test("the rows a line carries are counted against the height")
    func extraRowsCostLines() {
        let bare = KTVLyricMetrics.resolve(width: 720, height: 620)
        let withBoth = KTVLyricMetrics.resolve(width: 720, height: 620, extraRowsPerLine: 1.46)
        // Pronunciation and a translation are drawn, so they take height, so
        // fewer whole lines fit. Before this the column budgeted six lines and
        // drew eighteen rows.
        #expect(
            withBoth.linesBehind + withBoth.linesAhead
                < bare.linesBehind + bare.linesAhead)
    }

    @Test("the keys are the ones every application uses for this")
    func theKeysAreTheUsualOnes() {
        #expect(KTVKeyCommand.resolve(KeyEquivalent("-")) == .resizeLyrics(-0.1))
        #expect(KTVKeyCommand.resolve(KeyEquivalent("=")) == .resizeLyrics(0.1))
        #expect(
            KTVKeyCommand.resolve(KeyEquivalent("+"), modifiers: .shift) == .resizeLyrics(0.1))
        // Zero is the reset, which is why it carries no step.
        #expect(KTVKeyCommand.resolve(KeyEquivalent("0")) == .resizeLyrics(0))
        // Still somebody else's when a modifier is held.
        #expect(KTVKeyCommand.resolve(KeyEquivalent("-"), modifiers: .command) == nil)
    }
}
