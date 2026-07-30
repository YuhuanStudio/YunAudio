import Foundation
import Testing
import YunAudioEngine
import YunAudioRT

@Suite("Final output limiter bank")
struct OutputLimiterBankTests {
    @Test("mixed sources cannot leave above the output ceiling")
    func catchesSummedSources() throws {
        let limiter = try #require(
            OutputLimiterBank(
                channelCounts: [2], sampleRate: 48_000,
                ceilingDecibels: -0.3))
        let frames = 4_800
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let phase = Float(frame) * 2 * .pi * 997 / 48_000
            let mixed = 0.8 * sin(phase) + 0.7 * sin(phase)
            samples[frame * 2] = mixed
            samples[frame * 2 + 1] = mixed
        }

        samples.withUnsafeMutableBufferPointer {
            #expect(
                limiter.processInterleaved(
                    bus: 0, samples: $0.baseAddress!, frames: frames, channels: 2))
        }

        let peak = samples.map(abs).max() ?? 0
        #expect(peak <= limiter.ceiling + 0.000_001)
        #expect(peak >= limiter.ceiling - 0.001)
    }

    @Test("linked gain preserves the stereo image")
    func linksChannels() throws {
        let limiter = try #require(
            OutputLimiterBank(
                channelCounts: [2], sampleRate: 48_000,
                ceilingDecibels: -0.3))
        let frames = 4_800
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let left = 1.4 * sin(Float(frame) * 2 * .pi * 431 / 48_000)
            samples[frame * 2] = left
            samples[frame * 2 + 1] = left * 0.25
        }

        samples.withUnsafeMutableBufferPointer {
            #expect(
                limiter.processInterleaved(
                    bus: 0, samples: $0.baseAddress!, frames: frames, channels: 2))
        }

        var greatestRatioError: Float = 0
        for frame in limiter.latencyFrames..<frames {
            let left = samples[frame * 2]
            let right = samples[frame * 2 + 1]
            if abs(left) > 0.01 {
                greatestRatioError = max(greatestRatioError, abs(right / left - 0.25))
            }
        }
        #expect(greatestRatioError < 0.000_001)
    }

    @Test("non-finite samples cannot poison this or a later block")
    func sanitisesNonFiniteInput() throws {
        let limiter = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        var first = [Float](repeating: 0.4, count: 512 * 2)
        first[20] = .nan
        first[41] = .infinity
        first[62] = -.infinity
        first.withUnsafeMutableBufferPointer {
            #expect(
                limiter.processInterleaved(
                    bus: 0, samples: $0.baseAddress!, frames: 512, channels: 2))
        }

        var second = [Float](repeating: 0.2, count: 512 * 2)
        second.withUnsafeMutableBufferPointer {
            #expect(
                limiter.processInterleaved(
                    bus: 0, samples: $0.baseAddress!, frames: 512, channels: 2))
        }

        #expect(first.allSatisfy { $0.isFinite })
        #expect(second.allSatisfy { $0.isFinite })
        #expect(first.allSatisfy { abs($0) <= limiter.ceiling })
        #expect(second.allSatisfy { abs($0) <= limiter.ceiling })
    }

    @Test("audio below the ceiling is unchanged after the fixed delay")
    func transparentBelowCeiling() throws {
        let limiter = try #require(
            OutputLimiterBank(
                channelCounts: [2], sampleRate: 48_000,
                ceilingDecibels: -0.3))
        let frames = 4_800
        var input = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            input[frame * 2] = 0.4 * sin(Float(frame) * 2 * .pi * 997 / 48_000)
            input[frame * 2 + 1] =
                0.2 * cos(Float(frame) * 2 * .pi * 613 / 48_000)
        }
        var output = input

        output.withUnsafeMutableBufferPointer {
            #expect(
                limiter.processInterleaved(
                    bus: 0, samples: $0.baseAddress!, frames: frames, channels: 2))
        }

        var greatestError: Float = 0
        for frame in limiter.latencyFrames..<frames {
            for channel in 0..<2 {
                greatestError = max(
                    greatestError,
                    abs(
                        output[frame * 2 + channel]
                            - input[(frame - limiter.latencyFrames) * 2 + channel]))
            }
        }
        #expect(limiter.latencyFrames == 48)
        #expect(greatestError == 0)
    }

    @Test("bypass keeps the same exact delay without imposing a ceiling")
    func bypassIsExactAboveAndBelowCeiling() throws {
        let limiter = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        let latency = limiter.latencyFrames
        let frames = latency + 137
        var input = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            input[frame * 2] = frame.isMultiple(of: 2) ? 1.5 : 0.25
            input[frame * 2 + 1] = frame.isMultiple(of: 3) ? -1.25 : -0.125
        }
        var output = input

        output.withUnsafeMutableBufferPointer {
            #expect(
                limiter.processInterleaved(
                    bus: 0, samples: $0.baseAddress!, frames: frames, channels: 2,
                    limiting: false))
        }

        #expect(output.prefix(latency * 2).allSatisfy { $0 == 0 })
        for frame in latency..<frames {
            #expect(output[frame * 2] == input[(frame - latency) * 2])
            #expect(output[frame * 2 + 1] == input[(frame - latency) * 2 + 1])
        }
        #expect(output.contains(1.5))
        #expect(output.contains(-1.25))
    }

    @Test("each bus owns an independent linked detector")
    func separatesBuses() throws {
        let limiter = try #require(
            OutputLimiterBank(channelCounts: [2, 1], sampleRate: 48_000))
        var loud = [Float](repeating: 1.5, count: 512 * 2)
        var quiet = [Float](repeating: 0.2, count: 512)
        loud.withUnsafeMutableBufferPointer {
            #expect(
                limiter.processInterleaved(
                    bus: 0, samples: $0.baseAddress!, frames: 512, channels: 2))
        }
        quiet.withUnsafeMutableBufferPointer {
            #expect(
                limiter.processInterleaved(
                    bus: 1, samples: $0.baseAddress!, frames: 512, channels: 1))
        }

        #expect(quiet.dropFirst(limiter.latencyFrames).allSatisfy { $0 == 0.2 })
        quiet.withUnsafeMutableBufferPointer {
            #expect(
                !limiter.processInterleaved(
                    bus: 1, samples: $0.baseAddress!, frames: 1, channels: 2))
        }
    }

    #if DEBUG
        @Test(
            "steady-state limiting allocates nothing",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("steady-state limiting allocates nothing")
    #endif
    func steadyStateDoesNotAllocate() throws {
        let limiter = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        let blockFrames = 128
        let cycles = 3_750
        var samples = [Float](repeating: 1.25, count: blockFrames * 2)

        // Warm the branch layout and the allocation hook before measuring.
        samples.withUnsafeMutableBufferPointer {
            _ = limiter.processInterleaved(
                bus: 0, samples: $0.baseAddress!, frames: blockFrames, channels: 2)
        }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        samples.withUnsafeMutableBufferPointer { buffer in
            yun_rt_tripwire_mark_realtime(true)
            for cycle in 0..<cycles {
                let value: Float = cycle.isMultiple(of: 2) ? 1.25 : -1.25
                for index in 0..<buffer.count {
                    buffer[index] = value
                }
                _ = limiter.processInterleaved(
                    bus: 0, samples: buffer.baseAddress!,
                    frames: blockFrames, channels: 2)
            }
            yun_rt_tripwire_mark_realtime(false)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before
        let nanosecondsPerFrame = Double(elapsed) / Double(blockFrames * cycles)

        print(
            "linked output limiter: \(nanosecondsPerFrame) ns/frame, "
                + "\(allocations) realtime allocations")
        #expect(allocations == 0)
        #expect(nanosecondsPerFrame < 2_000)
    }
}
