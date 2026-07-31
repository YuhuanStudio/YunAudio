import CoreGraphics

/// Where the lyric column is looking, which is not always where the song is.
///
/// The stage has always been locked to the line being sung: six lines, the
/// middle one filling, no way to look ahead to find the second chorus and no
/// way to look back at the verse that just went past. Being able to play from
/// a line is worth much less when the only lines on offer are the five around
/// the one already playing.
///
/// A value rather than a pile of state in the view, so that the arithmetic —
/// which is where the mistakes are — can be exercised without a window: the
/// accumulator that stops one trackpad flick crossing the whole song, the
/// clamping at both ends, and the direction, which is the sort of thing that
/// is wrong in half of all scroll handlers.
struct KTVLyricBrowse: Equatable, Sendable {

    /// The line the column is centred on while somebody is looking around,
    /// and nil when the column is following the song.
    private(set) var line: Int?

    /// Wheel travel not yet spent on a line.
    private var carried: CGFloat = 0

    init(line: Int? = nil) { self.line = line }

    /// How far the wheel must travel for one line.
    ///
    /// A trackpad reports a few points per event and a great many events, so
    /// without an accumulator a single flick crosses the whole song. This is
    /// also what makes an accidental brush do nothing at all: under this much
    /// travel the column never leaves the line being sung.
    static let pointsPerLine: CGFloat = 24

    /// How far one notch of a wheel mouse travels.
    ///
    /// A notch is a deliberate act — there is no inertia and no fine control —
    /// so it moves further than 24 points of a trackpad glide would.
    static let linesPerNotch: CGFloat = 1

    /// Whether the column has been taken off the song.
    var isBrowsing: Bool { line != nil }

    /// The line the column should be centred on.
    func centre(whilePlaying playing: Int?) -> Int? { line ?? playing }

    /// Takes the wheel and moves the column, if it has travelled far enough.
    ///
    /// The sign follows the platform: a positive `scrollingDeltaY` is the
    /// content being dragged downwards, which shows what came *before*.
    /// - Parameter precise: Whether the device reports pixel deltas.
    ///
    ///   This is the whole of a defect that made the wheel read as broken. A
    ///   trackpad and a Magic Mouse send `scrollingDeltaY` in points, and 24 of
    ///   them is a line. **A wheel mouse does not**: its delta is in *lines*,
    ///   about one to three a notch. Measured against a 24-point line that is
    ///   roughly a dozen notches to move the column once — which is
    ///   indistinguishable from nothing happening, and was reported as the
    ///   wheel "almost not working".
    ///
    ///   So a notch is converted to what a notch means. `linesPerNotch` is
    ///   deliberately generous: a wheel is a coarse instrument and somebody
    ///   using one to look ahead in a song wants to travel.
    mutating func scroll(
        by deltaY: CGFloat, playing: Int?, lineCount: Int, precise: Bool = true
    ) {
        guard lineCount > 0, deltaY.isFinite else { return }
        carried += precise ? deltaY : deltaY * Self.pointsPerLine * Self.linesPerNotch
        let steps = Int((carried / Self.pointsPerLine).rounded(.towardZero))
        guard steps != 0 else { return }
        carried -= CGFloat(steps) * Self.pointsPerLine
        let from = line ?? playing ?? 0
        line = max(0, min(lineCount - 1, from - steps))
    }

    /// Moves the column a whole line, which is what a key press means.
    ///
    /// Not the wheel's path with a contrived distance: a key press is exact,
    /// and routing it through the accumulator would make the first press of a
    /// pair do nothing.
    mutating func step(by lines: Int, playing: Int?, lineCount: Int) {
        guard lineCount > 0, lines != 0 else { return }
        carried = 0
        let from = line ?? playing ?? 0
        line = max(0, min(lineCount - 1, from + lines))
    }

    /// Puts the column back on the song.
    mutating func stop() {
        line = nil
        carried = 0
    }
}
