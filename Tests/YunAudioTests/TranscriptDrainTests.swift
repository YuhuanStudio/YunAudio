import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Transcript drain")
struct TranscriptDrainTests {
    @Test("tap route admission stops at the first invalid or duplicate request")
    func tapRoutesAreAStrictPrefix() {
        let output = ChannelRef(deviceUID: "output", channel: 0)
        let keys = (0..<4).map { index in
            RouteOccurrenceKey(
                source: ChannelRef(deviceUID: "source-\(index)", channel: 0),
                destination: output, occurrence: 0)
        }

        #expect(
            RoutingEngine.transcriptTapRoutePrefix(
                routes: [0, 1, 9, 2], activeRouteKeys: keys, maximumCount: 4)
                == [0, 1])
        #expect(
            RoutingEngine.transcriptTapRoutePrefix(
                routes: [0, 1, 1, 2], activeRouteKeys: keys, maximumCount: 4)
                == [0, 1])
        #expect(
            RoutingEngine.transcriptTapRoutePrefix(
                routes: [0, 1, 2, 3], activeRouteKeys: keys, maximumCount: 2)
                == [0, 1])
    }

    @Test("per-slot telemetry reports exact fill and overflow without consuming audio")
    func tapStatisticsAreNumeric() throws {
        let engine = RoutingEngine()
        let ring = try #require(yun_rt_ring_create(1_024))
        let first = [Float](repeating: 0.25, count: 700)
        let second = [Float](repeating: -0.5, count: 500)

        let firstWritten = first.withUnsafeBufferPointer {
            yun_rt_ring_write(ring, $0.baseAddress!, UInt32($0.count))
        }
        let secondWritten = second.withUnsafeBufferPointer {
            yun_rt_ring_write(ring, $0.baseAddress!, UInt32($0.count))
        }
        #expect(firstWritten == 700)
        #expect(secondWritten == 323)
        engine.installTranscriptRingForTesting(ring)

        let full = try #require(engine.transcriptTapStatistics(at: 0))
        #expect(full.available == 1_023)
        #expect(full.dropped == 177)
        #expect(engine.transcriptTapStatistics(at: -1) == nil)
        #expect(engine.transcriptTapStatistics(at: 1) == nil)

        var output = [Float](repeating: 0, count: 100)
        let drained = output.withUnsafeMutableBufferPointer { buffer in
            engine.drainTranscript(0, into: buffer.baseAddress!, capacity: buffer.count)
        }
        let afterDrain = try #require(engine.transcriptTapStatistics(at: 0))
        #expect(drained == 100)
        #expect(afterDrain.available == 923)
        #expect(afterDrain.dropped == 177)
    }

    @Test("per-slot telemetry returns unavailable within five milliseconds under contention")
    func tapStatisticsDoNotWaitForEngineState() throws {
        let engine = RoutingEngine()
        let ring = try #require(yun_rt_ring_create(1_024))
        let samples = [Float](repeating: 0.125, count: 257)
        let written = samples.withUnsafeBufferPointer {
            yun_rt_ring_write(ring, $0.baseAddress!, UInt32($0.count))
        }
        #expect(written == 257)
        engine.installTranscriptRingForTesting(ring)

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            engine.withStateLockForTesting {
                entered.signal()
                release.wait()
            }
            finished.signal()
        }
        #expect(entered.wait(timeout: .now() + 1) == .success)

        let started = DispatchTime.now().uptimeNanoseconds
        let unavailable = engine.transcriptTapStatistics(at: 0)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        #expect(unavailable == nil)
        #expect(elapsed < 5_000_000)
        #expect(yun_rt_ring_available(ring) == 257)
        #expect(yun_rt_ring_dropped(ring) == 0)

        release.signal()
        #expect(finished.wait(timeout: .now() + 1) == .success)
        let recovered = try #require(engine.transcriptTapStatistics(at: 0))
        #expect(recovered.available == 257)
        #expect(recovered.dropped == 0)
    }

    @Test("stem telemetry returns a nonblocking unavailable snapshot under contention")
    func stemSnapshotDoesNotWaitForEngineState() {
        let lock = NSRecursiveLock()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            lock.lock()
            entered.signal()
            release.wait()
            lock.unlock()
            finished.signal()
        }
        #expect(entered.wait(timeout: .now() + 1) == .success)

        var readWasCalled = false
        let contended = RoutingEngine.withStemSnapshotLock(lock) {
            readWasCalled = true
            return 73
        }
        #expect(contended == 0)
        #expect(!readWasCalled)

        release.signal()
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(RoutingEngine.withStemSnapshotLock(lock) { 73 } == 73)
    }

    @Test("lock contention returns immediately without consuming audio")
    func contentionKeepsTheRing() throws {
        let engine = RoutingEngine()
        let ring = try #require(yun_rt_ring_create(512))

        let samples = (0..<257).map { index in
            Float((index * 37) % 257) / 257 - 0.5
        }
        let written = samples.withUnsafeBufferPointer {
            yun_rt_ring_write(ring, $0.baseAddress!, UInt32($0.count))
        }
        #expect(Int(written) == samples.count)
        engine.installTranscriptRingForTesting(ring)

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            engine.withStateLockForTesting {
                entered.signal()
                release.wait()
            }
            finished.signal()
        }
        #expect(entered.wait(timeout: .now() + 1) == .success)

        var output = [Float](repeating: .nan, count: samples.count)
        let started = DispatchTime.now().uptimeNanoseconds
        let blockedRead = output.withUnsafeMutableBufferPointer { buffer in
            engine.drainTranscript(0, into: buffer.baseAddress!, capacity: buffer.count)
        }
        let blockedNanoseconds = DispatchTime.now().uptimeNanoseconds - started

        #expect(blockedRead == 0)
        #expect(blockedNanoseconds < 5_000_000)
        #expect(Int(yun_rt_ring_available(ring)) == samples.count)

        release.signal()
        #expect(finished.wait(timeout: .now() + 1) == .success)

        let recoveredRead = output.withUnsafeMutableBufferPointer { buffer in
            engine.drainTranscript(0, into: buffer.baseAddress!, capacity: buffer.count)
        }
        let expectedChecksum = zip(samples.indices, samples).reduce(0.0) {
            $0 + Double($1.0 + 1) * Double($1.1)
        }
        let recoveredChecksum = zip(output.indices, output).reduce(0.0) {
            $0 + Double($1.0 + 1) * Double($1.1)
        }

        print(
            "contended transcript drain: \(blockedNanoseconds) ns; "
                + "recovered \(recoveredRead) samples; checksum \(recoveredChecksum)")
        #expect(recoveredRead == samples.count)
        #expect(output == samples)
        #expect(recoveredChecksum == expectedChecksum)
        #expect(yun_rt_ring_available(ring) == 0)
    }
}
