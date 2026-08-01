import Foundation

/// How much of the tune somebody actually sang.
///
/// The whole of this is a pure function of two series and a list of lines. That
/// is deliberate: a score computed inside a view or a timer is a number nobody
/// can check, and the failure mode of a karaoke scorer is not a crash — it is
/// eighty-seven per cent for a performance that was nothing of the kind, which
/// looks exactly like a correct answer. Given the two series it can be asserted
/// on a machine with no microphone.
public struct KaraokeScore: Sendable, Equatable {

    /// One line of the lyric and how it went.
    public struct Line: Sendable, Equatable {
        /// Index into the lyric this was scored against.
        public let index: Int
        /// When the line starts, on the same clock as the samples.
        public let time: Double
        public let text: String
        /// Seconds of tune in this line. Zero means the line has no melody
        /// under it and its score means nothing.
        public let referenceSeconds: Double
        public let onPitchSeconds: Double
        public let nearPitchSeconds: Double
        /// 0...100 over this line alone.
        public let percentage: Double

        public init(
            index: Int, time: Double, text: String, referenceSeconds: Double,
            onPitchSeconds: Double, nearPitchSeconds: Double, percentage: Double
        ) {
            self.index = index
            self.time = time
            self.text = text
            self.referenceSeconds = referenceSeconds
            self.onPitchSeconds = onPitchSeconds
            self.nearPitchSeconds = nearPitchSeconds
            self.percentage = percentage
        }
    }

    /// 0...100 over everything with a tune under it.
    public let percentage: Double
    /// Seconds spent within `onPitchSemitones` of the tune.
    public let onPitchSeconds: Double
    /// Seconds spent between `onPitchSemitones` and `nearPitchSemitones` of it.
    public let nearPitchSeconds: Double
    /// Seconds the tune was sounding and nothing was sung.
    public let silentSeconds: Double
    /// Seconds of tune to sing at all — the denominator.
    public let referenceSeconds: Double
    /// Seconds the singer produced a pitch, whether or not it was wanted.
    public let sungSeconds: Double
    /// Mean signed error in semitones where the two lined up, positive meaning
    /// sharp. Nil when nothing lined up.
    ///
    /// Reported separately from the score because it is the one number a singer
    /// can act on directly: consistently −0.4 means flat, not bad.
    public let meanErrorSemitones: Double?
    public let lines: [Line]

    /// What the performance looks like once the two series have been lined up.
    ///
    /// Everything above is measured moment to moment, which is right for "did
    /// the note sound when it should have" and wrong for a singer who is
    /// phrasing. This is the same performance measured after aligning it — see
    /// `KaraokeAlignment` — and it is deliberately *beside* the old numbers
    /// rather than instead of them: the live score is incremental and cannot be
    /// realigned four times a second, so what somebody watches while singing and
    /// what they are told at the end would stop agreeing.
    ///
    /// Nil while a song is being sung. Filled in when it ends, which is when
    /// there is a whole performance to align and the time to do it.
    public var timing: Timing?

    /// The alignment's reading of one performance.
    public struct Timing: Sendable, Equatable {
        /// 0…100 on pitch, after the two were lined up.
        public let alignedPercentage: Double
        /// Mean signed offset in seconds, positive meaning late.
        public let secondsLate: Double
        /// 0…1, one being metronomic.
        public let steadiness: Double
        /// How many lines had enough of both series to align at all.
        public let alignedLines: Int

        public init(
            alignedPercentage: Double, secondsLate: Double, steadiness: Double,
            alignedLines: Int
        ) {
            self.alignedPercentage = alignedPercentage
            self.secondsLate = secondsLate
            self.steadiness = steadiness
            self.alignedLines = alignedLines
        }

        /// What to tell somebody about their timing, in one clause.
        ///
        /// Steadiness first, because it is the part that is worth acting on: a
        /// singer who is consistently late is phrasing, and one who is
        /// scattered has lost the beat. The lateness itself is only mentioned
        /// when it is large enough to be a decision rather than a rounding.
        public var verdict: TimingVerdict {
            if steadiness < 0.45 { return .scattered }
            if secondsLate > 0.15 { return .behind }
            if secondsLate < -0.15 { return .ahead }
            return .withTheBeat
        }
    }

    public enum TimingVerdict: Sendable, Equatable {
        case withTheBeat
        case behind
        case ahead
        case scattered
    }

    /// The same score with an alignment attached.
    public func withTiming(_ timing: Timing?) -> Self {
        var copy = self
        copy.timing = timing
        return copy
    }

    /// Aligns a whole performance, one lyric line at a time.
    ///
    /// A line at a time rather than the whole song, for two reasons that happen
    /// to agree: a line is two to five seconds, which is what makes the banded
    /// alignment cheap, and it is also the unit anybody talks about a
    /// performance in. Aligning a four-minute song in one pass would let one
    /// late entrance in the first verse shift everything after it.
    ///
    /// - Returns: Nil when no line had enough of both series to align, which is
    ///   a silence rather than a bad performance.
    public static func timing(
        sung: [PitchSample], reference: [PitchSample], lyrics: [Lyrics.Line]
    ) -> Timing? {
        guard !lyrics.isEmpty, !sung.isEmpty, !reference.isEmpty else { return nil }
        var accuracy = 0.0
        var late = 0.0
        var weight = 0.0
        var aligned = 0
        var onsets: [Double] = []
        for (index, line) in lyrics.enumerated() {
            let start = line.time
            let end = index + 1 < lyrics.count ? lyrics[index + 1].time : .infinity
            let sungSlice = sung.filter { $0.time >= start && $0.time < end }
            let referenceSlice = reference.filter { $0.time >= start && $0.time < end }
            guard
                let result = KaraokeAlignment.align(
                    sung: sungSlice, reference: referenceSlice),
                let firstSung = sungSlice.first, let firstReference = referenceSlice.first
            else { continue }
            // Weighted by how much tune the line had. A two-word line and a
            // whole chorus are not one opinion each.
            let share = max(0.001, result.comparedSeconds)
            accuracy += result.pitchAccuracy * share

            // Lateness comes from the **entrance**, not from the alignment.
            //
            // A test caught this and it is worth keeping the reason. Dynamic
            // time warping answers "were these the right notes" and cannot
            // answer "were you on time" for a line held on one pitch: every
            // sung sample matches every reference sample at zero cost, so the
            // cheapest path is the diagonal and the alignment honestly reports
            // no offset. It is not wrong — there is nothing in a held note to
            // tell early from late.
            //
            // The entrance always can. When the reference line starts sounding
            // and when the singer does are two facts, and their difference is
            // exactly the thing anybody means by coming in late. So each tool
            // answers what it can: the alignment the notes, the onset the beat.
            let onset = firstSung.time - firstReference.time
            late += onset * share
            onsets.append(onset)
            weight += share
            aligned += 1
        }
        guard weight > 0, aligned > 0 else { return nil }
        let meanLate = late / weight
        // Steadiness is how much the entrances agreed with each other, not how
        // close they were to nought. Somebody a quarter of a second behind on
        // every line is phrasing; somebody early, then late, then early has
        // lost the beat, and only the second is worth calling a fault.
        //
        // One line cannot disagree with itself, so a single-line performance is
        // steady by definition rather than by measurement.
        let steadiness: Double
        if onsets.count < 2 {
            steadiness = 1
        } else {
            let mean = onsets.reduce(0, +) / Double(onsets.count)
            let variance =
                onsets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(onsets.count)
            // A quarter of a second of scatter is where a listener stops
            // hearing phrasing and starts hearing somebody lost.
            steadiness = max(0, 1 - variance.squareRoot() / 0.25)
        }
        return Timing(
            alignedPercentage: max(0, min(100, accuracy / weight * 100)),
            secondsLate: meanLate,
            steadiness: min(1, steadiness),
            alignedLines: aligned)
    }

