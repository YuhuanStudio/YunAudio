import Foundation

/// Loudness to ITU-R BS.1770-4, which is what EBU R128 and every streaming
/// platform actually measure.
///
/// A peak meter answers "will this clip". It does not answer the question
/// anybody streaming or recording actually has, which is "am I as loud as
/// everyone else" — peak and perceived loudness diverge badly, and a signal
/// that peaks at −1 dBFS can sit ten units quieter than one peaking at −6.
/// Discord normalises to about −18 LUFS, YouTube to −14, broadcast to −23.
/// Nothing else in this category on macOS will tell you where you are.
///
/// The measurement is exactly the standard: a two-stage pre-filter, mean square
/// over 400 ms blocks overlapping by 75%, and a two-pass gate that throws away
/// silence and then anything more than 10 LU below the ungated mean.
public struct LoudnessMeter: Sendable {

    /// One 400 ms block's mean square, which is what the gating works on.
    private var blocks: [Double] = []
    private var filter: KWeighting
    private let sampleRate: Double
    /// Frames in one 400 ms block.
    private let blockFrames: Int
    /// Frames between block starts: a quarter of a block, so they overlap 75%
    /// as the standard requires.
    private let hopFrames: Int
    private var pending: [Double] = []

    /// Momentary loudness, over the last 400 ms. What a meter shows.
    public private(set) var momentary: Double = -.infinity
    /// Short-term loudness, over the last 3 seconds.
    public private(set) var shortTerm: Double = -.infinity
    /// True peak is not estimated here; this is the sample peak in decibels,
    /// carried alongside because a loudness reading without one is incomplete.
    public private(set) var peak: Double = -.infinity

    private var shortTermBlocks: [Double] = []

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        blockFrames = Int(sampleRate * 0.4)
        hopFrames = max(1, blockFrames / 4)
        filter = KWeighting(sampleRate: sampleRate)
        pending.reserveCapacity(blockFrames)
    }

    /// Feeds mono samples. Multi-channel material should be summed by the
    /// caller with the standard's channel weights; for a microphone there is
    /// one channel and its weight is one.
    public mutating func add(_ samples: UnsafePointer<Float>, count: Int) {
        for index in 0..<count {
            let sample = Double(samples[index])
            let magnitude = abs(sample)
            if magnitude > 0 {
                peak = max(peak, 20 * log10(magnitude))
            }
            let weighted = filter.process(sample)
            pending.append(weighted * weighted)

            if pending.count >= blockFrames {
                let mean = pending.reduce(0, +) / Double(blockFrames)
                blocks.append(mean)
                shortTermBlocks.append(mean)
                // Three seconds of blocks, at one every 100 ms.
                if shortTermBlocks.count > 30 { shortTermBlocks.removeFirst() }
                momentary = Self.loudness(ofMeanSquare: mean)
                shortTerm = Self.loudness(
                    ofMeanSquare: shortTermBlocks.reduce(0, +)
                        / Double(shortTermBlocks.count))
                pending.removeFirst(hopFrames)
            }
        }
    }

    /// Integrated loudness over everything fed so far, gated as the standard
    /// requires.
    ///
    /// Two passes. The first throws away anything below −70 LUFS absolute,
    /// which is silence and would otherwise drag the average down for every
    /// pause. The second computes the mean of what is left and throws away
    /// anything more than 10 LU below *that*, which is what stops a quiet
    /// passage counting as much as the speech.
    public var integrated: Double {
        let absolute = blocks.filter { Self.loudness(ofMeanSquare: $0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }

        let ungated = absolute.reduce(0, +) / Double(absolute.count)
        let threshold = Self.loudness(ofMeanSquare: ungated) - 10
        let gated = absolute.filter { Self.loudness(ofMeanSquare: $0) > threshold }
        guard !gated.isEmpty else { return -.infinity }

        return Self.loudness(
            ofMeanSquare: gated.reduce(0, +) / Double(gated.count))
    }

    /// Loudness range: the spread between the quiet and loud parts, in LU.
    ///
    /// A single number cannot say whether a recording is evenly levelled or
    /// swings twenty units between a whisper and a shout, and that is exactly
    /// what decides whether it needs compression.
    public var range: Double {
        let absolute =
            blocks
            .map { Self.loudness(ofMeanSquare: $0) }
            .filter { $0 > -70 }
            .sorted()
        guard absolute.count > 4 else { return 0 }
        // The standard's 10th and 95th percentiles of the gated distribution.
        let low = absolute[Int(Double(absolute.count) * 0.1)]
        let high = absolute[min(absolute.count - 1, Int(Double(absolute.count) * 0.95))]
        return high - low
    }

    public mutating func reset() {
        blocks.removeAll(keepingCapacity: true)
        shortTermBlocks.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        filter = KWeighting(sampleRate: sampleRate)
        momentary = -.infinity
        shortTerm = -.infinity
        peak = -.infinity
    }

    /// The standard's mapping from mean square to LUFS.
    static func loudness(ofMeanSquare value: Double) -> Double {
        value > 0 ? -0.691 + 10 * log10(value) : -.infinity
    }
}

