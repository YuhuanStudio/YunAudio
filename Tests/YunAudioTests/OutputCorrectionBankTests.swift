import CoreAudio
import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

private final class CorrectionTestBus {
    let list: UnsafeMutableAudioBufferListPointer
    let frames: Int
    let channelCounts: [Int]
    private let storage: [UnsafeMutablePointer<Float>]

    init(channelCounts: [Int], frames: Int) {
        self.frames = frames
        self.channelCounts = channelCounts
        list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
        var pointers: [UnsafeMutablePointer<Float>] = []
        for (slot, channels) in channelCounts.enumerated() {
            let count = frames * channels
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            pointers.append(pointer)
            list[slot] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer))
        }
        storage = pointers
    }

    func fill(_ value: (Int, Int, Int) -> Float) {
        for slot in channelCounts.indices {
            let channels = channelCounts[slot]
            for frame in 0..<frames {
                for channel in 0..<channels {
                    storage[slot][frame * channels + channel] =
                        value(slot, frame, channel)
                }
            }
        }
    }

    func sample(slot: Int = 0, frame: Int, channel: Int = 0) -> Float {
        storage[slot][frame * channelCounts[slot] + channel]
    }

    deinit {
        for (slot, pointer) in storage.enumerated() {
            pointer.deinitialize(count: frames * channelCounts[slot])
            pointer.deallocate()
        }
        free(list.unsafeMutablePointer)
    }
}

@Suite("Live output correction bank")
struct OutputCorrectionBankTests {
    private var identity: OutputCorrectionBank.Configuration {
        OutputCorrectionBank.Configuration(
            coefficients: [1, 0, 0, 0, 0], preampGain: 1)!
    }

    private var halfLevel: OutputCorrectionBank.Configuration {
        OutputCorrectionBank.Configuration(
            coefficients: [1, 0, 0, 0, 0], preampGain: 0.5)!
    }

    @Test("the handover adds no delay")
    func transitionHasNoLatency() throws {
        let bank = try #require(
            OutputCorrectionBank(sampleRate: 48_000, maximumFrames: 128))
        #expect(bank.latencyFrames == 0)
        #expect(bank.fadeFrames == 960)

        let bus = CorrectionTestBus(channelCounts: [1], frames: 128)
        bus.fill { _, frame, _ in frame == 0 ? 1 : 0 }
        bank.prepareTransitionImmediately(from: identity, to: halfLevel, slot: 0)
        bank.process(bus.list)

