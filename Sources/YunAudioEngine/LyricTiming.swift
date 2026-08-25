import Foundation

/// Which of the three ways the words can be out of step with the song.
///
/// The words being out of step is reported often enough to be the ordinary
/// experience, and there is a per-song offset control for it — but a control
/// that is reached for every time is treating a systematic problem as a
/// per-song one. What was missing is knowing *which* problem, because the three
/// have nothing in common but the symptom:
///
/// 1. **The words are for a different recording** — a live version, another
///    edition. Nothing about timing will fix that; the file has to be replaced.
/// 2. **They are right and uniformly early or late** — a lead-in the file does
///    not describe, or a player reporting its position with an offset. One
///    number fixes the whole song.
/// 3. **They drift apart over its length** — the two clocks run at different
///    rates. That is the serious one, and no single offset can fix it.
///
/// Nothing measured which. This does, and it needs no extra data: the song's
/// own melody line, already extracted for scoring, says where somebody is
/// singing. Where there is singing there are words. Lining those two up is the
/// whole method.
public enum LyricTiming {

    public enum Verdict: String, Sendable {
        /// Within a syllable. Nothing to fix.
        case aligned
        /// One offset fixes the whole song.
        case uniformOffset
        /// The two clocks run at different rates.
        case drifting
        /// Nothing lines up at any offset — these words are not for this
        /// recording.
        case wrongWords
        /// Not enough sung pitch, or too few lines, to say anything.
        case notEnoughToTell
    }

    public struct Diagnosis: Sendable, Equatable {
        public let verdict: Verdict
        /// How far the words should move. Positive means the words are early
        /// and should be pushed later.
        public let offsetSeconds: Double
        /// How much that offset grows across the song. Reported per minute
        /// because that is the unit somebody can feel — half a second a minute
        /// is four seconds by the last chorus.
        public let driftSecondsPerMinute: Double
        /// How well anything lines up at the best offset, 0…1. This is what
        /// separates "late" from "not these words".
        public let agreement: Double
        /// Seconds of the song that carried sung pitch, so a verdict of
        /// `notEnoughToTell` can say why.
        public let sungSeconds: Double

        public var summary: String {
            String(
                format: "%@  offset %+.2f s  drift %+.2f s/min  agreement %.2f  sung %.0f s",
                verdict.rawValue, offsetSeconds, driftSecondsPerMinute, agreement,
                sungSeconds)
        }
    }

    /// The step both timelines are sampled at. The same one the scorer uses,
    /// so the two describe the song at one resolution.
    public static let step = KaraokeScore.referenceInterval

    /// How far the search looks either way. Beyond this the words are not late,
    /// they are for something else.
    public static let searchSeconds: Double = 12

    /// Below this, no offset explains the words.
    public static let leastAgreement = 0.35
    /// Above this at the best offset, the words are the right words.
    public static let confidentAgreement = 0.5
    /// Within this the offset is not worth mentioning — about a syllable.
    public static let closeEnoughSeconds = 0.25
    /// Above this the two clocks are running at different rates rather than
    /// starting at different moments.
    public static let driftPerMinuteThreshold = 0.35

