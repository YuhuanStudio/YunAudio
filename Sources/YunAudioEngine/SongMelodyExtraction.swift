import AVFoundation
import Foundation

/// The tune of a song, taken from the song itself, before anybody sings.
///
/// ## Why this exists beside `MidiMelody`
///
/// `MidiMelody` is exact and it is the right reference when there is one. But it
/// needs a `.mid` beside the `.lrc`, and for most songs somebody opens there is
/// no such file — so scoring fell to comparing a singer against the detected
/// key, which is nearly no comparison at all: anybody singing roughly in tune
/// with the record scores well, and the number stops meaning anything. That is
/// the whole of the complaint that scoring is bad.
///
/// `KaraokeMelody`'s own notes rejected measuring the original singer, and two
/// of those three reasons do not apply here — because they were written about
/// tracking *playback*, and this reads the *file*.
///
/// 1. *"The stage is the wrong stage — it never sees the player's output."*
///    This is not on any stage. It opens the file directly, off the realtime
///    path, before the song plays.
/// 2. *"A measurement of the original arrives too late to be a target."* It
///    arrives before the first line, because the whole song is analysed at open
///    time. It can be a target, and it can be drawn ahead of the singer.
/// 3. *"The vocal is usually not there."* This one stands, and is answered by
///    saying so: a reference with too little pitch in it is refused rather than
///    scored against, and a true instrumental produces exactly that. See
///    `leastUsableSeconds`.
///
/// The front end is the one the microphone already uses — `PitchTracker`'s
/// correlation curve, refined by `LearnedPitch` where the model is present.
/// That is deliberate: `correlationCurve`'s own documentation says it exists
/// because "for a voice over a backing track at the same level, several lags
/// score nearly identically and the peak picker picks the wrong one", and that
/// preference is what the learned head was trained on. A full mix is precisely
/// that case, and offline there is no realtime budget to trade against.
public enum SongMelody {

    public struct Result: Sendable {
        /// One sample per hop where a pitch was found, in MIDI numbers.
        public let samples: [PitchSample]
        /// Seconds of audio actually read.
        public let analysedSeconds: Double
        /// Seconds that carried a usable pitch, which is the number that says
        /// whether this reference is worth scoring against.
        public let pitchedSeconds: Double
        /// Whether the learned head refined the estimates or the peak picker
        /// stood alone.
        public let usedLearnedHead: Bool

        /// Whether there is enough tune here to score somebody against.
        ///
        /// An instrumental backing track produces a reference that is mostly
        /// silence and stray harmonics, and scoring against it would invent a
        /// confident bad number — the failure this is meant to end, not repeat.
        public var isUsable: Bool { pitchedSeconds >= SongMelody.leastUsableSeconds }
    }

    /// Below this the reference is refused. Twenty seconds of found pitch in a
    /// song is far less than a sung one carries and far more than an
    /// instrumental produces from harmonics alone.
    public static let leastUsableSeconds: Double = 20

    /// The hop, which is `KaraokeScore.referenceInterval` because the scorer
    /// samples the MIDI reference at exactly that spacing and the two have to
    /// be interchangeable.
    public static let hopSeconds = KaraokeScore.referenceInterval

    /// The longest song this will read. Bounded for the same reason
    /// `MidiMelody` bounds its own timeline: a file describes, and a
    /// description must not be able to ask this process for unbounded work.
    public static let maximumSeconds: Double = 30 * 60

    public enum Failure: Error, Sendable {
        case unreadable
        case unsupportedRate(Double)
        case noTracker
        case cancelled
    }

