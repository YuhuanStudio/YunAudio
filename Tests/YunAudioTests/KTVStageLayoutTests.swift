import CoreGraphics
import Testing

@testable import YunAudioApp

/// The stage has to read both dimensions, which is the whole complaint.
///
/// Sized from the width alone it put a 360-point square tile into a stage 430
/// points tall and a 364-point lyric column beside it at 700 points of window.
/// Those were reported as two faults and are one.
@Suite("KTV stage arrangement")
struct KTVStageLayoutTests {

    /// The stage inset the window applies before any of this: seven per cent of
    /// the height, and never less than 34 points.
    private func stageHeight(_ windowHeight: CGFloat) -> CGFloat {
        windowHeight - 2 * max(34, windowHeight * 0.07)
    }

    @Test("a window with room for both keeps them beside each other")
    func roomyWindowsAreSideBySide() {
        #expect(
            KTVStageLayout.resolve(width: 1080, stageHeight: stageHeight(720))
                == .sideBySide)
        #expect(
            KTVStageLayout.resolve(width: 984, stageHeight: stageHeight(670))
                == .sideBySide)
        #expect(
            KTVStageLayout.resolve(width: 2560, stageHeight: stageHeight(1400))
                == .sideBySide)
    }

    @Test("a narrow window lays the song down instead of squeezing the words")
    func narrowWindowsStack() {
        // The minimum the window itself allows, and the shape a user gets by
        // dragging the stage against the left of the screen.
        #expect(
            KTVStageLayout.resolve(width: 720, stageHeight: stageHeight(520))
                == .stacked)
        #expect(
            KTVStageLayout.resolve(width: 700, stageHeight: stageHeight(1000))
                == .stacked)
    }

    @Test("a short window gives the stage to the words")
    func shortWindowsDropTheTile() {
        // Wide and short: the tile and its block cannot both fit however much
        // width there is, and shrinking the tile to a stamp keeps a layout
        // built around something no longer worth looking at.
        #expect(
            KTVStageLayout.resolve(width: 1400, stageHeight: stageHeight(420))
                == .wordsOnly)
        #expect(
            KTVStageLayout.resolve(width: 1920, stageHeight: stageHeight(400))
                == .wordsOnly)
    }

    @Test("width alone never decides it")
    func heightIsAlwaysConsulted() {
        // One width, two answers, decided by the height — the property the old
        // rule did not have, and the one every arrangement fault came from.
        let width: CGFloat = 1400
        #expect(KTVStageLayout.resolve(width: width, stageHeight: 620) == .sideBySide)
        #expect(KTVStageLayout.resolve(width: width, stageHeight: 300) == .wordsOnly)

        // And one height, two answers, decided by the width. Neither dimension
        // is sufficient on its own; the old rule read only the first.
        let stage: CGFloat = 447
        #expect(KTVStageLayout.resolve(width: 1080, stageHeight: stage) == .sideBySide)
        #expect(KTVStageLayout.resolve(width: 700, stageHeight: stage) == .stacked)
    }

    @Test("the arrangement changes exactly once across each boundary")
    func boundariesAreMonotonic() {
        // Growing a window may never take an arrangement away and give it back.
        // Sweeping the height at a fixed width, the answer must move
        // wordsOnly → stacked → sideBySide and never back.
        let order: [KTVStageLayout: Int] = [.wordsOnly: 0, .stacked: 1, .sideBySide: 2]
        var previous = 0
        for height in stride(from: CGFloat(200), through: 1200, by: 4) {
            let rank = order[KTVStageLayout.resolve(width: 1400, stageHeight: height)]!
            #expect(rank >= previous, "went backwards at \(height)")
            previous = rank
        }
    }

    @Test("a tile is only kept while it is worth looking at")
    func tileFloorIsRespected() {
        // At the boundary the tile is exactly the smallest useful one, and one
        // point below it the arrangement gives up rather than shrinking it.
        let boundary = KTVStageLayout.metadataHeight + KTVStageLayout.smallestUsefulTile
        #expect(KTVStageLayout.resolve(width: 1200, stageHeight: boundary) == .sideBySide)
        #expect(KTVStageLayout.resolve(width: 1200, stageHeight: boundary - 1) != .sideBySide)
    }
}
