import Foundation

/// Scoring a performance against the tune it was trying to be, allowing for the
/// fact that people do not sing on the beat.
///
/// The scorer this joins compares moment to moment: the reference at 12.40 s is
/// answered by whatever was being sung at 12.40 s. That is exactly right for
/// "did the note sound at the moment it should have" and exactly wrong for
/// everything else, because nobody sings on the grid. A phrase entered a third
/// of a second late — which is what a singer does when they are *phrasing* —
/// scores near zero on every note in it, and the reading says "you were flat by
/// four semitones" when what happened was that the note before was still being
/// held.
///
/// The remedy is the one speech recognition settled on decades ago and karaoke
/// machines never adopted: align the two series first, then measure. Dynamic
/// time warping finds the correspondence that costs least — the singer's third
/// of a second becomes a shift in the path rather than an error at every point
/// — and what is left after the alignment is the part that really was out of
/// tune.
///
/// It also produces something the old measurement could not: **how late they
/// were**, and **whether they were consistently late or all over the place**.
/// Those are what a listener actually hears as rhythm, and no amount of
/// moment-to-moment pitch comparison can recover them.
///
/// ## Why it is affordable
///
/// Unbanded DTW over a five-minute song at a hundred samples a second is thirty
/// thousand squared — nine hundred million cells — and would be absurd. Two
/// things make this cheap:
///
/// 1. **A band.** Nobody is two seconds out; a singer who is has stopped
///    singing this song. Restricting the path to a corridor around the diagonal
///    turns *n²* into *n · band*.
/// 2. **A line at a time.** The caller aligns one lyric line, which is two to
///    five seconds. That is a few hundred samples against a band of a hundred:
///    tens of thousands of cells, per line, once. It also matches how anybody
///    talks about a performance — "that line was late" — rather than smearing
///    one late entry across a whole verse.
public enum KaraokeAlignment {
    static let maximumSamplesPerSide = 200_000
    static let maximumCorridorSamples = 4_096
    static let maximumAlignmentCells = 20_000_000

    /// What the alignment found.
    public struct Result: Sendable, Hashable {
        /// How much of the reference was sung close enough to count, 0…1.
        ///
        /// Measured *after* the alignment, so a phrase that was right but late
        /// scores as right. This is the number the old measurement was trying
        /// to produce.
        public let pitchAccuracy: Double

        /// Mean signed offset in seconds. Positive means late.
        ///
        /// A singer who is consistently a tenth of a second behind the file is
        /// not making a mistake — plenty of published `.lrc` and MIDI are that
        /// far out on their own — so this is reported rather than punished, and
        /// it is what the offset control could be set from.
        public let timingSeconds: Double

        /// How steady that offset was, 0…1, one being metronomic.
        ///
        /// Being consistently late is phrasing. Being late, then early, then
        /// late is the thing people mean by "off the beat", and it is the only
        /// part of timing worth scoring.
        public let steadiness: Double

        /// How much reference time the alignment covered.
        public let comparedSeconds: Double

        public static let none = Result(
            pitchAccuracy: 0, timingSeconds: 0, steadiness: 0, comparedSeconds: 0)
    }

    /// How far out of tune still counts as the right note, in semitones.
    ///
    /// Half a semitone is the boundary between two notes, so anything inside a
    /// quarter tone is unambiguously the note that was meant. This is the same
    /// threshold the moment-to-moment scorer uses, deliberately: the change
    /// here is *what* is compared, not how strict it is.
    public static let inTuneSemitones: Double = 0.5

    /// The widest the corridor gets, in seconds either side.
    ///
    /// A second is already generous — it is most of a phrase — and beyond it the
    /// alignment stops being "they were late" and starts being "they sang a
    /// different part of the song".
    public static let defaultBandSeconds: Double = 1.0

    /// Octaves are forgiven.
    ///
    /// A man singing a woman's part an octave down is singing the part. Two
    /// octaves either way covers every voice against every reference; beyond
    /// that it is a different note.
    static func semitoneDistance(_ sung: Double, _ reference: Double) -> Double {
        var best = Double.infinity
        for octave in -2...2 {
            best = min(best, abs(sung - reference + Double(12 * octave)))
        }
        return best
    }