    /// - Parameters:
    ///   - percentage: 0...100 over everything with a tune under it.
    ///   - onPitchSeconds: Seconds within `onPitchSemitones` of the tune.
    ///   - nearPitchSeconds: Seconds within `nearPitchSemitones` of it.
    ///   - silentSeconds: Seconds the tune sounded and nothing was sung.
    ///   - referenceSeconds: Seconds of tune to sing at all.
    ///   - sungSeconds: Seconds the singer produced a pitch.
    ///   - meanErrorSemitones: Mean signed error, positive meaning sharp.
    ///   - lines: One entry per lyric line, when lyrics were given.
    public init(
        percentage: Double, onPitchSeconds: Double, nearPitchSeconds: Double,
        silentSeconds: Double, referenceSeconds: Double, sungSeconds: Double,
        meanErrorSemitones: Double?, lines: [Line]
    ) {
        self.percentage = percentage
        self.onPitchSeconds = onPitchSeconds
        self.nearPitchSeconds = nearPitchSeconds
        self.silentSeconds = silentSeconds
        self.referenceSeconds = referenceSeconds
        self.sungSeconds = sungSeconds
        self.meanErrorSemitones = meanErrorSemitones
        self.lines = lines
    }

    public static let none = KaraokeScore(
        percentage: 0, onPitchSeconds: 0, nearPitchSeconds: 0, silentSeconds: 0,
        referenceSeconds: 0, sungSeconds: 0, meanErrorSemitones: nil, lines: [])

    /// True when there was a tune to sing and enough of it has gone by to say
    /// anything. Below this the number swings by tens of points per note.
    public var isMeaningful: Bool { referenceSeconds >= KaraokeScore.leastSeconds }

    /// How much of the available singing time contained a detected pitch.
    ///
    /// Kept separate from accuracy so a silent performance cannot look
    /// perfectly in tune by contributing no wrong notes.
    public var coveragePercentage: Double {
        guard referenceSeconds > 0 else { return 0 }
        return max(0, min(100, (referenceSeconds - silentSeconds) / referenceSeconds * 100))
    }

    /// Pitch credit among the moments where a voice was actually detected.
    ///
    /// The headline score is this multiplied by coverage. Showing both makes a
    /// low result actionable: missing phrases and singing the wrong notes are
    /// different problems.
    public var pitchPercentage: Double {
        let attempted = max(0, referenceSeconds - silentSeconds)
        guard attempted > 0 else { return 0 }
        let credit = onPitchSeconds + nearPitchSeconds * KaraokeScore.nearPitchCredit
        return max(0, min(100, credit / attempted * 100))
    }
}

extension KaraokeScore {

    // MARK: The thresholds, and why they are these numbers

    /// Within this many semitones of the tune is on the note.
    ///
    /// A semitone is the smallest step equal temperament has, so a voice inside
    /// one is closer to the note that was written than to either of its
    /// neighbours — everybody listening hears the intended note. Anything
    /// tighter would be a tuner rather than a score: untrained singers sit
    /// thirty to fifty cents under a sustained note routinely and nobody in the
    /// room calls that wrong.
    public static let onPitchSemitones: Double = 1.0

    /// Within this many is close, and earns part of the credit.
    ///
    /// Half a step beyond the first threshold, which is where a listener stops
    /// hearing "a bit flat" and starts hearing a different note: at one and a
    /// half semitones the voice is exactly between two notes, and past it, it
    /// is nearer the wrong one.
    public static let nearPitchSemitones: Double = 1.5

    /// What being close is worth against being on it.
    ///
    /// Half. A song sung entirely a semitone and a bit out is recognisably the
    /// song and is not a good performance, and fifty per cent says both.
    public static let nearPitchCredit: Double = 0.5

    /// Scale degrees are immutable across every refresh. Keeping them once
    /// avoids rebuilding two tiny heap arrays in the fallback scorer.
    private static let majorScaleDegrees = [0, 2, 4, 5, 7, 9, 11]
    private static let minorScaleDegrees = [0, 2, 3, 5, 7, 8, 10]

    /// How far a sung sample may be from a reference moment and still be that
    /// moment's answer.
    ///
    /// The pitch tracker produces one estimate per 2048 frames, which is 43 ms
    /// at 48 kHz, so anything under that is guaranteed to leave reference
    /// moments with no sung sample to pair with even while somebody sings
    /// continuously. Sixty milliseconds covers that with a little to spare and
    /// is short enough that a note change is never mistaken for the note before
    /// it — the shortest note anybody sings is well over twice this.
    public static let pairingWindowSeconds: Double = 0.06

    /// Below this much tune a score is noise, and the interface says so instead
    /// of printing a number. One bar at a walking tempo.
    public static let leastSeconds: Double = 2.0

    /// How finely a melody is sampled to become a reference series.
    ///
    /// Fifty milliseconds. Fine enough that the shortest note anybody sings —
    /// a semiquaver at 160 bpm is 94 ms — is still several moments rather than
    /// one, and coarse enough that a five-minute song is a few thousand samples
    /// rather than a few hundred thousand.
    public static let referenceInterval: Double = 0.05

