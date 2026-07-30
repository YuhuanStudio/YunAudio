import CoreGraphics

/// How the KTV stage arranges itself for the window it has been given.
///
/// The stage used to be sized from the window's width alone: the artwork tile
/// was `width * 0.31`, and the words took whatever was left. Both dimensions
/// decide whether an arrangement fits, so width-only produced two failures that
/// were reported separately and are the same one — a 360-point square tile in a
/// stage 430 points tall, and a lyric column 364 points wide that wrapped every
/// Chinese line into three.
///
/// A pure value, so the rule can be asserted at sizes nobody will open the
/// window at. The thresholds below are the measured floors, not preferences.
enum KTVStageLayout: String, Sendable, CaseIterable {
    /// The tile and its metadata beside the words.
    case sideBySide
    /// The song across the top, the words beneath, both full width.
    case stacked
    /// The words, with the song on one line along the bottom.
    case wordsOnly

    /// Space the block under a tile occupies: a title of up to two lines, the
    /// artist, the progress row and the player row, with the gaps between them.
    /// Measured on the 1080×720 stage at 138 points with a one-line title; 170
    /// covers a title that takes two.
    /// Re-measured against a real cover and a real transport row: title
    /// (up to two lines), artist, the progress bar with its two times, and the
    /// three transport buttons, with the gaps between them. 170 was estimated
    /// from a stage whose placeholder tile never grew large enough to push the
    /// bottom of the column out of the window; photographed with artwork, the
    /// buttons were outside the frame and the progress bar was on its edge.
    static let metadataHeight: CGFloat = 216

    /// Below this a tile is a stamp rather than artwork, and an arrangement
    /// built around one is not worth keeping.
    static let smallestUsefulTile: CGFloat = 190

    /// Narrower than this and the lyric column comes out under 380 points —
    /// measured at 700 points of window: a 220 column, 38 of spacing and 77 of
    /// padding leave 364, which wraps a Chinese lyric line into three.
    static let narrowestSideBySide: CGFloat = 760

    /// A stacked stage spends 128 points on the strip and 24 on the gap beneath
    /// it. That is only worth doing while four lines of lyrics still fit under
    /// it — a stage line is about sixty points including its spacing. Below
    /// this, keeping the artwork costs a line and a half of the thing the stage
    /// is for, so the words take it instead: at 352 points of stage, stacking
    /// leaves three lines and the words alone leave five.
    ///
    /// The window's own minimum, 720×520, is 447 points of stage and clears
    /// this — the smallest window a user can drag still shows the artwork.
    static let shortestStacked: CGFloat = 128 + 24 + 240

    static func resolve(width: CGFloat, stageHeight: CGFloat) -> KTVStageLayout {
        let tileFits = stageHeight - metadataHeight >= smallestUsefulTile
        if tileFits, width >= narrowestSideBySide { return .sideBySide }
        if stageHeight >= shortestStacked { return .stacked }
        return .wordsOnly
    }
}
