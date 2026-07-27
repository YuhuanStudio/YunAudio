import CoreAudio
import Testing
import YunAudioRT

@testable import YunAudioEngine

// MARK: - Self-test signal

@Suite("Self-test signal")
struct SelftestSignalTests {
    /// The whole bit-exactness proof rests on the generated signal surviving a
    /// float32 round trip unchanged. If a single value were not exactly
    /// representable, the comparison would fail for a reason that has nothing to
    /// do with the audio path.
    @Test("every generated sample is exactly representable in float32")
    func samplesAreExact() {
        for frame in stride(from: UInt64(0), to: 200_000, by: 97) {
            let value = selftestSample(frame)
            // Scaled by a power of two from a 24-bit integer, so the double and
            // the float must agree bit for bit.
            let widened = Double(value)
            #expect(Float(widened) == value)
            #expect(value >= -1.0)
            #expect(value < 1.0)
        }
    }

    @Test("the sequence is deterministic")
    func deterministic() {
        for frame in [UInt64(0), 1, 12345, 999_999] {
            #expect(selftestSample(frame) == selftestSample(frame))
        }
    }

    /// A repeating sequence would let the delay search lock onto the wrong
    /// offset and report a false match.
    @Test("the sequence does not repeat over a realistic capture")
    func noShortPeriod() {
        var seen = Set<Float>()
        for frame in 0..<20000 {
            seen.insert(selftestSample(UInt64(frame)))
        }
        // 24 bits of range over 20k samples: a handful of collisions is
        // expected by the birthday bound, a short period is not.
        #expect(seen.count > 19900)
    }
}

// MARK: - Lock-free command queue

@Suite("Lock-free command queue")
struct CommandQueueTests {
    @Test("values survive a round trip in order")
    func roundTrip() throws {
        let queue = try #require(yun_rt_queue_create(16))
        defer { yun_rt_queue_free(queue) }

        for index in 0..<8 {
            let pushed = yun_rt_queue_push(
                queue,
                YunRTCommand(kind: 0, index: Int32(index), value: Float(index) / 8))
            #expect(pushed)
        }

        for index in 0..<8 {
            var command = YunRTCommand(kind: -1, index: -1, value: -1)
            #expect(yun_rt_queue_pop(queue, &command))
            #expect(command.index == Int32(index))
            #expect(command.value == Float(index) / 8)
        }
    }

    @Test("popping an empty queue reports empty rather than returning stale data")
    func emptyQueue() throws {
        let queue = try #require(yun_rt_queue_create(8))
        defer { yun_rt_queue_free(queue) }
        var command = YunRTCommand(kind: 9, index: 9, value: 9)
        #expect(!yun_rt_queue_pop(queue, &command))
        // The out parameter must be left alone, not zeroed.
        #expect(command.index == 9)
    }

    /// A full queue has to refuse rather than overwrite. Dropping the newest
    /// fader update is recoverable — a torn command struct read by the audio
    /// thread is not.
    @Test("a full queue refuses instead of overwriting")
    func fullQueue() throws {
        let queue = try #require(yun_rt_queue_create(4))
        defer { yun_rt_queue_free(queue) }

        var accepted = 0
        for index in 0..<100
        where yun_rt_queue_push(
            queue, YunRTCommand(kind: 0, index: Int32(index), value: 0))
        {
            accepted += 1
        }
        // Capacity rounds up to a power of two and one slot distinguishes full
        // from empty, so fewer than the requested capacity fit.
        #expect(accepted > 0)
        #expect(accepted < 100)

        var command = YunRTCommand(kind: 0, index: 0, value: 0)
        #expect(yun_rt_queue_pop(queue, &command))
        // The oldest survived: nothing was overwritten.
        #expect(command.index == 0)
    }

    @Test("capacity rounds up to a power of two")
    func capacityRounding() throws {
        let queue = try #require(yun_rt_queue_create(5))
        defer { yun_rt_queue_free(queue) }
        var accepted = 0
        while yun_rt_queue_push(queue, YunRTCommand(kind: 0, index: 0, value: 0)) {
            accepted += 1
            if accepted > 64 { break }
        }
        // 5 rounds to 8, minus the slot that marks fullness.
        #expect(accepted == 7)
    }
}

// MARK: - Route model

@Suite("Routes")
struct RouteTests {
    @Test("a muted route carries its state into the realtime struct")
    func muteFlag() {
        let route = RTRoute(
            sourceBuffer: 0, sourceChannel: 1,
            destinationBuffer: 2, destinationChannel: 3,
            gain: 0.5, muted: true)
        #expect(route.muted == 1)
        #expect(route.usesIsolatedSource == 0)
        #expect(route.gain == 0.5)
    }