    /// The distance between two notes, folded into the octave.
    ///
    /// Octave errors are forgiven, which is what every karaoke machine ever
    /// built does and for the same reason: a man singing a melody written for a
    /// soprano sings it an octave down, and he is singing the tune. Not
    /// forgiving it would score every duet by which singer the file was written
    /// for.
    ///
    /// - Returns: Signed semitones within ±6, positive meaning the voice is
    ///   above the tune.
    public static func semitoneError(sung: Double, reference: Double) -> Double {
        let raw = sung - reference
        return raw - 12 * (raw / 12).rounded()
    }

    // MARK: The scorer

    /// Scores a performance.
    ///
    /// The measurement runs over the **reference**, not over what was sung. It
    /// has to: the question is "how much of the tune did they sing", so the
    /// denominator is the tune. Running it the other way round would let
    /// somebody score a hundred per cent by singing one note correctly and
    /// nothing else, and would let a tracker that happened to produce samples
    /// faster earn more credit for the same performance.
    ///
    /// Each reference moment is worth the time it stands for, so a series that
    /// stops for a rest and starts again does not charge the singer for the
    /// rest. That time is the typical gap between samples rather than the gap
    /// to the next one, which would make one long rest worth more than a whole
    /// verse.
    ///
    /// - Parameters:
    ///   - sung: What came out of the singer, in time order.
    ///   - reference: What should have, in time order. Rests are absent rather
    ///     than present and silent.
    ///   - lyrics: The words, in time order, for the per-line breakdown. A line
    ///     runs until the next one starts. Pass nothing for a total only.
    ///   - through: The song clock to score through. Future notes are not
    ///     silence; infinity scores the whole supplied reference.
    /// - Returns: The total and, when lyrics were given, one entry per line.
    public static func score(
        sung: [PitchSample], reference: [PitchSample], lyrics: [Lyrics.Line] = [],
        through: Double = .infinity
    ) -> KaraokeScore {
        let sung = sung.sorted { $0.time < $1.time }
        let reference = reference.sorted { $0.time < $1.time }
        return scoreChronological(
            sung: sung, sungStep: typicalStep(of: sung),
            reference: reference, referenceStep: typicalStep(of: reference),
            lyrics: lyrics, through: through)
    }

    /// Scores live series whose order and cadence are already known.
    ///
    /// `SingerPitch` and `MidiMelody` both publish chronological samples at a
    /// fixed cadence. Sorting them and finding the same median gap four times a
    /// second made a visible score walk and allocate over the whole performance
    /// forever. The general `score` entry point keeps accepting unordered data;
    /// this one records the stronger contract the live path can prove.
    public static func scoreChronological(
        sung: [PitchSample], sungStep: Double,
        reference: [PitchSample], referenceStep: Double,
        lyrics: [Lyrics.Line] = [], through: Double = .infinity
    ) -> KaraokeScore {
        guard !reference.isEmpty, referenceStep > 0 else { return .none }
        let sungCount = chronologicalCount(sung, through: through)

        // One bucket per lyric line, plus one for whatever falls before the
        // first line — an instrumental introduction that still has a tune in it
        // counts towards the total even though no line covers it.
        var starts: [Double] = []
        starts.reserveCapacity(lyrics.count + 1)
        if lyrics.first.map({ $0.time > 0 }) ?? true { starts.append(-.infinity) }
        for line in lyrics { starts.append(line.time) }
        var onPerBucket = [Double](repeating: 0, count: starts.count)
        var nearPerBucket = [Double](repeating: 0, count: starts.count)
        var totalPerBucket = [Double](repeating: 0, count: starts.count)

        var onSeconds = 0.0
        var nearSeconds = 0.0
        var silentSeconds = 0.0
        // Accumulated rather than reconstructed from the three categories.
        // Adding them up is the obvious thing and it is wrong: a moment that
        // was sung and sung badly is in none of them, so a performance that was
        // half right and half a tone out came back as a hundred per cent.
        var totalSeconds = 0.0
        var errorTotal = 0.0
        var errorCount = 0

        // Both series are in time order, so the search for the nearest sung
        // sample walks forward once rather than starting over per reference
        // moment. At a tracker frame apiece over a five-minute song that is
        // seven thousand against fifty million.
        var cursor = 0
        var bucket = 0
        // Every reference moment is worth the same: one typical step. Weighting
        // by the gap to the next would make the last moment before a rest worth
        // the whole rest, so a song with a long instrumental in it would be
        // decided by whether the singer held the note into the gap.
        let weight = referenceStep
        for moment in reference {
            // Notes after the player has reached this point have not been
            // missed. Counting the complete MIDI file here made a perfect first
            // verse of a four-minute song read about four per cent.
            if moment.time > through { break }
            while bucket + 1 < starts.count, starts[bucket + 1] <= moment.time { bucket += 1 }
            totalPerBucket[bucket] += weight
            totalSeconds += weight

            while cursor + 1 < sungCount,
                abs(sung[cursor + 1].time - moment.time) <= abs(sung[cursor].time - moment.time)
            {
                cursor += 1
            }
            guard cursor < sungCount,
                abs(sung[cursor].time - moment.time) <= pairingWindowSeconds
            else {
                silentSeconds += weight
                continue
            }

            let error = semitoneError(sung: sung[cursor].midi, reference: moment.midi)
            errorTotal += error
            errorCount += 1
            let distance = abs(error)
            if distance <= onPitchSemitones {
                onSeconds += weight
                onPerBucket[bucket] += weight
            } else if distance <= nearPitchSemitones {
                nearSeconds += weight
                nearPerBucket[bucket] += weight
            }
        }

        let credit = onSeconds + nearSeconds * nearPitchCredit
        let percentage =
            totalSeconds > 0 ? max(0, min(100, credit / totalSeconds * 100)) : 0

        // The buckets are reported against the lines that produced them. The
        // leading bucket, when there is one, belongs to no line and is in the
        // total only.
        let leading = lyrics.isEmpty || starts.count > lyrics.count ? 1 : 0
        var lines: [Line] = []
        lines.reserveCapacity(lyrics.count)
        for index in lyrics.indices {
            let slot = index + leading
            guard slot < totalPerBucket.count else { break }
            let lineTotal = totalPerBucket[slot]
            let lineCredit = onPerBucket[slot] + nearPerBucket[slot] * nearPitchCredit
            lines.append(
                Line(
                    index: index, time: lyrics[index].time, text: lyrics[index].text,
                    referenceSeconds: lineTotal, onPitchSeconds: onPerBucket[slot],
                    nearPitchSeconds: nearPerBucket[slot],
                    percentage: lineTotal > 0
                        ? max(0, min(100, lineCredit / lineTotal * 100)) : 0))
        }

        return KaraokeScore(
            percentage: percentage, onPitchSeconds: onSeconds, nearPitchSeconds: nearSeconds,
            silentSeconds: silentSeconds, referenceSeconds: totalSeconds,
            sungSeconds: Double(sungCount) * sungStep,
            meanErrorSemitones: errorCount > 0 ? errorTotal / Double(errorCount) : nil,
            lines: lines)
    }