    /// Aligns one stretch of singing against one stretch of tune, and measures
    /// what is left.
    ///
    /// - Parameters:
    ///   - sung: What came out of the singer, in time order. Silence is absent
    ///     rather than present and zero.
    ///   - reference: What should have, in time order.
    ///   - bandSeconds: The corridor either side of the diagonal.
    /// - Returns: Nil when there is nothing to compare — no reference, or
    ///   nothing sung at all, which is a silence for the caller to report as
    ///   silence rather than as being out of tune.
    public static func align(
        sung: [PitchSample], reference: [PitchSample],
        bandSeconds: Double = defaultBandSeconds
    ) -> Result? {
        guard !reference.isEmpty, !sung.isEmpty,
            reference.count <= maximumSamplesPerSide,
            sung.count <= maximumSamplesPerSide,
            bandSeconds.isFinite, bandSeconds > 0,
            admits(reference), admits(sung)
        else { return nil }

        let referenceStep = typicalStep(of: reference)
        let sungStep = typicalStep(of: sung)
        guard referenceStep.isFinite, referenceStep > 0,
            sungStep.isFinite, sungStep > 0
        else { return nil }

        // The band in samples, from the band in seconds. At least one, or the
        // corridor has no width and the path cannot move.
        let bandValue = (bandSeconds / sungStep).rounded()
        guard bandValue.isFinite, let admittedBand = Int(exactly: bandValue) else {
            return nil
        }
        let band = max(1, admittedBand)
        guard band <= maximumCorridorSamples else { return nil }
        let n = reference.count
        let m = sung.count
        let corridorWidth = min(m, band * 2 + 1)
        guard let cells = AudioProcessingContract.checkedProduct(n, corridorWidth),
            cells <= maximumAlignmentCells
        else { return nil }

        // Two rows rather than the whole matrix. The path itself is not needed
        // — only what it costs and where it goes — and one row of a few hundred
        // doubles is a cache line's worth of arithmetic instead of megabytes.
        //
        // The offsets are carried alongside so the timing can be recovered
        // without a traceback: each cell remembers the running sum and count of
        // the time differences along the best path that reached it, which is
        // all the mean and the spread need.
        var previous = [Cell](repeating: .unreachable, count: m + 1)
        var current = [Cell](repeating: .unreachable, count: m + 1)
        previous[0] = Cell(cost: 0, offsetSum: 0, offsetSquares: 0, pairs: 0, inTune: 0)

        // The band the previous row wrote into, so only that much is cleared.
        // Blanking the whole row per reference sample was two hundred and fifty
        // thousand writes for a five-second line — more than the alignment
        // itself — to reset cells the corridor never reaches.
        // Optional rather than an empty range: `0...(-1)` does not exist in
        // Swift, it traps at construction.
        var written: ClosedRange<Int>?
        for i in 1...n {
            if let written {
                for index in written where index < current.count {
                    current[index] = .unreachable
                }
            }
            let referenceSample = reference[i - 1]
            // The corridor: only the sung samples near this reference moment in
            // time are candidates at all.
            let centreValue =
                ((referenceSample.time - sung[0].time) / sungStep).rounded()
            guard centreValue.isFinite, let centre = Int(exactly: centreValue) else {
                continue
            }
            guard centre >= -band, centre <= m + band else { continue }
            let lower = max(1, centre - band + 1)
            let upper = min(m, centre + band + 1)
            guard lower <= upper else { continue }
            written = lower...upper

            if lower > 0, lower - 1 < current.count { current[lower - 1] = .unreachable }
            for j in lower...upper {
                let sungSample = sung[j - 1]
                let distance = semitoneDistance(sungSample.midi, referenceSample.midi)
                // The three ways a path can arrive: both advanced, only the
                // reference advanced (a note held through), only the singer
                // advanced (a note passed over).
                let best = Cell.best(previous[j - 1], previous[j], current[j - 1])
                guard best.pairs >= 0 else { continue }
                let offset = sungSample.time - referenceSample.time
                current[j] = Cell(
                    cost: best.cost + distance,
                    offsetSum: best.offsetSum + offset,
                    offsetSquares: best.offsetSquares + offset * offset,
                    pairs: best.pairs + 1,
                    inTune: best.inTune + (distance <= inTuneSemitones ? 1 : 0))
            }
            swap(&previous, &current)
        }

        let end = previous[m]
        guard end.pairs > 0 else { return nil }
        let pairs = Double(end.pairs)
        let mean = end.offsetSum / pairs
        // Population variance of the offsets along the path. Not a sample
        // variance: this is the whole path, not a draw from it.
        let variance = max(0, end.offsetSquares / pairs - mean * mean)
        let deviation = variance.squareRoot()
        return Result(
            pitchAccuracy: Double(end.inTune) / pairs,
            timingSeconds: mean,
            // A quarter of a second of wander is where a listener stops hearing
            // phrasing and starts hearing somebody who has lost the beat.
            steadiness: max(0, 1 - deviation / 0.25),
            comparedSeconds: Double(n) * referenceStep)
    }

    /// One cell of the two rows the alignment keeps.
    ///
    /// A struct rather than four parallel arrays because the four move
    /// together: every path that reaches a cell carries its own running totals,
    /// and splitting them would mean four bounds checks where there is one.
    struct Cell {
        var cost: Double
        var offsetSum: Double
        var offsetSquares: Double
        /// Negative marks a cell no path has reached, which is how the band's
        /// edge is expressed without a second array of flags.
        var pairs: Int
        var inTune: Int

        static let unreachable = Cell(
            cost: .infinity, offsetSum: 0, offsetSquares: 0, pairs: -1, inTune: 0)

        static func best(_ a: Cell, _ b: Cell, _ c: Cell) -> Cell {
            var winner = a
            if b.pairs >= 0, b.cost < winner.cost || winner.pairs < 0 { winner = b }
            if c.pairs >= 0, c.cost < winner.cost || winner.pairs < 0 { winner = c }
            return winner
        }
    }

    /// The typical gap between samples, which is the median rather than the
    /// mean: one long rest in the middle of a series would otherwise decide it.
    static func typicalStep(of samples: [PitchSample]) -> Double {
        guard samples.count > 1 else { return 0 }
        var gaps: [Double] = []
        gaps.reserveCapacity(samples.count - 1)
        for index in 1..<samples.count {
            let gap = samples[index].time - samples[index - 1].time
            if gap > 0 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return 0 }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    private static func admits(_ samples: [PitchSample]) -> Bool {
        var previous = -Double.infinity
        for sample in samples {
            guard sample.time.isFinite, sample.time >= 0,
                sample.time <= MidiMelody.maximumDurationSeconds,
                sample.midi.isFinite, (0...127).contains(sample.midi),
                sample.time >= previous
            else { return false }
            previous = sample.time
        }
        return true
    }
}