        #expect(bus.sample(frame: 0) == 1)
        #expect(
            (0..<128).first(where: { bus.sample(frame: $0) != 0 }) == 0)
    }

    @Test("twenty milliseconds replaces a hard correction step")
    func transitionDerivativeIsBounded() throws {
        let bank = try #require(
            OutputCorrectionBank(sampleRate: 48_000, maximumFrames: 128))
        bank.prepareTransitionImmediately(from: identity, to: halfLevel, slot: 0)
        let bus = CorrectionTestBus(channelCounts: [2], frames: 128)
        var rendered: [Float] = []
        var greatestRatioError: Float = 0

        while rendered.count < bank.fadeFrames + 128 {
            bus.fill { _, _, channel in channel == 0 ? 1 : 0.25 }
            bank.process(bus.list)
            for frame in 0..<bus.frames {
                let left = bus.sample(frame: frame)
                let right = bus.sample(frame: frame, channel: 1)
                rendered.append(left)
                greatestRatioError = max(
                    greatestRatioError, abs(right / left - 0.25))
            }
        }

        var greatestDerivative: Float = 0
        for frame in 1..<bank.fadeFrames {
            greatestDerivative = max(
                greatestDerivative,
                abs(rendered[frame] - rendered[frame - 1]))
        }

        let derivativeLimit = Float(0.5 / Double(bank.fadeFrames - 1)) + 0.000_001
        #expect(rendered[0] == 1)
        #expect(abs(rendered[bank.fadeFrames - 1] - 0.5) < 0.000_001)
        #expect(greatestDerivative <= derivativeLimit)
        #expect(greatestRatioError < 0.000_001)
    }

    @Test("block partition cannot move the fade")
    func transitionIsIndependentOfBlockSize() throws {
        func render(chunks: [Int], scratchFrames: Int = 256) throws -> [Float] {
            let bank = try #require(
                OutputCorrectionBank(
                    sampleRate: 48_000, maximumFrames: scratchFrames))
            bank.prepareTransitionImmediately(from: identity, to: halfLevel, slot: 0)
            var result: [Float] = []
            var chunk = 0
            while result.count < bank.fadeFrames + 64 {
                let frames = chunks[chunk % chunks.count]
                let bus = CorrectionTestBus(channelCounts: [1], frames: frames)
                bus.fill { _, _, _ in 1 }
                bank.process(bus.list)
                for frame in 0..<frames { result.append(bus.sample(frame: frame)) }
                chunk += 1
            }
            return Array(result.prefix(bank.fadeFrames + 64))
        }

        let uniform = try render(chunks: [128])
        let irregular = try render(chunks: [1, 127, 3, 251, 17, 64])
        let oversized = try render(chunks: [513], scratchFrames: 64)
        var greatestDifference: Float = 0
        for index in uniform.indices {
            greatestDifference = max(
                greatestDifference,
                abs(uniform[index] - irregular[index]),
                abs(uniform[index] - oversized[index]))
        }
        #expect(greatestDifference < 0.000_001)
    }

    @Test("each output advances by its own frame count and a nil output cannot wedge")
    func variableOutputFramesKeepIndependentTimelines() throws {
        let bank = try #require(
            OutputCorrectionBank(sampleRate: 48_000, maximumFrames: 32))
        let list = AudioBufferList.allocate(maximumBuffers: 3)
        let long = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        let short = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let dormant = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        long.initialize(repeating: 1, count: 128)
        short.initialize(repeating: 1, count: 64)
        dormant.initialize(to: 1)
        defer {
            long.deallocate()
            short.deallocate()
            dormant.deallocate()
            free(list.unsafeMutablePointer)
        }
        list[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(128 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(long))
        list[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(64 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(short))
        list[2] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(MemoryLayout<Float>.size),
            mData: nil)
        for slot in 0..<3 {
            bank.prepareTransitionImmediately(
                from: identity, to: halfLevel, slot: slot)
        }

        var shortTimeline: [Float] = []
        for cycle in 0..<15 {
            long.update(repeating: 1, count: 128)
            short.update(repeating: 1, count: 64)
            dormant[0] = 1
            if cycle == 8 {
                list[2].mData = UnsafeMutableRawPointer(dormant)
            }
            bank.process(list)
            for frame in 0..<64 {
                shortTimeline.append(short[frame])
            }
            if cycle == 8 {
                // Eight 128-frame callbacks are more than the 960-frame fade.
                // There was no dormant sample to click while it elapsed.
                #expect(abs(dormant[0] - 0.5) < 0.000_001)
            }
        }

        var greatestError: Float = 0
        for frame in 0..<bank.fadeFrames {
            let expected =
                1 - 0.5 * Float(frame) / Float(bank.fadeFrames - 1)
            greatestError = max(
                greatestError, abs(shortTimeline[frame] - expected))
        }
        #expect(greatestError < 0.000_001)

        long.update(repeating: 1, count: 128)
        short.update(repeating: 1, count: 64)
        bank.process(list)
        #expect((0..<128).allSatisfy { abs(long[$0] - 0.5) < 0.000_001 })
        #expect((0..<64).allSatisfy { abs(short[$0] - 0.5) < 0.000_001 })
    }

    @Test("stateful stereo correction never crosses channels")
    func stereoHistoryIsIndependent() throws {
        let bank = try #require(
            OutputCorrectionBank(sampleRate: 48_000, maximumFrames: 128))
        let stateful = try #require(
            OutputCorrectionBank.Configuration(
                coefficients: [0.5, 0.25, 0, -0.2, 0], preampGain: 1))
        #expect(bank.installImmediately(stateful, slot: 0))
        let bus = CorrectionTestBus(channelCounts: [2], frames: 128)
        bus.fill { _, frame, channel in frame == 0 && channel == 0 ? 1 : 0 }

        bank.process(bus.list)

        var greatestRight: Float = 0
        for frame in 0..<bus.frames {
            greatestRight = max(
                greatestRight, abs(bus.sample(frame: frame, channel: 1)))
        }
        #expect(greatestRight < 0.000_001)
        #expect(bus.sample(frame: 0, channel: 0) == 0.5)
        #expect(bus.sample(frame: 1, channel: 0) != 0)
    }

    @Test("live graph swaps share history without moving a correction to another bus")
    func graphSwapPreservesBankAndBusIdentity() throws {
        let old = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 1, destinationChannel: 0),
            ], bufferFrames: 128, sampleRate: 48_000)
        let next = RTGraph.allocate(
            routes: [
                // Route order changes, but output-buffer identity does not.
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 1, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0),
            ], bufferFrames: 128, sampleRate: 48_000)
        defer {
            RTGraph.deallocate(next)
            RTGraph.deallocate(old)
        }
        let oldBank = RTGraph.correctionBank(of: old)
        #expect(
            oldBank.installImmediately(
                OutputCorrectionBank.Configuration(
                    coefficients: [1, 0, 0, 0, 0], preampGain: 0.5),
                slot: 0))
        #expect(
            oldBank.installImmediately(
                OutputCorrectionBank.Configuration(
                    coefficients: [1, 0, 0, 0, 0], preampGain: 0.25),
                slot: 1))
        oldBank.setStateValue(0.375, slot: 0, index: 3)
        oldBank.setStateValue(0.625, slot: 1, index: 3)

        RTGraph.carryCorrections(from: old, to: next)

        let nextBank = RTGraph.correctionBank(of: next)
        #expect(nextBank === oldBank)
        #expect(nextBank.stateValue(slot: 0, index: 3) == 0.375)
        #expect(nextBank.stateValue(slot: 1, index: 3) == 0.625)
        let bus = CorrectionTestBus(channelCounts: [1, 1], frames: 128)
        bus.fill { _, _, _ in 1 }
        nextBank.process(bus.list)
        #expect(abs(bus.sample(slot: 0, frame: 0) - 0.5) < 0.000_001)
        #expect(abs(bus.sample(slot: 1, frame: 0) - 0.25) < 0.000_001)
    }

    @Test("settled response matches the published curve")
    func frequencyResponseMatchesCurve() throws {
        let rate = 48_000.0
        let curve = ParametricEQ(
            name: "measured", preampDecibels: -3,
            filters: [
                .init(kind: .lowShelf, hertz: 105, decibels: 4.5, q: 0.7),
                .init(kind: .peaking, hertz: 1_100, decibels: -5, q: 1.4),
                .init(kind: .highShelf, hertz: 8_000, decibels: 3, q: 0.8),
            ])
        let configuration = try #require(
            OutputCorrectionBank.Configuration(
                coefficients: curve.coefficients(sampleRate: rate),
                preampGain: pow(10, curve.preampDecibels / 20)))
        var greatestError: Float = 0

        for point in 0..<31 {
            let position = Double(point) / 30
            let hertz = Float(20 * pow(1_000, position))
            let bank = try #require(
                OutputCorrectionBank(sampleRate: rate, maximumFrames: 256))
            #expect(bank.installImmediately(configuration, slot: 0))
            let bus = CorrectionTestBus(channelCounts: [1], frames: 256)
            var phase = 0.0
            let step = 2 * Double.pi * Double(hertz) / rate
            var inputEnergy = 0.0
            var outputEnergy = 0.0

            for cycle in 0..<192 {
                var blockInputEnergy = 0.0
                bus.fill { _, _, _ in
                    let sample = Float(0.1 * sin(phase))
                    phase += step
                    blockInputEnergy += Double(sample * sample)
                    return sample
                }
                bank.process(bus.list)
                guard cycle >= 96 else { continue }
                inputEnergy += blockInputEnergy
                for frame in 0..<bus.frames {
                    let sample = bus.sample(frame: frame)
                    outputEnergy += Double(sample * sample)
                }
            }

            let measured = Float(
                10 * log10(outputEnergy / max(inputEnergy, Double.leastNonzeroMagnitude)))
            let expected = curve.response(atHertz: hertz, sampleRate: rate)
            greatestError = max(greatestError, abs(measured - expected))
        }

        #expect(greatestError <= 0.1)
    }

    @Test("SPSC publication becomes audible only through the handover")
    func publicationCompletesAtCycleBoundaries() throws {
        let bank = try #require(
            OutputCorrectionBank(sampleRate: 48_000, maximumFrames: 128))
        #expect(bank.installImmediately(identity, slot: 0))
        let bus = CorrectionTestBus(channelCounts: [1], frames: 128)
        let newConfiguration = halfLevel
        let publication = DispatchGroup()
        publication.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = bank.publish([0: newConfiguration])
            publication.leave()
        }

        var cycles = 0
        while publication.wait(timeout: .now()) != .success, cycles < 10_000 {
            bus.fill { _, _, _ in 1 }
            bank.process(bus.list)
            cycles += 1
            Thread.sleep(forTimeInterval: 0.000_1)
        }
        #expect(publication.wait(timeout: .now() + 1) == .success)

        bus.fill { _, _, _ in 1 }
        bank.process(bus.list)
        #expect((0..<bus.frames).allSatisfy { abs(bus.sample(frame: $0) - 0.5) < 0.000_001 })
        #expect(cycles >= Int(ceil(Double(bank.fadeFrames) / 128)))
    }

    @Test("maximum fixed storage stays below 190 kilobytes")
    func storageIsBounded() throws {
        let bank = try #require(
            OutputCorrectionBank(sampleRate: 48_000, maximumFrames: 4_096))
        #expect(bank.fixedStorageBytes == 188_160)
        #expect(bank.fixedStorageBytes < 190_000)
    }

    #if DEBUG
        @Test(
            "transition cost and allocation stay inside the release budget",
            .disabled("realtime cost evidence requires an optimised build"))
    #else
        @Test("transition cost and allocation stay inside the release budget")
    #endif
    func transitionPerformance() throws {
        func measure(slots: Int) throws -> (Double, UInt64) {
            let bank = try #require(
                OutputCorrectionBank(sampleRate: 48_000, maximumFrames: 128))
            var packed: [Float] = []
            for _ in 0..<OutputCorrectionBank.maximumStages {
                packed += [1.0009, -1.9781, 0.9781, -1.9781, 0.9790]
            }
            let old = try #require(
                OutputCorrectionBank.Configuration(
                    coefficients: packed, preampGain: 0.9))
            let new = try #require(
                OutputCorrectionBank.Configuration(
                    coefficients: packed, preampGain: 0.8))
            let bus = CorrectionTestBus(
                channelCounts: [Int](repeating: 2, count: slots), frames: 128)
            let cyclesPerFade = Int(ceil(Double(bank.fadeFrames) / 128))
            var elapsed: UInt64 = 0

            AllocationMeasurementLock.shared.lock()
            defer { AllocationMeasurementLock.shared.unlock() }
            RoutingEngine.enableAllocationTripwire()
            defer { RoutingEngine.disableAllocationTripwire() }
            let before = RoutingEngine.allocationViolations

            for _ in 0..<100 {
                for slot in 0..<slots {
                    bank.prepareTransitionImmediately(
                        from: old, to: new, slot: slot)
                }
                for cycle in 0..<cyclesPerFade {
                    bus.fill { slot, frame, channel in
                        let phase = Float(cycle * 128 + frame) * 0.05
                        let sample = 0.25 * sin(phase)
                        return channel == 0
                            ? sample * Float(slot + 1) / Float(slots)
                            : sample * 0.25
                    }
                    let started = DispatchTime.now().uptimeNanoseconds
                    yun_rt_tripwire_mark_realtime(true)
                    bank.process(bus.list)
                    yun_rt_tripwire_mark_realtime(false)
                    elapsed &+= DispatchTime.now().uptimeNanoseconds - started
                }
            }
            let cycles = 100 * cyclesPerFade
            return (
                Double(elapsed) / Double(cycles),
                RoutingEngine.allocationViolations - before
            )
        }

        let one = try measure(slots: 1)
        let eight = try measure(slots: 8)
        print(
            "output correction transition: one bus \(one.0) ns/cycle; "
                + "eight buses \(eight.0) ns/cycle; "
                + "\(one.1 + eight.1) realtime allocations")
        #expect(one.1 == 0)
        #expect(eight.1 == 0)
        #expect(one.0 < 25_000)
        #expect(eight.0 < 200_000)
    }
}