    /// Scores intonation in the detected key when no melody file exists.
    ///
    /// This is intentionally not called a melody score: it cannot know whether
    /// the singer chose the written note, only whether the note was in tune
    /// with this song and whether the timed phrases were actually sung. That
    /// is still a useful, reproducible answer for streaming tracks whose lyric
    /// databases carry words and time but no score.
    ///
    /// - Parameters:
    ///   - sung: Pitched samples from one microphone.
    ///   - key: The key measured from the backing track.
    ///   - lyrics: Timed phrases used to count silence.
    ///   - through: Where the performance has reached on the song clock.
    /// - Returns: The intonation and phrase-timing score.
    public static func keyScore(
        sung: [PitchSample], key: KeyDetector.Key, lyrics: [Lyrics.Line],
        through: Double
    ) -> KaraokeScore {
        let sung = sung.sorted { $0.time < $1.time }
        return keyScoreChronological(
            sung: sung, sungStep: typicalStep(of: sung), key: key,
            lyrics: lyrics, through: through)
    }

    /// The key-and-timing score for the live pitch tracker's ordered series.
    public static func keyScoreChronological(
        sung: [PitchSample], sungStep: Double, key: KeyDetector.Key,
        lyrics: [Lyrics.Line], through: Double
    ) -> KaraokeScore {
        guard sungStep > 0 else { return .none }

        let degrees = key.isMinor ? minorScaleDegrees : majorScaleDegrees
        let onThreshold = 0.5
        let nearThreshold = 0.9

        var onSeconds = 0.0
        var nearSeconds = 0.0
        var errorTotal = 0.0
        var onPerLine = [Double](repeating: 0, count: lyrics.count)
        var nearPerLine = [Double](repeating: 0, count: lyrics.count)
        var lineCursor = 0
        var sungCount = 0
        for sample in sung {
            // The microphone tap keeps producing while a player is paused.
            // Those frames are useful to the live tuner but are not part of the
            // song and must not earn credit or inflate `sungSeconds`.
            if sample.time > through { break }
            // Both lists are chronological. A binary search per sample was
            // about 380,000 comparisons in a half-hour session; one cursor
            // crosses each lyric boundary once.
            while lineCursor + 1 < lyrics.count,
                lyrics[lineCursor + 1].time <= sample.time
            {
                lineCursor += 1
            }
            let line: Int?
            if lyrics.indices.contains(lineCursor),
                sample.time >= lyrics[lineCursor].time
            {
                let end =
                    min(
                        lineCursor + 1 < lyrics.count
                            ? lyrics[lineCursor + 1].time
                            : lyrics[lineCursor].time + 4,
                        lyrics[lineCursor].time + 4)
                line = sample.time < end ? lineCursor : nil
            } else {
                line = nil
            }
            // With timed words, an instrumental section is neither something
            // to sing nor a chance to earn points by humming over it.
            guard lyrics.isEmpty || line != nil else { continue }
            sungCount += 1
            // An Array.map here allocated twice per pitched frame: 84,422
            // allocations to refresh one thirty-minute score. Seven scalar
            // comparisons are the entire operation.
            var error = Double.infinity
            for degree in degrees {
                let pitchClass = Double((key.pitchClass + degree) % 12)
                let candidate = semitoneError(
                    sung: sample.midi, reference: pitchClass)
                if abs(candidate) < abs(error) { error = candidate }
            }
            errorTotal += error
            if abs(error) <= onThreshold {
                onSeconds += sungStep
                if let line { onPerLine[line] += sungStep }
            } else if abs(error) <= nearThreshold {
                nearSeconds += sungStep
                if let line { nearPerLine[line] += sungStep }
            }
        }

        let sungSeconds = Double(sungCount) * sungStep
        let expectedSeconds =
            lyrics.isEmpty
            ? sungSeconds
            : lyrics.indices.reduce(0) { total, index in
                let start = lyrics[index].time
                let next = index + 1 < lyrics.count ? lyrics[index + 1].time : start + 4
                let end = min(through, next, start + 4)
                return total + max(0, end - start)
            }
        let denominator = max(sungSeconds, expectedSeconds)
        let credit = onSeconds + nearSeconds * nearPitchCredit
        let percentage =
            denominator > 0 ? max(0, min(100, credit / denominator * 100)) : 0

        var lineScores: [Line] = []
        lineScores.reserveCapacity(lyrics.count)
        for index in lyrics.indices {
            let start = lyrics[index].time
            let end =
                min(
                    through,
                    index + 1 < lyrics.count ? lyrics[index + 1].time : start + 4,
                    start + 4)
            let total = max(0, end - start)
            let lineCredit = onPerLine[index] + nearPerLine[index] * nearPitchCredit
            lineScores.append(
                Line(
                    index: index, time: start, text: lyrics[index].text,
                    referenceSeconds: total, onPitchSeconds: onPerLine[index],
                    nearPitchSeconds: nearPerLine[index],
                    percentage: total > 0
                        ? max(0, min(100, lineCredit / total * 100)) : 0))
        }

        return KaraokeScore(
            percentage: percentage, onPitchSeconds: onSeconds,
            nearPitchSeconds: nearSeconds,
            silentSeconds: max(0, denominator - sungSeconds),
            referenceSeconds: denominator, sungSeconds: sungSeconds,
            meanErrorSemitones:
                sungCount > 0 ? errorTotal / Double(sungCount) : nil,
            lines: lineScores)
    }

    /// Incremental form of the live key score.
    ///
    /// The ordinary entry point remains a pure one-shot function. The running
    /// panel asks for the same cumulative answer four times a second, however,
    /// and rescanning every pitch since the song began makes its cost grow with
    /// the session. This state consumes each sample exactly once and rebuilds
    /// only the fixed-size line summary.
    public struct IncrementalKeyScorer: Sendable {
        private let sungStep: Double
        private let key: KeyDetector.Key
        private let lyrics: [Lyrics.Line]
        private let degrees: [Int]

