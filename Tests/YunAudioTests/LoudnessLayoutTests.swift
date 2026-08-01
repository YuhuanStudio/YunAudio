import AppKit
import SwiftUI
import Testing

@testable import YunAudioApp
@testable import YunDesign

@Suite("Loudness figures fit the minimum window")
@MainActor
struct LoudnessLayoutTests {
    private var figures: [AnyView] {
        [
            AnyView(
                LoudnessFigure(
                    title: loc("Short-term"), value: -18.6, unit: loc("LUFS"),
                    isPrimary: true)),
            AnyView(
                LoudnessFigure(
                    title: loc("Integrated"), value: -18.2, unit: loc("LUFS"))),
            AnyView(LoudnessFigure(title: loc("Peak"), value: -8.1, unit: loc("dBFS"))),
            AnyView(LoudnessPitchFigure(hertz: 147)),
        ]
    }

    private func fittingSize(_ view: AnyView) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func renderedSize<V: View>(_ view: V, width: CGFloat) throws -> CGSize {
        let renderer = ImageRenderer(
            content: view.frame(width: width, alignment: .leading))
        renderer.scale = 1
        return try #require(renderer.nsImage).size
    }

    @Test("the constrained card uses two deliberate rows")
    func compactBreaksTwoByTwo() {
        let widths = figures.map { fittingSize($0).width }
        let spacing = LoudnessFigures.horizontalSpacing
        let unwrappedWidth = widths.reduce(0, +) + spacing * CGFloat(widths.count - 1)
        let lines = YunWrap.breaks(
            widths: widths, within: LoudnessFigures.compactContentWidth,
            spacing: spacing, balanced: true)

        #expect(
            unwrappedWidth > LoudnessFigures.compactContentWidth,
            "the fixture no longer reproduces the \(unwrappedWidth)-point row in a \(LoudnessFigures.compactContentWidth)-point card"
        )
        #expect(lines == [[0, 1], [2, 3]])
    }

    @Test("every number and unit remain one token")
    func tokensFitTheirCompactCells() throws {
        let cellWidth =
            (LoudnessFigures.compactContentWidth - LoudnessFigures.horizontalSpacing) / 2

        for (index, figure) in figures.enumerated() {
            let natural = fittingSize(figure)
            let rendered = try renderedSize(figure, width: cellWidth)
            #expect(
                natural.width <= cellWidth,
                "figure \(index) needs \(natural.width) points in a \(cellWidth)-point cell"
            )
            #expect(
                rendered.height <= 48,
                "figure \(index) grew to \(rendered.height) points, so its number or unit wrapped"
            )
        }
    }

    @Test("compact is two rows and wide is one")
    func responsiveHeightIsBounded() throws {
        let view = LoudnessFigures(
            shortTerm: -18.6, integrated: -18.2, peak: -8.1, pitchHertz: 147)
        let compact = try renderedSize(view, width: LoudnessFigures.compactContentWidth)
        let wide = try renderedSize(view, width: 480)

        #expect(compact.height >= 64)
        #expect(compact.height <= 108)
        #expect(wide.height <= 48)
    }
}

/// What the readout prints, and how wide it can get.
///
/// The row is laid out from the width of the readings it expects. A silent room
/// returned −150.3 LUFS and −128.5 dBFS — correct arithmetic over a signal that
/// is all dither, and not a measurement of anything — and each was a glyph wider
/// than the layout had been measured for, so every figure overlapped the label
/// of the one beside it.
@Suite("what the loudness readout prints")
struct LoudnessReadingTests {

    @Test("a real reading is printed to a tenth")
    func realReadings() {
        #expect(LoudnessFigure.text(for: -18.6) == "-18.6")
        #expect(LoudnessFigure.text(for: -6.2) == "-6.2")
        #expect(LoudnessFigure.text(for: 0) == "0.0")
    }

    @Test("below the floor there is no reading, only a dash")
    func belowTheFloor() {
        #expect(LoudnessFigure.text(for: -150.3) == "—")
        #expect(LoudnessFigure.text(for: -128.5) == "—")
        #expect(LoudnessFigure.text(for: -70.1) == "—")
        // And the floor itself is not a reading either: at exactly −70 there is
        // nothing to tell anybody.
        #expect(LoudnessFigure.text(for: LoudnessFigure.noReadingBelow) == "—")
        #expect(LoudnessFigure.text(for: -69.9) == "-69.9")
    }

    @Test("and neither is a value that is not a number")
    func notFinite() {
        #expect(LoudnessFigure.text(for: -.infinity) == "—")
        #expect(LoudnessFigure.text(for: .nan) == "—")
    }

    @Test("nothing it can print is wider than the row was measured for")
    func widthIsBounded() {
        // Five characters plus the sign. This is the actual constraint the
        // layout was built against — 316 points of card holding four figures —
        // and it is asserted here rather than discovered in a photograph,
        // which is how it was discovered the first time.
        for value in stride(from: -69.9, through: 20.0, by: 0.1) {
            let text = LoudnessFigure.text(for: value)
            #expect(text.count <= 5, "\(value) printed as \(text)")
        }
    }
}