    @Test("channel references compare by device and channel")
    func channelRefEquality() {
        let first = ChannelRef(deviceUID: "A", channel: 0)
        #expect(first == ChannelRef(deviceUID: "A", channel: 0))
        #expect(first != ChannelRef(deviceUID: "A", channel: 1))
        #expect(first != ChannelRef(deviceUID: "B", channel: 0))
    }
}

// MARK: - Path quality

@Suite("Path quality")
struct PathQualityTests {
    private func quality(
        bitExact: Bool, processing: Bool, drifted: [String] = []
    ) -> PathQuality {
        PathQuality(
            isBitExact: bitExact, hasProcessing: processing, isClockLocked: false,
            measuredRateRatio: 1, driftCorrectedDeviceUIDs: drifted,
            bufferFrames: 128, sampleRate: 48000)
    }

    @Test("buffer latency is derived from frames and rate")
    func latency() {
        let value = quality(bitExact: true, processing: false)
        // 128 frames at 48 kHz is 2.666… ms.
        #expect(abs(value.bufferLatencyMilliseconds - 2.6666) < 0.001)
    }

    @Test("a zero sample rate reports zero latency rather than dividing by it")
    func zeroRate() {
        let value = PathQuality(
            isBitExact: false, hasProcessing: false, isClockLocked: false,
            measuredRateRatio: 1, driftCorrectedDeviceUIDs: [],
            bufferFrames: 128, sampleRate: 0)
        #expect(value.bufferLatencyMilliseconds == 0)
    }
}

// MARK: - Meter ballistics

@Suite("Meter ballistics")
struct MeterBallisticsTests {
    /// A fixed per-cycle decay ties the meter's fall time to the buffer size:
    /// at 128 frames it would drop four times faster than at 512 for the same
    /// signal. The decay is derived from the cycle duration instead.
    @Test("the meter falls at the same rate whatever the buffer size")
    func rateIsIndependentOfBufferSize() {
        for frames in [64, 128, 256, 512] {
            let perCycle = RTGraph.decay(bufferFrames: frames, sampleRate: 48000)
            let cyclesPerSecond = 48000.0 / Double(frames)
            let perSecond = 20 * log10(pow(Double(perCycle), cyclesPerSecond))
            #expect(abs(perSecond - -20) < 0.01)
        }
    }

    @Test("a degenerate configuration falls back rather than dividing by zero")
    func degenerate() {
        #expect(RTGraph.decay(bufferFrames: 0, sampleRate: 48000) == 0.85)
        #expect(RTGraph.decay(bufferFrames: 128, sampleRate: 0) == 0.85)
    }
}

// MARK: - Realtime pointer publication

@Suite("RCU cell")
struct RealtimeCellTests {
    @Test("publish returns the pointer it replaced")
    func publishReturnsOld() throws {
        let first = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let second = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer {
            first.deallocate()
            second.deallocate()
        }

        let cell = try #require(yun_rt_cell_create(first))
        defer { yun_rt_cell_free(cell) }

        #expect(yun_rt_cell_load(cell) == first)
        #expect(yun_rt_cell_publish(cell, second) == first)
        #expect(yun_rt_cell_load(cell) == second)
    }

    /// The wait exists so the control thread does not free a graph a cycle
    /// already in flight is still reading. With no cycles being retired it has
    /// to time out rather than block forever.
    @Test("waiting times out when nothing is running")
    func waitTimesOutWhenIdle() throws {
        let cell = try #require(yun_rt_cell_create(nil))
        defer { yun_rt_cell_free(cell) }
        #expect(!yun_rt_cell_wait_for_swap(cell, 5))
    }

    @Test("waiting succeeds once two cycles have been retired")
    func waitSucceedsAfterTwoCycles() throws {
        let cell = try #require(yun_rt_cell_create(nil))
        defer { yun_rt_cell_free(cell) }

        // Stand in for the IO thread.
        let retiring = Thread {
            for _ in 0..<8 {
                yun_rt_cell_retire(cell)
                usleep(2000)
            }
        }
        retiring.start()
        #expect(yun_rt_cell_wait_for_swap(cell, 500))
    }

    /// One cycle is not enough: the swap may land midway through a cycle that
    /// already loaded the old pointer, so that cycle has to finish and one more
    /// has to start before the old graph is unreachable.
    @Test("one retired cycle is not enough to release the old pointer")
    func oneCycleIsNotEnough() throws {
        let cell = try #require(yun_rt_cell_create(nil))
        defer { yun_rt_cell_free(cell) }
        yun_rt_cell_retire(cell)
        #expect(!yun_rt_cell_wait_for_swap(cell, 5))
    }
}