        private var processedAbsoluteIndex = 0
        private var historyGeneration: Int?
        private var lastThrough: Double = -.infinity
        private var lineCursor = 0
        private var onSeconds = 0.0
        private var nearSeconds = 0.0
        private var errorTotal = 0.0
        private var sungCount = 0
        private var onPerLine: [Double]
        private var nearPerLine: [Double]

        /// True only if a caller left the scorer idle long enough for its
        /// bounded source history to overtake it.
        public private(set) var missedHistory = false

        public init(
            sungStep: Double,
            key: KeyDetector.Key,
            lyrics: [Lyrics.Line]
        ) {
            self.sungStep = sungStep
            self.key = key
            self.lyrics = lyrics
            degrees = key.isMinor ? minorScaleDegrees : majorScaleDegrees
            onPerLine = [Double](repeating: 0, count: lyrics.count)
            nearPerLine = [Double](repeating: 0, count: lyrics.count)
        }

        /// Folds in the retained suffix and returns the exact cumulative score.
        ///
        /// `historyStartIndex` is the absolute index of `sung[0]`. It lets a
        /// `SingerPitch` compact already-consumed samples without making this
        /// state believe the shortened array is a new performance.
        public mutating func update(
            sung: [PitchSample],
            historyStartIndex: Int = 0,
            historyGeneration: Int? = nil,
            through: Double
        ) -> KaraokeScore {
            let historyEndIndex = historyStartIndex + sung.count
            if self.historyGeneration != historyGeneration
                || through < lastThrough || processedAbsoluteIndex > historyEndIndex
            {
                reset(startingAt: historyStartIndex)
                self.historyGeneration = historyGeneration
            }
            if processedAbsoluteIndex < historyStartIndex {
                missedHistory = true
                reset(startingAt: historyStartIndex)
            }

            var absolute = processedAbsoluteIndex
            while absolute < historyEndIndex {
                let sample = sung[absolute - historyStartIndex]
                guard sample.time <= through else { break }
                processedAbsoluteIndex = absolute + 1
                absolute += 1

                while lineCursor + 1 < lyrics.count,
                    lyrics[lineCursor + 1].time <= sample.time
                {
                    lineCursor += 1
                }
                let line: Int?
                if lyrics.indices.contains(lineCursor),
                    sample.time >= lyrics[lineCursor].time
                {
                    let end =
                        min(
                            lineCursor + 1 < lyrics.count
                                ? lyrics[lineCursor + 1].time
                                : lyrics[lineCursor].time + 4,
                            lyrics[lineCursor].time + 4)
                    line = sample.time < end ? lineCursor : nil
                } else {
                    line = nil
                }
                guard lyrics.isEmpty || line != nil else { continue }
                sungCount += 1

                var error = Double.infinity
                for degree in degrees {
                    let pitchClass = Double((key.pitchClass + degree) % 12)
                    let candidate = KaraokeScore.semitoneError(
                        sung: sample.midi,
                        reference: pitchClass)
                    if abs(candidate) < abs(error) { error = candidate }
                }
                errorTotal += error
                if abs(error) <= 0.5 {
                    onSeconds += sungStep
                    if let line { onPerLine[line] += sungStep }
                } else if abs(error) <= 0.9 {
                    nearSeconds += sungStep
                    if let line { nearPerLine[line] += sungStep }
                }
            }
            lastThrough = through
            return reading(through: through)
        }

        private mutating func reset(startingAt index: Int) {
            processedAbsoluteIndex = index
            lastThrough = -.infinity
            lineCursor = 0
            onSeconds = 0
            nearSeconds = 0
            errorTotal = 0
            sungCount = 0
            onPerLine = [Double](repeating: 0, count: lyrics.count)
            nearPerLine = [Double](repeating: 0, count: lyrics.count)
        }

        private func reading(through: Double) -> KaraokeScore {
            let sungSeconds = Double(sungCount) * sungStep
            let expectedSeconds =
                lyrics.isEmpty
                ? sungSeconds
                : lyrics.indices.reduce(0) { total, index in
                    let start = lyrics[index].time
                    let next =
                        index + 1 < lyrics.count ? lyrics[index + 1].time : start + 4
                    let end = min(through, next, start + 4)
                    return total + max(0, end - start)
                }
            let denominator = max(sungSeconds, expectedSeconds)
            let credit = onSeconds + nearSeconds * KaraokeScore.nearPitchCredit
            let percentage =
                denominator > 0
                ? max(0, min(100, credit / denominator * 100))
                : 0

            var lineScores: [Line] = []
            lineScores.reserveCapacity(lyrics.count)
            for index in lyrics.indices {
                let start = lyrics[index].time
                let end =
                    min(
                        through,
                        index + 1 < lyrics.count
                            ? lyrics[index + 1].time
                            : start + 4,
                        start + 4)
                let total = max(0, end - start)
                let lineCredit =
                    onPerLine[index] + nearPerLine[index] * KaraokeScore.nearPitchCredit
                lineScores.append(
                    Line(
                        index: index,
                        time: start,
                        text: lyrics[index].text,
                        referenceSeconds: total,
                        onPitchSeconds: onPerLine[index],
                        nearPitchSeconds: nearPerLine[index],
                        percentage:
                            total > 0
                            ? max(0, min(100, lineCredit / total * 100))
                            : 0))
            }

            return KaraokeScore(
                percentage: percentage,
                onPitchSeconds: onSeconds,
                nearPitchSeconds: nearSeconds,
                silentSeconds: max(0, denominator - sungSeconds),
                referenceSeconds: denominator,
                sungSeconds: sungSeconds,
                meanErrorSemitones:
                    sungCount > 0 ? errorTotal / Double(sungCount) : nil,
                lines: lineScores)
        }
    }

    /// Incremental score against a fixed MIDI or other complete reference.
    ///
    /// Each new sung pitch only competes with reference moments inside the
    /// sixty-millisecond pairing window. Four Fenwick trees keep prefix totals,
    /// so asking for the cumulative score at the current playhead is logarithmic
    /// rather than another walk from the start of the song.
    public struct IncrementalExactScorer: Sendable {
        private struct Fenwick: Sendable {
            private var tree: [Double]

            init(count: Int) {
                tree = [Double](repeating: 0, count: count + 1)
            }

            mutating func add(_ value: Double, at index: Int) {
                var cursor = index + 1
                while cursor < tree.count {
                    tree[cursor] += value
                    cursor += cursor & -cursor
                }
            }

