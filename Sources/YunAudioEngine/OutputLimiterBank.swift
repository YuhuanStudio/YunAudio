import Foundation

/// A final, linked true-peak limiter for each output bus.
///
/// Constructed on the control thread and then owned by one realtime thread.
/// Every delay line and detector queue is allocated up front; `processInterleaved`
/// only walks those buffers and never changes their capacity.
public final class OutputLimiterBank: @unchecked Sendable {
    /// Sample rate all buses were prepared for.
    public let sampleRate: Double
    /// The true-peak ceiling as a linear full-scale magnitude.
    public let ceiling: Float
    /// Fixed look-ahead delay introduced on every bus.
    public let latencyFrames: Int
    /// Channel count prepared for each bus.
    public let channelCounts: [Int]

    private let states: UnsafeMutablePointer<BusState>

    /// Builds one linked limiter for every channel count.
    ///
    /// - Parameters:
    ///   - channelCounts: Interleaved channel count of every output bus.
    ///   - sampleRate: Sample rate shared by those buses.
    ///   - ceilingDecibels: Estimated true-peak ceiling in dBTP, no greater than zero.
    ///   - lookAheadSeconds: Fixed delay used to see a peak before it leaves.
    ///   - releaseSeconds: Time taken for attenuation to recover towards unity.
    public init?(
        channelCounts: [Int],
        sampleRate: Double,
        ceilingDecibels: Float = -0.3,
        lookAheadSeconds: Double = 0.001,
        releaseSeconds: Double = 0.05
    ) {
        guard !channelCounts.isEmpty, channelCounts.allSatisfy({ $0 > 0 && $0 <= 64 }),
            sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 384_000,
            ceilingDecibels.isFinite, ceilingDecibels <= 0, ceilingDecibels >= -60,
            lookAheadSeconds.isFinite, lookAheadSeconds >= 0, lookAheadSeconds <= 0.1,
            releaseSeconds.isFinite, releaseSeconds > 0, releaseSeconds <= 10
        else { return nil }

        let latencyFrames = Int(ceil(lookAheadSeconds * sampleRate))
        let ceiling = powf(10, ceilingDecibels / 20)
        let releaseCoefficient = Float(exp(-1 / (releaseSeconds * sampleRate)))

        self.sampleRate = sampleRate
        self.ceiling = ceiling
        self.latencyFrames = latencyFrames
        self.channelCounts = channelCounts
        states = .allocate(capacity: channelCounts.count)

        for (index, channels) in channelCounts.enumerated() {
            states.advanced(by: index).initialize(
                to: BusState(
                    channels: channels,
                    lookAheadFrames: latencyFrames,
                    ceiling: ceiling,
                    releaseCoefficient: releaseCoefficient))
        }
    }

    deinit {
        for index in channelCounts.indices {
            states[index].releaseStorage()
        }
        states.deinitialize(count: channelCounts.count)
        states.deallocate()
    }

    /// Limits one interleaved output bus in place.
    ///
    /// The prepared channel count is supplied again deliberately. A topology
    /// mismatch must fail closed at the future graph integration boundary,
    /// rather than striding a buffer using stale layout.
    @inline(__always)
    @discardableResult
    public func processInterleaved(
        bus: Int,
        samples: UnsafeMutablePointer<Float>,
        frames: Int,
        channels: Int,
        limiting: Bool = true,
        preGain: Float = 1
    ) -> Bool {
        guard bus >= 0, bus < channelCounts.count, frames >= 0,
            channels == channelCounts[bus], preGain.isFinite, preGain >= 0
        else { return false }
        states.advanced(by: bus).pointee.process(
            samples: samples, frames: frames, limiting: limiting,
            preGain: limiting ? preGain : 1)
        return true
    }

    /// Clears one bus before it is attached to a new stream.
    ///
    /// This is a control-thread operation. Resetting a live bus would erase its
    /// look-ahead history and deliberately introduce `latencyFrames` of silence.
    public func reset(bus: Int) -> Bool {
        guard bus >= 0, bus < channelCounts.count else { return false }
        states.advanced(by: bus).pointee.reset()
        return true
    }
}

private struct BusState {
    let channels: Int
    let lookAheadFrames: Int
    let ceiling: Float
    let releaseCoefficient: Float

    let delayCapacity: Int
    let delay: UnsafeMutablePointer<Float>
    var delayPosition = 0

    /// One FIR history per channel. These are pointer-backed because a bus can
    /// carry up to 64 channels and the realtime path may not resize storage.
    let truePeakDetectors: UnsafeMutablePointer<TruePeakDetector>

