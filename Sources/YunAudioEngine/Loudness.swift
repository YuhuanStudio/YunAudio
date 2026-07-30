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
/// The measurement follows the standard: a two-stage pre-filter, mean square
/// over 400 ms blocks overlapping by 75%, and a two-pass gate that throws away
/// silence and then anything more than 10 LU below the ungated mean.
public struct LoudnessMeter: Sendable {

    /// The gated distribution, in fixed storage however long the session runs.
    private var distribution = LoudnessDistribution()
    private var filter: KWeighting
    private let sampleRate: Double
    /// Frames in one 400 ms block.
    private let blockFrames: Int
    /// Frames between block starts: a quarter of a block, so they overlap 75%
    /// as the standard requires.
    private let hopFrames: Int
    /// One 400 ms window as a ring. Removing 100 ms from the front of an Array
    /// moved 14,400 doubles ten times a second at 48 kHz.
    private var energyWindow: [Double]
    private var energySum: Double = 0
    private var energyWriteIndex = 0
    private var energyCount = 0
    private var framesUntilBlock = 0
    private var emittedBlocks = 0

    /// Momentary loudness, over the last 400 ms. What a meter shows.
    public private(set) var momentary: Double = -.infinity
    /// Short-term loudness, over the last 3 seconds.
    public private(set) var shortTerm: Double = -.infinity
    /// True peak is not estimated here; this is the sample peak in decibels,
    /// carried alongside because a loudness reading without one is incomplete.
    public private(set) var peak: Double = -.infinity