            func prefix(_ count: Int) -> Double {
                var cursor = min(max(0, count), tree.count - 1)
                var total = 0.0
                while cursor > 0 {
                    total += tree[cursor]
                    cursor -= cursor & -cursor
                }
                return total
            }

            func range(_ bounds: Range<Int>) -> Double {
                prefix(bounds.upperBound) - prefix(bounds.lowerBound)
            }
        }

        private let sungStep: Double
        private let reference: [PitchSample]
        private let referenceStep: Double
        private let lyrics: [Lyrics.Line]
        private let lineReferenceRanges: [Range<Int>]

        private var processedAbsoluteIndex = 0
        private var historyGeneration: Int?
        private var lastThrough: Double = -.infinity
        private var sungCount = 0
        private var bestDistance: [Double]
        private var bestError: [Double]
        private var matched: [Bool]
        private var on: Fenwick
        private var near: Fenwick
        private var matchCount: Fenwick
        private var error: Fenwick

        public private(set) var missedHistory = false

        public init(
            sungStep: Double,
            reference: [PitchSample],
            referenceStep: Double,
            lyrics: [Lyrics.Line]
        ) {
            self.sungStep = sungStep
            self.reference = reference
            self.referenceStep = referenceStep
            self.lyrics = lyrics
            bestDistance = [Double](repeating: .infinity, count: reference.count)
            bestError = [Double](repeating: 0, count: reference.count)
            matched = [Bool](repeating: false, count: reference.count)
            on = Fenwick(count: reference.count)
            near = Fenwick(count: reference.count)
            matchCount = Fenwick(count: reference.count)
            error = Fenwick(count: reference.count)

            lineReferenceRanges = lyrics.indices.map { index in
                let start = Self.firstReferenceIndex(
                    atOrAfter: lyrics[index].time,
                    in: reference)
                let end =
                    index + 1 < lyrics.count
                    ? Self.firstReferenceIndex(
                        atOrAfter: lyrics[index + 1].time,
                        in: reference)
                    : reference.count
                return start..<max(start, end)
            }
        }

        public mutating func update(
            sung: [PitchSample],
            historyStartIndex: Int = 0,
            historyGeneration: Int? = nil,
            through: Double
        ) -> KaraokeScore {
            guard !reference.isEmpty, referenceStep > 0 else { return .none }
            let historyEndIndex = historyStartIndex + sung.count
            if self.historyGeneration != historyGeneration
                || through < lastThrough || processedAbsoluteIndex > historyEndIndex
            {
                reset(startingAt: historyStartIndex)
                self.historyGeneration = historyGeneration
            }
            if processedAbsoluteIndex < historyStartIndex {
                missedHistory = true
                reset(startingAt: historyStartIndex)
            }

            var absolute = processedAbsoluteIndex
            while absolute < historyEndIndex {
                let sample = sung[absolute - historyStartIndex]
                guard sample.time <= through else { break }
                processedAbsoluteIndex = absolute + 1
                absolute += 1
                sungCount += 1
                updateMatches(with: sample)
            }
            lastThrough = through
            return reading(through: through)
        }

        private mutating func updateMatches(with sample: PitchSample) {
            let lower = Self.firstReferenceIndex(
                atOrAfter: sample.time - KaraokeScore.pairingWindowSeconds,
                in: reference)
            let upper = Self.firstReferenceIndex(
                atOrAfter: sample.time + KaraokeScore.pairingWindowSeconds.nextUp,
                in: reference)
            guard lower < upper else { return }

            for index in lower..<upper {
                let distance = abs(reference[index].time - sample.time)
                // The one-shot cursor chooses the later sung sample on a tie.
                guard distance <= bestDistance[index] else { continue }
                let newError = KaraokeScore.semitoneError(
                    sung: sample.midi,
                    reference: reference[index].midi)
                if matched[index] {
                    removeClassification(at: index, error: bestError[index])
                } else {
                    matched[index] = true
                    matchCount.add(1, at: index)
                }
                bestDistance[index] = distance
                bestError[index] = newError
                addClassification(at: index, error: newError)
            }
        }

        private mutating func addClassification(at index: Int, error value: Double) {
            error.add(value, at: index)
            let distance = abs(value)
            if distance <= KaraokeScore.onPitchSemitones {
                on.add(referenceStep, at: index)
            } else if distance <= KaraokeScore.nearPitchSemitones {
                near.add(referenceStep, at: index)
            }
        }

        private mutating func removeClassification(at index: Int, error value: Double) {
            error.add(-value, at: index)
            let distance = abs(value)
            if distance <= KaraokeScore.onPitchSemitones {
                on.add(-referenceStep, at: index)
            } else if distance <= KaraokeScore.nearPitchSemitones {
                near.add(-referenceStep, at: index)
            }
        }

        private mutating func reset(startingAt index: Int) {
            processedAbsoluteIndex = index
            lastThrough = -.infinity
            sungCount = 0
            bestDistance = [Double](repeating: .infinity, count: reference.count)
            bestError = [Double](repeating: 0, count: reference.count)
            matched = [Bool](repeating: false, count: reference.count)
            on = Fenwick(count: reference.count)
            near = Fenwick(count: reference.count)
            matchCount = Fenwick(count: reference.count)
            error = Fenwick(count: reference.count)
        }

        private func reading(through: Double) -> KaraokeScore {
            let referenceCount = Self.referenceCount(reference, through: through)
            let onSeconds = on.prefix(referenceCount)
            let nearSeconds = near.prefix(referenceCount)
            let matches = Int(matchCount.prefix(referenceCount).rounded())
            let totalSeconds = Double(referenceCount) * referenceStep
            let credit = onSeconds + nearSeconds * KaraokeScore.nearPitchCredit
            let percentage =
                totalSeconds > 0
                ? max(0, min(100, credit / totalSeconds * 100))
                : 0

            var lineScores: [Line] = []
            lineScores.reserveCapacity(lyrics.count)
            for index in lyrics.indices {
                let full = lineReferenceRanges[index]
                let upper = max(
                    full.lowerBound,
                    min(full.upperBound, referenceCount))
                let bounds = full.lowerBound..<upper
                let total = Double(bounds.count) * referenceStep
                let lineOn = on.range(bounds)
                let lineNear = near.range(bounds)
                let lineCredit = lineOn + lineNear * KaraokeScore.nearPitchCredit
                lineScores.append(
                    Line(
                        index: index,
                        time: lyrics[index].time,
                        text: lyrics[index].text,
                        referenceSeconds: total,
                        onPitchSeconds: lineOn,
                        nearPitchSeconds: lineNear,
                        percentage:
                            total > 0
                            ? max(0, min(100, lineCredit / total * 100))
                            : 0))
            }

            return KaraokeScore(
                percentage: percentage,
                onPitchSeconds: onSeconds,
                nearPitchSeconds: nearSeconds,
                silentSeconds: max(
                    0,
                    totalSeconds - Double(matches) * referenceStep),
                referenceSeconds: totalSeconds,
                sungSeconds: Double(sungCount) * sungStep,
                meanErrorSemitones:
                    matches > 0 ? error.prefix(referenceCount) / Double(matches) : nil,
                lines: lineScores)
        }

