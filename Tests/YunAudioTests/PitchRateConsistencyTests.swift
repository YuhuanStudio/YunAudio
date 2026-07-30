import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Pitch sample-rate consistency", .serialized)
struct PitchRateConsistencyTests {
    private let rates = [44_100.0, 48_000.0, 96_000.0]
    private let lowFrequencies = [60.0, 65.41, 73.42, 82.41]

    @Test("low voices remain voiced and in tune at every supported rate")
    func lowVoiceMatrix() throws {
        for rate in rates {
            let tracker = try #require(PitchTracker(sampleRate: rate))
            for frequency in lowFrequencies {
                let input = tone(
                    hertz: frequency,
                    count: PitchTracker.frameSize * 3,
                    sampleRate: rate)
                let estimates = tracker.track(frames: input, count: 3)
                let errors = estimates.map {
                    cents(measured: Double($0), expected: frequency)
                }
                let largestError = errors.map(abs).max() ?? .infinity

                print(
                    "pitch \(Int(rate)) Hz / \(frequency) Hz: "
                        + "\(estimates), max \(largestError) cents")
                #expect(estimates.count == 3)
                #expect(estimates.allSatisfy { $0 > 0 })
                #expect(
                    largestError < 15,
                    "\(rate) Hz reported \(frequency) Hz with \(largestError) cents error")
            }
        }
    }

    @Test("SingerPitch keeps pitch and audio time across rates and block boundaries")
    func singerClockMatrix() throws {
        let anchor = 12.5
        let blockSizes = [1, 127, 2_047, 64, 4_096, 509]

        for rate in rates {
            let frequency = 65.41
            let singer = try #require(SingerPitch(sampleRate: rate))
            singer.reset(at: anchor)
            let input = tone(
                hertz: frequency, count: Int(rate), sampleRate: rate)
            input.withUnsafeBufferPointer { buffer in
                var offset = 0
                var block = 0
                while offset < buffer.count {
                    let count = min(
                        blockSizes[block % blockSizes.count],
                        buffer.count - offset)
                    singer.add(
                        UnsafeBufferPointer(
                            start: buffer.baseAddress! + offset,
                            count: count))
                    offset += count
                    block += 1
                }
            }

            let completeFrames = input.count / PitchTracker.frameSize
            let expectedElapsed =
                anchor
                + Double(completeFrames * PitchTracker.frameSize) / rate
            let elapsedError = abs(singer.elapsed - expectedElapsed)
            let unconsumedSeconds =
                1 - Double(completeFrames * PitchTracker.frameSize) / rate
            let pitchError = cents(
                measured: Double(singer.hertz), expected: frequency)
            let sampleErrors = singer.samples.map {
                cents(
                    measured: 440 * pow(2, ($0.midi - 69) / 12),
                    expected: frequency)
            }
            let largestSampleError = sampleErrors.map(abs).max() ?? .infinity

            print(
                "singer \(Int(rate)) Hz: \(completeFrames) estimates, "
                    + "\(pitchError) cents, elapsed \(singer.elapsed), "
                    + "tail \(unconsumedSeconds) s")
            #expect(singer.samples.count == completeFrames)
            #expect(abs(pitchError) < 15)
            #expect(largestSampleError < 15)
            #expect(elapsedError < 1e-12)
            #expect(unconsumedSeconds >= 0)
            #expect(
                unconsumedSeconds < Double(PitchTracker.frameSize) / rate)
        }
    }

    #if DEBUG
        @Test(
            "steady low-pitch tracking allocates nothing at any rate",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("steady low-pitch tracking allocates nothing at any rate")
    #endif
    func releaseAllocations() throws {
        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }

        for rate in rates {
            let singer = try #require(SingerPitch(sampleRate: rate))
            singer.keepsHistory = false
            let input = tone(
                hertz: 65.41, count: Int(rate), sampleRate: rate)
            input.withUnsafeBufferPointer {
                singer.add(
                    UnsafeBufferPointer(
                        start: $0.baseAddress!,
                        count: PitchTracker.frameSize))
            }
            singer.reset(at: 0)

            RoutingEngine.enableAllocationTripwire()
            let allocationBaseline = RoutingEngine.allocationViolations
            let started = DispatchTime.now().uptimeNanoseconds
            input.withUnsafeBufferPointer { buffer in
                yun_rt_tripwire_mark_realtime(true)
                singer.add(buffer)
                yun_rt_tripwire_mark_realtime(false)
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            let allocations =
                RoutingEngine.allocationViolations - allocationBaseline
            RoutingEngine.disableAllocationTripwire()
            let pitchError = cents(
                measured: Double(singer.hertz), expected: 65.41)

            print(
                "pitch release \(Int(rate)) Hz: \(elapsed) ns/s audio, "
                    + "\(allocations) allocations, \(pitchError) cents")
            #expect(allocations == 0)
            #expect(abs(pitchError) < 15)
        }
    }

    private func tone(
        hertz: Double, count: Int, sampleRate: Double
    ) -> [Float] {
        (0..<count).map {
            0.4
                * Float(
                    sin(
                        2 * Double.pi * hertz * Double($0)
                            / sampleRate + 0.37))
        }
    }

    private func cents(measured: Double, expected: Double) -> Double {
        guard measured > 0, expected > 0 else { return .infinity }
        return 1_200 * log2(measured / expected)
    }
}
