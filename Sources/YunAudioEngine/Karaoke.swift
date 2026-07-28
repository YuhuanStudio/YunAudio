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
    /// - Returns: The total and, when lyrics were given, one entry per line.
    public static func score(
        sung: [PitchSample], reference: [PitchSample], lyrics: [Lyrics.Line] = []
    ) -> KaraokeScore {
        let sung = sung.sorted { $0.time < $1.time }
        let reference = reference.sorted { $0.time < $1.time }
        guard !reference.isEmpty else { return .none }

        let referenceStep = typicalStep(of: reference)
        let sungStep = typicalStep(of: sung)
        guard referenceStep > 0 else { return .none }

        // One bucket per lyric line, plus one for whatever falls before the
        // first line — an instrumental introduction that still has a tune in it
        // counts towards the total even though no line covers it.
        var starts = lyrics.map(\.time)
        if starts.first.map({ $0 > 0 }) ?? true { starts.insert(-.infinity, at: 0) }
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
            while bucket + 1 < starts.count, starts[bucket + 1] <= moment.time { bucket += 1 }
            totalPerBucket[bucket] += weight
            totalSeconds += weight

            while cursor + 1 < sung.count,
                abs(sung[cursor + 1].time - moment.time) <= abs(sung[cursor].time - moment.time)
            {
                cursor += 1
            }
            guard cursor < sung.count,
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
            sungSeconds: Double(sung.count) * sungStep,
            meanErrorSemitones: errorCount > 0 ? errorTotal / Double(errorCount) : nil,
            lines: lines)
    }

    /// The median gap between samples, which is how long one of them stands
    /// for.
    ///
    /// The median rather than the mean, because a series with one rest in the
    /// middle of it has one enormous gap and a mean that says every sample is
    /// worth twice what it is.
    static func typicalStep(of samples: [PitchSample]) -> Double {
        guard samples.count > 1 else { return 0 }
        var gaps: [Double] = []
        gaps.reserveCapacity(samples.count - 1)
        for index in 1..<samples.count {
            gaps.append(samples[index].time - samples[index - 1].time)
        }
        gaps.sort()
        return gaps[gaps.count / 2]
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

    /// Everything sung since the last reset, in time order.
    public private(set) var samples: [PitchSample] = []
    /// The most recent estimate in hertz, or zero when there is no pitch to
    /// find. What the interface shows.
    public private(set) var hertz: Float = 0

    private let tracker: PitchTracker?
    private let sampleRate: Double
    /// Samples waiting for a whole tracker frame.
    private var pending: [Float] = []
    /// Whole frames consumed since the anchor, which is the clock.
    private var frames = 0
    private var anchor: Double = 0

    public init?(sampleRate: Double) {
        guard let tracker = PitchTracker(sampleRate: sampleRate) else { return nil }
        self.tracker = tracker
        self.sampleRate = sampleRate
    }

    /// Starts again from a moment on the song's clock.
    public func reset(at seconds: Double) {
        samples.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        hertz = 0
        frames = 0
        anchor = seconds
    }

    /// Takes what the source's ring produced.
    ///
    /// The clock is the audio, not the player. Timestamping from what Music or
    /// Spotify reports would put a scattering of Apple event round trips —
    /// tens of milliseconds each, and irregular — between the singer and the
    /// tune. Counting frames off the same stream the notes came from cannot
    /// drift against them at all; the player is asked once, for where the song
    /// was when scoring started.
    public func add(_ block: [Float]) {
        guard let tracker else { return }
        pending.append(contentsOf: block)
        while pending.count >= PitchTracker.frameSize {
            let frame = Array(pending.prefix(PitchTracker.frameSize))
            let found = tracker.track(frame: frame)
            hertz = found
            if found > 0 {
                // The middle of the frame, because that is what an estimate
                // over a frame is about. Half a frame is 21 ms at 48 kHz and
                // the pairing window is 60, so it matters at a note boundary.
                let centre =
                    anchor
                    + (Double(frames) * Double(PitchTracker.frameSize)
                        + Double(PitchTracker.frameSize) / 2) / sampleRate
                samples.append(
                    PitchSample(time: centre, midi: PitchSample.midi(fromHertz: Double(found))))
            }
            pending.removeFirst(PitchTracker.frameSize)
            frames += 1
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
        guard samples.count >= 20 else { return nil }
        return samples.reduce(0) { $0 + $1.midi } / Double(samples.count)
    }
}
