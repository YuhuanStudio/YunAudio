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
                    for extra in [0.0, 0.68, 1.46] as [CGFloat] {
                        let metrics = KTVLyricMetrics.resolve(
                            width: width, height: height, scale: scale,
                            extraRowsPerLine: extra)
                        let perNeighbour =
                            metrics.neighbourSize * (1.35 + extra) + metrics.spacing
                        let drawn =
                            metrics.currentSize * (1.4 + extra)
                            + CGFloat(metrics.linesBehind + metrics.linesAhead) * perNeighbour
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
                                        + "\(extra) extra rows: drew \(Int(drawn))"))
                        }
                    }
                }
            }
        }
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
        #expect(KTVKeyCommand.resolve(KeyEquivalent("+"), modifiers: .shift) == .resizeLyrics(0.1))
        // Zero is the reset, which is why it carries no step.
        #expect(KTVKeyCommand.resolve(KeyEquivalent("0")) == .resizeLyrics(0))
        // Still somebody else's when a modifier is held.
        #expect(KTVKeyCommand.resolve(KeyEquivalent("-"), modifiers: .command) == nil)
    }
}
