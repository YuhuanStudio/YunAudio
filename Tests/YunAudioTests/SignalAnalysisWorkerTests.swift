import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Bounded signal analysis")
struct SignalAnalysisWorkerTests {
    private final class RateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []

        func append(_ value: Double) {
            lock.withLock { values.append(value) }
        }

        var last: Double? {
            lock.withLock { values.last }
        }
    }

    private final class BlockingSource: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseFirst = DispatchSemaphore(value: 0)
        private let firstSamples: [Float]
        private var calls = 0

        init(firstSamples: [Float] = []) {
            self.firstSamples = firstSamples
        }

        var callCount: Int {
            lock.withLock { calls }
        }

        func take(_ destination: UnsafeMutablePointer<Float>, capacity: Int) -> Int {
            let call = lock.withLock {
                calls += 1
                return calls
            }
            guard call == 1 else { return 0 }
            releaseFirst.wait()
            let count = min(capacity, firstSamples.count)
            firstSamples.withUnsafeBufferPointer {
                guard count > 0 else { return }
                destination.update(from: $0.baseAddress!, count: count)
            }
            return count
        }

        func release() {
            releaseFirst.signal()
        }
    }

    private final class RingSource: @unchecked Sendable {
        private let ring: OpaquePointer

        init?(capacity: UInt32) {
            guard let ring = yun_rt_ring_create(capacity) else { return nil }
            self.ring = ring
        }

        deinit {
            yun_rt_ring_free(ring)
        }

        func write(_ samples: [Float]) -> UInt32 {
            samples.withUnsafeBufferPointer {
                yun_rt_ring_write(ring, $0.baseAddress!, UInt32($0.count))
            }
        }

        func take(_ destination: UnsafeMutablePointer<Float>, capacity: Int) -> Int {
            guard let admittedCapacity = UInt32(exactly: capacity) else { return 0 }
            return Int(yun_rt_ring_read(ring, destination, admittedCapacity))
        }

        func statistics() -> SignalAnalysisWorker.RingStatistics {
            SignalAnalysisWorker.RingStatistics(
                isEnabled: true,
                written: yun_rt_ring_written(ring),
                available: yun_rt_ring_available(ring),
                dropped: yun_rt_ring_dropped(ring))
        }
    }

    @Test("an idle or released analyser retains no latest-only storage")
    func latestOnlyStorageFollowsDemand() {
        let analyser = SignalAnalyser(sampleRate: 48_000) { _ in nil }
        #expect(analyser.workingBufferBytes == 0)
        #expect(analyser.latestOnlyStorageBytes == 0)

        analyser.require(.spectrum)
        #expect(analyser.workingBufferBytes == 98_304)
        #expect(
            analyser.latestOnlyStorageBytes
                >= analyser.latestBufferLimitFrames * MemoryLayout<Float>.stride)

        analyser.require([])
        #expect(analyser.workingBufferBytes == 0)
        #expect(analyser.latestOnlyStorageBytes == 0)
    }

    @Test("unsupported analyser rates use one bounded fallback configuration")
    func invalidRateFallback() {
        let unsupported = [
            -Double.infinity, -1, 0, 7_999, 384_001, Double.infinity, Double.nan,
        ]
        for rate in unsupported {
            var classifierRate: Double?
            let analyser = SignalAnalyser(sampleRate: rate) { receivedRate in
                classifierRate = receivedRate
                return nil
            }
            analyser.require([.classification, .loudness])
            analyser.addForTesting([Float](repeating: 0, count: 480))

            #expect(classifierRate == SignalAnalyser.fallbackSampleRate)
            #expect(analyser.latestBufferLimitFrames == 24_000)
            #expect(analyser.reading().duration == 0.01)
        }

        #expect(SignalAnalyser(sampleRate: 8_000) { _ in nil }.latestBufferLimitFrames == 4_000)
        #expect(
            SignalAnalyser(sampleRate: 384_000) { _ in nil }.latestBufferLimitFrames
                == 192_000)
    }

    @Test("the worker normalises an unsupported rate before construction")
    func workerNormalisesRate() async throws {
        let rates = RateRecorder()
        let worker = SignalAnalysisWorker(
            label: "yunaudio.test.analysis-rate",
            drain: { _, _ in 0 },
            makeAnalyser: { rate in
                rates.append(rate)
                return SignalAnalyser(sampleRate: rate) { _ in nil }
            })
        worker.activate(sampleRate: .infinity)

        for _ in 0..<1_000 where rates.last == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(rates.last == SignalAnalyser.fallbackSampleRate)
    }

    @Test("ring overflow is visible beside the otherwise lossless reading")
    func ringOverflowIsObservable() async throws {
        let source = try #require(RingSource(capacity: 600))
        let attempted = [Float](repeating: 0.25, count: 2_000)
        #expect(source.write(attempted) == 1_023)

        let worker = SignalAnalysisWorker(
            label: "yunaudio.test.analysis-overflow",
            drain: source.take,
            ringStatistics: source.statistics,
            makeAnalyser: { rate in
                SignalAnalyser(sampleRate: rate) { _ in nil }
            })
        worker.activate(sampleRate: 48_000)
        worker.require(.loudness)
        worker.requestDrain()

        for _ in 0..<1_000 where worker.telemetry.pendingDrains != 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let snapshot = worker.snapshot
        let telemetry = worker.telemetry
        #expect(snapshot.statistics.loudnessSamples == 1_023)
        #expect(snapshot.ring.written == 1_023)
        #expect(snapshot.ring.available == 0)
        #expect(snapshot.ring.dropped == 977)
        #expect(telemetry.ringDroppedSamples == 977)
        #expect(telemetry.maximumRingDroppedSamples == 977)
    }

    @Test("deactivation rejects a reading completed by an obsolete lifetime")
    func deactivateInvalidatesInFlightDrain() async throws {
        let source = BlockingSource(firstSamples: [Float](repeating: 0.5, count: 4_800))
        let worker = SignalAnalysisWorker(
            label: "yunaudio.test.analysis-deactivate",
            drain: source.take,
            makeAnalyser: { rate in
                SignalAnalyser(sampleRate: rate) { _ in nil }
            })
        worker.activate(sampleRate: 48_000)
        worker.require(.loudness)
        worker.requestDrain()

        for _ in 0..<1_000 where source.callCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(source.callCount == 1)
        worker.deactivate()
        let invalidatedGeneration = worker.snapshot.generation
        source.release()

        for _ in 0..<1_000 where worker.telemetry.scheduledTurns != 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let snapshot = worker.snapshot
        #expect(snapshot.generation >= invalidatedGeneration)
        #expect(snapshot.reading.duration == 0)
        #expect(snapshot.statistics.loudnessSamples == 0)
        #expect(!snapshot.hearsSpeech)
    }

    @Test("reset rejects samples from a drain which crossed the reset boundary")
    func resetInvalidatesInFlightDrain() async throws {
        let source = BlockingSource(firstSamples: [Float](repeating: 0.5, count: 4_800))
        let worker = SignalAnalysisWorker(
            label: "yunaudio.test.analysis-reset",
            drain: source.take,
            makeAnalyser: { rate in
                SignalAnalyser(sampleRate: rate) { _ in nil }
            })
        worker.activate(sampleRate: 48_000)
        worker.require(.loudness)
        worker.requestDrain()

        for _ in 0..<1_000 where source.callCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(source.callCount == 1)
        worker.reset()
        let invalidatedGeneration = worker.snapshot.generation
        source.release()

        for _ in 0..<1_000 where worker.telemetry.scheduledTurns != 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let snapshot = worker.snapshot
        #expect(snapshot.generation > invalidatedGeneration)
        #expect(snapshot.reading.duration == 0)
        #expect(snapshot.statistics.loudnessSamples == 0)
        #expect(worker.telemetry.completedDrains == 1)
    }

    @Test("retained backlog is lossless for loudness and latest-only for transforms")
    func semanticBacklogPolicy() {
        let sampleRate = 48_000.0
        let sampleCount = SignalAnalyser.workingBufferFrames * 3 + 1_234
        let samples = (0..<sampleCount).map { index in
            let amplitude = index < sampleCount / 2 ? 0.16 : 0.42
            return Float(amplitude * sin(2 * Double.pi * 440 * Double(index) / sampleRate))
        }

        var reference = LoudnessMeter(sampleRate: sampleRate)!
        samples.withUnsafeBufferPointer {
            reference.add($0.baseAddress!, count: $0.count)
        }

        let analyser = SignalAnalyser(sampleRate: sampleRate) { _ in nil }
        analyser.require([.loudness, .spectrum, .pitch])
        var offset = 0
        while true {
            let progress = analyser.drainStep { destination, capacity in
                let count = min(capacity, samples.count - offset)
                if count > 0 {
                    samples.withUnsafeBufferPointer {
                        destination.update(
                            from: $0.baseAddress!.advanced(by: offset), count: count)
                    }
                    offset += count
                }
                return count
            }
            if progress.isDrained { break }
        }

        let reading = analyser.reading()
        let statistics = analyser.statistics
        #expect(offset == sampleCount)
        #expect(statistics.loudnessSamples == sampleCount)
        #expect(
            statistics.coalescedLatestSamples
                == sampleCount - analyser.latestBufferLimitFrames)
        #expect(statistics.latestBatches == 1)
        #expect(statistics.spectrumSamples == SpectrumAnalyser.windowSize)
        #expect(statistics.pitchFrames == 1)
        #expect(reading.duration == Double(sampleCount) / sampleRate)
        #expect(reading.momentary == reference.momentary)
        #expect(reading.shortTerm == reference.shortTerm)
        #expect(reading.integrated == reference.integrated)
        #expect(reading.range == reference.range)
        #expect(reading.peak == reference.peak)
    }

    @Test("ten thousand polls retain one drain and one scheduled turn")
    func pollingBurstIsBounded() async throws {
        let source = BlockingSource()
        let worker = SignalAnalysisWorker(
            label: "yunaudio.test.analysis-bound",
            drain: source.take,
            makeAnalyser: { rate in
                SignalAnalyser(sampleRate: rate) { _ in nil }
            })
        worker.activate(sampleRate: 48_000)
        worker.require(.loudness)
        worker.requestDrain()

        for _ in 0..<1_000 where source.callCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(source.callCount == 1)

        for _ in 1..<10_000 { worker.requestDrain() }
        let blocked = worker.telemetry
        #expect(blocked.drainRequests == 10_000)
        #expect(blocked.coalescedDrainRequests == 9_999)
        #expect(blocked.pendingDrains == 1)
        #expect(blocked.maximumPendingDrains == 1)
        #expect(blocked.scheduledTurns == 1)
        #expect(blocked.maximumScheduledTurns == 1)

        source.release()
        for _ in 0..<1_000 where worker.telemetry.pendingDrains != 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let finished = worker.telemetry
        #expect(finished.pendingDrains == 0)
        #expect(finished.scheduledTurns == 0)
        // The request sequence changed during the first read, so one final
        // short read proves the coalesced tail was not accidentally lost.
        #expect(finished.drainSteps == 2)
        #expect(finished.completedDrains == 1)
        #expect(finished.mainThreadTurns == 0)
    }

    @MainActor
    @Test("a blocked analyser cannot stop MainActor heartbeats")
    func mainActorRemainsResponsive() async throws {
        let source = BlockingSource()
        let worker = SignalAnalysisWorker(
            label: "yunaudio.test.analysis-main-heartbeat",
            drain: source.take,
            makeAnalyser: { rate in
                SignalAnalyser(sampleRate: rate) { _ in nil }
            })
        worker.activate(sampleRate: 48_000)
        worker.require(.loudness)
        worker.requestDrain()

        for _ in 0..<1_000 where source.callCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(source.callCount == 1)

        var heartbeats = 0
        for _ in 0..<100 {
            heartbeats += 1
            await Task.yield()
        }
        #expect(heartbeats == 100)
        #expect(worker.telemetry.pendingDrains == 1)
        #expect(worker.telemetry.mainThreadTurns == 0)

        source.release()
        for _ in 0..<1_000 where worker.telemetry.pendingDrains != 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(worker.telemetry.pendingDrains == 0)
    }
}