        private static func firstReferenceIndex(
            atOrAfter time: Double,
            in reference: [PitchSample]
        ) -> Int {
            var lower = 0
            var upper = reference.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if reference[middle].time < time {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        private static func referenceCount(
            _ reference: [PitchSample],
            through: Double
        ) -> Int {
            guard through.isFinite else { return reference.count }
            return firstReferenceIndex(atOrAfter: through.nextUp, in: reference)
        }
    }

    /// Keeps the pitched part of captured player audio that overlaps words.
    ///
    /// This is the automatic reference used when an original recording is
    /// already one of the routed application sources. Instrumental gaps are
    /// excluded by the lyric phrases, and pitches outside any practical human
    /// range are excluded so a bass line cannot become the tune merely because
    /// it was the loudest periodic sound in the mix.
    ///
    /// This is still an audio-derived reference, not a score file. The
    /// interface says so and continues to call MIDI the exact source.
    public static func capturedReference(
        _ samples: [PitchSample], lyrics: [Lyrics.Line], through: Double
    ) -> [PitchSample] {
        guard !lyrics.isEmpty else { return [] }
        return samples.filter { sample in
            sample.time <= through
                && (36...96).contains(sample.midi)
                && lyricIndex(at: sample.time, lyrics: lyrics) != nil
        }
    }

    private static func lyricIndex(
        at time: Double, lyrics: [Lyrics.Line]
    ) -> Int? {
        guard let first = lyrics.first, time >= first.time else { return nil }
        var low = 0
        var high = lyrics.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lyrics[middle].time <= time { low = middle } else { high = middle - 1 }
        }
        let end =
            min(
                low + 1 < lyrics.count ? lyrics[low + 1].time : lyrics[low].time + 4,
                lyrics[low].time + 4)
        return time < end ? low : nil
    }

