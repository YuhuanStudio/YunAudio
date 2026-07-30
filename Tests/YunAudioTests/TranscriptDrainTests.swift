import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

@Suite("Transcript drain")
struct TranscriptDrainTests {
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