    /// Diagnoses one song's words against its own melody.
    ///
    /// - Parameters:
    ///   - lyrics: The lines as the file gives them, in order.
    ///   - melody: Sung pitch found in the recording, from `SongMelody.extract`.
    ///   - duration: The song's length, so a line's activity can be bounded.
    /// - Returns: What is wrong with the timing, or that there is not enough
    ///   sung material to say.
    public static func diagnose(
        lyrics: [Lyrics.Line], melody: [PitchSample], duration: Double
    ) -> Diagnosis {
        let sungSeconds = Double(melody.count) * step
        guard lyrics.count >= 4, sungSeconds >= 20, duration > 0 else {
            return Diagnosis(
                verdict: .notEnoughToTell, offsetSeconds: 0, driftSecondsPerMinute: 0,
                agreement: 0, sungSeconds: sungSeconds)
        }
        let wordOnsets = onsets(ofLyrics: lyrics)
        let sungOnsets = onsets(ofMelody: melody)
        guard wordOnsets.count >= 4, sungOnsets.count >= 4 else {
            return Diagnosis(
                verdict: .notEnoughToTell, offsetSeconds: 0, driftSecondsPerMinute: 0,
                agreement: 0, sungSeconds: sungSeconds)
        }

        // **A coarse pass, then a fit — because segment correlation cannot see
        // drift and a fit alone cannot find a large offset.**
        //
        // Correlating whole segments was the first attempt and it fails on the
        // one case that matters: with the clocks 1.5 per cent apart, no offset
        // lines up more than a fraction of any segment long enough to hold
        // several phrases, so a drifting song scores as badly as words from
        // another recording. Halving the song did not help — the drift inside
        // one half still exceeds the width of an onset.
        //
        // Matching each lyric onset to the nearest sung one and fitting a line
        // through the residuals has no such limit: drift is the slope, which is
        // exactly what is being asked for, rather than something the method has
        // to survive.
        let coarse = coarseOffset(words: wordOnsets, sung: sungOnsets)
        var times: [Double] = []
        var residuals: [Double] = []
        for onset in wordOnsets {
            let moved = onset + coarse
            guard
                let nearest = sungOnsets.min(by: {
                    abs($0 - moved) < abs($1 - moved)
                })
            else { continue }
            let residual = nearest - onset
            // Beyond the search there is no pairing worth having, and keeping
            // one would drag the fit toward a coincidence.
            guard abs(residual) <= searchSeconds else { continue }
            times.append(onset)
            residuals.append(residual)
        }
        guard times.count >= 4 else {
            return Diagnosis(
                verdict: .wrongWords, offsetSeconds: 0, driftSecondsPerMinute: 0,
                agreement: 0, sungSeconds: sungSeconds)
        }

        let line = robustLine(times: times, residuals: residuals)
        // How many of the words the fitted line actually explains. This is what
        // separates "late" from "not these words": a good line accounts for
        // nearly all of them, a coincidence for a handful.
        let explained = zip(times, residuals).reduce(into: 0) { total, pair in
            let predicted = line.intercept + line.slope * pair.0
            if abs(pair.1 - predicted) <= onsetWidthSeconds * 4 { total += 1 }
        }
        let agreement = Double(explained) / Double(wordOnsets.count)
        // The residual *is* the correction: it is how much later the singing
        // is than the words, so adding it to a lyric time moves that line onto
        // the note it belongs with.
        let offset = line.intercept
        let drift = line.slope * 60

        let verdict: Verdict
        if agreement < leastAgreement {
            verdict = .wrongWords
        } else if abs(drift) > driftPerMinuteThreshold {
            verdict = .drifting
        } else if abs(offset) > closeEnoughSeconds {
            verdict = .uniformOffset
        } else {
            verdict = .aligned
        }
        return Diagnosis(
            verdict: verdict, offsetSeconds: offset, driftSecondsPerMinute: drift,
            agreement: agreement, sungSeconds: sungSeconds)
    }

