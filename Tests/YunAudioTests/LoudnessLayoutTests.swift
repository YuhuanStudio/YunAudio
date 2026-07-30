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
