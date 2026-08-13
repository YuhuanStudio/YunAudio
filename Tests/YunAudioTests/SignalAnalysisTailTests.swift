import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Signal analysis latest-tail storage", .serialized)
struct SignalAnalysisTailTests {
    private final class BacklogSource {
        private let samples: [Float]
        private var offset = 0

        init(samples: [Float]) {
            self.samples = samples
        }

        func rewind() {
            offset = 0
        }

        func take(_ destination: UnsafeMutablePointer<Float>, capacity: Int) -> Int {
            let count = min(capacity, samples.count - offset)
            samples.withUnsafeBufferPointer { source in
                if count > 0 {
                    destination.update(from: source.baseAddress! + offset, count: count)
                }
            }
            offset += count
            return count
        }
    }

    @Test("wrapped writes retain the exact chronological suffix")
    func wrappedChronology() {
        var tail = SignalAnalysisTail()
        tail.allocate(capacity: 8)
        let first = (0..<6).map(Float.init)
        let second = (6..<11).map(Float.init)

        first.withUnsafeBufferPointer {
            #expect(tail.append($0.baseAddress!, count: $0.count) == 0)
        }
        second.withUnsafeBufferPointer {
            #expect(tail.append($0.baseAddress!, count: $0.count) == 3)
        }

        var retained = [Float](repeating: -1, count: 8)
        retained.withUnsafeMutableBufferPointer { tail.copyAll(into: $0.baseAddress!) }
        #expect(retained == (3..<11).map(Float.init))

        var suffix: [Float] = []
        tail.forEachSuffix(count: 3) { samples, count in
            suffix.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        }
        #expect(suffix == [8, 9, 10])
    }

    @Test("an oversized write replaces history without growing storage")
    func oversizedWrite() {
        var tail = SignalAnalysisTail()
        tail.allocate(capacity: 8)
        let old = [Float](repeating: -1, count: 8)
        let incoming = (20..<30).map(Float.init)
        old.withUnsafeBufferPointer {
            #expect(tail.append($0.baseAddress!, count: $0.count) == 0)
        }
        let bytes = tail.storageBytes
        incoming.withUnsafeBufferPointer {
            #expect(tail.append($0.baseAddress!, count: $0.count) == 10)
        }

        var retained = [Float](repeating: 0, count: 8)
        retained.withUnsafeMutableBufferPointer { tail.copyAll(into: $0.baseAddress!) }
        #expect(retained == (22..<30).map(Float.init))
        #expect(tail.storageBytes == bytes)
        #expect(tail.count == 8)
    }

    @Test("pitch consumes one newest frame after a wrapped backlog")
    func pitchUsesOneNewestFrame() {
        let sampleRate = 48_000.0
        let sampleCount = SignalAnalyser.workingBufferFrames * 2 + 2_731
        let samples = (0..<sampleCount).map { index in
            Float(0.6 * sin(2 * .pi * 220 * Double(index) / sampleRate))
        }
        let analyser = SignalAnalyser(sampleRate: sampleRate) { _ in nil }
        analyser.require(.pitch)

        var offset = 0
        while true {
            let progress = analyser.drainStep { destination, capacity in
                let count = min(capacity, samples.count - offset)
                samples.withUnsafeBufferPointer { source in
                    if count > 0 {
                        destination.update(from: source.baseAddress! + offset, count: count)
                    }
                }
                offset += count
                return count
            }
            if progress.isDrained { break }
        }

        #expect(analyser.statistics.pitchFrames == 1)
        #expect(
            analyser.statistics.coalescedLatestSamples
                == sampleCount - analyser.latestBufferLimitFrames)
        #expect(abs(analyser.reading().pitchHertz - 220) < 1)
    }

    #if DEBUG
        @Test(
            "twenty thousand full-tail evictions allocate nothing",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("twenty thousand full-tail evictions allocate nothing")
    #endif
    func steadyStateEvictionCost() {
        let capacity = 24_000
        let iterations = 20_000
        let chunk = [Float](repeating: 0.25, count: 257)
        let initial = [Float](repeating: -0.5, count: capacity)
        var tail = SignalAnalysisTail()
        tail.allocate(capacity: capacity)
        initial.withUnsafeBufferPointer {
            _ = tail.append($0.baseAddress!, count: $0.count)
        }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        var discarded = 0
        chunk.withUnsafeBufferPointer { input in
            yun_rt_tripwire_mark_realtime(true)
            for _ in 0..<iterations {
                discarded += tail.append(input.baseAddress!, count: input.count)
            }
            yun_rt_tripwire_mark_realtime(false)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before

        print(
            "20,000 latest-tail evictions: \(elapsed) ns, \(allocations) allocations, "
                + "\(discarded) discarded samples")
        #expect(discarded == iterations * chunk.count)
        #expect(tail.count == capacity)
        #expect(tail.storageBytes == capacity * MemoryLayout<Float>.stride)
        #expect(allocations == 0)
        #expect(elapsed < 250_000_000)
    }

    #if DEBUG
        @Test(
            "one hundred analyser backlogs allocate nothing",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("one hundred analyser backlogs allocate nothing")
    #endif
    func steadyStateAnalyserBacklogs() {
        let iterations = 100
        let sampleRate = 48_000.0
        let sampleCount = SignalAnalyser.workingBufferFrames * 3 + 1_357
        let samples = (0..<sampleCount).map { index in
            Float(0.5 * sin(2 * .pi * 220 * Double(index) / sampleRate))
        }
        let analyser = SignalAnalyser(sampleRate: sampleRate) { _ in nil }
        analyser.require([.spectrum, .pitch])
        let source = BacklogSource(samples: samples)
        let take = source.take

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        // Warm both the transforms and the tripwire's fixed thread registry.
        // Marks made before enabling are deliberately ignored, so this belongs
        // after the hook is installed and before the baseline is sampled.
        yun_rt_tripwire_mark_realtime(true)
        source.rewind()
        while !analyser.drainStep(take).isDrained {}
        yun_rt_tripwire_mark_realtime(false)
        analyser.reset()
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        for _ in 0..<iterations {
            source.rewind()
            while !analyser.drainStep(take).isDrained {}
        }
        yun_rt_tripwire_mark_realtime(false)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before

        print(
            "100 analyser backlogs: \(elapsed) ns, \(allocations) allocations, "
                + "\(analyser.statistics.coalescedLatestSamples) coalesced samples")
        #expect(
            analyser.statistics.coalescedLatestSamples
                == iterations * (sampleCount - analyser.latestBufferLimitFrames))
        #expect(analyser.statistics.pitchFrames == iterations)
        #expect(analyser.statistics.latestBatches == iterations)
        #expect(allocations == 0)
        #expect(elapsed < 500_000_000)
    }
}