    /// Reads the file once and returns its melody line.
    ///
    /// Synchronous and cancellable: the caller owns the thread it runs on, and
    /// it is never the main one.
    public static func extract(
        from url: URL,
        isCancelled: @Sendable () -> Bool = { false },
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Result {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw Failure.unreadable
        }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard AudioProcessingContract.supports(sampleRate: rate) else {
            throw Failure.unsupportedRate(rate)
        }
        // The sung range, not the speaking one: this is a melody, and the
        // microphone path passes the same pair for the same reason.
        guard
            let tracker = PitchTracker(
                sampleRate: rate,
                lowest: PitchTracker.lowestSungHertz,
                highest: PitchTracker.highestSungHertz)
        else { throw Failure.noTracker }
        let learned = LearnedPitch(sampleRate: rate)

        let frameSize = PitchTracker.frameSize
        let hop = max(1, Int((hopSeconds * rate).rounded()))
        let totalFrames = min(file.length, AVAudioFramePosition(maximumSeconds * rate))
        guard totalFrames > AVAudioFramePosition(frameSize) else {
            return Result(
                samples: [], analysedSeconds: 0, pitchedSeconds: 0,
                usedLearnedHead: learned != nil)
        }

        // One window of history, refilled a hop at a time. Reading a fresh
        // window per hop would read every sample forty-two times over.
        var window = [Float](repeating: 0, count: frameSize)
        var filled = 0
        var samples: [PitchSample] = []
        samples.reserveCapacity(Int(Double(totalFrames) / rate / hopSeconds) + 1)
        var read: AVAudioFramePosition = 0
        // Read in blocks rather than a hop at a time: a hop is 2400 frames at
        // 48 kHz and one `AVAudioFile.read` per hop spends its time in the
        // decoder's setup rather than in decoding.
        let blockFrames = AVAudioFrameCount(max(hop, 1 << 15))
        guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames)
        else { throw Failure.unreadable }
        var pending: [Float] = []
        pending.reserveCapacity(Int(blockFrames))

        while read < totalFrames {
            if isCancelled() { throw Failure.cancelled }
            block.frameLength = 0
            do { try file.read(into: block) } catch { break }
            let got = Int(block.frameLength)
            guard got > 0 else { break }
            read += AVAudioFramePosition(got)
            progress?(min(1, Double(read) / Double(totalFrames)))

            // Mono, because a melody has no sides. Averaging rather than taking
            // the left channel: a vocal is usually centred and a hard-panned
            // instrument is not, so the average is already a mild lift of the
            // thing being looked for.
            appendMono(from: block, count: got, into: &pending)

            var consumed = 0
            while consumed < pending.count {
                let take = min(hop - (filled % hop == 0 ? 0 : 0), pending.count - consumed)
                _ = take
                // Slide the window by one hop, then estimate.
                let available = pending.count - consumed
                if available < hop { break }
                slide(&window, by: hop, appending: pending, from: consumed)
                consumed += hop
                filled = min(frameSize, filled + hop)
                guard filled >= frameSize else { continue }
                let time =
                    Double(read - AVAudioFramePosition(pending.count - consumed))
                    / rate
                if let midi = estimate(
                    window: window, tracker: tracker, learned: learned)
                {
                    samples.append(PitchSample(time: max(0, time), midi: midi))
                }
            }
            if consumed > 0 { pending.removeFirst(consumed) }
        }

        let analysed = Double(read) / rate
        let pitched = Double(samples.count) * hopSeconds
        return Result(
            samples: samples, analysedSeconds: analysed, pitchedSeconds: pitched,
            usedLearnedHead: learned != nil)
    }

    /// One window's estimate, learned head first where there is one.
    private static func estimate(
        window: [Float], tracker: PitchTracker, learned: LearnedPitch?
    ) -> Double? {
        let ruled = tracker.track(frame: window)
        guard let learned else { return midi(fromHertz: ruled) }
        let curve = tracker.correlationCurve(frame: window)
        guard !curve.isEmpty else { return midi(fromHertz: ruled) }
        return midi(fromHertz: learned.hertz(from: curve, agreeingWith: ruled))
    }

    private static func midi(fromHertz hertz: Float) -> Double? {
        guard hertz > 0, hertz.isFinite else { return nil }
        let value = PitchSample.midi(fromHertz: Double(hertz))
        // The same window the captured reference keeps: below 36 and above 96
        // is not a sung melody, it is a bass line or a harmonic.
        guard (36...96).contains(value) else { return nil }
        return value
    }

    private static func appendMono(
        from buffer: AVAudioPCMBuffer, count: Int, into pending: inout [Float]
    ) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            pending.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
            return
        }
        let scale = 1 / Float(channelCount)
        for frame in 0..<count {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            pending.append(sum * scale)
        }
    }

    private static func slide(
        _ window: inout [Float], by hop: Int, appending source: [Float], from offset: Int
    ) {
        let size = window.count
        if hop >= size {
            for index in 0..<size {
                window[index] = source[offset + hop - size + index]
            }
            return
        }
        for index in 0..<(size - hop) { window[index] = window[index + hop] }
        for index in 0..<hop { window[size - hop + index] = source[offset + index] }
    }
}