    /// The moments a lyric file names.
    static func onsets(ofLyrics lyrics: [Lyrics.Line]) -> [Double] {
        lyrics
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.time)
            .sorted()
    }

    /// The start of each sung phrase — pitch appearing after a real gap.
    static func onsets(ofMelody melody: [PitchSample]) -> [Double] {
        var found: [Double] = []
        var previous = -Double.infinity
        for sample in melody.sorted(by: { $0.time < $1.time }) {
            if sample.time - previous > phraseGapSeconds { found.append(sample.time) }
            previous = sample.time
        }
        return found
    }

    /// A whole-song shift, good to about an onset, to pair by.
    ///
    /// Only has to be close enough that the nearest sung onset is the right
    /// one; the fit does the rest. Drift makes this worse but not wrong,
    /// because the pairing tolerates being off by less than the gap between
    /// phrases.
    static func coarseOffset(words: [Double], sung: [Double]) -> Double {
        // **Searched outward from nothing, and ties go to the smaller shift.**
        //
        // Phrases in a song are regularly spaced, so this score is periodic:
        // shifting by exactly one phrase length pairs every line with its
        // neighbour and scores precisely as well as the true offset. Scanning
        // from one end and keeping the first best therefore returns a whole
        // phrase of error — measured here as −10 s on a song whose phrases are
        // ten seconds apart, which then produced a confident and entirely wrong
        // correction.
        //
        // Preferring the smallest shift that explains the words is the right
        // tie-break for the same reason a listener would: words that are one
        // whole phrase out are not what anybody means by "late".
        var best = 0.0
        var bestScore = -1
        var magnitude = 0.0
        while magnitude <= searchSeconds {
            for shift in magnitude == 0 ? [0.0] : [magnitude, -magnitude] {
                var hits = 0
                for onset in words {
                    let moved = onset + shift
                    if sung.contains(where: { abs($0 - moved) <= phraseGapSeconds }) {
                        hits += 1
                    }
                }
                if hits > bestScore {
                    bestScore = hits
                    best = shift
                }
            }
            magnitude += step
        }
        return best
    }

    /// Intercept and slope, fitted so a handful of bad pairings cannot carry
    /// the line away.
    ///
    /// Least squares on the points whose residual is near the median, which is
    /// enough: the outliers here are lyric lines with no singing under them —
    /// a spoken intro, a credit line — and they are a minority by construction
    /// or the words are the wrong words and the agreement says so.
    static func robustLine(
        times: [Double], residuals: [Double]
    ) -> (intercept: Double, slope: Double) {
        let median = residuals.sorted()[residuals.count / 2]
        let deviations = residuals.map { abs($0 - median) }.sorted()
        let spread = max(onsetWidthSeconds * 2, deviations[deviations.count / 2] * 3)
        var keptTimes: [Double] = []
        var keptResiduals: [Double] = []
        for (time, residual) in zip(times, residuals) where abs(residual - median) <= spread {
            keptTimes.append(time)
            keptResiduals.append(residual)
        }
        guard keptTimes.count >= 3 else { return (median, 0) }
        let count = Double(keptTimes.count)
        let meanTime = keptTimes.reduce(0, +) / count
        let meanResidual = keptResiduals.reduce(0, +) / count
        var covariance = 0.0
        var variance = 0.0
        for (time, residual) in zip(keptTimes, keptResiduals) {
            covariance += (time - meanTime) * (residual - meanResidual)
            variance += (time - meanTime) * (time - meanTime)
        }
        let slope = variance > 0 ? covariance / variance : 0
        return (meanResidual - slope * meanTime, slope)
    }

    /// How wide an onset is drawn, either side of the moment itself.
    ///
    /// A tenth of a second. Narrower and quantisation alone can make two
    /// onsets miss each other; wider and two adjacent lines merge into one
    /// event and the alignment loses the resolution it is looking for.
    public static let onsetWidthSeconds: Double = 0.1

    /// A quiet gap long enough to say the next pitch is a new phrase rather
    /// than a continuation. Shorter than the space between lines in any song,
    /// longer than a breath inside one.
    public static let phraseGapSeconds: Double = 0.5

    /// Onsets, not spans.
    ///
    /// A `.lrc` says when a line *starts* and nothing about how long it is
    /// sung for. The first version of this extended each line to the next one
    /// and capped it — which is a guess at a duration, and the guess biased
    /// every alignment by however wrong it was. Both timelines are onset trains
    /// now, and nothing is assumed that the files do not say.
    static func activity(ofLyrics lyrics: [Lyrics.Line], duration: Double) -> [Float] {
        let count = max(1, Int(duration / step))
        var signal = [Float](repeating: 0, count: count)
        for line in lyrics
        where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mark(line.time, in: &signal, count: count)
        }
        return signal
    }

    /// The start of each sung phrase — pitch appearing after a real gap.
    static func activity(ofMelody melody: [PitchSample], duration: Double) -> [Float] {
        let count = max(1, Int(duration / step))
        var signal = [Float](repeating: 0, count: count)
        var previous = -Double.infinity
        for sample in melody.sorted(by: { $0.time < $1.time }) {
            if sample.time - previous > phraseGapSeconds {
                mark(sample.time, in: &signal, count: count)
            }
            previous = sample.time
        }
        return signal
    }

    private static func mark(_ time: Double, in signal: inout [Float], count: Int) {
        let centre = Int(time / step)
        let half = max(1, Int(onsetWidthSeconds / step))
        let from = max(0, centre - half)
        let to = min(count, centre + half + 1)
        guard to > from else { return }
        for slot in from..<to { signal[slot] = 1 }
    }

    /// The shift that lines the words up with the singing, and how well.
    ///
    /// Agreement is the overlap of the two, normalised so a signal that is
    /// mostly ones cannot score well by covering everything. Without that, a
    /// lyric file with no gaps would agree with any melody at every offset.
    static func bestOffset(words: [Float], sung: [Float]) -> (offset: Double, agreement: Double)
    {
        let count = min(words.count, sung.count)
        guard count > 8 else { return (0, 0) }
        let limit = min(Int(searchSeconds / step), count / 3)
        guard limit > 0 else { return (0, 0) }
        var best = 0
        var bestScore = -1.0
        for shift in -limit...limit {
            var overlap = 0.0
            var wordTotal = 0.0
            var sungTotal = 0.0
            for slot in 0..<count {
                let moved = slot + shift
                guard moved >= 0, moved < count else { continue }
                let word = Double(words[slot])
                let voice = Double(sung[moved])
                overlap += word * voice
                wordTotal += word
                sungTotal += voice
            }
            // The geometric mean of the two coverages, which is 1 only when
            // each one's time is the other's time.
            let denominator = (wordTotal * sungTotal).squareRoot()
            let score = denominator > 0 ? overlap / denominator : 0
            if score > bestScore {
                bestScore = score
                best = shift
            }
        }
        // Positive offset means the words are early and belong later.
        return (Double(best) * step, max(0, bestScore))
    }
}