    /// Thirty 100 ms hops, kept as a ring with a running sum.
    private var shortTermBlocks: [Double]
    private var shortTermSum: Double = 0
    private var shortTermWriteIndex = 0
    private var shortTermCount = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        blockFrames = Int(sampleRate * 0.4)
        hopFrames = max(1, blockFrames / 4)
        filter = KWeighting(sampleRate: sampleRate)
        energyWindow = [Double](repeating: 0, count: blockFrames)
        shortTermBlocks = [Double](repeating: 0, count: 30)
    }

    /// Bytes occupied by the meter's fixed Array elements at one sample rate.
    ///
    /// Array headers and allocator metadata are deliberately excluded; this is
    /// the portable lower bound whose lifecycle the analyser can assert.
    static func retainedArrayBytes(sampleRate: Double) -> Int {
        LoudnessDistribution.retainedArrayBytes
            + Int(sampleRate * 0.4) * MemoryLayout<Double>.stride
            + 30 * MemoryLayout<Double>.stride
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
            addEnergy(weighted * weighted)
        }
    }

    private mutating func addEnergy(_ energy: Double) {
        if energyCount < blockFrames {
            energyWindow[energyWriteIndex] = energy
            energySum += energy
            advanceEnergyWriteIndex()
            energyCount += 1
            guard energyCount == blockFrames else { return }
            emitBlock()
            framesUntilBlock = hopFrames
            return
        }

        energySum += energy - energyWindow[energyWriteIndex]
        energyWindow[energyWriteIndex] = energy
        advanceEnergyWriteIndex()
        framesUntilBlock -= 1
        if framesUntilBlock == 0 {
            emitBlock()
            framesUntilBlock = hopFrames
        }
    }

    private mutating func advanceEnergyWriteIndex() {
        energyWriteIndex += 1
        if energyWriteIndex == blockFrames { energyWriteIndex = 0 }
    }

    private mutating func emitBlock() {
        emittedBlocks += 1
        // Subtracting the outgoing energy is constant-time but accumulates
        // floating-point round-off. Rebasing every hundred seconds keeps the
        // running sum numerically tied to the actual window at negligible cost.
        if emittedBlocks % 1000 == 0 { energySum = energyWindow.reduce(0, +) }
        let mean = energySum / Double(blockFrames)
        distribution.add(mean)

        if shortTermCount < shortTermBlocks.count {
            shortTermBlocks[shortTermCount] = mean
            shortTermSum += mean
            shortTermCount += 1
        } else {
            shortTermSum += mean - shortTermBlocks[shortTermWriteIndex]
            shortTermBlocks[shortTermWriteIndex] = mean
            shortTermWriteIndex += 1
            if shortTermWriteIndex == shortTermBlocks.count { shortTermWriteIndex = 0 }
        }
        momentary = Self.loudness(ofMeanSquare: mean)
        shortTerm = Self.loudness(
            ofMeanSquare: shortTermSum / Double(shortTermCount))
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
        distribution.integrated
    }

    /// Loudness range: the spread between the quiet and loud parts, in LU.
    ///
    /// A single number cannot say whether a recording is evenly levelled or
    /// swings twenty units between a whisper and a shout, and that is exactly
    /// what decides whether it needs compression.
    public var range: Double {
        distribution.range
    }

    public mutating func reset() {
        distribution.reset()
        energyWindow.withUnsafeMutableBufferPointer {
            $0.update(repeating: 0)
        }
        energySum = 0
        energyWriteIndex = 0
        energyCount = 0
        framesUntilBlock = 0
        emittedBlocks = 0
        shortTermBlocks.withUnsafeMutableBufferPointer {
            $0.update(repeating: 0)
        }
        shortTermSum = 0
        shortTermWriteIndex = 0
        shortTermCount = 0
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

/// A fixed-size approximation of the BS.1770 gated block distribution.
///
/// Integrated loudness needs an absolute gate, then a relative gate ten units
/// below the surviving mean. Loudness range needs two percentiles of the same
/// blocks. Keeping every block made both getters allocate and sort the entire
/// session at display rate: 36,000 values after one hour, then twice as many
/// after two. A 0.01 LU histogram is much finer than the meter can display and
/// bounds both memory and query time for a session of any length.
struct LoudnessDistribution: Sendable {
    private static let lowerLUFS = -70.0
    private static let upperLUFS = 30.0
    private static let binWidth = 0.01
    static let binCount = Int((upperLUFS - lowerLUFS) / binWidth)
    /// A relative gate can land inside one coarse bin. Keeping several
    /// populations inside every bin prevents a large group either side of that
    /// boundary being admitted or rejected as one value.
    private static let centroidCapacity = 16

    private var counts = [UInt64](repeating: 0, count: binCount)
    private var energySums = [Double](repeating: 0, count: binCount)
    /// Fenwick indices are one-based. Prefix queries and percentile lookup stay
    /// logarithmic instead of scanning all ten thousand bins per UI frame.
    private var countTree = [UInt64](repeating: 0, count: binCount + 1)
    private var energyTree = [Double](repeating: 0, count: binCount + 1)
    /// Fixed micro-distributions for the one coarse bin a relative gate can
    /// split. Sixteen centroids retain repeated modes exactly and merge only
    /// the closest energies once a bin contains more distinct populations.
    private var centroidCounts = [UInt64](
        repeating: 0, count: binCount * centroidCapacity)
    private var centroidEnergySums = [Double](
        repeating: 0, count: binCount * centroidCapacity)
    private(set) var blockCount: UInt64 = 0
    private var totalEnergy: Double = 0

    static var retainedArrayBytes: Int {
        let ordinaryBins =
            binCount
            * (MemoryLayout<UInt64>.stride + MemoryLayout<Double>.stride)
        let treeBins =
            (binCount + 1)
            * (MemoryLayout<UInt64>.stride + MemoryLayout<Double>.stride)
        let centroidBins =
            binCount * centroidCapacity
            * (MemoryLayout<UInt64>.stride + MemoryLayout<Double>.stride)
        return ordinaryBins + treeBins + centroidBins
    }

    mutating func add(_ meanSquare: Double) {
        let loudness = LoudnessMeter.loudness(ofMeanSquare: meanSquare)
        guard loudness > Self.lowerLUFS else { return }
        let bin = Self.bin(for: loudness)
        counts[bin] += 1
        energySums[bin] += meanSquare
        blockCount += 1
        totalEnergy += meanSquare
        addToBoundarySketch(meanSquare, bin: bin)

        var index = bin + 1
        while index <= Self.binCount {
            countTree[index] += 1
            energyTree[index] += meanSquare
            index += index & -index
        }
    }

    var integrated: Double {
        guard blockCount > 0 else { return -.infinity }
        let ungated = totalEnergy / Double(blockCount)
        // Ten loudness units are exactly a factor of ten in mean-square
        // energy, so the relative threshold needs no logarithm.
        let thresholdEnergy = ungated / 10
        let thresholdLUFS = LoudnessMeter.loudness(ofMeanSquare: thresholdEnergy)
        let boundary = Self.bin(for: thresholdLUFS)

        let excludedWholeCount = prefixCount(before: boundary)
        var excludedCount = Double(excludedWholeCount)
        var excludedEnergy = prefixEnergy(before: boundary)
        // The previous implementation decided this for the whole 0.01 LU bin.
        // A large population on both sides amplified that tiny quantisation
        // into a 2.43 LU error. The fixed micro-distribution keeps those
        // populations separate without making storage grow with session time.
        let start = boundary * Self.centroidCapacity
        for slot in start..<(start + Self.centroidCapacity) {
            let count = centroidCounts[slot]
            guard count > 0 else { continue }
            let energy = centroidEnergySums[slot]
            if energy / Double(count) <= thresholdEnergy {
                excludedCount += Double(count)
                excludedEnergy += energy
            }
        }

        let gatedCount = Double(blockCount) - excludedCount
        guard gatedCount > 0 else { return -.infinity }
        return LoudnessMeter.loudness(
            ofMeanSquare: (totalEnergy - excludedEnergy) / gatedCount)
    }

    var range: Double {
        guard blockCount > 4 else { return 0 }
        let lowRank = UInt64(Double(blockCount) * 0.1)
        let highRank = min(blockCount - 1, UInt64(Double(blockCount) * 0.95))
        let low = loudness(atRank: lowRank)
        let high = loudness(atRank: highRank)
        return high - low
    }

    mutating func reset() {
        counts.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        energySums.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        countTree.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        energyTree.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        centroidCounts.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        centroidEnergySums.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        blockCount = 0
        totalEnergy = 0
    }

    private mutating func addToBoundarySketch(_ meanSquare: Double, bin: Int) {
        let start = bin * Self.centroidCapacity
        var empty: Int?
        var nearest = start
        var nearestDistance = Double.infinity

        for slot in start..<(start + Self.centroidCapacity) {
            let count = centroidCounts[slot]
            guard count > 0 else {
                if empty == nil { empty = slot }
                continue
            }
            let mean = centroidEnergySums[slot] / Double(count)
            let distance = abs(mean - meanSquare)
            // Repeated stationary blocks should remain one exact population
            // rather than consume every centroid before another level arrives.
            if distance <= max(mean, meanSquare) * 1e-12 {
                centroidCounts[slot] += 1
                centroidEnergySums[slot] += meanSquare
                return
            }
            if distance < nearestDistance {
                nearest = slot
                nearestDistance = distance
            }
        }

        let slot = empty ?? nearest
        centroidCounts[slot] += 1
        centroidEnergySums[slot] += meanSquare
    }

    private static func bin(for loudness: Double) -> Int {
        min(
            binCount - 1,
            max(0, Int((loudness - lowerLUFS) / binWidth)))
    }

    private func prefixCount(before bin: Int) -> UInt64 {
        var index = bin
        var total: UInt64 = 0
        while index > 0 {
            total += countTree[index]
            index -= index & -index
        }
        return total
    }

    private func prefixEnergy(before bin: Int) -> Double {
        var index = bin
        var total = 0.0
        while index > 0 {
            total += energyTree[index]
            index -= index & -index
        }
        return total
    }

    private func loudness(atRank rank: UInt64) -> Double {
        let bin = bin(containingRank: rank)
        guard counts[bin] > 0 else { return -.infinity }
        return LoudnessMeter.loudness(
            ofMeanSquare: energySums[bin] / Double(counts[bin]))
    }

    /// Finds the bin containing a zero-based order statistic.
    private func bin(containingRank rank: UInt64) -> Int {
        let target = rank + 1
        var index = 0
        var accumulated: UInt64 = 0
        var step = 1
        while step << 1 <= Self.binCount { step <<= 1 }
        while step > 0 {
            let next = index + step
            if next <= Self.binCount,
                accumulated + countTree[next] < target
            {
                index = next
                accumulated += countTree[next]
            }
            step >>= 1
        }
        return min(index, Self.binCount - 1)
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
