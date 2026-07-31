import YunAudioEngine
import YunDesign

/// What to call a finished score.
///
/// A KTV machine says a word as well as a number, and the word is the part
/// people remember. Kept as a value so the boundaries can be argued with and
/// tested rather than being four magic numbers inside a view.
///
/// The bands are deliberately not generous. A score here is time spent within
/// half a semitone of the tune over the whole song, silence included — 70 is
/// a good performance of a hard song, not a mediocre one, and calling 70
/// 「不錯」 keeps the top of the scale meaning something.
enum KTVPerformanceGrade: String, CaseIterable, Sendable {
    case perfect
    case great
    case good
    case keepGoing

    /// What the alignment found, in one clause somebody can act on.
    ///
    /// Only after a song has ended, because that is when there is a whole
    /// performance to align. Nil when there was not enough of both series to
    /// line up, which is a silence rather than a verdict.
    ///
    /// The pitch reading goes with it because it is the point of the exercise:
    /// a score of 61 that becomes 88 once the phrasing is allowed for is a
    /// singer who was right and late, and telling them 61 and nothing else is
    /// the lie this replaces.
    @MainActor
    static func timing(for score: KaraokeScore) -> String? {
        guard let timing = score.timing, timing.alignedLines > 0 else { return nil }
        let verdict: String =
            switch timing.verdict {
            case .withTheBeat: loc("right with the beat")
            case .behind:
                String(format: loc("about %.1f s behind, steadily"), timing.secondsLate)
            case .ahead:
                String(format: loc("about %.1f s ahead, steadily"), -timing.secondsLate)
            case .scattered: loc("the timing wandered")
            }
        // Said only when the alignment changes the answer by enough to matter.
        // Repeating the same number in different words teaches nobody anything.
        guard abs(timing.alignedPercentage - score.percentage) >= 5 else { return verdict }
        return String(
            format: loc("%1$@ — allowing for that, %2$.0f%% of the notes were right"),
            verdict, timing.alignedPercentage)
    }

    static func of(_ percentage: Double) -> KTVPerformanceGrade {
        switch percentage {
        case 90...: .perfect
        case 75..<90: .great
        case 55..<75: .good
        default: .keepGoing
        }
    }

    /// The word, in the language the application is running in.
    @MainActor var title: String {
        switch self {
        case .perfect: loc("Perfect")
        case .great: loc("Great")
        case .good: loc("Good")
        case .keepGoing: loc("Keep going")
        }
    }

    /// The one thing a singer can act on, when there is one.
    ///
    /// Mean error rather than the score: consistently four tenths of a semitone
    /// flat is a different problem from missing half the lines, and the score
    /// alone cannot tell them apart.
    @MainActor static func advice(for score: KaraokeScore) -> String? {
        // Coverage first: a singer who was not singing cannot be told they were
        // flat, and the score is low for a reason they already know.
        if score.coveragePercentage < 60 {
            return loc("Much of the tune went unsung")
        }
        guard let error = score.meanErrorSemitones, abs(error) >= 0.25 else { return nil }
        return error < 0
            ? String(format: loc("Flat by about %.0f cents"), abs(error) * 100)
            : String(format: loc("Sharp by about %.0f cents"), abs(error) * 100)
    }

    /// The line that went best, ignoring lines with no tune under them.
    static func bestLine(in score: KaraokeScore) -> KaraokeScore.Line? {
        score.lines
            .filter { $0.referenceSeconds > 0 && !$0.text.isEmpty }
            .max { $0.percentage < $1.percentage }
    }
}
