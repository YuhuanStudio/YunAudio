import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

/// Whether the analyser hand-off actually keeps up with a realtime producer.
///
/// The flow check has been reporting `1.14s measured over 2.0s of wall clock`
/// on a virtual machine — forty-three per cent of the audio never reaching the
/// meter — and the note beside it says only that. Nothing distinguished the two
/// things it could mean: the ring overflowing because nobody drained it, or the
/// drain running and the meter not counting what it received.
///
/// This reproduces the same measurement without a device: the shipping ring
/// size, a producer writing at 48 kHz in IOProc-sized blocks, and the worker
/// driven at the twenty hertz the interface polls it at.
@Suite("The analyser keeps up with the audio", .serialized)
struct AnalyserKeepsUpTests {

    /// What the running route allocates, so the answer is about the real one.
    private static let ringCapacity: UInt32 = 131_072
    private static let sampleRate = 48_000.0
    private static let blockFrames = 512
    private static let seconds = 2.0

    /// The ring, carried across the worker's lanes.
    ///
    /// `OpaquePointer` is not `Sendable` and the drain closure has to be, which
    /// is the same crossing the running route makes: one owner allocates it,
    /// the IO thread writes it, the analysis lane reads it, and the ring itself
    /// is what makes that safe.
    private struct Ring: @unchecked Sendable {
        let storage: OpaquePointer
    }

    /// A producer thread writing at wall-clock rate, as an IOProc does.
    private final class Producer: @unchecked Sendable {
        let ring: OpaquePointer
        private var stopped = false
        private let lock = NSLock()

        init(ring: OpaquePointer) { self.ring = ring }

        func stop() { lock.withLock { stopped = true } }
        private var isStopped: Bool { lock.withLock { stopped } }

        func run(for seconds: Double, rate: Double, blockFrames: Int) {
            // A tone rather than silence: the loudness meter counts every frame
            // it is given either way, but a silent fixture could not tell a
            // meter that dropped frames from one that read them as quiet.
            var phase = 0.0
            let increment = 2 * Double.pi * 440 / rate
            var block = [Float](repeating: 0, count: blockFrames)
            let blockSeconds = Double(blockFrames) / rate
            let start = DispatchTime.now().uptimeNanoseconds
            var written = 0
            let wanted = Int(seconds * rate)
            while written < wanted, !isStopped {
                for index in block.indices {
                    block[index] = Float(sin(phase)) * 0.5
                    phase += increment
                }
                _ = block.withUnsafeBufferPointer {
                    yun_rt_ring_write(ring, $0.baseAddress!, UInt32(blockFrames))
                }
                written += blockFrames
                // Paced against the start rather than by sleeping a block at a
                // time, so a slow iteration does not push the whole run late
                // and understate what the drain had to keep up with.
                let due = start + UInt64(Double(written) / rate * 1_000_000_000)
                let now = DispatchTime.now().uptimeNanoseconds
                if due > now {
                    Thread.sleep(forTimeInterval: Double(due - now) / 1_000_000_000)
                }
                _ = blockSeconds
            }
        }
    }

    @Test("two seconds in, two seconds measured")
    func measuredTimeTracksWallClock() throws {
        let ring = try #require(yun_rt_ring_create(Self.ringCapacity))
        defer { yun_rt_ring_free(ring) }

        let shared = Ring(storage: ring)
        let worker = SignalAnalysisWorker(
            drain: { destination, capacity in
                guard let bounded = UInt32(exactly: capacity) else { return 0 }
                return Int(yun_rt_ring_read(shared.storage, destination, bounded))
            },
            ringStatistics: {
                .init(
                    isEnabled: true,
                    written: yun_rt_ring_written(shared.storage),
                    available: yun_rt_ring_available(shared.storage),
                    dropped: yun_rt_ring_dropped(shared.storage))
            })
        worker.activate(sampleRate: Self.sampleRate)
        worker.require(.loudness)

        let producer = Producer(ring: ring)
        let producing = Thread {
            producer.run(
                for: Self.seconds, rate: Self.sampleRate, blockFrames: Self.blockFrames)
        }
        producing.start()

        // The cadence the interface actually polls at. Anything faster would
        // measure a drain nobody performs in the product.
        let pollInterval = 0.05
        let deadline = Date().addingTimeInterval(Self.seconds + 0.5)
        while Date() < deadline {
            worker.requestDrain()
            Thread.sleep(forTimeInterval: pollInterval)
        }
        producer.stop()

        // One last chance to catch up, since the final blocks were written
        // after the last poll.
        for _ in 0..<20 {
            worker.requestDrain()
            Thread.sleep(forTimeInterval: pollInterval)
        }

        let measured = worker.snapshot.reading.duration
        let dropped = yun_rt_ring_dropped(ring)
        let produced = Double(yun_rt_ring_written(ring)) / Self.sampleRate
        print(
            String(
                format:
                    "analyser: %.2fs measured of %.2fs produced, %llu dropped, %llu still in the ring",
                measured, produced, dropped, UInt64(yun_rt_ring_available(ring))))

        // The claim the flow check makes, stated the same way.
        #expect(dropped == 0)
        #expect(measured > produced - 0.2)
        worker.deactivate()
    }
}
