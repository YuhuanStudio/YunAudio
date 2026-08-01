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
        // The rows moved into `KTVWordsSourcing` when the stage turned out to
        // have no way to reach any of them. Same assertion, at its new address:
        // the two action rows wrap rather than clipping, which is what stops
        // 「Sp / oti / fy」 happening in a narrow column.
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/KTVWordsSourcing.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "var body: some View"))
        let lookup = try #require(
            source.range(
                of: "if isExpanded { search }",
                range: start.upperBound..<source.endIndex))
        let actionRows = source[start.lowerBound..<lookup.lowerBound]

        #expect(actionRows.ranges(of: "YunWrap(").count == 2)
        #expect(actionRows.ranges(of: "HStack(").isEmpty)
    }

    @Test("both presentations identify a lyric row by its line, not its slot")
    func lyricRowsAreIdentifiedByLine() throws {
        // A slot identified by its offset is "the same view with different
        // words" from one line to the next, so `contentTransition(.opacity)`
        // cross-fades them in place and both lines are drawn at once for the
        // length of the transition. The stage was corrected; this panel was
        // not, and the photograph gate caught it superimposing the line above
        // the sung one on the line before that. Held here because nothing else
        // can: the overlap only exists mid-animation, so a still frame catches
        // it by luck and a test cannot catch it at all.
        let root = PreferencesCompletenessTests.sourceRootForTests
        for file in ["SingingPanel.swift", "KTVWindow.swift"] {
            let source = try String(
                contentsOfFile: root + "Sources/YunAudioApp/" + file,
                encoding: .utf8)
            #expect(
                source.contains(".id(index)"),
                Comment(rawValue: "\(file) draws lyric rows without a line identity"))
        }
    }
}