/// The two filters BS.1770 puts in front of the measurement.
///
/// A high shelf standing in for the head's acoustic effect, then a high-pass.
/// Coefficients are the standard's own, specified at 48 kHz and re-derived here
/// for whatever rate is in use — using the 48 kHz numbers at 96 kHz would put
/// the shelf an octave out and read two units high on a bright voice.
struct KWeighting {
    private var shelf: Biquad
    private var highPass: Biquad

    init(sampleRate: Double) {
        // Stage 1: high shelf, +4 dB at 1681 Hz, Q 0.7071.
        shelf = Biquad.highShelf(
            frequency: 1681.974450955533, q: 0.7071752369554196,
            gain: 3.999843853973347, sampleRate: sampleRate)
        // Stage 2: high-pass at 38.1 Hz, Q 0.5.
        highPass = Biquad.highPass(
            frequency: 38.13547087602444, q: 0.5003270373238773,
            sampleRate: sampleRate)
    }

    mutating func process(_ sample: Double) -> Double {
        highPass.process(shelf.process(sample))
    }
}

/// A direct-form biquad. Small enough to keep here rather than depend on
/// Accelerate for two filters running on a control thread.
struct Biquad {
    var b0 = 1.0
    var b1 = 0.0
    var b2 = 0.0
    var a1 = 0.0
    var a2 = 0.0
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }

    static func highShelf(
        frequency: Double, q: Double, gain: Double, sampleRate: Double
    ) -> Biquad {
        let amplitude = pow(10, gain / 40)
        let omega = 2 * .pi * frequency / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)
        let sqrtA = sqrt(amplitude)

        let a0 = (amplitude + 1) - (amplitude - 1) * cosine + 2 * sqrtA * alpha
        var filter = Biquad()
        filter.b0 =
            amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + 2 * sqrtA * alpha)
            / a0
        filter.b1 = -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine) / a0
        filter.b2 =
            amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - 2 * sqrtA * alpha)
            / a0
        filter.a1 = 2 * ((amplitude - 1) - (amplitude + 1) * cosine) / a0
        filter.a2 = ((amplitude + 1) - (amplitude - 1) * cosine - 2 * sqrtA * alpha) / a0
        return filter
    }

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let omega = 2 * .pi * frequency / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)

        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = (1 + cosine) / 2 / a0
        filter.b1 = -(1 + cosine) / a0
        filter.b2 = (1 + cosine) / 2 / a0
        filter.a1 = -2 * cosine / a0
        filter.a2 = (1 - alpha) / a0
        return filter
    }
}

/// What a platform expects, so a reading can say more than a number.
public enum LoudnessTarget: String, CaseIterable, Identifiable, Sendable {
    case broadcast
    case youTube
    case discord
    case spotify

    public var id: String { rawValue }

    public var lufs: Double {
        switch self {
        case .broadcast: -23
        case .youTube: -14
        case .discord: -18
        case .spotify: -14
        }
    }

    public var title: String {
        switch self {
        case .broadcast: "EBU R128"
        case .youTube: "YouTube"
        case .discord: "Discord"
        case .spotify: "Spotify"
        }
    }
}