    /// A monotonic queue gives the linked maximum of the whole look-ahead
    /// window in amortised constant time. Re-scanning the window would make a
    /// 1 ms safety stage cost 49 comparisons per output frame at 48 kHz.
    let peakCapacity: Int
    let peakValues: UnsafeMutablePointer<Float>
    let peakIndices: UnsafeMutablePointer<Int64>
    var peakFront = 0
    var peakBack = 0
    var peakCount = 0
    var sampleIndex: Int64 = 0

    var gain: Float = 1

    init(
        channels: Int,
        lookAheadFrames: Int,
        ceiling: Float,
        releaseCoefficient: Float
    ) {
        self.channels = channels
        self.lookAheadFrames = lookAheadFrames
        self.ceiling = ceiling
        self.releaseCoefficient = releaseCoefficient

        delayCapacity = lookAheadFrames + 1
        delay = .allocate(capacity: delayCapacity * channels)
        delay.initialize(repeating: 0, count: delayCapacity * channels)

        truePeakDetectors = .allocate(capacity: channels)
        truePeakDetectors.initialize(repeating: TruePeakDetector(), count: channels)

        // One spare slot keeps front and back unambiguous at the maximum
        // look-ahead occupancy.
        peakCapacity = lookAheadFrames + 2
        peakValues = .allocate(capacity: peakCapacity)
        peakValues.initialize(repeating: 0, count: peakCapacity)
        peakIndices = .allocate(capacity: peakCapacity)
        peakIndices.initialize(repeating: 0, count: peakCapacity)
    }

    func releaseStorage() {
        delay.deinitialize(count: delayCapacity * channels)
        delay.deallocate()
        truePeakDetectors.deinitialize(count: channels)
        truePeakDetectors.deallocate()
        peakValues.deinitialize(count: peakCapacity)
        peakValues.deallocate()
        peakIndices.deinitialize(count: peakCapacity)
        peakIndices.deallocate()
    }

    mutating func reset() {
        delay.update(repeating: 0, count: delayCapacity * channels)
        for channel in 0..<channels {
            truePeakDetectors[channel].reset()
        }
        peakValues.update(repeating: 0, count: peakCapacity)
        peakIndices.update(repeating: 0, count: peakCapacity)
        delayPosition = 0
        peakFront = 0
        peakBack = 0
        peakCount = 0
        sampleIndex = 0
        gain = 1
    }

    @inline(__always)
    mutating func process(
        samples: UnsafeMutablePointer<Float>, frames: Int,
        limiting: Bool, preGain: Float
    ) {
        var frameOffset = 0
        for _ in 0..<frames {
            let delayOffset = delayPosition * channels
            var linkedPeak: Float = 0

            for channel in 0..<channels {
                let sample = sanitisedAudioSample(samples[frameOffset + channel] * preGain)
                delay[delayOffset + channel] = sample
                let magnitude = abs(sample)
                if magnitude > linkedPeak { linkedPeak = magnitude }
                let truePeak = truePeakDetectors[channel].push(
                    sample, measuring: limiting)
                if truePeak > linkedPeak { linkedPeak = truePeak }
            }

            let oldest = sampleIndex - Int64(lookAheadFrames)
            while peakCount > 0, peakIndices[peakFront] < oldest {
                peakFront += 1
                if peakFront == peakCapacity { peakFront = 0 }
                peakCount -= 1
            }

            while peakCount > 0 {
                var last = peakBack - 1
                if last < 0 { last = peakCapacity - 1 }
                if peakValues[last] > linkedPeak { break }
                peakBack = last
                peakCount -= 1
            }

            peakValues[peakBack] = linkedPeak
            peakIndices[peakBack] = sampleIndex
            peakBack += 1
            if peakBack == peakCapacity { peakBack = 0 }
            peakCount += 1

            let windowPeak = peakValues[peakFront]
            let target =
                limiting && windowPeak > ceiling
                ? ceiling / windowPeak : 1
            if target < gain {
                // The delayed signal has not reached this peak yet, so the
                // safest attack is immediate. Recovery is deliberately slow.
                gain = target
            } else {
                gain = target + releaseCoefficient * (gain - target)
            }

            var readPosition = delayPosition - lookAheadFrames
            if readPosition < 0 { readPosition += delayCapacity }
            let readOffset = readPosition * channels
            let appliedGain = limiting ? gain : 1
            for channel in 0..<channels {
                let delayed = sanitisedAudioSample(
                    delay[readOffset + channel] * appliedGain)
                samples[frameOffset + channel] =
                    limiting ? min(ceiling, max(-ceiling, delayed)) : delayed
            }

            delayPosition += 1
            if delayPosition == delayCapacity { delayPosition = 0 }
            sampleIndex &+= 1
            frameOffset += channels
        }
    }
}
