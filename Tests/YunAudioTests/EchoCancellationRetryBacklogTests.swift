import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Echo-cancellation retry backlog", .serialized)
struct EchoCancellationRetryBacklogTests {
    @Test("a stalled 750 ms start leaves the oldest third-second in the reference ring")
    func quantifiesUndrainedRetryBacklog() throws {
        let sampleRate = 48_000
        let ring = try #require(yun_rt_ring_create(UInt32(sampleRate / 4)))
        defer { yun_rt_ring_free(ring) }

        let attempted = (0..<(sampleRate * 3 / 4)).map { Float($0 + 1) }
        let written = attempted.withUnsafeBufferPointer {
            yun_rt_ring_write(ring, $0.baseAddress!, UInt32($0.count))
        }
        let available = yun_rt_ring_available(ring)
        let dropped = yun_rt_ring_dropped(ring)
        let staleMilliseconds = Double(available) / Double(sampleRate) * 1_000

        var first: Float = 0
        let read = yun_rt_ring_read(ring, &first, 1)

        print(
            "AEC retry backlog: \(available)f, \(staleMilliseconds) ms, "
                + "\(dropped) dropped")
        #expect(written == 16_383)
        #expect(available == 16_383)
        #expect(dropped == 19_617)
        #expect(abs(staleMilliseconds - 341.312_5) < 0.000_001)
        #expect(read == 1)
        #expect(first == 1)
    }

    @Test("every attempt drains stale reference before starting the unit")
    func retryDrainsBeforeStarting() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/EchoCancellationBridge.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "public func start() -> Bool"))
        let stop = try #require(
            source.range(of: "public func stop()", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<stop.lowerBound]

        #expect(body.contains("for _ in 0..<2"))
        #expect(body.contains("capture.stop()"))
        let drain = try #require(body.range(of: "discardBufferedFrames"))
        let startUnit = try #require(body.range(of: "capture.start"))
        #expect(drain.lowerBound < startUnit.lowerBound)
    }

    #if DEBUG
        @Test(
            "a bounded snapshot drain allocates nothing",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("a bounded snapshot drain allocates nothing")
    #endif
    func boundedDrainCost() throws {
        let sampleRate = 48_000
        let ring = try #require(yun_rt_ring_create(UInt32(sampleRate / 4)))
        defer { yun_rt_ring_free(ring) }
        var scratch = [Float](repeating: 0, count: 4_096)
        scratch.withUnsafeMutableBufferPointer {
            _ = FarEndCapture.discardBufferedFrames(
                from: ring, into: $0.baseAddress!, capacity: $0.count)
        }

        let samples = [Float](repeating: 0.25, count: sampleRate * 3 / 4)
        _ = samples.withUnsafeBufferPointer {
            yun_rt_ring_write(ring, $0.baseAddress!, UInt32($0.count))
        }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        let discarded = scratch.withUnsafeMutableBufferPointer { buffer in
            yun_rt_tripwire_mark_realtime(true)
            let count = FarEndCapture.discardBufferedFrames(
                from: ring, into: buffer.baseAddress!, capacity: buffer.count)
            yun_rt_tripwire_mark_realtime(false)
            return count
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before

        print(
            "AEC retry snapshot drain: \(discarded)f in \(elapsed) ns, "
                + "\(allocations) realtime allocations")
        #expect(discarded == 16_383)
        #expect(yun_rt_ring_available(ring) == 0)
        #expect(allocations == 0)
        #expect(elapsed < 1_000_000)

        var fresh: Float = 0.75
        let freshWritten = yun_rt_ring_write(ring, &fresh, 1)
        var firstAfterRetry: Float = 0
        let freshRead = yun_rt_ring_read(ring, &firstAfterRetry, 1)
        #expect(freshWritten == 1)
        #expect(freshRead == 1)
        #expect(firstAfterRetry == fresh)
    }
}
