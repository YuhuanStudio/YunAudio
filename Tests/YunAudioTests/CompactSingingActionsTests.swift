import Foundation
import Testing

@testable import YunAudioApp
@testable import YunDesign

@Suite("Compact singing actions fit the inspector")
struct CompactSingingActionsTests {
    /// 292-point inspector less the card's two 12-point insets.
    private let contentWidth: CGFloat = 268

    @Test("four Traditional Chinese actions form a balanced two-by-two row")
    func fourActionsBreakTwoByTwo() {
        // Measured before removing AppKit from this test: the four small-button
        // intrinsic widths are 48, 84, 60 and 84 points. Keeping the captured
        // numbers makes this a layout test without constructing a hosting view,
        // which caused LaunchServices to start a real YunAudio app from the
        // SwiftPM test process.
        let widths: [CGFloat] = [48, 84, 60, 84]
        let lines = YunWrap.breaks(
            widths: widths, within: contentWidth,
            spacing: Yun.Space.sm, balanced: true)

        #expect(widths.allSatisfy { $0 <= contentWidth })
        #expect(lines == [[0, 1], [2, 3]])
    }

    @Test("both dynamic action rows use the wrapping layout")
    func productionRowsWrap() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/SingingPanel.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "private var handRun: some View"))
        let lookup = try #require(
            source.range(
                of: "if isTitleLookupExpanded",
                range: start.upperBound..<source.endIndex))
        let actionRows = source[start.lowerBound..<lookup.lowerBound]

        #expect(actionRows.ranges(of: "YunWrap(").count == 2)
        #expect(actionRows.ranges(of: "HStack(").isEmpty)
    }
}
