import Darwin
import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

/// A formant is a frequency in hertz, not a number of samples.
///
/// The stage used to keep a 1024-frame window and thirty cepstral coefficients
/// at every rate. At 96 kHz that halved its time support, doubled its bin width
/// and moved the envelope boundary up an octave. These checks compare physical
/// quantities across rates, then measure the burst which lands whenever an
/// accumulated hop completes.
@Suite("Formant sample-rate consistency", .serialized)
struct FormantRateConsistencyTests {
    private static let rates = [44_100.0, 48_000.0, 96_000.0]
    private static let callbackPatterns = [
        [64], [128], [256], [512],
        [64, 192, 128, 384, 256, 96, 416],
    ]

    @Test("analysis geometry preserves physical time and frequency")
    func geometry() throws {
        let expected = [
            (rate: 44_100.0, window: 1_024, hop: 256, depth: 28),
            (rate: 48_000.0, window: 1_024, hop: 256, depth: 30),
            (rate: 96_000.0, window: 2_048, hop: 512, depth: 60),
        ]

        for item in expected {
            let configuration = try #require(
                FormantShifter.configuration(sampleRate: item.rate))
            let windowMilliseconds =
                Double(configuration.windowSize) / item.rate * 1_000
            let hopMilliseconds = Double(configuration.hop) / item.rate * 1_000
            let cepstralMilliseconds =
                Double(configuration.cepstralDepth) / item.rate * 1_000

            print(
                "formant \(Int(item.rate)) Hz: N\(configuration.windowSize), "
                    + "H\(configuration.hop), Q\(configuration.cepstralDepth), "
                    + "\(windowMilliseconds) / \(hopMilliseconds) / "
                    + "\(cepstralMilliseconds) ms")
            #expect(configuration.windowSize == item.window)
            #expect(configuration.hop == item.hop)
            #expect(configuration.cepstralDepth == item.depth)
            #expect((20.0...24.0).contains(windowMilliseconds))
            #expect((5.0...6.0).contains(hopMilliseconds))
            #expect((0.6...0.7).contains(cepstralMilliseconds))
        }
    }

    @Test("identity is an exact one-window delay at every rate")
    func identityDelay() throws {
        for rate in Self.rates {
            let configuration = try #require(
                FormantShifter.configuration(sampleRate: rate))
            let source = signal(
                count: configuration.windowSize * 4 + 517, sampleRate: rate)

            for pattern in Self.callbackPatterns {
                let output = try render(
                    source, sampleRate: rate, ratio: 1, callbackFrames: pattern)
                var startPeak: Float = 0
                for value in output.prefix(configuration.latencyFrames) {
                    startPeak = max(startPeak, abs(value))
                }
                var largestError: Float = 0
                for index in configuration.latencyFrames..<output.count {
                    largestError = max(
                        largestError,
                        abs(output[index] - source[index - configuration.latencyFrames]))
                }

                print(
                    "formant identity \(Int(rate)) Hz / \(pattern): "
                        + "start \(startPeak), error \(largestError)")
                #expect(startPeak == 0)
                #expect(largestError == 0)
            }
        }
    }

    @Test("callback boundaries do not change shifted samples")
    func callbackMatrix() throws {
        for rate in Self.rates {
            let source = vowel(seconds: 0.5, sampleRate: rate)
            let reference = try render(
                source, sampleRate: rate, ratio: 1.35, callbackFrames: [512])

            for pattern in Self.callbackPatterns {
                let output = try render(
                    source, sampleRate: rate, ratio: 1.35,
                    callbackFrames: pattern)
                var largestDifference: Float = 0
                var squaredDifference = 0.0
                for index in output.indices {
                    let difference = abs(output[index] - reference[index])
                    largestDifference = max(largestDifference, difference)
                    squaredDifference += Double(difference * difference)
                }
                let rmsDifference =
                    sqrt(squaredDifference / Double(output.count))

                print(
                    "formant callback \(Int(rate)) Hz / \(pattern): "
                        + "max \(largestDifference), RMS \(rmsDifference)")
                #expect(largestDifference < 1e-6)
                #expect(rmsDifference < 1e-7)
            }
        }
    }

    @Test("formants move consistently while pitch stays put")
    func soundMatrix() throws {
        let ratios: [Float] = [0.7, 1.02, 1.5]
        var movements: [Float: [Double]] = [:]

        for rate in Self.rates {
            let source = vowel(seconds: 0.75, sampleRate: rate)
            let plainCentroid = harmonicCentroid(source, sampleRate: rate)

            for ratio in ratios {
                let output = try render(
                    source, sampleRate: rate, ratio: ratio,
                    callbackFrames: [64, 192, 128, 384, 256, 96, 416])
                let centroid = harmonicCentroid(output, sampleRate: rate)
                let movement = centroid / plainCentroid
                movements[ratio, default: []].append(movement)

                let pitch = try measuredPitch(output, sampleRate: rate)
                let pitchError = cents(measured: pitch, expected: 120)
                print(
                    "formant sound \(Int(rate)) Hz / \(ratio): "
                        + "centroid \(plainCentroid) -> \(centroid) "
                        + "(\(movement)x), pitch \(pitch) Hz / \(pitchError) cents")

                #expect(pitch > 0)
                #expect(abs(pitchError) < 15)
                if ratio < 1 {
                    #expect(movement < 0.97)
                } else if ratio > 1.1 {
                    #expect(movement > 1.08)
                } else {
                    #expect(abs(movement - 1) < 0.08)
                }
            }
        }

        for ratio in ratios {
            let values = try #require(movements[ratio])
            let lowest = try #require(values.min())
            let highest = try #require(values.max())
            #expect(
                highest - lowest < 0.08,
                "ratio \(ratio) moved centroids inconsistently: \(values)")
        }
    }

    #if DEBUG
        @Test(
            "release callback bursts allocate nothing and fit their deadline",
            .disabled("allocation and deadline evidence requires an optimised build"))
    #else
        @Test("release callback bursts allocate nothing and fit their deadline")
    #endif
    func realtimeMatrix() throws {
        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }

        for rate in Self.rates {
            for callbackFrames in [64, 128, 256, 512] {
                let source = signal(count: Int(rate), sampleRate: rate)
                let shifter = try #require(FormantShifter(sampleRate: rate))
                shifter.ratio = 1.25
                var warm = signal(
                    count: shifter.configuration.windowSize * 8,
                    sampleRate: rate)
                process(&warm, using: shifter, callbackFrames: callbackFrames)

                var allocationInput = source
                RoutingEngine.enableAllocationTripwire()
                let allocationBaseline = RoutingEngine.allocationViolations
                allocationInput.withUnsafeMutableBufferPointer { buffer in
                    yun_rt_tripwire_mark_realtime(true)
                    process(
                        buffer.baseAddress!, count: buffer.count,
                        using: shifter, callbackFrames: callbackFrames)
                    yun_rt_tripwire_mark_realtime(false)
                }
                let allocations =
                    RoutingEngine.allocationViolations - allocationBaseline
                RoutingEngine.disableAllocationTripwire()

                let measured = try #require(FormantShifter(sampleRate: rate))
                measured.ratio = 1.25
                warm = signal(
                    count: measured.configuration.windowSize * 8,
                    sampleRate: rate)
                process(&warm, using: measured, callbackFrames: callbackFrames)
                var performanceInput = source
                var durations: [UInt64] = []
                durations.reserveCapacity(
                    (performanceInput.count + callbackFrames - 1) / callbackFrames)
                performanceInput.withUnsafeMutableBufferPointer { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let frames = min(callbackFrames, buffer.count - offset)
                        let started = Self.threadNanoseconds()
                        measured.process(buffer.baseAddress! + offset, count: frames)
                        durations.append(Self.threadNanoseconds() - started)
                        offset += frames
                    }
                }
                durations.sort()
                let p99Index = min(
                    durations.count - 1,
                    Int((Double(durations.count - 1) * 0.99).rounded(.down)))
                let p99 = durations[p99Index]
                let maximum = try #require(durations.last)
                let deadline =
                    UInt64(Double(callbackFrames) / rate * 1_000_000_000)

                print(
                    "formant release \(Int(rate)) Hz / \(callbackFrames): "
                        + "\(allocations) allocations, p99 \(p99) ns "
                        + "(\(Double(p99) / Double(deadline) * 100)% deadline), "
                        + "max \(maximum) ns "
                        + "(\(Double(maximum) / Double(deadline) * 100)% deadline)")
                #expect(allocations == 0)
                #expect(p99 < deadline)
                #expect(maximum < deadline)
            }
        }
    }

    private func render(
        _ source: [Float], sampleRate: Double, ratio: Float,
        callbackFrames: [Int]
    ) throws -> [Float] {
        let shifter = try #require(FormantShifter(sampleRate: sampleRate))
        shifter.ratio = ratio
        var output = source
        output.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            var callback = 0
            while offset < buffer.count {
                let frames = min(
                    callbackFrames[callback % callbackFrames.count],
                    buffer.count - offset)
                shifter.process(buffer.baseAddress! + offset, count: frames)
                offset += frames
                callback += 1
            }
        }
        return output
    }

    private func signal(count: Int, sampleRate: Double) -> [Float] {
        (0..<count).map { index in
            let time = Double(index) / sampleRate
            return Float(
                0.25 * sin(2 * Double.pi * 173 * time + 0.31)
                    + 0.12 * sin(2 * Double.pi * 997 * time + 0.73))
        }
    }

    private func vowel(seconds: Double, sampleRate: Double) -> [Float] {
        let fundamental = 120.0
        let formants = [700.0, 1_220.0, 2_600.0]
        var samples = [Float](
            repeating: 0, count: Int(sampleRate * seconds))
        var harmonic = 1
        while Double(harmonic) * fundamental <= 6_000 {
            let frequency = Double(harmonic) * fundamental
            var weight = 0.02
            for (index, formant) in formants.enumerated() {
                let bandwidth = 110.0 + Double(index) * 60
                let distance = (frequency - formant) / bandwidth
                weight += (1 / (1 + distance * distance)) / Double(index + 1)
            }
            let phaseStep = 2 * Double.pi * frequency / sampleRate
            for index in samples.indices {
                samples[index] += Float(weight * sin(phaseStep * Double(index)))
            }
            harmonic += 1
        }
        let scale = 0.5 / (samples.map(abs).max() ?? 1)
        for index in samples.indices { samples[index] *= scale }
        return samples
    }

    /// Projects the steady tail onto the known harmonic grid.
    ///
    /// A quarter-second contains exactly thirty periods at 120 Hz, so every
    /// harmonic is orthogonal at all three integer sample rates. This avoids
    /// making a cross-rate assertion depend on an analyser's own FFT size.
    private func harmonicCentroid(_ samples: [Float], sampleRate: Double) -> Double {
        let count = min(samples.count, Int(sampleRate / 4))
        let start = samples.count - count
        var weighted = 0.0
        var total = 0.0

        for harmonic in 1...50 {
            let frequency = Double(harmonic) * 120
            let phaseStep = 2 * Double.pi * frequency / sampleRate
            let stepReal = cos(phaseStep)
            let stepImaginary = sin(phaseStep)
            var oscillatorReal = cos(phaseStep * Double(start))
            var oscillatorImaginary = sin(phaseStep * Double(start))
            var projectionReal = 0.0
            var projectionImaginary = 0.0

            for index in start..<samples.count {
                let sample = Double(samples[index])
                projectionReal += sample * oscillatorReal
                projectionImaginary -= sample * oscillatorImaginary
                let nextReal =
                    oscillatorReal * stepReal - oscillatorImaginary * stepImaginary
                oscillatorImaginary =
                    oscillatorImaginary * stepReal + oscillatorReal * stepImaginary
                oscillatorReal = nextReal
            }
            let amplitude = hypot(projectionReal, projectionImaginary)
            weighted += frequency * amplitude
            total += amplitude
        }
        return total > 0 ? weighted / total : 0
    }

    private func measuredPitch(_ samples: [Float], sampleRate: Double) throws -> Double {
        let frameCount = 3
        let wanted = PitchTracker.frameSize * frameCount
        let frames = Array(samples.suffix(wanted))
        let tracker = try #require(PitchTracker(sampleRate: sampleRate))
        let voiced = tracker.track(frames: frames, count: frameCount).filter { $0 > 0 }
        return Double(voiced.reduce(0, +)) / Double(max(voiced.count, 1))
    }

    private func cents(measured: Double, expected: Double) -> Double {
        1_200 * log2(measured / expected)
    }

    private func process(
        _ samples: inout [Float], using shifter: FormantShifter,
        callbackFrames: Int
    ) {
        samples.withUnsafeMutableBufferPointer {
            process(
                $0.baseAddress!, count: $0.count,
                using: shifter, callbackFrames: callbackFrames)
        }
    }

    private func process(
        _ samples: UnsafeMutablePointer<Float>, count: Int,
        using shifter: FormantShifter, callbackFrames: Int
    ) {
        var offset = 0
        while offset < count {
            let frames = min(callbackFrames, count - offset)
            shifter.process(samples + offset, count: frames)
            offset += frames
        }
    }

    private static func threadNanoseconds() -> UInt64 {
        var time = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0 else { return 0 }
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }
}
