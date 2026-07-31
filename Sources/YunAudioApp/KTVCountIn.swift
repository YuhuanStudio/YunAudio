import SwiftUI
import YunAudioEngine
import YunDesign

/// The count somebody needs in order to come in on time.
///
/// Every KTV machine has this and nothing here did: the words appear at the
/// moment they are to be sung, which is exactly too late to take a breath.
/// The gaps this fills are the intro — the whole of 慢冷's complaint, where a
/// file carries no leading silence and the first line simply arrives — and the
/// return from an instrumental break, which is the harder one, because the
/// sweep across 「♪ ♪ ♪」 says a wait is happening but not how much is left.
///
/// Free arithmetic. It is read from the second the song is on, which the model
/// already publishes once a second for the timecode, so counting costs the
/// stage no clock of its own.
enum KTVCountIn {

    /// How many dots the count shows, and so how many seconds it covers.
    static let dots = 4

    /// Seconds until the next line with words in it, when the music is waiting.
    ///
    /// Nil when somebody is already singing: a count over a line being sung
    /// would be counting into the next one while this one is still going.
    static func secondsUntilWords(
        in lyrics: Lyrics, playing: Int?, position: Double, nudge: Double
    ) -> Double? {
        let waiting: Bool
        if let playing {
            guard lyrics.lines.indices.contains(playing) else { return nil }
            waiting = lyrics.lines[playing].isInterlude
        } else {
            // Before the first line: the intro, whether the file left room for
            // one or not.
            waiting = true
        }
        guard waiting else { return nil }

        let from = playing.map { $0 + 1 } ?? 0
        guard from < lyrics.lines.count,
            let next = lyrics.lines[from...].firstIndex(where: { !$0.isInterlude })
        else { return nil }
        // The music's own clock, which is the words' clock less every shift
        // applied to them — the same inversion the seek does.
        let start = lyrics.lines[next].time - lyrics.offset - nudge
        let remaining = start - position
        return remaining > 0 ? remaining : nil
    }

    /// Dots still to go, or nil when there is nothing worth counting.
    ///
    /// A count that runs the length of a thirty-second break is a distraction,
    /// not a cue; it starts when it is nearly time.
    static func remaining(seconds: Double?) -> Int? {
        guard let seconds, seconds > 0, seconds <= Double(dots) else { return nil }
        return max(1, min(dots, Int(seconds.rounded(.up))))
    }
}

/// Four dots that go out one a second until the singing starts.
///
/// Reads the second itself. Computing the count where the column is built
/// would put a one-hertz dependency on the whole stage for four seconds of
/// dots — which is how a stage that draws nothing becomes a stage that
/// rebuilds everything, once per second, for the whole of a song.
struct KTVCountInDots: View {
    @Bindable var model: RouterModel
    let size: CGFloat
    /// Whether to keep the row's height while there is nothing to count.
    ///
    /// The stage does: it holds the line being sung on the centre line, and a
    /// row that appears and disappears would move every other line twice per
    /// break. A floating window has nothing to hold still and every point of
    /// it is over somebody's work, so there it collapses.
    var reservesSpace = true

    var body: some View {
        let _ = BodyCount.tick("KTVCountInDots")
        // Sized from the line it counts into, so it keeps its proportion on a
        // full screen and on a 420-point stage alike.
        let dot = max(7, size * 0.24)
        let remaining =
            model.lyrics.flatMap {
                KTVCountIn.remaining(
                    seconds: KTVCountIn.secondsUntilWords(
                        in: $0, playing: model.lyricLine,
                        position: Double(model.songSecond), nudge: model.lyricNudge))
            } ?? 0
        return HStack(spacing: dot * 0.7) {
            ForEach(0..<KTVCountIn.dots, id: \.self) { index in
                Circle()
                    .fill(
                        index < remaining
                            ? Yun.Palette.accent.opacity(0.92)
                            : .white.opacity(0.16)
                    )
                    .frame(width: dot, height: dot)
            }
        }
        .frame(
            height: remaining > 0 || reservesSpace ? size * 0.9 : 0,
            alignment: .center
        )
        .opacity(remaining > 0 ? 1 : 0)
        .accessibilityLabel(loc("The singing starts in a moment"))
        .accessibilityIdentifier("KTVCountIn")
    }
}