    /// The median gap between samples, which is how long one of them stands
    /// for.
    ///
    /// The median rather than the mean, because a series with one rest in the
    /// middle of it has one enormous gap and a mean that says every sample is
    /// worth twice what it is.
    public static func typicalStep(of samples: [PitchSample]) -> Double {
        guard samples.count > 1 else { return 0 }
        var gaps: [Double] = []
        gaps.reserveCapacity(samples.count - 1)
        for index in 1..<samples.count {
            gaps.append(samples[index].time - samples[index - 1].time)
        }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    /// Number of chronological samples at or before the song clock.
    ///
    /// Live histories grow for the whole performance and are scored four times
    /// a second. A linear prefix/filter here would turn the UI cost into a walk
    /// of the whole song forever; the series is ordered, so this is logarithmic.
    private static func chronologicalCount(
        _ samples: [PitchSample], through: Double
    ) -> Int {
        guard through.isFinite else { return samples.count }
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].time <= through {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

/// One singer's pitch, sampled off their own tap.
///
/// A duet is two microphones, two colours and two scores, and it is structurally
/// free here: the sources were never mixed, so each already has its own route
/// and its own ring. What was missing was that the pitch tracker existed once,
/// on the mixed analysis tap, and a score off that would be the two of them
/// averaged. This is one per source, fed from the ring that source already had.
public final class SingerPitch {

    /// Everything sung since the last reset, in time order. Empty unless
    /// `keepsHistory` is set. The running application may bound the retained
    /// suffix after handing older samples to an incremental scorer.
    public private(set) var samples: [PitchSample] = []
    /// Absolute index represented by `samples[0]`.
    ///
    /// Zero for the default unbounded history. Incremental consumers use it to
    /// survive compaction without rescoring the retained suffix.
    public private(set) var historyStartIndex = 0
    /// Changes whenever the history begins a different performance.
    ///
    /// An absolute index distinguishes compaction from an append. It cannot
    /// distinguish a seek whose new history happens to grow past the old
    /// cursor before the next UI refresh, so incremental consumers also keep
    /// this generation.
    public private(set) var historyGeneration = 0
    /// The most recent estimate in hertz, or zero when there is no pitch to
    /// find. What the interface shows.
    public private(set) var hertz: Float = 0

    /// Seconds represented by one tracker estimate.
    ///
    /// Known from the frame size rather than rediscovered by allocating and
    /// sorting every historical gap whenever the interface refreshes a score.
    public var sampleInterval: Double {
        Double(PitchTracker.frameSize) / sampleRate
    }

    /// Whether every sample is kept, or only the running range.
    ///
    /// The singing panel runs one of these per source the whole time it is
    /// open, so that the note it shows is the singer rather than the mixed bus
    /// — and that is minutes or hours. The list of every sample is wanted for a
    /// score, which is one song. Twenty-three samples a second is eighty
    /// thousand an hour per source for a list nobody reads, so the panel turns
    /// this off unless somebody has asked to be scored. The default is on,
    /// because a tracker whose samples silently went missing is a scorer that
    /// reads zero for a reason nobody can see.
    public var keepsHistory = true

    /// Samples to retain after an incremental consumer has seen them.
    ///
    /// Nil preserves the public default of keeping the complete performance.
    /// A positive value compacts in batches when twice this many have accrued,
    /// avoiding `removeFirst` work per tracker frame while placing a hard bound
    /// on a multi-hour open singing panel.
    public var historyCapacity: Int? {
        didSet {
            if let historyCapacity, historyCapacity <= 0 {
                self.historyCapacity = nil
            }
            compactHistoryIfNeeded()
        }
    }

    /// The range, accumulated rather than reduced over the list.
    ///
    /// Read at the interface's own rate against a list that grows all song, so
    /// the obvious `samples.reduce` is a walk of thousands of elements twenty
    /// times a second — and it has to work when nothing is being kept at all.
    private var rangeTotal: Double = 0
    private var rangeCount = 0

    private let tracker: PitchTracker?
    private let sampleRate: Double
    /// Samples waiting for a whole tracker frame.
    ///
    /// A growable array plus `removeFirst` used to allocate two frame arrays
    /// and move the whole unread tail every 43 ms. The input arrives in order,
    /// so one fixed frame and a fill count are the complete queue.
    private let pending: UnsafeMutablePointer<Float>
    private var pendingCount = 0
    /// Whole frames consumed since the anchor, which is the clock.
    private var frames = 0
    private var anchor: Double = 0

    private let head: LearnedPitch?

    /// Whether the learned head is consulted.
    ///
    /// A setting rather than only an environment variable, because it is a
    /// real choice with a measured trade: worth three to thirteen points when
    /// the accompaniment is louder than the singer, worth nothing below that,
    /// and 0.24 ms a frame either way. Somebody scoring a quiet studio take has
    /// every reason to turn it off, and somebody in a room with the PA up has
    /// every reason to leave it on.
    ///
    /// `YUNAUDIO_NO_LEARNED_PITCH` still forces it off, and stays: a claim
    /// about what something is worth needs the same pipeline measured without
    /// it, and a test cannot reach into somebody's preferences.
    public static let isForcedOff =
        ProcessInfo.processInfo.environment["YUNAUDIO_NO_LEARNED_PITCH"] != nil

    /// Set from the model's setting. Read on the audio-analysis path, so it is
    /// a plain `Bool` written from the main actor and read without
    /// synchronisation — the worst a torn read could do is use the previous
    /// value for one 43 ms frame.
    public nonisolated(unsafe) static var usesLearnedHead = !isForcedOff

    public init?(sampleRate: Double) {
        // The sung range, not the spoken one. Above 400 Hz the speaking search
        // returns the octave below, note for note — see `lowestSungHertz`.
        guard
            let tracker = PitchTracker(
                sampleRate: sampleRate,
                lowest: PitchTracker.lowestSungHertz,
                highest: PitchTracker.highestSungHertz)
        else { return nil }
        self.tracker = tracker
        self.sampleRate = sampleRate
        // Optional by design: a build without the model, or a machine that will
        // not compile it, keeps the rule and loses only the case the rule was
        // already losing.
        head = LearnedPitch(sampleRate: sampleRate)
        pending = .allocate(capacity: PitchTracker.frameSize)
    }

    deinit { pending.deallocate() }

    /// Starts again from a moment on the song's clock.
    public func reset(at seconds: Double) {
        samples.removeAll(keepingCapacity: true)
        historyStartIndex = 0
        historyGeneration &+= 1
        pendingCount = 0
        hertz = 0
        frames = 0
        anchor = seconds
        rangeTotal = 0
        rangeCount = 0
    }

    /// Takes what the source's ring produced.
    ///
    /// The clock is the audio, not the player. Timestamping from what Music or
    /// Spotify reports would put a scattering of Apple event round trips —
    /// tens of milliseconds each, and irregular — between the singer and the
    /// tune. Counting frames off the same stream the notes came from cannot
    /// drift against them at all; the player is asked once, for where the song
    /// was when scoring started.
    public func add(_ block: [Float], advancesTimeline: Bool = true) {
        block.withUnsafeBufferPointer { add($0, advancesTimeline: advancesTimeline) }
    }

    /// Takes a borrowed block without making an intermediate array.
    public func add(
        _ block: UnsafeBufferPointer<Float>, advancesTimeline: Bool = true
    ) {
        guard let tracker else { return }
        guard let blockAddress = block.baseAddress else { return }
        var consumed = 0
        while consumed < block.count {
            let copied = min(PitchTracker.frameSize - pendingCount, block.count - consumed)
            pending.advanced(by: pendingCount).update(
                from: blockAddress.advanced(by: consumed), count: copied)
            pendingCount += copied
            consumed += copied

            if pendingCount == PitchTracker.frameSize {
                var found = tracker.track(
                    frame: UnsafeBufferPointer(
                        start: pending, count: PitchTracker.frameSize))
                // The learned head settles which periodicity belongs to the
                // singer when the accompaniment is in the microphone at the
                // same level, which is where the peak-picking rule loses every
                // note. It is consulted only on the singing path — the voice
                // changer and the analysis panel hear one person in a room, and
                // have nothing to settle. See `LearnedPitch`.
                if let head, SingerPitch.usesLearnedHead, !SingerPitch.isForcedOff {
                    let curve = tracker.correlationCurve(
                        frame: Array(
                            UnsafeBufferPointer(
                                start: pending, count: PitchTracker.frameSize)))
                    if !curve.isEmpty {
                        found = head.hertz(from: curve, agreeingWith: found)
                    }
                }
                hertz = found
                if found > 0, advancesTimeline {
                    // The middle of the frame, because that is what an estimate
                    // over a frame is about. Half a frame is 21 ms at 48 kHz and
                    // the pairing window is 60, so it matters at a note boundary.
                    let centre =
                        anchor
                        + (Double(frames) * Double(PitchTracker.frameSize)
                            + Double(PitchTracker.frameSize) / 2) / sampleRate
                    let midi = PitchSample.midi(fromHertz: Double(found))
                    rangeTotal += midi
                    rangeCount += 1
                    appendToHistory(PitchSample(time: centre, midi: midi))
                }
                pendingCount = 0
                if advancesTimeline { frames += 1 }
            }
        }
    }

    /// Where the clock has reached, in song time.
    public var elapsed: Double {
        anchor + Double(frames) * Double(PitchTracker.frameSize) / sampleRate
    }

    /// The middle of everything sung so far, as a MIDI number, or nil before
    /// there is enough of it to call a range rather than a note.
    ///
    /// Twenty frames is about a second of actual singing.
    public var comfortableMidi: Double? {
        guard rangeCount >= 20 else { return nil }
        return rangeTotal / Double(rangeCount)
    }

    private func appendToHistory(_ sample: PitchSample) {
        guard keepsHistory else { return }
        samples.append(sample)
        compactHistoryIfNeeded()
    }

    /// Supplies deterministic pitch history without running an FFT.
    ///
    /// Internal rather than public API: the production path above is the only
    /// source of estimates, while an hour-long memory assertion needs to test
    /// compaction without doing eighty thousand transforms.
    func appendPitchForTesting(_ sample: PitchSample) {
        appendToHistory(sample)
    }

    private func compactHistoryIfNeeded() {
        guard let historyCapacity, historyCapacity > 0,
            samples.count > historyCapacity * 2
        else { return }
        let discarded = samples.count - historyCapacity
        samples.removeFirst(discarded)
        historyStartIndex += discarded
    }
}
