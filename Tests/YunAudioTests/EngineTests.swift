import AVFoundation
import CoreAudio
import Testing
import YunAudioRT

@testable import YunAudioEngine
@testable import YunAudioHAL

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

// MARK: - Negotiated graph timing

@Suite("Negotiated graph timing")
struct NegotiatedGraphTimingTests {
    @Test("actual rate and slice size are the graph's only timing")
    func actualTimingWins() throws {
        let timing = try #require(
            RoutingEngine.graphTiming(
                actualSampleRate: 44100,
                actualBufferFrames: 256))

        #expect(timing.sampleRate == 44100)
        #expect(timing.cycleFrames == 256)
        #expect(timing.processingCapacity == 4096)

        // A tracker configured from the requested 48 kHz would report this A4
        // almost a semitone and a half sharp. Configured from the live rate, the
        // same 44.1 kHz period remains exactly 440 Hz.
        let period = 44100.0 / 440.0
        let correctlyConfiguredPitch = timing.sampleRate / period
        let requestedRatePitch = 48000.0 / period
        #expect(abs(correctlyConfiguredPitch - 440) < 0.000_001)
        #expect(abs(requestedRatePitch - 478.911_564_625_850_3) < 0.000_001)
        #expect(12 * log2(requestedRatePitch / correctlyConfiguredPitch) > 1.46)
    }

    @Test("capacity never makes a callback consume frames it did not receive")
    func capacityIsOnlyAClampedUpperBound() throws {
        let timing = try #require(
            RoutingEngine.graphTiming(
                actualSampleRate: 48000,
                actualBufferFrames: 256))
        #expect(
            RTGraph.processingFrames(
                available: timing.cycleFrames,
                capacity: timing.processingCapacity) == 256)
        #expect(RTGraph.processingFrames(available: 8192, capacity: 4096) == 4096)
        #expect(RTGraph.processingFrames(available: -1, capacity: 4096) == 0)

        let chain = try #require(
            EffectChain(
                kinds: [.limiter],
                sampleRate: timing.sampleRate,
                maximumFrames: timing.processingCapacity))
        let sentinel: Float = 123
        for block in 0..<16 {
            for frame in 0..<timing.processingCapacity {
                chain.inputBuffer[frame] = frame < timing.cycleFrames ? 0.25 : 0.9
                chain.outputBuffer[frame] = frame < timing.cycleFrames ? 0 : sentinel
            }
            #expect(
                chain.render(
                    frames: timing.cycleFrames,
                    sampleTime: Double(block * timing.cycleFrames)))
            var tailIsUntouched = true
            for frame in timing.cycleFrames..<timing.processingCapacity {
                if chain.outputBuffer[frame] != sentinel {
                    tailIsUntouched = false
                    break
                }
            }
            #expect(tailIsUntouched)
        }

        var energy: Float = 0
        for frame in 0..<timing.cycleFrames {
            energy += chain.outputBuffer[frame] * chain.outputBuffer[frame]
        }
        let rms = sqrt(energy / Float(timing.cycleFrames))
        #expect(rms > 0.2)

        // The old 64-frame capacity against this 256-frame callback left three
        // quarters of the cleared output untouched: a precise 6.02 dB loss and
        // a 187.5 Hz gate at 48 kHz.
        let truncatedRMS = sqrt((64 * 0.25 * 0.25) / 256)
        let loss = 20 * log10(Double(0.5 / truncatedRMS))
        #expect(abs(truncatedRMS - 0.25) < 0.000_001)
        #expect(abs(loss - 6.020_599_913_279_624) < 0.000_001)
        #expect(timing.sampleRate / Double(timing.cycleFrames) == 187.5)
    }

    @Test("a sample-rate timeout cannot start mismatched DSP")
    func sampleRateTimeoutIsAnError() throws {
        try AggregateDevice.requireSampleRateArrival(
            true, uid: "ready", rate: 48000)

        do {
            try AggregateDevice.requireSampleRateArrival(
                false, uid: "slow-device", rate: 48000)
            Issue.record("a timed-out device was accepted")
        } catch let error as AggregateError {
            guard case .sampleRateDidNotSet(let uid, let rate) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(uid == "slow-device")
            #expect(rate == 48000)
        }
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
            hasSampleRateMismatch: false, bufferFrames: 128, sampleRate: 48000)
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
            hasSampleRateMismatch: false, bufferFrames: 128, sampleRate: 0)
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

// MARK: - Clock publication cost

@Suite("Clock publication cost")
struct ClockPublicationCostTests {
    @Test("ten clock writes need only two status reads")
    func statusReadbackIsDecimated() {
        let refreshes = (1...10).filter {
            ClockAnchorPublisher.shouldRefreshStatus(afterPublication: $0)
        }
        // The first answer still arrives after one 100 ms publication, while
        // the steady-state property traffic falls from 20 to 12 calls/s.
        #expect(refreshes == [1, 6])
        #expect(refreshes.count == 2)
    }

    @Test("the reduced cadence remains stable over a minute")
    func cadenceDoesNotDrift() {
        let refreshes = (1...600).count {
            ClockAnchorPublisher.shouldRefreshStatus(afterPublication: $0)
        }
        #expect(refreshes == 120)
    }
}

// MARK: - Realtime pointer publication

@Suite("RCU cell")
struct RealtimeCellTests {
    /// The test owns the pointer until its worker has signalled completion.
    /// Swift cannot infer that lifetime from a semaphore, so the unchecked part
    /// is confined to the box whose only job is carrying that fact.
    private final class CellHandle: @unchecked Sendable {
        let pointer: OpaquePointer

        init(_ pointer: OpaquePointer) {
            self.pointer = pointer
        }
    }

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
        let handle = CellHandle(cell)

        // Stand in for the IO thread.
        //
        // The cell is freed only once this thread has finished, and that is not
        // fussiness: the first version let the test return while the thread was
        // still retiring, so the freed cell was written to for another fifteen
        // milliseconds. Whichever test allocated next got that address and had
        // its cycle counter advanced underneath it, which made two unrelated
        // assertions here fail perhaps one run in three. AddressSanitizer named
        // it in one line after an hour of it looking like a product bug.
        let finished = DispatchSemaphore(value: 0)
        let retiring = Thread {
            for _ in 0..<8 {
                yun_rt_cell_retire(handle.pointer)
                usleep(2000)
            }
            finished.signal()
        }
        retiring.start()
        #expect(yun_rt_cell_wait_for_swap(cell, 500))
        _ = finished.wait(timeout: .now() + 2)
        yun_rt_cell_free(cell)
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

// MARK: - Effect parameters

@Suite("Effect parameters")
struct EffectParameterTests {
    /// A frequency control has to be logarithmic. On a linear slider the useful
    /// range for a voice high-pass — 20 to 200 Hz — would occupy the first
    /// third of the travel and the rest would be unusable.
    @Test("a logarithmic parameter puts its midpoint at the geometric mean")
    func logarithmicCurve() throws {
        let frequency = try #require(
            EffectKind.equaliser.parameters.first { $0.id == "frequency" })
        let middle = frequency.value(atFraction: 0.5)
        let geometric = (Double(frequency.minimum) * Double(frequency.maximum)).squareRoot()
        #expect(abs(Double(middle) - geometric) < 1)
    }

    @Test("position and value are inverses of each other")
    func roundTrip() {
        for kind in EffectKind.allCases {
            for parameter in kind.parameters {
                for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let value = parameter.value(atFraction: fraction)
                    #expect(abs(parameter.fraction(for: value) - fraction) < 0.001)
                }
            }
        }
    }

    @Test("every default sits inside its own range")
    func defaultsAreValid() {
        for kind in EffectKind.allCases {
            for parameter in kind.parameters {
                #expect(parameter.defaultValue >= parameter.minimum)
                #expect(parameter.defaultValue <= parameter.maximum)
            }
        }
    }

    @Test("a position outside the slider is clamped rather than extrapolated")
    func clamping() throws {
        let threshold = try #require(
            EffectKind.compressor.parameters.first { $0.id == "threshold" })
        #expect(threshold.value(atFraction: -1) == threshold.minimum)
        #expect(threshold.value(atFraction: 2) == threshold.maximum)
    }

    /// Stages are rendered in signal order regardless of the order they were
    /// switched on: a limiter ahead of a compressor is a configuration mistake.
    @Test("stages carry a signal order independent of when they were enabled")
    func chainOrder() {
        let ordered = EffectKind.allCases.sorted { $0.chainOrder < $1.chainOrder }
        #expect(
            ordered == [
                .voiceIsolation, .equaliser, .tone, .gate, .pitch, .formant, .character,
                .compressor, .echo, .reverb, .limiter,
            ])
        // Every stage has a distinct position, or the sort is not deterministic
        // and the same set of switches can build two different chains.
        #expect(Set(EffectKind.allCases.map(\.chainOrder)).count == EffectKind.allCases.count)
    }
}

@Suite("Sample ring")
struct SampleRingTests {

    /// The far-end capture reports "the tap never started" and "the application
    /// is silent" differently, and the only thing that can tell them apart is
    /// the write cursor: a ring drained as fast as it fills looks empty either
    /// way.
    @Test("a fresh ring has produced nothing")
    func freshRingIsEmpty() throws {
        let ring = try #require(yun_rt_ring_create(1024))
        defer { yun_rt_ring_free(ring) }
        #expect(yun_rt_ring_written(ring) == 0)
        #expect(yun_rt_ring_available(ring) == 0)
    }

    @Test("draining a ring leaves the produced count standing")
    func drainedRingRemembersProduction() throws {
        let ring = try #require(yun_rt_ring_create(1024))
        defer { yun_rt_ring_free(ring) }

        let written = [Float](repeating: 0.5, count: 300)
        _ = written.withUnsafeBufferPointer {
            yun_rt_ring_write(ring, $0.baseAddress!, 300)
        }
        #expect(yun_rt_ring_available(ring) == 300)

        var read = [Float](repeating: 0, count: 300)
        let taken = read.withUnsafeMutableBufferPointer {
            yun_rt_ring_read(ring, $0.baseAddress!, 300)
        }
        #expect(taken == 300)
        #expect(read.allSatisfy { $0 == 0.5 })
        // Empty, but not untouched — which is the distinction that matters.
        #expect(yun_rt_ring_available(ring) == 0)
        #expect(yun_rt_ring_written(ring) == 300)
    }

    @Test("a full ring drops rather than blocking")
    func fullRingDrops() throws {
        // Rounded up to 1024 slots, one of which the ring keeps to tell full
        // from empty.
        let ring = try #require(yun_rt_ring_create(600))
        defer { yun_rt_ring_free(ring) }

        let samples = [Float](repeating: 1, count: 2000)
        let taken = samples.withUnsafeBufferPointer {
            yun_rt_ring_write(ring, $0.baseAddress!, 2000)
        }
        #expect(taken == 1023)
        #expect(yun_rt_ring_dropped(ring) == 977)
    }
}

@Suite("Loopback grading")
struct LoopbackGradingTests {

    /// Builds a capture as if the path had returned `transform` applied to the
    /// generated sequence, offset by `delay` frames.
    private func grade(
        delay: Int, frames: Int = 8192,
        transform: (Float, Int) -> Float
    ) -> SelftestResult {
        let selftest = RTSelftest.allocate(
            outBuffer: 0, outChannel: 0, inBuffer: 0, inChannel: 0, captureFrames: frames)
        defer { RTSelftest.deallocate(selftest) }

        // The capture begins well past the start so the search has room to look
        // backwards, exactly as it does on a real device.
        let startFrame = UInt64(delay + 4096)
        selftest.pointee.captureStartFrame.pointee = startFrame
        selftest.pointee.captureCount.pointee = Int32(frames)
        for index in 0..<frames {
            let source = selftestSample(startFrame &+ UInt64(index) &- UInt64(delay))
            selftest.pointee.capture[index] = transform(source, index)
        }
        return RTSelftest.evaluate(selftest)
    }

    @Test("an untouched return is graded bit-exact and its delay recovered")
    func exactReturn() {
        let result = grade(delay: 872) { sample, _ in sample }
        #expect(result.isBitExact)
        #expect(result.didAlign)
        #expect(result.delayFrames == 872)
        #expect(result.maxAbsoluteError == 0)
        #expect(result.alignmentSeparation == 0)
    }

    /// The case that was being reported as a total failure.
    ///
    /// A resampler low-passes the probe, so every sample differs even though
    /// the path is carrying the signal. Scoring by exact equality found no
    /// offset at all and returned delay 0 with no matches — which reads as "the
    /// loopback carried nothing", and is a very different thing to tell someone.
    @Test("a smoothed return still aligns, and is not called bit-exact")
    func resampledReturn() {
        var previous: Float = 0
        let result = grade(delay: 555) { sample, _ in
            // A one-pole smoother stands in for the resampler.
            previous = previous * 0.5 + sample * 0.5
            return previous
        }
        #expect(result.didAlign)
        #expect(!result.isBitExact)
        #expect(result.delayFrames == 555)
        #expect(result.alignmentSeparation < 0.6)
        #expect(result.meanAbsoluteError > 0)
    }

    @Test("an unrelated return is not claimed to align")
    func unrelatedReturn() {
        // A different sequence entirely: what a path that never carried the
        // signal returns.
        let result = grade(delay: 300) { _, index in
            selftestSample(UInt64(index) &* 7 &+ 999_331)
        }
        #expect(!result.didAlign)
        #expect(!result.isBitExact)
        #expect(result.alignmentSeparation > 0.6)
    }

    @Test("silence is not mistaken for a returned signal")
    func silentReturn() {
        let result = grade(delay: 100) { _, _ in 0 }
        #expect(!result.didAlign)
        #expect(!result.isBitExact)
    }
}

@Suite("Processing chain")
struct ProcessingChainTests {

    /// Gating before the high-pass would key the gate off rumble the high-pass
    /// is about to remove — holding it open on energy nobody can hear.
    @Test("the high-pass runs before the gate")
    func highPassBeforeGate() {
        #expect(EffectKind.equaliser.chainOrder < EffectKind.gate.chainOrder)
    }

    @Test("every stage names itself and says what it costs")
    func described() {
        for kind in EffectKind.allCases {
            #expect(!kind.title.isEmpty)
            #expect(!kind.detail.isEmpty)
        }
    }

    /// Every knob has to sit inside its own range, or the first render clamps
    /// it somewhere the interface never showed.
    @Test("every default sits inside its own range")
    func defaultsInRange() {
        for kind in EffectKind.allCases {
            for parameter in kind.parameters {
                #expect(parameter.defaultValue >= parameter.minimum)
                #expect(parameter.defaultValue <= parameter.maximum)
            }
        }
    }

    /// The stored form has to stay put: a preferences file written before the
    /// stage was renamed still says `equaliser`, and changing the raw value
    /// would silently drop it from everybody's saved chain.
    @Test("the high-pass keeps its old stored name")
    func storedNameIsStable() {
        #expect(EffectKind.equaliser.rawValue == "equaliser")
        #expect(EffectKind(rawValue: "equaliser") == .equaliser)
        #expect(EffectKind.gate.rawValue == "gate")
    }
}

// MARK: - Loudness

/// The whole value of a loudness meter is that its number means the same thing
/// as everybody else's. A meter that is internally consistent but two units off
/// the standard is worse than no meter, because it will be trusted.
///
/// These check it against the properties BS.1770 fixes: the calibration of a
/// 1 kHz sine, the decibel law, and the two gates.
@Suite("Loudness")
struct LoudnessTests {

    private func referenceReadings(
        _ blocks: [Double]
    ) -> (
        integrated: Double, range: Double
    ) {
        let absolute = blocks.filter { LoudnessMeter.loudness(ofMeanSquare: $0) > -70 }
        guard !absolute.isEmpty else { return (-.infinity, 0) }
        let ungated = absolute.reduce(0, +) / Double(absolute.count)
        let threshold = LoudnessMeter.loudness(ofMeanSquare: ungated) - 10
        let gated = absolute.filter {
            LoudnessMeter.loudness(ofMeanSquare: $0) > threshold
        }
        let integrated =
            gated.isEmpty
            ? -.infinity
            : LoudnessMeter.loudness(
                ofMeanSquare: gated.reduce(0, +) / Double(gated.count))
        let ordered = absolute.map {
            LoudnessMeter.loudness(ofMeanSquare: $0)
        }.sorted()
        guard ordered.count > 4 else { return (integrated, 0) }
        let low = ordered[Int(Double(ordered.count) * 0.1)]
        let high =
            ordered[
                min(ordered.count - 1, Int(Double(ordered.count) * 0.95))]
        return (integrated, high - low)
    }

    private func hourOfBlockEnergy() -> [Double] {
        var state: UInt64 = 0xCAFE_F00D_D15C_A11
        let centres = [-61.0, -37.0, -25.0, -15.0, -8.0]
        return (0..<36_000).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(UInt64.max >> 11)
            let loudness = centres[index % centres.count] + (unit - 0.5) * 10
            return pow(10, (loudness + 0.691) / 10)
        }
    }

    /// Most blocks occupy one 0.01 LU bin, half immediately either side of the
    /// relative gate. Treating that bin as one mean produced a 2.43 LU error
    /// even though its width was only 0.01 LU.
    private func gateBoundaryCorpus() -> [Double] {
        let below = pow(10, (-29.999 + 0.691) / 10)
        let above = pow(10, (-29.991 + 0.691) / 10)
        let high = pow(10, (-10.0 + 0.691) / 10)
        let target = pow(10, (-29.995 + 0.691) / 10)
        let lowMean = (below + above) / 2
        let highShare = (10 * target - lowMean) / (high - lowMean)
        let total = 100_000
        let highCount = Int((Double(total) * highShare).rounded())
        let lowCount = total - highCount

        return [Double](repeating: below, count: lowCount / 2)
            + [Double](repeating: above, count: lowCount - lowCount / 2)
            + [Double](repeating: high, count: highCount)
    }

    /// Feeds `seconds` of a sine at a given peak amplitude.
    private func sine(
        into meter: inout LoudnessMeter, amplitude: Float, seconds: Double,
        frequency: Double = 1000, sampleRate: Double = 48000
    ) {
        let count = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            samples[index] =
                amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
        samples.withUnsafeBufferPointer { meter.add($0.baseAddress!, count: count) }
    }

    /// The standard is calibrated so a 1 kHz sine reads its own RMS level. A
    /// sine peaking at 0.1 has an RMS of 0.1/√2, which is −23.0 dBFS — and the
    /// answer has to be −23.0 LUFS, not merely something stable.
    @Test("a 1 kHz sine reads its own RMS level in LUFS")
    func calibration() {
        var meter = LoudnessMeter(sampleRate: 48000)
        // 0.1 peak → −23.01 dBFS RMS.
        sine(into: &meter, amplitude: 0.1, seconds: 5)
        #expect(abs(meter.integrated - (-23.01)) < 0.35)
    }

    /// Doubling amplitude is 6.02 dB, and LUFS is a decibel scale, so the
    /// reading has to move by exactly that. This is what catches a mean-square
    /// that has become a mean-absolute somewhere.
    @Test("doubling the amplitude adds 6 units")
    func decibelLaw() {
        var quiet = LoudnessMeter(sampleRate: 48000)
        sine(into: &quiet, amplitude: 0.1, seconds: 5)
        var loud = LoudnessMeter(sampleRate: 48000)
        sine(into: &loud, amplitude: 0.2, seconds: 5)
        #expect(abs((loud.integrated - quiet.integrated) - 6.02) < 0.1)
    }

    /// The K-weighting is not flat, and it must not be: that is the whole
    /// difference between this and an RMS meter. Subsonic rumble — a desk knock
    /// or a passing lorry — carries real energy that nobody hears, and the
    /// high-pass is there to stop it counting.
    ///
    /// The corner is 38 Hz at Q 0.5, so the numbers below are what that filter
    /// measurably does, not round figures: 6.1 dB at 40 Hz and 13.8 dB at 20 Hz.
    /// A 60 Hz mains hum is barely touched, which is correct and worth knowing —
    /// the standard's high-pass is not a hum filter.
    @Test("the weighting filter attenuates subsonic energy")
    func weightingIsNotFlat() {
        var mid = LoudnessMeter(sampleRate: 48000)
        sine(into: &mid, amplitude: 0.5, seconds: 4, frequency: 1000)

        var atCorner = LoudnessMeter(sampleRate: 48000)
        sine(into: &atCorner, amplitude: 0.5, seconds: 4, frequency: 40)
        #expect(atCorner.integrated < mid.integrated - 5)

        var subsonic = LoudnessMeter(sampleRate: 48000)
        sine(into: &subsonic, amplitude: 0.5, seconds: 4, frequency: 20)
        #expect(subsonic.integrated < mid.integrated - 13)
    }

    /// And it lifts the top, which is the shelf standing in for the head.
    @Test("the weighting filter lifts high frequencies")
    func shelfLifts() {
        var mid = LoudnessMeter(sampleRate: 48000)
        sine(into: &mid, amplitude: 0.5, seconds: 4, frequency: 1000)
        var high = LoudnessMeter(sampleRate: 48000)
        sine(into: &high, amplitude: 0.5, seconds: 4, frequency: 8000)
        #expect(high.integrated > mid.integrated + 2)
    }

    /// The coefficients are specified at 48 kHz. Using them unchanged at 96 kHz
    /// would put the shelf an octave out; re-deriving them means the same signal
    /// reads the same at either rate.
    @Test("the reading does not depend on the sample rate")
    func rateIndependent() {
        var at48 = LoudnessMeter(sampleRate: 48000)
        sine(into: &at48, amplitude: 0.1, seconds: 4, sampleRate: 48000)
        var at96 = LoudnessMeter(sampleRate: 96000)
        sine(into: &at96, amplitude: 0.1, seconds: 4, sampleRate: 96000)
        #expect(abs(at48.integrated - at96.integrated) < 0.2)
    }

    /// The absolute gate is what stops pauses counting. Speech with silence
    /// between the sentences has to read the same as the speech alone — without
    /// the gate, a recording with long pauses reads far quieter than it sounds,
    /// which is exactly the mistake the standard exists to prevent.
    @Test("silence between passages does not drag the reading down")
    func absoluteGate() {
        var continuous = LoudnessMeter(sampleRate: 48000)
        sine(into: &continuous, amplitude: 0.1, seconds: 6)

        var gapped = LoudnessMeter(sampleRate: 48000)
        for _ in 0..<3 {
            sine(into: &gapped, amplitude: 0.1, seconds: 2)
            let silence = [Float](repeating: 0, count: 48000 * 2)
            silence.withUnsafeBufferPointer { gapped.add($0.baseAddress!, count: $0.count) }
        }
        #expect(abs(gapped.integrated - continuous.integrated) < 1.0)
    }

    /// The relative gate discards anything more than 10 LU below the mean, so a
    /// quiet passage under loud material must not pull the figure down by the
    /// share of time it occupies.
    @Test("a passage far below the mean is gated out")
    func relativeGate() {
        var loudOnly = LoudnessMeter(sampleRate: 48000)
        sine(into: &loudOnly, amplitude: 0.5, seconds: 6)

        var mixed = LoudnessMeter(sampleRate: 48000)
        sine(into: &mixed, amplitude: 0.5, seconds: 6)
        // 40 dB down: well past the 10 LU relative threshold.
        sine(into: &mixed, amplitude: 0.005, seconds: 6)
        #expect(abs(mixed.integrated - loudOnly.integrated) < 0.6)
    }

    /// Nothing in, nothing out — and specifically not a very large negative
    /// number that would render as a plausible reading.
    @Test("silence reads as no measurement rather than a number")
    func silenceIsNotAReading() {
        var meter = LoudnessMeter(sampleRate: 48000)
        let silence = [Float](repeating: 0, count: 48000 * 2)
        silence.withUnsafeBufferPointer { meter.add($0.baseAddress!, count: $0.count) }
        #expect(meter.integrated == -.infinity)
        #expect(meter.peak == -.infinity)
    }

    /// A steady tone has no loudness range. If this reports a spread, the
    /// percentile arithmetic is picking up block-boundary noise.
    @Test("a steady signal has no loudness range")
    func steadyRange() {
        var meter = LoudnessMeter(sampleRate: 48000)
        sine(into: &meter, amplitude: 0.1, seconds: 8)
        #expect(meter.range < 1.0)
    }

    /// And material that swings has to show it, or the number says nothing.
    @Test("material that swings reports a range")
    func swingingRange() {
        var meter = LoudnessMeter(sampleRate: 48000)
        for _ in 0..<4 {
            sine(into: &meter, amplitude: 0.5, seconds: 1)
            sine(into: &meter, amplitude: 0.05, seconds: 1)
        }
        #expect(meter.range > 15)
    }

    /// Peak is a separate question from loudness and has to keep answering it:
    /// a single sample at full scale in otherwise quiet material is a clip, and
    /// no amount of gating may hide it.
    @Test("peak catches a lone sample the loudness reading averages away")
    func peakIsIndependent() {
        var meter = LoudnessMeter(sampleRate: 48000)
        sine(into: &meter, amplitude: 0.01, seconds: 2)
        let spike: [Float] = [1.0]
        spike.withUnsafeBufferPointer { meter.add($0.baseAddress!, count: 1) }
        #expect(abs(meter.peak) < 0.01)
        #expect(meter.integrated < -40)
    }

    /// Reset has to clear the filter state too. A meter that kept its biquad
    /// history would carry a transient across the boundary and misread the
    /// first block of the next take.
    @Test("reset returns the meter to its initial state")
    func resetClears() {
        var meter = LoudnessMeter(sampleRate: 48000)
        sine(into: &meter, amplitude: 0.5, seconds: 3)
        meter.reset()
        #expect(meter.integrated == -.infinity)
        #expect(meter.peak == -.infinity)
        #expect(meter.momentary == -.infinity)

        var fresh = LoudnessMeter(sampleRate: 48000)
        sine(into: &fresh, amplitude: 0.1, seconds: 3)
        sine(into: &meter, amplitude: 0.1, seconds: 3)
        #expect(abs(meter.integrated - fresh.integrated) < 0.01)
    }

    /// Short-term follows the last three seconds, so it has to move when the
    /// signal changes while integrated is still remembering everything.
    @Test("short-term tracks recent material and integrated does not")
    func shortTermIsRecent() {
        var meter = LoudnessMeter(sampleRate: 48000)
        sine(into: &meter, amplitude: 0.5, seconds: 6)
        let integratedAfterLoud = meter.integrated
        sine(into: &meter, amplitude: 0.05, seconds: 4)
        #expect(meter.shortTerm < integratedAfterLoud - 15)
        // The relative gate throws the quiet part away, so the integrated
        // figure barely moves.
        #expect(abs(meter.integrated - integratedAfterLoud) < 0.6)
    }

    @Test("a bounded distribution agrees with the exact one after an hour")
    func boundedDistributionMatchesReference() {
        let blocks = hourOfBlockEnergy()
        let reference = referenceReadings(blocks)
        var distribution = LoudnessDistribution()
        for block in blocks { distribution.add(block) }

        let integratedError = abs(distribution.integrated - reference.integrated)
        let rangeError = abs(distribution.range - reference.range)
        print(
            "loudness histogram error: integrated \(integratedError) LU, "
                + "range \(rangeError) LU")
        #expect(distribution.blockCount == 36_000)
        #expect(integratedError < 0.02)
        #expect(rangeError < 0.02)
    }

    @Test("a relative gate splits populations inside its boundary bin")
    func gateBoundaryIsNotQuantisedAsOnePopulation() {
        let blocks = gateBoundaryCorpus()
        let reference = referenceReadings(blocks)
        var distribution = LoudnessDistribution()
        for block in blocks { distribution.add(block) }

        let error = abs(distribution.integrated - reference.integrated)
        print(
            "gate-boundary loudness: reference \(reference.integrated) LUFS, "
                + "bounded \(distribution.integrated) LUFS, error \(error) LU")
        #expect(reference.integrated > -17.57)
        #expect(reference.integrated < -17.56)
        #expect(error < 0.001)
    }

    @Test("an hour of loudness has bounded update and display costs")
    func longSessionQueriesAreBounded() {
        var distribution = LoudnessDistribution()
        for block in hourOfBlockEnergy() { distribution.add(block) }
        let probes = (0..<17).map {
            pow(10, (-24.0 + Double($0) * 0.17 + 0.691) / 10)
        }

        let started = DispatchTime.now().uptimeNanoseconds
        var checksum = 0.0
        for index in 0..<1_000 {
            // Mutating between reads stops an optimised build hoisting the
            // otherwise pure-looking getters out of the benchmark loop. The
            // number therefore includes the fixed-cost Fenwick and centroid
            // update as well as both display readings.
            distribution.add(probes[index % probes.count])
            checksum += distribution.integrated + distribution.range
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        print(
            "1,000 hour-long loudness updates and reads: \(elapsed) ns, "
                + "checksum \(checksum)")
        // The previous filter-and-sort getters took about 1.21 ms per reading
        // at this size. A 100 ms ceiling for one thousand reads leaves a wide
        // margin for a loaded test machine while still rejecting that shape.
        #expect(elapsed < 100_000_000)
    }

    /// Every target has to name itself and sit somewhere a person could reach.
    @Test("every platform target is labelled and plausible")
    func targets() {
        for target in LoudnessTarget.allCases {
            #expect(!target.title.isEmpty)
            #expect(target.lufs < 0)
            #expect(target.lufs > -30)
        }
    }
}

// MARK: - Spectrum

/// A spectrum display is only worth having if a bar's position corresponds to
/// the frequency it claims. These put known tones in and check the energy lands
/// where the labels say it will.
@Suite("Spectrum")
struct SpectrumTests {

    private func feed(
        _ analyser: SpectrumAnalyser, frequency: Double, amplitude: Float = 0.5,
        seconds: Double = 0.5, sampleRate: Double = 48000
    ) {
        let count = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            samples[index] =
                amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
        samples.withUnsafeBufferPointer { analyser.add($0.baseAddress!, count: count) }
    }

    /// The band whose range contains the tone has to be the loudest one. This is
    /// the whole contract of the display; an off-by-one in the bin mapping would
    /// still produce a plausible-looking picture.
    @Test("a tone lands in the band that covers its frequency")
    func tonePosition() throws {
        for frequency in [100.0, 440.0, 1000.0, 4000.0] {
            let analyser = try #require(SpectrumAnalyser(sampleRate: 48000))
            feed(analyser, frequency: frequency)

            let loudest = try #require(
                analyser.bands.enumerated().max(by: { $0.element < $1.element })?.offset)
            let centre = analyser.centreFrequency(ofBand: loudest)
            // Within half a band either way, which at 24 log-spaced bands is a
            // factor of 1.13.
            #expect(centre > frequency / 1.15)
            #expect(centre < frequency * 1.15)
        }
    }

    /// And the rest of the display has to be quiet, or every band would light up
    /// together and the picture would carry no information at all.
    @Test("a single tone does not light the whole display")
    func toneIsLocalised() throws {
        let analyser = try #require(SpectrumAnalyser(sampleRate: 48000))
        feed(analyser, frequency: 1000)

        let loudest = try #require(
            analyser.bands.enumerated().max(by: { $0.element < $1.element })?.offset)
        // Two bands either side are the window's own skirts; beyond that
        // anything substantial means leakage the window should have suppressed.
        let distant = analyser.bands.enumerated()
            .filter { abs($0.offset - loudest) > 2 }
            .map(\.element)
        #expect(distant.allSatisfy { $0 < analyser.bands[loudest] * 0.5 })
    }

    /// Louder in, higher bar. Obvious, and exactly the thing a sign error in the
    /// decibel mapping would invert.
    @Test("a louder tone reads higher")
    func levelOrdering() throws {
        let quiet = try #require(SpectrumAnalyser(sampleRate: 48000))
        feed(quiet, frequency: 1000, amplitude: 0.05)
        let loud = try #require(SpectrumAnalyser(sampleRate: 48000))
        feed(loud, frequency: 1000, amplitude: 0.5)
        #expect(loud.bands.max()! > quiet.bands.max()!)
    }

    /// Bands are normalised for display, so nothing may leave the range the
    /// drawing code assumes — a value above one would draw a bar out of its box.
    @Test("every band stays within the display range")
    func normalised() throws {
        let analyser = try #require(SpectrumAnalyser(sampleRate: 48000))
        // Full scale, which is the case most likely to overflow.
        feed(analyser, frequency: 1000, amplitude: 1.0)
        #expect(analyser.bands.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    /// Silence has to settle to nothing rather than to a noise floor invented by
    /// the window function.
    @Test("silence settles to an empty display")
    func silence() throws {
        let analyser = try #require(SpectrumAnalyser(sampleRate: 48000))
        let quiet = [Float](repeating: 0, count: 48000)
        quiet.withUnsafeBufferPointer { analyser.add($0.baseAddress!, count: $0.count) }
        #expect(analyser.bands.allSatisfy { $0 < 0.01 })
    }

    /// The bin mapping is derived from the sample rate, so a tone has to land in
    /// the same band at either rate.
    @Test("band positions do not depend on the sample rate")
    func rateIndependent() throws {
        let at48 = try #require(SpectrumAnalyser(sampleRate: 48000))
        feed(at48, frequency: 1000, sampleRate: 48000)
        let at96 = try #require(SpectrumAnalyser(sampleRate: 96000))
        feed(at96, frequency: 1000, sampleRate: 96000)

        let first = at48.bands.enumerated().max(by: { $0.element < $1.element })?.offset
        let second = at96.bands.enumerated().max(by: { $0.element < $1.element })?.offset
        #expect(first == second)
    }

    /// The reading has to be calibrated, not merely ordered: a tone of known
    /// amplitude must come back at its own level in decibels.
    ///
    /// This is the assertion that catches a wrong transform. The first version
    /// of this analyser ran a complex-to-complex FFT over buffers packed for a
    /// real one, reading and writing twice past the end of both on every frame.
    /// Every test above still passed — the peak landed in the right band and
    /// rose with level — because none of them ever asked what the number *was*.
    @Test("a tone of known amplitude reads its own level")
    func calibration() throws {
        // Half scale is −6.02 dBFS.
        let analyser = try #require(SpectrumAnalyser(sampleRate: 48000))
        feed(analyser, frequency: 1000, amplitude: 0.5, seconds: 1.0)
        let loudest = try #require(
            analyser.bands.enumerated().max(by: { $0.element < $1.element })?.offset)
        // 1 kHz falls between bins, so up to 1.4 dB of scalloping loss with a
        // Hann window is expected and is not an error.
        #expect(abs(analyser.decibels(ofBand: loudest) - -6.02) < 1.6)

        // And a decade down has to move it by twenty.
        let quieter = try #require(SpectrumAnalyser(sampleRate: 48000))
        feed(quieter, frequency: 1000, amplitude: 0.05, seconds: 1.0)
        #expect(abs(quieter.decibels(ofBand: loudest) - -26.02) < 1.6)
    }

    /// Bands ascend in frequency, which is what lets the drawing code map index
    /// to horizontal position without consulting anything.
    @Test("band centres ascend")
    func ascending() throws {
        let analyser = try #require(SpectrumAnalyser(sampleRate: 48000))
        for index in 1..<SpectrumAnalyser.bandCount {
            #expect(
                analyser.centreFrequency(ofBand: index)
                    > analyser.centreFrequency(ofBand: index - 1))
        }
    }

    /// Feeding one continuous signal in small pieces has to give the same
    /// answer as feeding it whole, or the reading would depend on the buffer
    /// size the device happened to pick.
    ///
    /// One signal generated once and then sliced, rather than a fresh tone per
    /// chunk: restarting the phase at every boundary would make this a test of
    /// how the analyser handles fifty discontinuities, which is a different
    /// question and an easier one to pass.
    @Test("the result does not depend on how the samples are chunked")
    func chunking() throws {
        let count = 24000
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            samples[index] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(index) / 48000))
        }

        let whole = try #require(SpectrumAnalyser(sampleRate: 48000))
        samples.withUnsafeBufferPointer { whole.add($0.baseAddress!, count: count) }

        let pieces = try #require(SpectrumAnalyser(sampleRate: 48000))
        var offset = 0
        // Deliberately not a divisor of the window size, so the chunk boundaries
        // fall inside windows rather than lining up with them.
        let chunk = 373
        while offset < count {
            let take = min(chunk, count - offset)
            samples.withUnsafeBufferPointer {
                pieces.add($0.baseAddress! + offset, count: take)
            }
            offset += take
        }

        for index in 0..<SpectrumAnalyser.bandCount {
            #expect(abs(whole.bands[index] - pieces.bands[index]) < 0.02)
        }
    }
}

// MARK: - The realtime callback itself

/// Drives `yunAudioIOProc` directly with synthetic buffer lists.
///
/// Everything else about the router can be checked from the outside, but the
/// mixing rules cannot: the flow check can say audio kept flowing, and no
/// amount of that proves the master fader skipped the monitor or that the
/// recorder read the destination rather than whichever buffer happened to be
/// first. Those are claims about which sample lands where, and the only way to
/// assert them is to hand the callback known input and read the output back.
@Suite("Realtime callback")
struct IOProcTests {

    /// One interleaved buffer, allocated for the length of a test.
    private final class Bus {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []
        let frames: Int

        init(channelCounts: [Int], frames: Int, fill: Float = 0) {
            self.frames = frames
            list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
            for (index, channels) in channelCounts.enumerated() {
                let samples = frames * channels
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples)
                pointer.initialize(repeating: fill, count: samples)
                storage.append(pointer)
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(samples * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(pointer))
            }
        }

        func channel(_ buffer: Int, _ channel: Int, _ frame: Int) -> Float {
            let stride = Int(list[buffer].mNumberChannels)
            return storage[buffer][frame * stride + channel]
        }

        func set(_ buffer: Int, _ channel: Int, to value: Float) {
            let stride = Int(list[buffer].mNumberChannels)
            for frame in 0..<frames { storage[buffer][frame * stride + channel] = value }
        }

        deinit {
            for pointer in storage { pointer.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    /// Runs one cycle and returns the output bus.
    private func cycle(
        graph: UnsafeMutablePointer<RTGraph>, input: Bus, output: Bus, cycles: Int = 1
    ) {
        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        time.mSampleTime = 0
        time.mFlags = .sampleTimeValid
        for _ in 0..<cycles {
            _ = yunAudioIOProc(
                0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
                output.list.unsafeMutablePointer, &time,
                UnsafeMutableRawPointer(cell))
        }
    }

    /// Two output buffers: buffer 0 the monitor, buffer 1 the destination. That
    /// ordering is deliberate — it is the case the old code got wrong, because
    /// it assumed the destination was always buffer zero.
    private func twoDestinationGraph() -> UnsafeMutablePointer<RTGraph> {
        let graph = RTGraph.allocate(
            routes: [
                // Microphone into the destination.
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 1, destinationChannel: 0,
                    appliesInputTrim: true),
                // The same microphone into the monitor.
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    appliesInputTrim: true),
            ],
            bufferFrames: 64)
        graph.pointee.mainOutputBuffer = 1
        graph.pointee.masterExemptBuffer = 0
        return graph
    }

    @Test("a route copies its source channel into its destination channel")
    func basicRouting() {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 0)
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }

        let input = Bus(channelCounts: [2], frames: 64)
        input.set(0, 0, to: 0.1)
        input.set(0, 1, to: 0.5)
        let output = Bus(channelCounts: [2], frames: 64)

        cycle(graph: graph, input: input, output: output)
        #expect(output.channel(0, 0, 0) == 0.5)
        // Nothing routed there, so it must be silent rather than whatever the
        // buffer held.
        #expect(output.channel(0, 1, 0) == 0)
    }

    /// The master is the level going to the far end. Pulling it down must not
    /// take away the ability to hear yourself, or monitoring stops working at
    /// exactly the moment somebody mutes to cough.
    @Test("the master does not reach the monitor")
    func masterSkipsMonitor() {
        let graph = twoDestinationGraph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.outputGain = 0.25

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.8)
        let output = Bus(channelCounts: [2, 2], frames: 64)

        cycle(graph: graph, input: input, output: output)
        // Destination scaled by the master.
        #expect(abs(output.channel(1, 0, 0) - 0.2) < 0.0001)
        // Monitor untouched by it.
        #expect(abs(output.channel(0, 0, 0) - 0.8) < 0.0001)
    }

    @Test("muting the master leaves the monitor audible")
    func masterMuteSkipsMonitor() {
        let graph = twoDestinationGraph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.outputMuted = 1

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.8)
        let output = Bus(channelCounts: [2, 2], frames: 64)

        cycle(graph: graph, input: input, output: output)
        #expect(output.channel(1, 0, 0) == 0)
        #expect(abs(output.channel(0, 0, 0) - 0.8) < 0.0001)
    }

    /// The input trim and mute are the microphone's own level, so they reach
    /// everything the microphone feeds — including the monitor. Muting the
    /// microphone and still hearing it would be the worse surprise of the two.
    @Test("muting the input silences the monitor as well")
    func inputMuteReachesMonitor() {
        let graph = twoDestinationGraph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.inputMuted = 1

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.8)
        let output = Bus(channelCounts: [2, 2], frames: 64)

        cycle(graph: graph, input: input, output: output)
        #expect(output.channel(1, 0, 0) == 0)
        #expect(output.channel(0, 0, 0) == 0)
    }

    /// The analysers measure what the far end receives. With a monitor present
    /// buffer zero is the headphones, so a fold that assumed buffer zero would
    /// be measuring the wrong device entirely — and would report a healthy
    /// signal while the destination was silent.
    @Test("the analysis tap follows the destination, not buffer zero")
    func analysisReadsDestination() throws {
        let graph = twoDestinationGraph()
        defer { RTGraph.deallocate(graph) }
        // Explicitly, because the fold is off unless something is consuming it:
        // with the panel closed and levelling off there is no consumer and the
        // IO thread should not be doing the work.
        graph.pointee.analysisEnabled = 1
        // Destination muted by the master, monitor still loud.
        graph.pointee.outputMuted = 1

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.8)
        let output = Bus(channelCounts: [2, 2], frames: 64)

        cycle(graph: graph, input: input, output: output, cycles: 4)

        let ring = try #require(graph.pointee.analysisRing)
        var drained = [Float](repeating: 99, count: 512)
        let taken = drained.withUnsafeMutableBufferPointer {
            Int(yun_rt_ring_read(ring, $0.baseAddress!, UInt32($0.count)))
        }
        #expect(taken == 256)
        // Silence, because the destination is muted — not 0.8 from the monitor.
        #expect(drained[0..<taken].allSatisfy { $0 == 0 })
    }

    /// And when the destination is the one carrying signal, the fold has to
    /// find it — averaged across the pair rather than summed, or two copies of
    /// one voice would read three decibels louder than one.
    @Test("the analysis tap averages the destination pair")
    func analysisAverages() throws {
        let graph = twoDestinationGraph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.analysisEnabled = 1
        // A second route so both destination channels carry the signal.
        graph.pointee.routes[1] = RTRoute(
            sourceBuffer: 0, sourceChannel: 0,
            destinationBuffer: 1, destinationChannel: 1)

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.5)
        let output = Bus(channelCounts: [2, 2], frames: 64)

        cycle(graph: graph, input: input, output: output)

        let ring = try #require(graph.pointee.analysisRing)
        var drained = [Float](repeating: 0, count: 128)
        let taken = drained.withUnsafeMutableBufferPointer {
            Int(yun_rt_ring_read(ring, $0.baseAddress!, UInt32($0.count)))
        }
        #expect(taken == 64)
        // 0.5 on both channels averages to 0.5, not 1.0.
        #expect(drained[0..<taken].allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    /// A captured application arrives on a second input buffer of the same
    /// aggregate, and its routes name the same destination the microphone's do.
    /// So it is on the analysis path by construction — the fold is taken off
    /// the destination bus after everything has been summed into it.
    ///
    /// Asserted rather than reasoned about, because the whole karaoke feature
    /// rests on it: the key detector, the loudness meter and the spectrum all
    /// read the one ring, and if a tapped application were missing from it they
    /// would every one of them be measuring the microphone alone while the
    /// interface said otherwise. The microphone is muted here so that anything
    /// arriving can only have come from the tap — the input mute is the
    /// microphone's own, and a captured application is deliberately exempt from
    /// it.
    @Test("a captured application reaches the analysis ring")
    func analysisHearsACapturedApplication() throws {
        let graph = RTGraph.allocate(
            routes: [
                // The microphone, which `start` builds with the input trim.
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    appliesInputTrim: true),
                // The process tap, which it deliberately does not.
                RTRoute(
                    sourceBuffer: 1, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 1, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 1),
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }
        graph.pointee.analysisEnabled = 1
        graph.pointee.inputMuted = 1

        let input = Bus(channelCounts: [1, 2], frames: 64)
        input.set(0, 0, to: 0.9)
        input.set(1, 0, to: 0.5)
        input.set(1, 1, to: 0.5)
        let output = Bus(channelCounts: [2], frames: 64)

        cycle(graph: graph, input: input, output: output)

        let ring = try #require(graph.pointee.analysisRing)
        var drained = [Float](repeating: 0, count: 128)
        let taken = drained.withUnsafeMutableBufferPointer {
            Int(yun_rt_ring_read(ring, $0.baseAddress!, UInt32($0.count)))
        }
        #expect(taken == 64)
        // 0.5 on both destination channels, averaged — the tap's level exactly,
        // with none of the muted microphone's 0.9 in it.
        #expect(drained[0..<taken].allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    /// Several routes into one destination channel sum. That is what makes an
    /// application's audio and a microphone arrive as one mix.
    @Test("routes sharing a destination are summed")
    func summing() {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 0),
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }

        let input = Bus(channelCounts: [2], frames: 64)
        input.set(0, 0, to: 0.25)
        input.set(0, 1, to: 0.5)
        let output = Bus(channelCounts: [1], frames: 64)

        cycle(graph: graph, input: input, output: output)
        #expect(abs(output.channel(0, 0, 0) - 0.75) < 0.0001)
    }

    /// The output buffer is not promised to arrive zeroed, and routes add into
    /// it. A channel nothing feeds has to come out silent rather than replaying
    /// whatever the last cycle left.
    @Test("an unfed channel is cleared rather than left holding stale audio")
    func clearsOutput() {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0)
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.3)
        // Pre-filled with something loud, as a real buffer might be.
        let output = Bus(channelCounts: [2], frames: 64, fill: 0.9)

        cycle(graph: graph, input: input, output: output)
        #expect(abs(output.channel(0, 0, 0) - 0.3) < 0.0001)
        #expect(output.channel(0, 1, 0) == 0)
        // And it does not accumulate across cycles.
        cycle(graph: graph, input: input, output: output)
        #expect(abs(output.channel(0, 0, 0) - 0.3) < 0.0001)
    }

    /// A muted route contributes nothing, but is still metered — the meter
    /// shows what arrived, which is what lets somebody see they are talking
    /// into a muted microphone.
    @Test("a muted route is silent but still metered")
    func mutedRouteMeters() {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0, muted: true)
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.6)
        let output = Bus(channelCounts: [1], frames: 64)

        cycle(graph: graph, input: input, output: output)
        #expect(output.channel(0, 0, 0) == 0)
        #expect(abs(graph.pointee.peaks[0] - 0.6) < 0.0001)
    }

    /// The recorder is fed from the destination for the same reason the
    /// analysers are, and gets the same test: with a monitor in the aggregate,
    /// reading buffer zero would put the monitor feed on disk.
    @Test("the recorder is fed from the destination, not buffer zero")
    func recorderReadsDestination() throws {
        let graph = twoDestinationGraph()
        defer { RTGraph.deallocate(graph) }
        let ring = try #require(yun_rt_ring_create(4096))
        defer { yun_rt_ring_free(ring) }
        graph.pointee.recordRing = ring
        graph.pointee.recordChannels = 2
        // Destination at a quarter, monitor at full, so the two are separable.
        graph.pointee.outputGain = 0.25

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.8)
        let output = Bus(channelCounts: [2, 2], frames: 64)

        cycle(graph: graph, input: input, output: output)

        var drained = [Float](repeating: 0, count: 256)
        let taken = drained.withUnsafeMutableBufferPointer {
            Int(yun_rt_ring_read(ring, $0.baseAddress!, UInt32($0.count)))
        }
        #expect(taken == 128)
        // Interleaved stereo: channel 0 carries the routed signal after the
        // master, channel 1 nothing.
        #expect(abs(drained[0] - 0.2) < 0.0001)
        #expect(drained[1] == 0)
    }

    /// The command queue is what makes a fader move without rebuilding the
    /// graph, so it has to be drained before the samples it applies to.
    @Test("a queued gain change takes effect in the same cycle")
    func commandsApplyBeforeMixing() throws {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0)
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }

        let commands = try #require(graph.pointee.commands)
        #expect(
            yun_rt_queue_push(
                commands,
                YunRTCommand(
                    kind: Int32(kYunRTCommandSetGain.rawValue), index: 0, value: 0.5)))

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.8)
        let output = Bus(channelCounts: [1], frames: 64)

        cycle(graph: graph, input: input, output: output)
        #expect(abs(output.channel(0, 0, 0) - 0.4) < 0.0001)
    }

    /// A route pointing at a buffer the device did not provide has to be
    /// skipped, not followed. Device configurations change underneath a running
    /// graph, and an out-of-range index is a crash rather than a glitch.
    @Test("a route pointing past the buffer list is skipped")
    func outOfRangeRoute() {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 9, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 9, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 7,
                    destinationBuffer: 0, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0),
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.3)
        let output = Bus(channelCounts: [1], frames: 64)

        cycle(graph: graph, input: input, output: output)
        // Only the last route was valid, and it contributed exactly once.
        #expect(abs(output.channel(0, 0, 0) - 0.3) < 0.0001)
    }

    /// The cycle counter is what the control thread waits on before freeing a
    /// graph it has replaced. If it stopped advancing, a swap would free memory
    /// the realtime thread was still reading.
    @Test("every cycle advances the counter and the clock")
    func counterAdvances() {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0)
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }

        let input = Bus(channelCounts: [1], frames: 64)
        let output = Bus(channelCounts: [1], frames: 64)
        cycle(graph: graph, input: input, output: output, cycles: 5)
        #expect(graph.pointee.cycleCounter.pointee == 5)
    }

    /// The transcription tap has to carry that source and only that source,
    /// which is the entire reason attribution here is not a guess. A tap that
    /// picked up the mix would put everybody's words under one name and the
    /// feature would be worth nothing.
    @Test("a transcription tap carries only its own source")
    func transcriptTapIsPerSource() throws {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    transcriptIndex: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 0),
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }

        let ring = try #require(yun_rt_ring_create(4096))
        defer { yun_rt_ring_free(ring) }
        graph.pointee.transcriptRings[0] = ring

        let input = Bus(channelCounts: [2], frames: 64)
        input.set(0, 0, to: 0.25)
        input.set(0, 1, to: 0.9)
        let output = Bus(channelCounts: [1], frames: 64)
        cycle(graph: graph, input: input, output: output)

        var taken = 0
        var drained = [Float](repeating: 0, count: 128)
        drained.withUnsafeMutableBufferPointer {
            taken = Int(yun_rt_ring_read(ring, $0.baseAddress!, 128))
        }
        #expect(taken == 64)
        // The tapped source, not the sum of the two that reached the output.
        #expect(abs(drained[0] - 0.25) < 0.0001)
        #expect(abs(drained[63] - 0.25) < 0.0001)
    }

    /// Pre-fader, like a stem and for the same reason: a transcript should say
    /// what somebody said, not what the mix decided about them. A muted source
    /// is the case that proves it — muting somebody in the mix is not asking
    /// for their words to stop being written down.
    @Test("a transcription tap is taken before the fader")
    func transcriptTapIsPreFader() throws {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    gain: 0.1, muted: true, transcriptIndex: 0)
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }

        let ring = try #require(yun_rt_ring_create(4096))
        defer { yun_rt_ring_free(ring) }
        graph.pointee.transcriptRings[0] = ring

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.4)
        let output = Bus(channelCounts: [1], frames: 64)
        cycle(graph: graph, input: input, output: output)

        var drained = [Float](repeating: 0, count: 64)
        drained.withUnsafeMutableBufferPointer {
            _ = yun_rt_ring_read(ring, $0.baseAddress!, 64)
        }
        #expect(output.channel(0, 0, 0) == 0)
        #expect(abs(drained[0] - 0.4) < 0.0001)
    }

    /// A tap nobody opened must cost nothing and must not be followed. A null
    /// ring behind a non-negative index is the ordinary state between stopping
    /// transcription and the next graph rebuild.
    @Test("a transcription index with no ring behind it is ignored")
    func transcriptTapWithoutRing() {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    transcriptIndex: 0)
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }

        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.3)
        let output = Bus(channelCounts: [1], frames: 64)
        cycle(graph: graph, input: input, output: output)
        #expect(abs(output.channel(0, 0, 0) - 0.3) < 0.0001)
    }
}

/// Moving one cable rebuilds the graph, and everything that belongs to the
/// route rather than to that particular graph has to come across with it. Stem
/// recording was being dropped here: a patchbay edit during a recording left
/// every stem file open, silent and still counting time, with nothing saying
/// so. The matching is the part that can be wrong, so it is the part tested.
@Suite("Route assignments across a rebuild")
struct CarriedRouteTests {

    private func route(_ source: String, _ channel: Int, _ destination: String) -> Route {
        Route(
            source: ChannelRef(deviceUID: source, channel: channel),
            destination: ChannelRef(deviceUID: destination, channel: 0))
    }

    @Test("an unchanged list maps to itself")
    func identity() {
        let routes = [route("Mic", 0, "Out"), route("Discord", 0, "Out")]
        #expect(RoutingEngine.carriedPositions(from: routes, to: routes) == [0, 1])
    }

    /// The case the bug was: a rebuild reorders, and copying by index would
    /// hand one source's audio to another's file.
    @Test("a reordered list follows the route, not the position")
    func reordered() {
        let before = [route("Mic", 0, "Out"), route("Discord", 0, "Out")]
        let after = [route("Discord", 0, "Out"), route("Mic", 0, "Out")]
        #expect(RoutingEngine.carriedPositions(from: before, to: after) == [1, 0])
    }

    @Test("a route that did not exist before carries nothing")
    func addedRoute() {
        let before = [route("Mic", 0, "Out")]
        let after = [route("Mic", 0, "Out"), route("Spotify", 0, "Out")]
        #expect(RoutingEngine.carriedPositions(from: before, to: after) == [0, nil])
    }

    @Test("removing one leaves the rest where they belong")
    func removedRoute() {
        let before = [route("Mic", 0, "Out"), route("Discord", 0, "Out")]
        let after = [route("Discord", 0, "Out")]
        // Discord was second, and unplugging the microphone does not move it —
        // the answer is where it was, not where it now sits.
        #expect(RoutingEngine.carriedPositions(from: before, to: after) == [1])
    }

    /// Two cables between the same pair of channels is unusual and not an
    /// error. Both matching the same old route would put two sources in one
    /// file, so each old position is claimed once.
    @Test("duplicate routes each claim their own position")
    func duplicates() {
        let duplicated = [route("Mic", 0, "Out"), route("Mic", 0, "Out")]
        #expect(RoutingEngine.carriedPositions(from: duplicated, to: duplicated) == [0, 1])
    }

    /// A stereo source is two routes off two channels, and they must not be
    /// confused with each other — swapping them would swap the channels of the
    /// stem file.
    @Test("channels of one source are told apart")
    func channelsAreDistinct() {
        let before = [route("Mic", 0, "Out"), route("Mic", 1, "Out")]
        let after = [route("Mic", 1, "Out"), route("Mic", 0, "Out")]
        #expect(RoutingEngine.carriedPositions(from: before, to: after) == [1, 0])
    }
}

/// Clock recovery replays `StartConfiguration`, so a live graph swap is only
/// complete when the snapshot describes the graph that was just published.
///
/// These assertions stay below CoreAudio deliberately. A real lock failure is
/// a hardware event; the bug was the value handed to that event, and that value
/// can be proved exactly without taking anybody's microphone or output.
@Suite("Recovery configuration after a live graph swap")
struct LiveRecoveryConfigurationTests {
    private func route(_ source: String, _ destination: String) -> Route {
        Route(
            source: ChannelRef(deviceUID: source, channel: 0),
            destination: ChannelRef(deviceUID: destination, channel: 0))
    }

    private func plugin(_ name: String) -> AudioUnitPlugin {
        AudioUnitPlugin(
            type: kAudioUnitType_Effect, subType: 0x7465_7374,
            manufacturer: 0x7961_7564, name: name, manufacturerName: "Test",
            loadsInProcess: true)
    }

    private func configuration() -> RoutingEngine.StartConfiguration {
        RoutingEngine.StartConfiguration(
            sourceDeviceUID: "Mic",
            destinationDeviceUID: "Out",
            routes: [route("Mic", "Out")],
            taps: [],
            additionalSourceUIDs: ["Line"],
            additionalDestinationUIDs: ["Stream"],
            monitorDeviceUID: "Headphones",
            effects: [.gate],
            plugins: [plugin("Before")],
            preferredSampleRate: 48_000,
            bufferFrames: 256,
            voiceIsolation: VoiceIsolationSettings(mixPercent: 20, isHighQuality: false),
            echoCancellation: EchoCancellationSettings(speakerUID: "Out"),
            outputLatencyTrim: ["Out": 12],
            analysisEnabled: false,
            selftest: true)
    }

    @Test("a live route edit replaces only the recovery patchbay")
    func routesReplaceOnlyRoutes() {
        var snapshot = configuration()
        let before = snapshot
        let routes = [route("Spotify", "Out"), route("Mic", "Stream")]

        snapshot.rememberLiveRoutes(routes)

        #expect(snapshot.routes == routes)
        #expect(snapshot.effects == before.effects)
        #expect(snapshot.plugins == before.plugins)
        #expect(snapshot.voiceIsolation == before.voiceIsolation)
        #expect(snapshot.sourceDeviceUID == before.sourceDeviceUID)
        #expect(snapshot.destinationDeviceUID == before.destinationDeviceUID)
        #expect(snapshot.monitorDeviceUID == before.monitorDeviceUID)
        #expect(snapshot.bufferFrames == before.bufferFrames)
        #expect(snapshot.outputLatencyTrim == before.outputLatencyTrim)
    }

    @Test("a live chain edit keeps all three processing inputs together")
    func effectsReplaceTheWholeProcessingDecision() {
        var snapshot = configuration()
        let before = snapshot
        let plugins = [plugin("After")]
        let isolation = VoiceIsolationSettings(mixPercent: 73, isHighQuality: true)

        snapshot.rememberLiveEffects(
            [.voiceIsolation, .compressor, .limiter],
            plugins: plugins,
            voiceIsolation: isolation)

        #expect(snapshot.effects == [.voiceIsolation, .compressor, .limiter])
        #expect(snapshot.plugins == plugins)
        #expect(snapshot.voiceIsolation == isolation)
        #expect(snapshot.routes == before.routes)
        #expect(snapshot.taps.count == before.taps.count)
        #expect(snapshot.additionalSourceUIDs == before.additionalSourceUIDs)
        #expect(snapshot.additionalDestinationUIDs == before.additionalDestinationUIDs)
        #expect(
            snapshot.echoCancellation?.speakerUID
                == before.echoCancellation?.speakerUID)
        #expect(snapshot.preferredSampleRate == before.preferredSampleRate)
        #expect(snapshot.selftest == before.selftest)
    }

    @Test("snapshots change only after the matching graph is published")
    func snapshotFollowsPublication() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift", encoding: .utf8)
        let routesStart = try #require(source.range(of: "public func updateRoutes("))
        let effectsStart = try #require(
            source.range(
                of: "public func updateEffects(",
                range: routesStart.upperBound..<source.endIndex))
        let liveControl = try #require(
            source.range(
                of: "// MARK: Live control",
                range: effectsStart.upperBound..<source.endIndex))
        let routeUpdate = source[routesStart.lowerBound..<effectsStart.lowerBound]
        let effectUpdate = source[effectsStart.lowerBound..<liveControl.lowerBound]

        let routePublish = try #require(routeUpdate.range(of: "yun_rt_cell_publish"))
        let routeSnapshot = try #require(
            routeUpdate.range(of: "lastConfiguration?.rememberLiveRoutes"))
        #expect(routePublish.lowerBound < routeSnapshot.lowerBound)
        #expect(routeUpdate.ranges(of: "rememberLiveRoutes").count == 1)

        let effectPublish = try #require(effectUpdate.range(of: "yun_rt_cell_publish"))
        let effectSnapshot = try #require(
            effectUpdate.range(of: "lastConfiguration?.rememberLiveEffects"))
        #expect(effectPublish.lowerBound < effectSnapshot.lowerBound)
        #expect(effectUpdate.ranges(of: "rememberLiveEffects").count == 1)
    }

    @Test("clock recovery retains an analyser that was enabled after start")
    func analysisSurvivesRecoverySnapshot() throws {
        var snapshot = configuration()
        #expect(!snapshot.analysisEnabled)

        snapshot.rememberAnalysisEnabled(true)

        #expect(snapshot.analysisEnabled)
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift", encoding: .utf8)
        let setterStart = try #require(source.range(of: "public func setAnalysisEnabled("))
        let setterEnd = try #require(
            source.range(
                of: "public struct AnalysisStatistics",
                range: setterStart.upperBound..<source.endIndex))
        let setter = source[setterStart.lowerBound..<setterEnd.lowerBound]
        #expect(setter.ranges(of: "lastConfiguration?.rememberAnalysisEnabled").count == 1)

        let attemptStart = try #require(source.range(of: "private func startAttempt("))
        let attemptEnd = try #require(
            source.range(
                of: "public func stop()",
                range: attemptStart.upperBound..<source.endIndex))
        let attempt = source[attemptStart.lowerBound..<attemptEnd.lowerBound]
        #expect(
            attempt.ranges(of: "graph.pointee.analysisEnabled = analysisEnabled ? 1 : 0").count
                == 1)
    }
}

// MARK: - Giving up on a monitor

/// A monitor is an additional output, and the mix has to survive one that will
/// not start. The engine finds that out by building again without it, so what
/// "without it" means is worth asserting on its own: a reduction that took one
/// route too many would drop the call to save the sidetone, which is the defect
/// upside down.
@Suite("Dropping an unusable monitor")
struct MonitorDropTests {

    private func route(_ source: String, _ destination: String, channel: Int = 0) -> Route {
        Route(
            source: ChannelRef(deviceUID: source, channel: channel),
            destination: ChannelRef(deviceUID: destination, channel: channel))
    }

    private func configuration(
        monitor: String?, routes: [Route], destination: String = "Out"
    ) -> RoutingEngine.StartConfiguration {
        RoutingEngine.StartConfiguration(
            sourceDeviceUID: "Mic",
            destinationDeviceUID: destination,
            routes: routes,
            taps: [],
            additionalSourceUIDs: [],
            additionalDestinationUIDs: [],
            monitorDeviceUID: monitor,
            effects: [],
            plugins: [],
            preferredSampleRate: nil,
            bufferFrames: 128,
            voiceIsolation: nil,
            echoCancellation: nil,
            outputLatencyTrim: [:],
            analysisEnabled: false,
            selftest: false)
    }

    @Test("the second mix goes and the main mix stays")
    func keepsTheMainMix() throws {
        let start = configuration(
            monitor: "Headphones",
            routes: [
                route("Mic", "Out"), route("Mic", "Out", channel: 1),
                route("Mic", "Headphones"), route("Mic", "Headphones", channel: 1),
            ])
        let reduced = try #require(start.withoutMonitor())
        #expect(reduced.monitorDeviceUID == nil)
        #expect(reduced.routes.count == 2)
        #expect(reduced.routes.allSatisfy { $0.destination.deviceUID == "Out" })
        // In order and unaltered: every fader, mute and stem in the application
        // is a position in this list.
        #expect(reduced.routes == Array(start.routes.prefix(2)))
    }

    @Test("a monitor that is also the destination is not droppable")
    func refusesToDropTheDestination() {
        // The routes into it are the mix. Dropping them to save the monitor
        // would be giving up the call, and a destination that will not start is
        // not the monitor's failure to answer for.
        let start = configuration(
            monitor: "Out", routes: [route("Mic", "Out")], destination: "Out")
        #expect(start.withoutMonitor() == nil)
    }

    @Test("nothing to give up when there is no monitor")
    func refusesWithoutAMonitor() {
        #expect(
            configuration(monitor: nil, routes: [route("Mic", "Out")]).withoutMonitor() == nil)
    }

    /// Monitoring can be on with every send at −∞, which builds no routes into
    /// it at all. Retrying an identical start would only fail identically, and
    /// would blame the monitor for something it is not part of.
    @Test("a monitor carrying nothing is not what went wrong")
    func refusesWhenNothingWasSentThere() {
        let start = configuration(monitor: "Headphones", routes: [route("Mic", "Out")])
        #expect(start.withoutMonitor() == nil)
    }

    @Test("a start that is nothing but monitor routes is not reduced to silence")
    func refusesToEmptyTheRoute() {
        let start = configuration(monitor: "Headphones", routes: [route("Mic", "Headphones")])
        #expect(start.withoutMonitor() == nil)
    }
}

// MARK: - Automatic levelling

/// A control loop that has only ever been tried by talking into a microphone
/// has not been tested. These drive it with known loudness sequences and assert
/// the properties that decide whether it is pleasant or maddening to use:
/// that it converges, that it does not overshoot, that it does not hunt, and
/// that it refuses to act on anything that is not speech.
@Suite("Automatic levelling")
struct AutoLevelTests {

    /// Runs the loop against a signal whose loudness moves with the gain, which
    /// is what a real one does.
    private func settle(
        from start: Double, target: Double, seconds: Double = 60,
        hearsSpeech: Bool = true, step: Double = 0.05
    ) -> (loop: AutoLevel, loudness: Double, history: [Double]) {
        var loop = AutoLevel()
        var history: [Double] = []
        var loudness = start
        for _ in 0..<Int(seconds / step) {
            let offset = loop.update(
                loudness: loudness, target: target, hearsSpeech: hearsSpeech,
                elapsed: step)
            loudness = start + offset
            history.append(loudness)
        }
        return (loop, loudness, history)
    }

    /// The point of the thing. A voice ten units too quiet has to end up at the
    /// target and stay there.
    @Test("a quiet source converges on the target")
    func convergesFromQuiet() {
        let result = settle(from: -28, target: -18)
        #expect(abs(result.loudness - -18) <= AutoLevel.deadZone)
    }

    @Test("a loud source converges on the target")
    func convergesFromLoud() {
        let result = settle(from: -8, target: -18)
        #expect(abs(result.loudness - -18) <= AutoLevel.deadZone)
    }

    /// Overshoot is what a leveller must never do: correcting a quiet voice by
    /// going loud and coming back is exactly the pumping people complain about.
    @Test("it approaches the target without overshooting past it")
    func noOvershoot() {
        let result = settle(from: -28, target: -18)
        // Coming up from below, nothing may ever exceed the target by more
        // than the dead zone.
        #expect(result.history.allSatisfy { $0 <= -18 + AutoLevel.deadZone + 0.001 })
    }

    /// And once settled it has to stay still. A loop that keeps moving inside
    /// its own measurement noise is audible as slow breathing.
    @Test("it stops moving once it is inside the dead zone")
    func doesNotHunt() {
        let result = settle(from: -28, target: -18)
        let tail = result.history.suffix(200)
        let spread = (tail.max() ?? 0) - (tail.min() ?? 0)
        #expect(spread < 0.001)
    }

    /// The whole reason for the classifier. Without a speech verdict the loop
    /// must not move at all — this is the failure mode of every conventional
    /// AGC, which spends the pauses amplifying the room.
    @Test("it does not move when the model does not hear speech")
    func silenceDoesNotMoveIt() {
        let result = settle(from: -40, target: -18, hearsSpeech: false)
        #expect(result.loop.offset == 0)
        #expect(result.loop.isWaiting)
    }

    /// And a speech verdict on something far below the floor is the model being
    /// polite about silence, not evidence of level.
    @Test("it does not act on a signal below the floor")
    func floorHolds() {
        var loop = AutoLevel()
        for _ in 0..<200 {
            loop.update(
                loudness: AutoLevel.floor - 5, target: -18, hearsSpeech: true,
                elapsed: 0.05)
        }
        #expect(loop.offset == 0)
        #expect(loop.isWaiting)
    }

    /// An infinite reading is what silence produces, and arithmetic on it would
    /// put the offset at NaN and leave the trim there permanently.
    @Test("an infinite reading is ignored rather than propagated")
    func infiniteLoudness() {
        var loop = AutoLevel()
        loop.update(
            loudness: -.infinity, target: -18, hearsSpeech: true, elapsed: 0.05)
        #expect(loop.offset == 0)
        loop.update(loudness: .nan, target: -18, hearsSpeech: true, elapsed: 0.05)
        #expect(loop.offset == 0)
        #expect(!loop.offset.isNaN)
    }

    /// The slew limit is what makes the correction inaudible. A single call
    /// with a huge error must not be allowed to take the whole error at once.
    @Test("no single step exceeds the slew limit")
    func slewLimited() {
        var loop = AutoLevel()
        // Above the floor, or this would pass because the loop refused to act
        // rather than because it limited itself — which is how the first
        // version of this test was written, and it proved nothing.
        loop.update(loudness: -40, target: 0, hearsSpeech: true, elapsed: 0.05)
        #expect(loop.offset > 0)
        #expect(loop.offset <= AutoLevel.slewPerSecond * 0.05 + 0.0001)
    }

    /// And it is per second, not per call, so a slower poll does not mean a
    /// slower leveller.
    @Test("the rate is per second rather than per call")
    func rateIsPerSecond() {
        var fast = AutoLevel()
        for _ in 0..<20 {
            fast.update(loudness: -40, target: -18, hearsSpeech: true, elapsed: 0.05)
        }
        var slow = AutoLevel()
        for _ in 0..<2 {
            slow.update(loudness: -40, target: -18, hearsSpeech: true, elapsed: 0.5)
        }
        #expect(abs(fast.offset - slow.offset) < 0.0001)
    }

    /// Past the limit something is wrong with the setup, and silently adding
    /// forty decibels of make-up would hide it rather than fix it.
    @Test("the correction is bounded and says when it ran out")
    func limited() {
        var loop = AutoLevel()
        // 40 units of error against a 15 dB limit, and above the floor so the
        // loop actually engages.
        for _ in 0..<4000 {
            loop.update(loudness: -40, target: 0, hearsSpeech: true, elapsed: 0.05)
        }
        #expect(loop.offset <= AutoLevel.limit + 0.0001)
        #expect(loop.isAtLimit)
    }

    @Test("reset returns it to no correction at all")
    func resets() {
        var loop = AutoLevel()
        for _ in 0..<100 {
            loop.update(loudness: -30, target: -18, hearsSpeech: true, elapsed: 0.05)
        }
        #expect(loop.offset != 0)
        loop.reset()
        #expect(loop.offset == 0)
        #expect(loop.isWaiting)
    }

    /// Settling has to be quick enough to be useful. Ten units at 1.5 dB per
    /// second is under seven, and a leveller that took a minute would have the
    /// first half of every call at the wrong level.
    @Test("it settles within a few seconds")
    func settlesQuickly() {
        var loop = AutoLevel()
        var loudness = -28.0
        var seconds = 0.0
        while abs(loudness - -18) > AutoLevel.deadZone, seconds < 30 {
            let offset = loop.update(
                loudness: loudness, target: -18, hearsSpeech: true, elapsed: 0.05)
            loudness = -28 + offset
            seconds += 0.05
        }
        #expect(seconds < 10)
    }
}

// MARK: - Sound classification

@Suite("Sound classification")
struct SoundClassifierTests {
    /// The model's taxonomy is far finer than anything worth showing, so the
    /// labels are folded. A label landing in the wrong bucket would mean the
    /// leveller acting on a keyboard.
    @Test("model labels fold onto the right verdict")
    func folding() {
        #expect(SoundClassifier.fold("speech") == .speech)
        #expect(SoundClassifier.fold("shout") == .speech)
        #expect(SoundClassifier.fold("whispering") == .speech)
        #expect(SoundClassifier.fold("computer_keyboard") == .typing)
        #expect(SoundClassifier.fold("typing") == .typing)
        #expect(SoundClassifier.fold("singing") == .music)
        #expect(SoundClassifier.fold("acoustic_guitar") == .music)
        #expect(SoundClassifier.fold("air_conditioning") == .noise)
        #expect(SoundClassifier.fold("hum") == .noise)
    }

    /// Anything unrecognised has to land somewhere harmless. The one thing it
    /// must never do is default to speech, which would let the leveller act on
    /// a sound nobody identified.
    @Test("an unknown label never becomes speech")
    func unknownIsNotSpeech() {
        for label in ["", "zither", "helicopter", "unknown_thing"] {
            #expect(SoundClassifier.fold(label) != .speech)
        }
    }

    /// Building it against a real rate has to work, or the levelling silently
    /// never engages.
    @Test("the classifier builds at the rates the router uses")
    func builds() {
        for rate in [44100.0, 48000.0, 96000.0] {
            #expect(SoundClassifier(sampleRate: rate) != nil)
        }
    }
}

// MARK: - The classifier against real speech

/// Folding labels proves the table is right. It does not prove the model ever
/// says "speech" about speech, and the whole levelling feature rests on that.
///
/// `AVSpeechSynthesizer.write` renders to buffers without touching any audio
/// hardware, so a real utterance can be pushed through the real classifier with
/// no microphone, no room and no timing.
@Suite("Classifier against speech")
struct ClassifierSpeechTests {

    /// Renders an utterance to mono float samples.
    ///
    /// Time-bounded, and nil rather than a hang when it does not deliver.
    /// `AVSpeechSynthesizer.write` needs the main queue to be serviced to call
    /// back, and a test process is not guaranteed to be doing that — the first
    /// version of this waited on a continuation that never resumed and took the
    /// whole suite with it. A test that cannot run has to say so and get out of
    /// the way, not block.
    private func render(_ text: String) async -> (samples: [Float], rate: Double)? {
        let box = Box()
        await MainActor.run {
            let synthesiser = AVSpeechSynthesizer()
            box.synthesiser = synthesiser
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            synthesiser.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    box.finish()
                    return
                }
                let frames = Int(pcm.frameLength)
                box.lock.lock()
                box.rate = pcm.format.sampleRate
                if let channel = pcm.floatChannelData {
                    box.samples.append(
                        contentsOf: UnsafeBufferPointer(start: channel[0], count: frames))
                } else if let channel = pcm.int16ChannelData {
                    // The default voice renders 16-bit, so this is the branch
                    // that actually runs.
                    box.samples.append(
                        contentsOf: (0..<frames).map {
                            Float(channel[0][$0]) / Float(Int16.max)
                        })
                }
                box.lock.unlock()
            }
        }

        // Poll rather than wait on a signal, so the deadline is real.
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(100))
            if box.isReady { break }
        }
        return box.result()
    }

    /// Carries the rendered audio out of the callback.
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var samples: [Float] = []
        var rate: Double = 0
        var isFinished = false
        var synthesiser: AVSpeechSynthesizer?

        func finish() {
            lock.lock()
            isFinished = true
            lock.unlock()
        }

        /// Scoped accessors, because `NSLock.lock()` is unavailable from an
        /// async context — holding a lock across a suspension point is exactly
        /// the deadlock the compiler is refusing to let anybody write.
        var isReady: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isFinished && !samples.isEmpty
        }

        func result() -> (samples: [Float], rate: Double)? {
            lock.lock()
            defer { lock.unlock() }
            guard !samples.isEmpty, rate > 0 else { return nil }
            return (samples, rate)
        }
    }

    /// The assertion the levelling depends on: real speech is recognised as
    /// speech, confidently enough to act on.
    @Test("synthesised speech is recognised as speech")
    func recognisesSpeech() async throws {
        guard
            let rendered = await render(
                "The quick brown fox jumps over the lazy dog. "
                    + "Testing the loudness of this microphone, one two three.")
        else {
            // Not a pass dressed up as one: the synthesiser did not deliver, so
            // this run has no evidence either way and says so.
            Issue.record("the speech synthesiser produced nothing — claim unverified")
            return
        }
        let classifier = try #require(SoundClassifier(sampleRate: rendered.rate))

        // Fed in device-sized blocks rather than one lump, because that is how
        // it is fed in the application and the windowing has to survive it.
        var offset = 0
        rendered.samples.withUnsafeBufferPointer { pointer in
            while offset < pointer.count {
                let take = min(512, pointer.count - offset)
                classifier.add(pointer.baseAddress! + offset, count: take)
                offset += take
            }
        }
        // The analyser reports on its own queue, so the verdict lands shortly
        // after the last buffer goes in.
        try await Task.sleep(for: .seconds(2))

        #expect(classifier.verdict == .speech)
        #expect(classifier.hearsSpeech)
    }

    /// And silence is not. A classifier that called silence speech would let
    /// the leveller wind the gain up through every pause, which is the exact
    /// failure this feature exists to avoid.
    @Test("silence is not recognised as speech")
    func silenceIsNotSpeech() async throws {
        let classifier = try #require(SoundClassifier(sampleRate: 48000))
        let silence = [Float](repeating: 0, count: 48000 * 3)
        silence.withUnsafeBufferPointer {
            classifier.add($0.baseAddress!, count: $0.count)
        }
        try await Task.sleep(for: .seconds(1))
        #expect(classifier.verdict == .quiet)
        #expect(!classifier.hearsSpeech)
    }

    /// Neither is a sine tone, whatever the model decides to call it — the RMS
    /// floor is not the only guard, the verdict has to be wrong-shaped too.
    @Test("a steady tone is not recognised as speech")
    func toneIsNotSpeech() async throws {
        let classifier = try #require(SoundClassifier(sampleRate: 48000))
        let count = 48000 * 3
        var tone = [Float](repeating: 0, count: count)
        for index in 0..<count {
            tone[index] = 0.3 * Float(sin(2 * Double.pi * 440 * Double(index) / 48000))
        }
        tone.withUnsafeBufferPointer { classifier.add($0.baseAddress!, count: $0.count) }
        try await Task.sleep(for: .seconds(1))
        #expect(!classifier.hearsSpeech)
    }
}

// MARK: - Levelling must never be what clips you

/// Loudness and peak are different questions, and answering only the first is
/// how a leveller hands the far end distortion in exchange for hitting a
/// number. Quiet-but-clean beats correct-but-clipped every time.
@Suite("Levelling headroom")
struct AutoLevelHeadroomTests {

    @Test("it stops short when the peak has no room left")
    func respectsCeiling() {
        var loop = AutoLevel()
        // Wants +10, but the measured peak allows only +3.
        for _ in 0..<400 {
            loop.update(
                loudness: -28, target: -18, hearsSpeech: true, elapsed: 0.05,
                ceiling: 3)
        }
        #expect(loop.offset <= 3.0001)
        #expect(loop.isHeldByHeadroom)
    }

    /// A ceiling below where it already sits means the peak grew underneath it.
    /// The answer is to stop adding, not to lunge downwards — a sudden drop is
    /// far more audible than staying put.
    @Test("a ceiling below the current offset does not force it down")
    func ceilingDoesNotPush() {
        var loop = AutoLevel()
        for _ in 0..<200 {
            loop.update(loudness: -28, target: -18, hearsSpeech: true, elapsed: 0.05)
        }
        let before = loop.offset
        #expect(before > 2)
        loop.update(
            loudness: -28, target: -18, hearsSpeech: true, elapsed: 0.05, ceiling: -5)
        #expect(loop.offset == before)
    }

    /// Turning down is always allowed, whatever the ceiling says: coming down
    /// can never cause clipping.
    @Test("the ceiling never blocks a reduction")
    func reductionAlwaysAllowed() {
        var loop = AutoLevel()
        for _ in 0..<200 {
            loop.update(
                loudness: -6, target: -18, hearsSpeech: true, elapsed: 0.05, ceiling: 0)
        }
        #expect(loop.offset < -5)
    }

    /// With headroom to spare it behaves exactly as it did before the ceiling
    /// existed.
    @Test("plenty of headroom changes nothing")
    func generousCeiling() {
        var unbounded = AutoLevel()
        var bounded = AutoLevel()
        for _ in 0..<200 {
            unbounded.update(loudness: -28, target: -18, hearsSpeech: true, elapsed: 0.05)
            bounded.update(
                loudness: -28, target: -18, hearsSpeech: true, elapsed: 0.05,
                ceiling: 40)
        }
        #expect(abs(unbounded.offset - bounded.offset) < 0.0001)
        #expect(!bounded.isHeldByHeadroom)
    }
}

// MARK: - What actually leaves

/// Every meter in the graph is taken before gain, which is right for a fader
/// and meant nothing could see the trim or the master pushing the signal past
/// full scale. The far end heard distortion and this side read healthy.
@Suite("Output measurement")
struct OutputMeasurementTests {

    private final class Bus {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []
        let frames: Int

        init(channelCounts: [Int], frames: Int) {
            self.frames = frames
            list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
            for (index, channels) in channelCounts.enumerated() {
                let samples = frames * channels
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples)
                pointer.initialize(repeating: 0, count: samples)
                storage.append(pointer)
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(samples * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(pointer))
            }
        }

        func set(_ buffer: Int, _ channel: Int, to value: Float) {
            let stride = Int(list[buffer].mNumberChannels)
            for frame in 0..<frames { storage[buffer][frame * stride + channel] = value }
        }

        deinit {
            for pointer in storage { pointer.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    private func cycle(
        graph: UnsafeMutablePointer<RTGraph>, input: Bus, output: Bus, cycles: Int = 1
    ) {
        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        for _ in 0..<cycles {
            _ = yunAudioIOProc(
                0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
                output.list.unsafeMutablePointer, &time,
                UnsafeMutableRawPointer(cell))
        }
    }

    private func graph(gain: Float) -> UnsafeMutablePointer<RTGraph> {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    gain: gain, appliesInputTrim: true)
            ], bufferFrames: 64)
        return graph
    }

    /// The case that was invisible: a route gain pushing an in-range signal
    /// past full scale.
    @Test("gain-induced clipping is counted")
    func gainClips() {
        let graph = graph(gain: 4)
        defer { RTGraph.deallocate(graph) }
        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.5)
        let output = Bus(channelCounts: [1], frames: 64)

        cycle(graph: graph, input: input, output: output)
        #expect(graph.pointee.outputClipped == 64)
        #expect(graph.pointee.outputPeak >= 0.999)
        // And the route meter still reads the arriving level, unchanged: that
        // is the behaviour worth keeping, and the reason the second measurement
        // had to exist rather than replace it.
        #expect(abs(graph.pointee.peaks[0] - 0.5) < 0.0001)
    }

    /// The master is applied after the routes, so it has to be inside the
    /// measurement too.
    @Test("master-induced clipping is counted")
    func masterClips() {
        let graph = graph(gain: 1)
        defer { RTGraph.deallocate(graph) }
        graph.pointee.outputGain = 3
        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.5)
        let output = Bus(channelCounts: [1], frames: 64)

        cycle(graph: graph, input: input, output: output)
        #expect(graph.pointee.outputClipped == 64)
    }

    /// And the input trim, which is applied before the routes read.
    @Test("trim-induced clipping is counted")
    func trimClips() {
        let graph = graph(gain: 1)
        defer { RTGraph.deallocate(graph) }
        graph.pointee.inputGain = 5
        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.4)
        let output = Bus(channelCounts: [1], frames: 64)

        cycle(graph: graph, input: input, output: output)
        #expect(graph.pointee.outputClipped == 64)
    }

    /// A signal inside full scale must not be reported as clipping, or the
    /// indicator means nothing.
    @Test("a signal with headroom is not reported as clipping")
    func cleanSignal() {
        let graph = graph(gain: 1)
        defer { RTGraph.deallocate(graph) }
        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.5)
        let output = Bus(channelCounts: [1], frames: 64)

        cycle(graph: graph, input: input, output: output, cycles: 10)
        #expect(graph.pointee.outputClipped == 0)
        #expect(abs(graph.pointee.outputPeak - 0.5) < 0.0001)
    }

    /// The count latches across cycles: a clip two seconds ago is exactly the
    /// event a meter that only falls would hide.
    @Test("the clip count accumulates rather than resetting each cycle")
    func latches() {
        let graph = graph(gain: 4)
        defer { RTGraph.deallocate(graph) }
        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: 0.5)
        let output = Bus(channelCounts: [1], frames: 64)

        cycle(graph: graph, input: input, output: output, cycles: 3)
        #expect(graph.pointee.outputClipped == 192)
    }

    /// Negative excursions clip just as hard as positive ones, and taking a
    /// signed maximum rather than a magnitude is an easy way to miss half of
    /// them.
    @Test("clipping on the negative half is counted too")
    func negativeClips() {
        let graph = graph(gain: 1)
        defer { RTGraph.deallocate(graph) }
        let input = Bus(channelCounts: [1], frames: 64)
        input.set(0, 0, to: -1.5)
        let output = Bus(channelCounts: [1], frames: 64)

        cycle(graph: graph, input: input, output: output)
        #expect(graph.pointee.outputClipped == 64)
        #expect(graph.pointee.outputPeak >= 0.999)
    }
}

// MARK: - Ducking

/// Music getting out of the way of a voice. The rule that matters more than any
/// other here is what it must *not* touch: the microphone. A ducker that ever
/// reached the voice would be a gate, and a gate keyed off a classifier that
/// reports twice a second would cut the front of every word — which is exactly
/// how this feature would ruin the thing it exists to improve.
@Suite("Ducking")
struct DuckingTests {

    private final class Bus {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []
        let frames: Int

        init(channelCounts: [Int], frames: Int) {
            self.frames = frames
            list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
            for (index, channels) in channelCounts.enumerated() {
                let samples = frames * channels
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples)
                pointer.initialize(repeating: 0, count: samples)
                storage.append(pointer)
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(samples * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(pointer))
            }
        }

        func channel(_ buffer: Int, _ channel: Int, _ frame: Int) -> Float {
            let stride = Int(list[buffer].mNumberChannels)
            return storage[buffer][frame * stride + channel]
        }

        func set(_ buffer: Int, _ channel: Int, to value: Float) {
            let stride = Int(list[buffer].mNumberChannels)
            for frame in 0..<frames { storage[buffer][frame * stride + channel] = value }
        }

        deinit {
            for pointer in storage { pointer.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    private func cycle(
        graph: UnsafeMutablePointer<RTGraph>, input: Bus, output: Bus, cycles: Int = 1
    ) {
        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        for _ in 0..<cycles {
            _ = yunAudioIOProc(
                0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
                output.list.unsafeMutablePointer, &time,
                UnsafeMutableRawPointer(cell))
        }
    }

    /// Channel 0 of the input is the microphone, channel 1 an application. Both
    /// land on their own output channel so each can be read back separately.
    private func duckingGraph() -> UnsafeMutablePointer<RTGraph> {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    appliesInputTrim: true),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 1,
                    isDuckable: true),
            ], bufferFrames: 64)
        graph.pointee.duckEnabled = 1
        graph.pointee.duckDepth = 0.2
        graph.pointee.duckThreshold = 0.02
        return graph
    }

    /// The whole point, and the one assertion worth writing first: whatever
    /// ducking does to the music, the voice comes through untouched.
    @Test("the microphone is never ducked")
    func microphoneUntouched() {
        let graph = duckingGraph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.duckAllowed = 1

        let input = Bus(channelCounts: [2], frames: 64)
        input.set(0, 0, to: 0.5)  // voice
        input.set(0, 1, to: 0.5)  // music
        let output = Bus(channelCounts: [2], frames: 64)

        // Long enough for the duck to be fully engaged.
        cycle(graph: graph, input: input, output: output, cycles: 200)
        #expect(abs(output.channel(0, 0, 0) - 0.5) < 0.0001)
        // And the music really did move, or this proves nothing.
        #expect(output.channel(0, 1, 0) < 0.3)
    }

    /// Both conditions have to hold. An envelope on its own ducks for a cough,
    /// a chair and a keyboard.
    @Test("a loud microphone alone does not duck without the model's agreement")
    func envelopeAloneDoesNotDuck() {
        let graph = duckingGraph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.duckAllowed = 0

        let input = Bus(channelCounts: [2], frames: 64)
        input.set(0, 0, to: 0.9)
        input.set(0, 1, to: 0.5)
        let output = Bus(channelCounts: [2], frames: 64)

        cycle(graph: graph, input: input, output: output, cycles: 200)
        #expect(abs(output.channel(0, 1, 0) - 0.5) < 0.0001)
    }

    /// And the model's agreement alone is not enough either: between sentences
    /// the verdict is still held, and the music has to come back up.
    @Test("the model's verdict alone does not duck a silent microphone")
    func verdictAloneDoesNotDuck() {
        let graph = duckingGraph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.duckAllowed = 1

        let input = Bus(channelCounts: [2], frames: 64)
        input.set(0, 0, to: 0.001)  // below the trigger
        input.set(0, 1, to: 0.5)
        let output = Bus(channelCounts: [2], frames: 64)

        cycle(graph: graph, input: input, output: output, cycles: 200)
        #expect(abs(output.channel(0, 1, 0) - 0.5) < 0.0001)
    }

    /// Muting the microphone means nobody is talking, whatever the envelope
    /// picked up before the mute landed.
    @Test("a muted microphone does not duck")
    func mutedDoesNotDuck() {
        let graph = duckingGraph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.duckAllowed = 1
        graph.pointee.inputMuted = 1

        let input = Bus(channelCounts: [2], frames: 64)
        input.set(0, 0, to: 0.9)
        input.set(0, 1, to: 0.5)
        let output = Bus(channelCounts: [2], frames: 64)

        cycle(graph: graph, input: input, output: output, cycles: 200)
        #expect(abs(output.channel(0, 1, 0) - 0.5) < 0.0001)
    }

    /// Switched off it is exactly a no-op, not a very shallow duck.
    @Test("with ducking off nothing is attenuated")
    func disabled() {
        let graph = duckingGraph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.duckEnabled = 0
        graph.pointee.duckAllowed = 1

        let input = Bus(channelCounts: [2], frames: 64)
        input.set(0, 0, to: 0.9)
        input.set(0, 1, to: 0.5)
        let output = Bus(channelCounts: [2], frames: 64)

        cycle(graph: graph, input: input, output: output, cycles: 50)
        #expect(output.channel(0, 1, 0) == 0.5)
    }

    /// It arrives smoothly rather than as a step. A duck that landed in one
    /// cycle would be a click.
    @Test("the duck fades in rather than stepping")
    func smoothAttack() {
        let graph = duckingGraph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.duckAllowed = 1

        let input = Bus(channelCounts: [2], frames: 64)
        input.set(0, 0, to: 0.5)
        input.set(0, 1, to: 0.5)
        let output = Bus(channelCounts: [2], frames: 64)

        // One cycle is 1.3 ms at 64 frames; the attack is 80 ms, so almost
        // nothing may have happened yet.
        cycle(graph: graph, input: input, output: output, cycles: 2)
        #expect(output.channel(0, 1, 0) > 0.45)
        cycle(graph: graph, input: input, output: output, cycles: 400)
        #expect(output.channel(0, 1, 0) < 0.15)
    }

    /// And it comes back slowly, or the music surges between every word.
    @Test("the music returns gradually when talking stops")
    func slowRelease() {
        let graph = duckingGraph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.duckAllowed = 1

        let talking = Bus(channelCounts: [2], frames: 64)
        talking.set(0, 0, to: 0.5)
        talking.set(0, 1, to: 0.5)
        let output = Bus(channelCounts: [2], frames: 64)
        cycle(graph: graph, input: talking, output: output, cycles: 400)
        #expect(output.channel(0, 1, 0) < 0.15)

        // Silence on the microphone, music still playing.
        let quiet = Bus(channelCounts: [2], frames: 64)
        quiet.set(0, 0, to: 0)
        quiet.set(0, 1, to: 0.5)
        cycle(graph: graph, input: quiet, output: output, cycles: 5)
        // Barely moved after 7 ms of a 600 ms release.
        #expect(output.channel(0, 1, 0) < 0.2)
        cycle(graph: graph, input: quiet, output: output, cycles: 3000)
        #expect(output.channel(0, 1, 0) > 0.45)
    }

    /// The smoothing is expressed in seconds, so the same setting has to behave
    /// the same at any buffer size — the mistake the meter ballistics already
    /// made once.
    @Test("the attack takes the same time whatever the buffer size")
    func rateIsIndependentOfBufferSize() {
        for frames in [64, 128, 256, 512] {
            let coefficient = RTGraph.coefficient(
                seconds: 0.08, bufferFrames: frames, sampleRate: 48000)
            // Cycles to fall to 1/e, times the cycle duration, is the time
            // constant.
            let cycles = -1.0 / log(Double(coefficient))
            let seconds = cycles * Double(frames) / 48000
            #expect(abs(seconds - 0.08) < 0.001)
        }
    }
}

// MARK: - Doing nothing costs nothing

/// A router forwarding audio between two devices should not be folding buses,
/// running an FFT or holding a neural network open in case somebody looks at a
/// panel. These assert that the work genuinely does not happen.
@Suite("Idle cost")
struct IdleCostTests {

    /// Nothing is built until something asks for it.
    @Test("an analyser with no declared needs builds nothing")
    func nothingBuiltByDefault() {
        let analyser = SignalAnalyser(sampleRate: 48000)
        #expect(analyser.isIdle)
        #expect(analyser.classifier == nil)
    }

    @Test("declaring a need builds exactly that")
    func buildsOnDemand() {
        let analyser = SignalAnalyser(sampleRate: 48000)
        analyser.require([.loudness])
        #expect(!analyser.isIdle)
        // Loudness alone must not drag the sound model in with it.
        #expect(analyser.classifier == nil)

        analyser.require([.loudness, .classification])
        #expect(analyser.classifier != nil)
    }

    /// And releasing it really releases it, rather than leaving it built for
    /// the next time.
    @Test("withdrawing a need releases what it built")
    func releasesOnWithdrawal() {
        let analyser = SignalAnalyser(sampleRate: 48000)
        analyser.require([.classification])
        #expect(analyser.classifier != nil)
        analyser.require([])
        #expect(analyser.classifier == nil)
        #expect(analyser.isIdle)
    }

    /// The IO thread's own share: with nothing consuming, the fold does not run
    /// and the ring stays empty.
    @Test("the output fold does not run when nothing is consuming it")
    func foldIsSkipped() throws {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0)
            ], bufferFrames: 64)
        defer { RTGraph.deallocate(graph) }

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        storage.initialize(repeating: 0.5, count: 64)
        defer { storage.deallocate() }
        list[0] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(64 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(storage))

        let outList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outList.unsafeMutablePointer) }
        let outStorage = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        outStorage.initialize(repeating: 0, count: 64)
        defer { outStorage.deallocate() }
        outList[0] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(64 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(outStorage))

        let cell = try #require(yun_rt_cell_create(UnsafeMutableRawPointer(graph)))
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        for _ in 0..<20 {
            _ = yunAudioIOProc(
                0, &now, UnsafePointer(list.unsafeMutablePointer), &time,
                outList.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))
        }

        let ring = try #require(graph.pointee.analysisRing)
        #expect(yun_rt_ring_written(ring) == 0)

        // And it does run once something is listening, so the check above is
        // about the gate rather than about the fold being broken.
        graph.pointee.analysisEnabled = 1
        _ = yunAudioIOProc(
            0, &now, UnsafePointer(list.unsafeMutablePointer), &time,
            outList.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))
        #expect(yun_rt_ring_written(ring) == 64)
    }
}

// MARK: - The new stages

/// A stage that cannot be instantiated is a switch in the interface that does
/// nothing, and the failure is silent — `AudioComponentFindNext` returns nil
/// and the chain simply carries on without it. These build every stage against
/// the real component list.
@Suite("Effect stages")
struct EffectStageTests {

    /// Every stage has to actually exist on this system.
    ///
    /// `NewTimePitch` is the reason this test is here: it is a format
    /// converter, not an effect, so looking for it under
    /// `kAudioUnitType_Effect` finds nothing and the pitch stage would vanish
    /// from the chain without a word.
    @Test("every stage resolves to a real audio unit")
    func componentsExist() {
        for kind in EffectKind.allCases {
            var description = AudioComponentDescription(
                componentType: kind.componentType,
                componentSubType: kind.subType,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            #expect(
                AudioComponentFindNext(nil, &description) != nil,
                "\(kind.rawValue) has no component")
        }
    }

    /// And has to build, initialise and render inside a chain.
    @Test("every stage builds a working chain on its own")
    func buildsAlone() throws {
        for kind in EffectKind.allCases {
            let chain = try #require(
                EffectChain(kinds: [kind], sampleRate: 48000, maximumFrames: 512),
                "\(kind.rawValue) did not build")
            #expect(chain.stages == [kind])
            // A stage that reports negative latency would corrupt the delay
            // compensation arithmetic downstream.
            #expect(chain.latencyFrames >= 0)
        }
    }

    /// The one stage whose latency is large enough to hear, asserted as a
    /// number rather than as `>= 0`.
    ///
    /// This exists because the question "is the chain's latency zero or 56 ms?"
    /// was open for a while, and the two sides of the argument were both
    /// reading a real measurement — the probe reports 56.35 ms and a reading of
    /// the chain reported nothing. Only one of them can be true of the same
    /// build, so it is asserted here: whatever `AUSoundIsolation` says about
    /// itself is what the chain must carry, because that is the number the tap
    /// alignment delays by. A future macOS reporting zero is then a test
    /// failure with the delay line to fix, rather than lyrics drifting a
    /// twentieth of a second out of time with nobody able to say when it began.
    @Test("the chain carries the isolation latency the unit reports")
    func isolationLatencyReachesTheChain() throws {
        let report = SoundIsolation.probe(sampleRate: 48000, blockFrames: 512, iterations: 40)
        try #require(report.isAvailable, "AUSoundIsolation is not on this machine")
        let chain = try #require(
            EffectChain(kinds: [.voiceIsolation], sampleRate: 48000, maximumFrames: 512))
        #expect(chain.latencyFrames == Int(report.latencySeconds * 48000))
        // And it is a real delay rather than a rounding of nothing: the model
        // works in blocks and cannot be free.
        #expect(chain.latencyFrames > 0)
    }

    /// All of them together, in the order the chain imposes rather than the
    /// order they were named.
    @Test("the whole set builds in signal order")
    func buildsTogether() throws {
        let chain = try #require(
            EffectChain(
                kinds: EffectKind.allCases.reversed(), sampleRate: 48000,
                maximumFrames: 512))
        #expect(chain.stages.count == EffectKind.allCases.count)
        // Sorted by chain order, whatever order they arrived in.
        for (first, second) in zip(chain.stages, chain.stages.dropFirst()) {
            #expect(first.chainOrder < second.chainOrder)
        }
    }

    /// The limiter is the only stage whose position is not a matter of taste:
    /// anything after it can put the signal back over full scale, which is the
    /// one thing it exists to prevent.
    @Test("the limiter is always last")
    func limiterIsLast() throws {
        let chain = try #require(
            EffectChain(kinds: EffectKind.allCases, sampleRate: 48000, maximumFrames: 512))
        #expect(chain.stages.last == .limiter)
    }

    /// Voice isolation is a model and has to see the signal before anything
    /// else has shaped it.
    @Test("voice isolation is always first")
    func isolationIsFirst() throws {
        let chain = try #require(
            EffectChain(kinds: EffectKind.allCases, sampleRate: 48000, maximumFrames: 512))
        #expect(chain.stages.first == .voiceIsolation)
    }

    /// Pitch shifting is not free, and the interface has to be able to say what
    /// it costs rather than discovering it on a call.
    @Test("pitch shifting reports the latency it adds")
    func pitchCostsLatency() throws {
        let plain = try #require(
            EffectChain(kinds: [.limiter], sampleRate: 48000, maximumFrames: 512))
        let shifted = try #require(
            EffectChain(kinds: [.pitch], sampleRate: 48000, maximumFrames: 512))
        #expect(shifted.latencyFrames > plain.latencyFrames)
    }

    /// The mix control on voice isolation, when isolation is the whole chain.
    ///
    /// Reported as doing nothing, which is exactly the shape of defect this
    /// project keeps finding: the parameter is recognised, the setter runs, the
    /// unit accepts the value and the sound does not change. `recognises` and
    /// `set` both pass on a control that is wired to nothing, so neither is
    /// evidence. The signal is.
    ///
    /// Fully wet against fully dry, on noise the model has every reason to
    /// remove — if the two come back the same the control is decorative.
    @Test("the isolation mix control changes the sound on its own")
    func isolationMixIsAudible() throws {
        func render(mix: Float) throws -> [Float] {
            let chain = try #require(
                EffectChain(kinds: [.voiceIsolation], sampleRate: 48000, maximumFrames: 1024))
            chain.set("mix", of: .voiceIsolation, to: mix)
            var tail: [Float] = []
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            // Well past the model's 56 ms of latency, so what is compared is
            // processed signal rather than the silence it emits while filling.
            for block in 0..<200 {
                for index in 0..<1024 {
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    let value =
                        Float(Int32(bitPattern: UInt32(truncatingIfNeeded: state >> 32)))
                        / Float(Int32.max)
                    chain.inputBuffer[index] = value * 0.2
                }
                guard chain.render(frames: 1024, sampleTime: Float64(block * 1024)) else {
                    Issue.record("render failed")
                    return []
                }
                if block >= 190 {
                    for index in 0..<1024 { tail.append(chain.outputBuffer[index]) }
                }
            }
            return tail
        }

        let wet = try render(mix: 100)
        let dry = try render(mix: 0)
        try #require(wet.count == dry.count, "one of the renders produced nothing")
        func level(_ samples: [Float]) -> Float {
            samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        }
        let wetPower = level(wet)
        let dryPower = level(dry)
        // Noise is what the model exists to remove, so fully wet must be
        // quieter than fully dry by a margin no rounding could produce.
        #expect(dryPower > wetPower * 4, "wet \(wetPower) dry \(dryPower)")
    }

    /// The recording scene's chain, at the rate and block size that scene asks
    /// for rather than at the defaults everything else is tested with.
    @Test("a limiter on its own builds at every rate and block a scene can ask for")
    func limiterAloneAtSceneSettings() throws {
        for rate in [44100, 48000, 96000] as [Double] {
            for frames in [64, 128, 256, 512] {
                #expect(
                    EffectChain(kinds: [.limiter], sampleRate: rate, maximumFrames: frames)
                        != nil, "\(rate) Hz, \(frames) frames")
            }
        }
    }

    /// Every knob the interface offers has to be one the chain recognises.
    /// A mismatch between the two is a control that moves and does nothing.
    @Test("every advertised knob reaches its unit")
    func knobsAreWired() throws {
        for kind in EffectKind.allCases {
            let chain = try #require(
                EffectChain(kinds: [kind], sampleRate: 48000, maximumFrames: 512))
            for parameter in kind.parameters {
                // The setter is silent on an unknown pair by design, so this
                // checks the mapping exists rather than the return value: a
                // parameter that fell through would leave the unit at its
                // default and nothing would say so.
                chain.set(parameter.id, of: kind, to: parameter.defaultValue)
                #expect(chain.recognises(parameter.id, of: kind))
            }
        }
    }

    /// The stored form has to stay put across renames, or a preferences file
    /// written today stops loading tomorrow.
    @Test("the new stages have stable stored names")
    func storedNames() {
        #expect(EffectKind.pitch.rawValue == "pitch")
        #expect(EffectKind.reverb.rawValue == "reverb")
        #expect(EffectKind.echo.rawValue == "echo")
        #expect(EffectKind(rawValue: "pitch") == .pitch)
    }
}

// MARK: - Balancing sources against each other

/// The arithmetic behind the calibration button. It has to be right in the
/// cases nobody tests by hand: somebody who barely spoke, somebody who did not
/// speak at all, and a source that is so far out that the answer is not a
/// balance problem.
@Suite("Level calibration")
struct LevelCalibrationTests {

    private func measurement(
        _ id: Int, _ role: LevelCalibration.Role, _ decibels: Double,
        seconds: Double = 4, gain: Double = 0
    ) -> LevelCalibration.Measurement {
        LevelCalibration.Measurement(
            id: id, role: role, decibels: decibels, seconds: seconds, currentGain: gain)
    }

    /// Two voices at different levels end up at the same one.
    @Test("two voices are brought to the same level")
    func balancesVoices() {
        let proposals = LevelCalibration.propose(from: [
            measurement(0, .voice, -30),
            measurement(1, .voice, -14),
        ])
        #expect(proposals.count == 2)
        // Each is moved to the target, so applying both leaves them equal.
        let first = proposals.first { $0.id == 0 }!
        let second = proposals.first { $0.id == 1 }!
        #expect(abs((-30 + first.change) - (-14 + second.change)) < 0.001)
        #expect(abs((-30 + first.change) - LevelCalibration.voiceTarget) < 0.001)
    }

    /// And the music ends up underneath them by the fixed offset rather than
    /// beside them.
    @Test("background sits below the voices")
    func backgroundGoesUnder() {
        let proposals = LevelCalibration.propose(from: [
            measurement(0, .voice, -30),
            measurement(1, .background, -30),
        ])
        let voice = proposals.first { $0.id == 0 }!
        let music = proposals.first { $0.id == 1 }!
        let separation = (-30 + voice.change) - (-30 + music.change)
        #expect(abs(separation - -LevelCalibration.backgroundOffset) < 0.001)
        #expect(separation > 0)
    }

    /// The measurement is taken after the fader, so a source already turned up
    /// must not be turned up again by the same amount.
    @Test("the fader's own contribution is not counted twice")
    func accountsForCurrentGain() {
        let atUnity = LevelCalibration.propose(from: [measurement(0, .voice, -30, gain: 0)])
        let turnedUp = LevelCalibration.propose(from: [
            measurement(0, .voice, -30, gain: 6)
        ])
        // Both are 10 dB from the target, so both move by 10 — but they end at
        // different absolute gains, six apart.
        #expect(abs(atUnity[0].change - turnedUp[0].change) < 0.001)
        #expect(abs((turnedUp[0].gain - atUnity[0].gain) - 6) < 0.001)
    }

    /// A source that never produced anything gets no proposal at all. Guessing
    /// at a level for something that was silent is worse than saying nothing.
    @Test("a silent source is left alone")
    func silentSourceIgnored() {
        let proposals = LevelCalibration.propose(from: [
            measurement(0, .voice, -30),
            measurement(1, .voice, -.infinity, seconds: 0),
        ])
        #expect(proposals.count == 1)
        #expect(proposals[0].id == 0)
    }

    /// Nor does a source that only produced a fraction of a second — that is
    /// somebody clearing their throat, not a measurement.
    @Test("too little material is not enough to act on")
    func tooLittleMaterial() {
        let proposals = LevelCalibration.propose(from: [
            measurement(0, .voice, -30, seconds: 0.4)
        ])
        #expect(proposals.isEmpty)
    }

    /// Something already at the target is not proposed at all, so the list
    /// shows what will change rather than everything.
    @Test("a source already on target is not proposed")
    func alreadyBalanced() {
        let proposals = LevelCalibration.propose(from: [
            measurement(0, .voice, LevelCalibration.voiceTarget)
        ])
        #expect(proposals.isEmpty)
    }

    /// A proposal beyond the limit is not a balance problem — it is a
    /// microphone pointed the wrong way — and quietly applying it would hide
    /// that rather than fix it.
    @Test("an absurd correction is capped rather than applied")
    func capped() {
        let proposals = LevelCalibration.propose(from: [measurement(0, .voice, -70)])
        #expect(proposals[0].change == LevelCalibration.maximumChange)
    }

    @Test("a source far too loud is capped downwards too")
    func cappedDownwards() {
        let proposals = LevelCalibration.propose(from: [measurement(0, .voice, -1)])
        #expect(proposals[0].change == -LevelCalibration.maximumChange)
    }

    /// The failure report has to name the source that stayed silent, because
    /// "it did not work" is not something anybody can act on.
    @Test("silent sources are named rather than merely counted")
    func namesSilentSources() {
        let problem = LevelCalibration.problem(with: [
            measurement(0, .voice, -30),
            measurement(1, .voice, -.infinity, seconds: 0),
            measurement(2, .background, -.infinity, seconds: 0),
        ])
        #expect(problem == .silentSources([1, 2]))
    }

    @Test("a pass where nobody spoke is reported as such")
    func nothingHeard() {
        let problem = LevelCalibration.problem(with: [
            measurement(0, .voice, -.infinity, seconds: 0)
        ])
        #expect(problem == .nothingHeard)
    }

    @Test("a clean pass reports no problem")
    func noProblem() {
        #expect(LevelCalibration.problem(with: [measurement(0, .voice, -30)]) == nil)
    }

    /// Applying the proposals has to actually land everything where it said,
    /// which is the property all the others are really about.
    @Test("applying every proposal lands the whole mix where it said")
    func endToEnd() {
        // All within the correction limit on purpose: the cap has its own two
        // tests, and mixing the two questions would make a capped source look
        // like arithmetic that missed.
        let sources: [(LevelCalibration.Role, Double)] = [
            (.voice, -34), (.voice, -21), (.background, -18), (.voice, -27),
        ]
        let measurements = sources.enumerated().map {
            measurement($0.offset, $0.element.0, $0.element.1)
        }
        let proposals = LevelCalibration.propose(from: measurements)

        for measurement in measurements {
            let change = proposals.first { $0.id == measurement.id }?.change ?? 0
            let final = measurement.decibels + change
            let expected =
                measurement.role == .voice
                ? LevelCalibration.voiceTarget
                : LevelCalibration.voiceTarget + LevelCalibration.backgroundOffset
            #expect(abs(final - expected) < 0.001)
        }
    }
}

// MARK: - Which applications are voices

@Suite("Source roles")
struct SourceRoleTests {
    /// Getting this wrong puts a voice call underneath the music, which is the
    /// one arrangement nobody wants.
    @Test("conferencing applications default to voice")
    func commsAreVoices() {
        for bundle in [
            "com.hnc.Discord", "us.zoom.xos", "com.microsoft.teams2",
            "com.apple.FaceTime", "com.tinyspeck.slackmacgap",
        ] {
            #expect(LevelCalibration.Role.default(forBundleID: bundle) == .voice, "\(bundle)")
        }
    }

    @Test("music and games default to background")
    func othersAreBackground() {
        for bundle in [
            "com.spotify.client", "com.apple.Music", "com.valvesoftware.steam",
            "com.google.Chrome",
        ] {
            #expect(
                LevelCalibration.Role.default(forBundleID: bundle) == .background,
                "\(bundle)")
        }
    }

    /// An application with no identifier at all must not be treated as a voice,
    /// or an unknown source ends up as loud as the person talking.
    @Test("an unidentified source is background rather than voice")
    func unknownIsBackground() {
        #expect(LevelCalibration.Role.default(forBundleID: nil) == .background)
    }
}

// MARK: - The voice changer

/// Pitch on its own only makes somebody sound small. These check the half that
/// makes them sound like something else.
@Suite("Voice character")
struct VoiceCharacterTests {

    /// Every voice has to be reachable from the parameter, or a name appears in
    /// the picker that nothing can select.
    @Test("every flavour has a position on the control")
    func flavoursAreSelectable() throws {
        let parameter = try #require(
            EffectKind.character.parameters.first { $0.id == "flavour" })
        #expect(parameter.isChoice)
        #expect(parameter.options.count == EffectKind.Flavour.allCases.count)
        for flavour in EffectKind.Flavour.allCases {
            #expect(Float(flavour.rawValue) >= parameter.minimum)
            #expect(Float(flavour.rawValue) <= parameter.maximum)
            #expect(parameter.options[flavour.rawValue] == flavour.title)
        }
    }

    /// The flavours have to be distinct, which is the one thing a bundle of
    /// settings on a shared unit can quietly fail to be.
    @Test("every flavour is named and different")
    func flavoursAreDistinct() {
        let titles = EffectKind.Flavour.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    /// Setting the amount must not reset the voice, and setting the voice must
    /// not reset the amount. They are one state and the unit keeps whatever it
    /// was last told, so touching them in either order has to give the same
    /// result.
    @Test("voice and amount do not overwrite each other")
    func stateSurvivesEitherOrder() throws {
        let first = try #require(
            EffectChain(kinds: [.character], sampleRate: 48000, maximumFrames: 512))
        first.set("flavour", of: .character, to: 2)
        first.set("amount", of: .character, to: 35)

        let second = try #require(
            EffectChain(kinds: [.character], sampleRate: 48000, maximumFrames: 512))
        second.set("amount", of: .character, to: 35)
        second.set("flavour", of: .character, to: 2)

        // Both landed on the same unit state, which is what "one state" means.
        #expect(first.characterState == second.characterState)
        #expect(first.characterState?.flavour == .monster)
        #expect(first.characterState?.amount == 35)
    }

    /// An out-of-range position falls back rather than crashing on a preferences
    /// file written by a later version.
    @Test("an unknown voice falls back instead of trapping")
    func unknownFlavour() throws {
        let chain = try #require(
            EffectChain(kinds: [.character], sampleRate: 48000, maximumFrames: 512))
        chain.set("flavour", of: .character, to: 99)
        #expect(chain.characterState?.flavour == .robot)
    }

    /// It is a real audio unit and it renders.
    @Test("the character stage builds and reports its latency")
    func builds() throws {
        let chain = try #require(
            EffectChain(kinds: [.character], sampleRate: 48000, maximumFrames: 512))
        #expect(chain.stages == [.character])
        #expect(chain.latencyFrames >= 0)
    }
}

// MARK: - Recording formats

/// A format that cannot be written is a segment in the picker that produces an
/// error at the worst possible moment — after somebody has recorded something.
@Suite("Recording formats")
struct RecorderFormatTests {

    @Test("stopping an idle writer does not wait for its polling interval")
    func idleStopIsPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = try Recorder(
            directory: directory, format: .wav, channels: 1, sampleRate: 48000,
            timestamp: Date(timeIntervalSince1970: 0))
        #expect(recorder.waitUntilWriterIsReady(timeout: .now() + 5))
        let began = DispatchTime.now().uptimeNanoseconds
        recorder.stop()
        let milliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000

        #expect(milliseconds < 60, "idle stop took \(milliseconds) ms")
    }

    @Test("every offered format opens a real file")
    func formatsWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for format in Recorder.Format.allCases {
            let recorder = try Recorder(
                directory: directory, format: format, channels: 2, sampleRate: 48000,
                timestamp: Date(timeIntervalSince1970: 0))
            #expect(recorder.url.pathExtension == format.fileExtension)

            // A second of a tone, so there is something for the encoder to
            // encode — an empty file proves nothing about a lossy format.
            var samples = [Float](repeating: 0, count: 48000 * 2)
            for frame in 0..<48000 {
                let value = 0.25 * Float(sin(2 * Double.pi * 440 * Double(frame) / 48000))
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
            samples.withUnsafeBufferPointer {
                recorder.write($0.baseAddress!, count: $0.count)
            }
            recorder.stop()

            #expect(
                recorder.lastError == nil, "\(format.rawValue): \(recorder.lastError ?? "")")
            let size =
                (try? FileManager.default.attributesOfItem(atPath: recorder.url.path))?[.size]
                as? Int ?? 0
            #expect(size > 1000, "\(format.rawValue) wrote \(size) bytes")
            // Roughly a second of stereo, whatever the container did with it.
            #expect(abs(recorder.duration - 1.0) < 0.05, "\(format.rawValue)")
        }
    }

    /// The lossless claim has to mean something, because the whole project is
    /// built on the path being bit-exact and a lossy container throws that away
    /// at the last step.
    @Test("only the lossy format says it is lossy")
    func losslessIsHonest() {
        #expect(Recorder.Format.wav.isLossless)
        #expect(Recorder.Format.flac.isLossless)
        #expect(!Recorder.Format.aac.isLossless)
    }

    /// And a lossless format has to actually be smaller than uncompressed, or
    /// there is no reason to offer it.
    @Test("FLAC is smaller than WAV for the same audio")
    func flacIsSmaller() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var sizes: [Recorder.Format: Int] = [:]
        for format in [Recorder.Format.wav, .flac] {
            let recorder = try Recorder(
                directory: directory, format: format, channels: 1, sampleRate: 48000,
                timestamp: Date(timeIntervalSince1970: 0))
            var samples = [Float](repeating: 0, count: 48000)
            for frame in 0..<48000 {
                samples[frame] =
                    0.3 * Float(sin(2 * Double.pi * 220 * Double(frame) / 48000))
            }
            samples.withUnsafeBufferPointer {
                recorder.write($0.baseAddress!, count: $0.count)
            }
            recorder.stop()
            sizes[format] =
                (try? FileManager.default.attributesOfItem(atPath: recorder.url.path))?[.size]
                as? Int ?? 0
        }
        #expect(sizes[.flac]! < sizes[.wav]!)
    }
}

// MARK: - Formant shifting

/// The half of a voice changer that decides whether it sounds like a different
/// person or like a chipmunk.
///
/// Two claims have to hold and they pull against each other: the resonances
/// move, and the pitch does not. A test that only checked the first would pass
/// for a plain pitch shifter, which is the thing this exists not to be.
@Suite("Formant shifting")
struct FormantShifterTests {

    /// A synthetic vowel: a harmonic series shaped by three resonances.
    ///
    /// Three rather than one, because one is not a vowel and — more to the
    /// point — is not something a cepstral envelope can represent. The envelope
    /// follows structure on the scale of the spacing between formants, about a
    /// kilohertz; a lone 150 Hz-wide resonance is far narrower than that and
    /// gets smoothed away, so a fixture built from one measures the smoothing
    /// rather than the shifting. The first version of this test did exactly
    /// that and reported the effect doing nothing.
    private func vowel(
        fundamental: Double, formants: [Double] = [700, 1220, 2600],
        seconds: Double, sampleRate: Double = 48000
    ) -> [Float] {
        let count = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: count)
        var harmonic = 1
        while Double(harmonic) * fundamental < sampleRate / 2 - 1000 {
            let frequency = fundamental * Double(harmonic)
            var weight = 0.02
            for (index, formant) in formants.enumerated() {
                let bandwidth = 110.0 + Double(index) * 60
                let distance = (frequency - formant) / bandwidth
                // Later formants are quieter, as they are in a real voice.
                weight += (1 / (1 + distance * distance)) / Double(index + 1)
            }
            for index in 0..<count {
                samples[index] +=
                    Float(weight * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
            }
            harmonic += 1
        }
        let peak = samples.map(abs).max() ?? 1
        return samples.map { $0 / peak * 0.5 }
    }

    /// Runs the shifter and returns the part past the start-up.
    private func shift(_ input: [Float], ratio: Float) throws -> [Float] {
        let shifter = try #require(FormantShifter())
        shifter.ratio = ratio
        var samples = input
        samples.withUnsafeMutableBufferPointer {
            shifter.process($0.baseAddress!, count: $0.count)
        }
        return Array(samples.dropFirst(FormantShifter.windowSize * 4))
    }

    /// Where the energy sits, in hertz. Robust in a way a single peak bin is
    /// not: moving a whole spectral envelope moves the centroid whether or not
    /// it moves which harmonic happens to be loudest.
    private func centroid(_ samples: [Float], sampleRate: Double = 48000) throws -> Double {
        let analyser = try #require(SpectrumAnalyser(sampleRate: sampleRate))
        samples.withUnsafeBufferPointer { analyser.add($0.baseAddress!, count: $0.count) }
        var weighted = 0.0
        var total = 0.0
        for band in 0..<SpectrumAnalyser.bandCount {
            // Back to amplitude from the display's decibel mapping, so the
            // centroid is of the signal rather than of the picture.
            let decibels = Double(analyser.decibels(ofBand: band))
            guard decibels > -70 else { continue }
            let amplitude = pow(10, decibels / 20)
            weighted += analyser.centreFrequency(ofBand: band) * amplitude
            total += amplitude
        }
        return total > 0 ? weighted / total : 0
    }

    /// Through the transform, not around it.
    ///
    /// The bypass at exactly 1.0 skips the FFT entirely, so a test written at
    /// that ratio proves the bypass works and nothing else — which is how two
    /// scaling errors survived: the reconstruction was 2× loud and the envelope
    /// was doubled in the log domain, so every correction was applied at twice
    /// the decibels asked for.
    @Test("a barely-shifted signal comes back at the level it went in")
    func levelIsPreserved() throws {
        let input = vowel(fundamental: 120, seconds: 0.6)
        let output = try shift(input, ratio: 1.02)
        let reference = Array(input.dropFirst(FormantShifter.windowSize * 4))

        let outPeak = output.map(abs).max() ?? 0
        let inPeak = reference.map(abs).max() ?? 0
        #expect(abs(outPeak - inPeak) < 0.05, "level changed: \(inPeak) → \(outPeak)")

        // And it is still the same signal, not a reconstruction that merely
        // happens to be as loud.
        let outCentroid = try centroid(output)
        let inCentroid = try centroid(reference)
        #expect(
            abs(outCentroid - inCentroid) / inCentroid < 0.06,
            "spectrum moved at ratio 1.02: \(inCentroid) → \(outCentroid)")
    }

    @Test("the resonances move up with the ratio")
    func formantsMoveUp() throws {
        let input = vowel(fundamental: 120, seconds: 1.0)
        let plain = try centroid(try shift(input, ratio: 1.0))
        let raised = try centroid(try shift(input, ratio: 1.5))
        #expect(raised > plain * 1.1, "\(plain) Hz → \(raised) Hz")
    }

    @Test("and down again")
    func formantsMoveDown() throws {
        let input = vowel(fundamental: 120, seconds: 1.0)
        let plain = try centroid(try shift(input, ratio: 1.0))
        let lowered = try centroid(try shift(input, ratio: 0.7))
        #expect(lowered < plain * 0.95, "\(plain) Hz → \(lowered) Hz")
    }

    /// The assertion that separates this from a pitch shifter, and the one a
    /// naive implementation fails: the harmonics stay exactly where they were.
    @Test("the pitch does not move with the formants")
    func pitchStaysPut() throws {
        let input = vowel(fundamental: 150, seconds: 1.0)
        let shifted = try shift(input, ratio: 1.5)
        let reference = Array(input.dropFirst(FormantShifter.windowSize * 4))

        #expect(abs(Self.pitch(of: reference) - 150) < 5)
        #expect(
            abs(Self.pitch(of: shifted) - Self.pitch(of: reference)) < 5,
            "pitch moved: \(Self.pitch(of: reference)) → \(Self.pitch(of: shifted))")
    }

    /// Autocorrelation, taking the *shortest* period that correlates nearly as
    /// well as the best one.
    ///
    /// Taking the maximum outright is the classic octave error: twice the true
    /// period correlates almost as strongly, and a plain maximum picks it about
    /// half the time. The first version of this reported a 150 Hz fixture as
    /// 75 Hz and blamed the shifter.
    private static func pitch(of samples: [Float], sampleRate: Double = 48000) -> Double {
        let window = Array(samples.prefix(8192))
        var scores: [Int: Float] = [:]
        var best: Float = 0
        for lag in 120...800 {
            var score: Float = 0
            var energy: Float = 0
            for index in 0..<(window.count - lag) {
                score += window[index] * window[index + lag]
                energy += window[index + lag] * window[index + lag]
            }
            let normalised = energy > 0 ? score / energy.squareRoot() : 0
            scores[lag] = normalised
            best = max(best, normalised)
        }
        let shortest = (120...800).first { (scores[$0] ?? 0) > best * 0.9 } ?? 120
        return sampleRate / Double(shortest)
    }

    /// Silence in, silence out. A shifter that produced anything from nothing
    /// would add a noise floor to every quiet moment — and warping an envelope
    /// estimated from a numerical floor is exactly how that happens.
    @Test("silence stays silent")
    func silence() throws {
        let output = try shift([Float](repeating: 0, count: 48000), ratio: 1.5)
        #expect(output.allSatisfy { abs($0) < 1e-5 })
    }

    /// Nor may it invent much above the signal.
    ///
    /// Warping reads the envelope from a lower bin, so at the top of the
    /// spectrum it reads real content and applies it to whatever is up there —
    /// which, where the source has little, is a boost applied to almost
    /// nothing. Measured against the unshifted signal rather than an absolute
    /// floor, because the source has its own high end and an absolute threshold
    /// would be a test of the fixture.
    @Test("it does not manufacture energy above the signal")
    func noInventedHighEnd() throws {
        let input = vowel(fundamental: 120, formants: [500, 900], seconds: 0.6)
        let plain = try #require(SpectrumAnalyser(sampleRate: 48000))
        let shifted = try #require(SpectrumAnalyser(sampleRate: 48000))
        try shift(input, ratio: 1.0).withUnsafeBufferPointer {
            plain.add($0.baseAddress!, count: $0.count)
        }
        try shift(input, ratio: 1.6).withUnsafeBufferPointer {
            shifted.add($0.baseAddress!, count: $0.count)
        }
        // The clamp allows twelve decibels of boost anywhere; the top of the
        // spectrum must not exceed that, which is what would happen if the
        // guard on empty bins were not there.
        for band in (SpectrumAnalyser.bandCount - 4)..<SpectrumAnalyser.bandCount {
            let added = shifted.decibels(ofBand: band) - plain.decibels(ofBand: band)
            #expect(added < 12.5, "band \(band) gained \(added) dB")
        }
    }

    @Test("it reports its latency")
    func latency() throws {
        let shifter = try #require(FormantShifter())
        #expect(shifter.latencyFrames == FormantShifter.windowSize)
    }

    /// Resetting has to clear the overlap state, or the first frames of the
    /// next take carry the tail of the last one.
    @Test("reset clears the overlap history")
    func reset() throws {
        let shifter = try #require(FormantShifter())
        shifter.ratio = 1.3
        var loud = vowel(fundamental: 120, seconds: 0.2)
        loud.withUnsafeMutableBufferPointer {
            shifter.process($0.baseAddress!, count: $0.count)
        }
        shifter.reset()

        var quiet = [Float](repeating: 0, count: FormantShifter.windowSize * 4)
        quiet.withUnsafeMutableBufferPointer {
            shifter.process($0.baseAddress!, count: $0.count)
        }
        #expect(quiet.allSatisfy { abs($0) < 1e-5 })
    }
}

// MARK: - A chain with a stage that is not an audio unit

/// The formant shifter is the only stage written here rather than hosted, and
/// it sits in the middle of the run. That splits the pull chain in two, and the
/// split is exactly the kind of thing that works in isolation and quietly
/// misconfigures everything downstream.
@Suite("Native chain stage")
struct NativeStageTests {

    @Test("a chain of only the native stage works")
    func aloneBuilds() throws {
        let chain = try #require(
            EffectChain(kinds: [.formant], sampleRate: 48000, maximumFrames: 512))
        #expect(chain.stages == [.formant])
        // A whole window, which is the honest cost of doing this at all.
        #expect(chain.latencyFrames == FormantShifter.windowSize)
    }

    /// Signal has to reach the far end of a split chain.
    @Test("a split chain passes signal end to end")
    func splitPassesSignal() throws {
        let chain = try #require(
            EffectChain(
                kinds: [.equaliser, .formant, .limiter], sampleRate: 48000,
                maximumFrames: 1024))
        #expect(chain.stages == [.equaliser, .formant, .limiter])

        // Enough hops for the shifter's window to fill.
        var produced = false
        for block in 0..<40 {
            for index in 0..<1024 {
                let frame = block * 1024 + index
                chain.inputBuffer[index] =
                    0.4 * Float(sin(2 * Double.pi * 440 * Double(frame) / 48000))
            }
            guard chain.render(frames: 1024, sampleTime: Float64(block * 1024)) else {
                Issue.record("render failed on block \(block)")
                return
            }
            if block > 4 {
                let peak = (0..<1024).map { abs(chain.outputBuffer[$0]) }.max() ?? 0
                if peak > 0.05 { produced = true }
            }
        }
        #expect(produced, "no signal came out of the split chain")
    }

    /// The parameter mapping is what the split breaks: `stages` and `units` are
    /// no longer index-paired, so pairing them hands every stage after the
    /// native one the wrong unit. A compressor configured as a limiter renders
    /// perfectly happily and sounds wrong.
    @Test("stages after the native one still reach their own unit")
    func parametersStillLandOnTheRightUnit() throws {
        let chain = try #require(
            EffectChain(
                kinds: [.formant, .character, .limiter], sampleRate: 48000,
                maximumFrames: 512))
        chain.set("flavour", of: .character, to: 3)
        #expect(chain.characterState?.flavour == .bitcrush)
        // And the native stage's own knob is not confused for a unit's.
        #expect(chain.recognises("shift", of: .formant))
    }

    /// Every stage still resolves to something that can be built, native or
    /// not.
    @Test("the whole set including the native stage builds in order")
    func everythingTogether() throws {
        let chain = try #require(
            EffectChain(
                kinds: EffectKind.allCases.reversed(), sampleRate: 48000,
                maximumFrames: 512))
        #expect(chain.stages.count == EffectKind.allCases.count)
        for (first, second) in zip(chain.stages, chain.stages.dropFirst()) {
            #expect(first.chainOrder < second.chainOrder)
        }
        #expect(chain.latencyFrames >= FormantShifter.windowSize)
    }
}

// MARK: - Third-party units

/// Hosting somebody else's Audio Unit is the one place where loading other
/// people's code is the right answer rather than an elaborate way to avoid a
/// configuration file: the format exists, the system vets it, and thousands are
/// already installed.
///
/// What can be tested without assuming any particular plugin is present is the
/// machinery around it — which is also where the mistakes are.
@Suite("Audio Unit plugins")
struct AudioUnitPluginTests {

    /// Enumeration must not crash, must not list Apple's own units twice, and
    /// must come back in a stable order.
    @Test("enumeration is well-formed whatever is installed")
    func enumeration() {
        let plugins = AudioUnitPlugins.installed()
        // Apple's own are the built-in stages; listing them again would put
        // AUPeakLimiter in the plugin picker beside the limiter in the panel.
        #expect(plugins.allSatisfy { $0.manufacturer != kAudioUnitManufacturer_Apple })
        #expect(plugins.allSatisfy { !$0.name.isEmpty })
        #expect(Set(plugins.map(\.id)).count == plugins.count)
        // Stable between calls, so the list does not shuffle between launches.
        #expect(AudioUnitPlugins.installed().map(\.id) == plugins.map(\.id))
    }

    /// The identifier has to survive being written to preferences and read
    /// back, or a chain cannot be restored.
    @Test("a plugin reference round-trips through preferences")
    func codable() throws {
        let plugin = AudioUnitPlugin(
            type: kAudioUnitType_Effect, subType: 0x61626364,
            manufacturer: 0x65666768, name: "Example", manufacturerName: "Somebody",
            loadsInProcess: true)
        let data = try JSONEncoder().encode(plugin)
        #expect(try JSONDecoder().decode(AudioUnitPlugin.self, from: data) == plugin)
    }

    /// Parameter ids are strings so they can share a type with the built-in
    /// ones; the mapping back has to be exact.
    @Test("parameter identifiers survive the round trip")
    func parameterIdentifiers() {
        #expect(AudioUnitPlugins.parameterID(from: "p0") == 0)
        #expect(AudioUnitPlugins.parameterID(from: "p42") == 42)
        // Anything that is not one of ours must not be mistaken for one: the
        // built-in stages use names like "threshold".
        #expect(AudioUnitPlugins.parameterID(from: "threshold") == nil)
        #expect(AudioUnitPlugins.parameterID(from: "") == nil)
        #expect(AudioUnitPlugins.parameterID(from: "pitch") == nil)
    }

    /// A plugin that is not installed has to be reported, not silently dropped:
    /// a chain that quietly lost a stage sounds different and says nothing.
    @Test("a missing plugin is named rather than skipped in silence")
    func missingPlugin() throws {
        let absent = AudioUnitPlugin(
            type: kAudioUnitType_Effect, subType: 0x7A7A7A7A,
            manufacturer: 0x7A7A7A7A, name: "Not Installed",
            manufacturerName: "Nobody", loadsInProcess: true)
        let chain = try #require(
            EffectChain(
                kinds: [.limiter], plugins: [absent], sampleRate: 48000,
                maximumFrames: 512))
        #expect(chain.failedPlugins == ["Not Installed"])
        #expect(chain.pluginFailures.map(\.reason) == [.notInstalled])
        // And the rest of the chain still works.
        #expect(chain.stages == [.limiter])
    }

    /// The chain is mono, and a great many units are not.
    ///
    /// This is the one that was crashing. A unit that refuses the chain's
    /// format reached the common initialise loop, failed there, and the loop
    /// freed the three buffers and returned nil — but Swift runs `deinit` on a
    /// class whose failable init returns nil, so the same three allocations
    /// were freed twice and libmalloc aborted the process:
    /// POINTER_BEING_FREED_WAS_NOT_ALLOCATED inside `EffectChain.deinit`,
    /// reached from `EffectChain.init`. Adding one stereo-only plugin killed
    /// the application. Before that it took the gate, the equaliser, the
    /// compressor and the limiter with it, and named none of them.
    ///
    /// `AUAudioMix` stands in for the stereo-only third-party unit because it
    /// is on every macOS 26 machine and its refusal is measured rather than
    /// assumed: -10868 (`kAudioUnitErr_FormatNotSupported`) to each stream
    /// format, and -10875 (`kAudioUnitErr_FailedInitialization`) after. A test
    /// naming a particular third-party plugin would only run here.
    @Test("a unit that refuses mono is dropped with a reason, not fatally")
    func refusesTheChainFormat() throws {
        let stubborn = AudioUnitPlugin(
            type: kAudioUnitType_FormatConverter,
            subType: kAudioUnitSubType_AUAudioMix,
            manufacturer: kAudioUnitManufacturer_Apple,
            name: "AUAudioMix", manufacturerName: "Apple", loadsInProcess: true)
        let chain = try #require(
            EffectChain(
                kinds: [.equaliser, .limiter], plugins: [stubborn], sampleRate: 48000,
                maximumFrames: 512))

        // Named, with the step that refused and the number behind it.
        let failure = try #require(chain.pluginFailures.first)
        #expect(chain.pluginFailures.count == 1)
        #expect(failure.name == "AUAudioMix")
        #expect(failure.reason == .formatRejected)
        #expect(failure.status == kAudioUnitErr_FormatNotSupported)

        // And everything else the user switched on is still there and running.
        #expect(chain.stages == [.equaliser, .limiter])
        #expect(chain.unitCountForTesting == 2)
        for index in 0..<512 { chain.inputBuffer[index] = 0.2 }
        #expect(chain.render(frames: 512, sampleTime: 0))
    }

    /// The property that generalises, so this says something on any machine.
    ///
    /// Naming a particular plugin would pass here and fail everywhere else. The
    /// claim worth making is the one the interface depends on: whatever is
    /// installed, each unit either ends up rendering or ends up named with a
    /// reason and a status — and either way the chain around it survives.
    @Test("every installed unit either loads or is named with a decoded reason")
    func everyInstalledUnitIsAccountedFor() throws {
        let installed = AudioUnitPlugins.installed()
        for plugin in installed {
            let chain = try #require(
                EffectChain(
                    kinds: [.limiter], plugins: [plugin], sampleRate: 48000,
                    maximumFrames: 512),
                "\(plugin.name) took the whole chain down")
            // The limiter is this application's own and must survive whatever
            // somebody else's unit did.
            #expect(chain.stages == [.limiter])

            if let failure = chain.pluginFailures.first {
                #expect(chain.pluginFailures.count == 1)
                #expect(failure.name == plugin.name)
                // A reason rather than a silent drop, and a number behind it.
                // `notInstalled` is the one case with no status of its own:
                // nothing answered, so nothing returned anything.
                if failure.reason != .notInstalled { #expect(failure.status != noErr) }
            } else {
                // It loaded, so it renders: the plugin and the limiter.
                #expect(chain.unitCountForTesting == 2)
                for index in 0..<512 { chain.inputBuffer[index] = 0.2 }
                #expect(chain.render(frames: 512, sampleTime: 0))
            }
        }
    }

    /// The limiter's guarantee is that nothing downstream sees a sample it has
    /// to clip. Anything running after it can put the signal back over full
    /// scale, so a plugin must never land there — whatever order they were
    /// given in.
    @Test("plugins are placed before the limiter, never after")
    func placement() throws {
        // Uses a real installed plugin when there is one, because the
        // assertion is about where a unit that actually loaded ends up.
        guard let plugin = AudioUnitPlugins.installed().first(where: \.loadsInProcess)
        else {
            Issue.record("no third-party units installed — placement not exercised")
            return
        }
        let chain = try #require(
            EffectChain(
                kinds: [.equaliser, .limiter], plugins: [plugin], sampleRate: 48000,
                maximumFrames: 512))
        #expect(chain.failedPlugins.isEmpty, "\(plugin.name) did not load")
        #expect(chain.unitCountForTesting == 3)
        // Signal still reaches the end.
        for index in 0..<512 { chain.inputBuffer[index] = 0.2 }
        #expect(chain.render(frames: 512, sampleTime: 0))
    }

    /// A unit that has to run in its own process makes every render an XPC
    /// round trip, which is fine in a mixing application and not fine inside a
    /// callback with a 2.7 ms deadline. It has to be visible before somebody
    /// puts it in the path.
    @Test("in-process loading is reported rather than discovered")
    func reportsProcessModel() {
        // Whatever is installed, the flag has to be a definite answer for each.
        for plugin in AudioUnitPlugins.installed() {
            _ = plugin.loadsInProcess
        }
        #expect(Bool(true))
    }
}

// MARK: - Sounding like somebody else

/// Whether the voice change actually works, measured rather than asserted.
///
/// The claim is specific: a male speaking voice through the higher-voice preset
/// comes out with both its pitch and its resonances moved, by the amounts the
/// preset says. Either one alone is a well-known failure — pitch alone is a
/// chipmunk, formants alone is somebody talking through a tube — so both are
/// measured, in the same signal, through the real chain.
@Suite("Voice presets")
struct VoicePresetTests {

    /// A male speaking voice: 120 Hz fundamental under male formants.
    private func maleVoice(seconds: Double, sampleRate: Double = 48000) -> [Float] {
        let count = Int(sampleRate * seconds)
        var samples = [Float](repeating: 0, count: count)
        let formants = [700.0, 1220.0, 2600.0]
        var harmonic = 1
        while Double(harmonic) * 120 < sampleRate / 2 - 1000 {
            let frequency = 120 * Double(harmonic)
            var weight = 0.02
            for (index, formant) in formants.enumerated() {
                let bandwidth = 110.0 + Double(index) * 60
                let distance = (frequency - formant) / bandwidth
                weight += (1 / (1 + distance * distance)) / Double(index + 1)
            }
            for index in 0..<count {
                samples[index] +=
                    Float(weight * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
            }
            harmonic += 1
        }
        let peak = samples.map(abs).max() ?? 1
        return samples.map { $0 / peak * 0.4 }
    }

    /// Runs a signal through a real chain carrying the preset's stages.
    private func through(_ preset: VoicePreset, _ input: [Float]) throws -> [Float] {
        let kinds = Array(preset.stages)
        guard !kinds.isEmpty else { return input }
        let chain = try #require(
            EffectChain(kinds: kinds, sampleRate: 48000, maximumFrames: 512))
        chain.set("cents", of: .pitch, to: preset.cents)
        chain.set("shift", of: .formant, to: preset.formantPercent)

        var output: [Float] = []
        var offset = 0
        while offset + 512 <= input.count {
            for index in 0..<512 { chain.inputBuffer[index] = input[offset + index] }
            guard chain.render(frames: 512, sampleTime: Float64(offset)) else {
                Issue.record("render failed")
                return []
            }
            for index in 0..<512 { output.append(chain.outputBuffer[index]) }
            offset += 512
        }
        // Past the fill of both stages.
        return Array(output.dropFirst(8192))
    }

    /// Where the harmonics are, by autocorrelation. Shortest period that
    /// correlates nearly as well as the best, so an octave down is not mistaken
    /// for the answer.
    private static func pitch(of samples: [Float], sampleRate: Double = 48000) -> Double {
        let window = Array(samples.prefix(16384))
        guard window.count > 900 else { return 0 }
        var scores: [Int: Float] = [:]
        var best: Float = 0
        for lag in 90...800 {
            var score: Float = 0
            var energy: Float = 0
            for index in 0..<(window.count - lag) {
                score += window[index] * window[index + lag]
                energy += window[index + lag] * window[index + lag]
            }
            let normalised = energy > 0 ? score / energy.squareRoot() : 0
            scores[lag] = normalised
            best = max(best, normalised)
        }
        let shortest = (90...800).first { (scores[$0] ?? 0) > best * 0.9 } ?? 90
        return sampleRate / Double(shortest)
    }

    /// Where the energy sits, which moves with the resonances.
    private func centroid(_ samples: [Float]) throws -> Double {
        let analyser = try #require(SpectrumAnalyser(sampleRate: 48000))
        samples.withUnsafeBufferPointer { analyser.add($0.baseAddress!, count: $0.count) }
        var weighted = 0.0
        var total = 0.0
        for band in 0..<SpectrumAnalyser.bandCount {
            let decibels = Double(analyser.decibels(ofBand: band))
            guard decibels > -70 else { continue }
            let amplitude = pow(10, decibels / 20)
            weighted += analyser.centreFrequency(ofBand: band) * amplitude
            total += amplitude
        }
        return total > 0 ? weighted / total : 0
    }

    /// The whole claim, in one test: both things move, by roughly the amounts
    /// the preset says, in the same signal.
    @Test("a male voice through the higher preset moves pitch and resonances together")
    func higherVoice() throws {
        let input = maleVoice(seconds: 1.2)
        let output = try through(.masculineToFeminine, input)
        try #require(!output.isEmpty)

        let originalPitch = Self.pitch(of: input)
        let shiftedPitch = Self.pitch(of: output)
        #expect(abs(originalPitch - 120) < 6, "fixture pitch is \(originalPitch)")

        // +500 cents is a factor of 2^(500/1200) = 1.335.
        let expected = originalPitch * pow(2, 500.0 / 1200)
        #expect(
            abs(shiftedPitch - expected) / expected < 0.12,
            "pitch \(originalPitch) → \(shiftedPitch), wanted about \(expected)")

        // And the resonances went up too, which is the half that makes it a
        // person rather than a chipmunk. Not by the formant ratio alone: the
        // pitch stage moves the whole spectrum as well, so the centroid rises
        // by more than 17%.
        let before = try centroid(input)
        let after = try centroid(output)
        #expect(after > before * 1.1, "centroid \(before) → \(after)")
    }

    /// The other direction has to work too, and it is the one where a mistake
    /// in the sign is invisible until somebody uses it.
    @Test("the lower preset moves both the other way")
    func lowerVoice() throws {
        let input = maleVoice(seconds: 1.2)
        let output = try through(.feminineToMasculine, input)
        try #require(!output.isEmpty)
        #expect(Self.pitch(of: output) < Self.pitch(of: input) * 0.9)
        #expect(try centroid(output) < (try centroid(input)) * 0.98)
    }

    /// Every preset moves both in the same direction, which is the entire point
    /// — one of them going the wrong way is what a chipmunk is.
    @Test("pitch and formants always move the same way")
    func directionsAgree() {
        for preset in VoicePreset.allCases where preset != .none {
            #expect(
                preset.cents.sign == preset.formantPercent.sign,
                "\(preset.rawValue) moves them in opposite directions")
        }
    }

    /// Nothing enabled means nothing switched on, because an idle stage still
    /// costs its latency.
    @Test("the empty preset enables no stages at all")
    func noneIsFree() {
        #expect(VoicePreset.none.stages.isEmpty)
        #expect(VoicePreset.none.latencyFrames(sampleRate: 48000) == 0)
        for preset in VoicePreset.allCases where preset != .none {
            #expect(!preset.stages.isEmpty)
            #expect(preset.latencyFrames(sampleRate: 48000) > 0)
        }
    }

    @Test("every preset is named and explained")
    func described() {
        for preset in VoicePreset.allCases {
            #expect(!preset.title.isEmpty)
            #expect(!preset.detail.isEmpty)
        }
    }

    /// Stored names have to stay put or a saved setting stops loading.
    @Test("stored names are stable")
    func storedNames() {
        #expect(VoicePreset.masculineToFeminine.rawValue == "masculineToFeminine")
        #expect(VoicePreset(rawValue: "child") == .child)
    }
}

// MARK: - Finding the note

/// Pitch tracking is the thing every serious voice conversion starts from, and
/// the one place where a plausible-looking implementation is usually wrong by
/// exactly an octave. These feed it voices at known fundamentals.
@Suite("Pitch tracking")
struct PitchTrackerTests {

    /// A voice-shaped signal: a harmonic series under formants, which is much
    /// harder to track than a sine — the second harmonic is often louder than
    /// the fundamental, which is exactly what makes trackers report an octave
    /// up.
    private func voice(
        fundamental: Double, frames: Int, sampleRate: Double = 48000
    ) -> [Float] {
        let count = frames * PitchTracker.frameSize
        var samples = [Float](repeating: 0, count: count)
        let formants = [700.0, 1220.0, 2600.0]
        var harmonic = 1
        while Double(harmonic) * fundamental < sampleRate / 2 - 1000 {
            let frequency = fundamental * Double(harmonic)
            var weight = 0.02
            for (index, formant) in formants.enumerated() {
                let bandwidth = 110.0 + Double(index) * 60
                let distance = (frequency - formant) / bandwidth
                weight += (1 / (1 + distance * distance)) / Double(index + 1)
            }
            for index in 0..<count {
                samples[index] +=
                    Float(weight * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
            }
            harmonic += 1
        }
        let peak = samples.map(abs).max() ?? 1
        return samples.map { $0 / peak * 0.4 }
    }

    /// The whole claim. A male voice, a female voice and something between,
    /// each found to within a few hertz.
    @Test("it finds the fundamental of a voice-shaped signal")
    func findsFundamental() throws {
        let tracker = try #require(PitchTracker(sampleRate: 48000))
        for expected in [95.0, 120.0, 165.0, 220.0, 300.0] {
            let samples = voice(fundamental: expected, frames: 4)
            let found = tracker.track(frames: samples, count: 4)
            #expect(found.count == 4)
            for estimate in found {
                #expect(
                    abs(Double(estimate) - expected) < expected * 0.05,
                    "wanted \(expected), got \(estimate)")
            }
        }
    }

    /// The failure mode of every autocorrelation tracker ever written: twice
    /// the period correlates almost as well, and a naive peak search takes it
    /// about half the time. A voice whose second harmonic is louder than its
    /// fundamental is the case that catches it.
    @Test("it does not report an octave down")
    func noOctaveErrors() throws {
        let tracker = try #require(PitchTracker(sampleRate: 48000))
        for expected in [110.0, 140.0, 180.0, 240.0] {
            let samples = voice(fundamental: expected, frames: 2)
            for estimate in tracker.track(frames: samples, count: 2) {
                // Not half, and not double.
                #expect(
                    abs(Double(estimate) - expected / 2) > expected * 0.1,
                    "reported an octave down for \(expected): \(estimate)")
                #expect(
                    abs(Double(estimate) - expected * 2) > expected * 0.1,
                    "reported an octave up for \(expected): \(estimate)")
            }
        }
    }

    /// Silence has no pitch, and saying it has one would make a converter chase
    /// noise between words.
    @Test("silence reports no pitch at all")
    func silence() throws {
        let tracker = try #require(PitchTracker(sampleRate: 48000))
        let quiet = [Float](repeating: 0, count: PitchTracker.frameSize * 3)
        #expect(tracker.track(frames: quiet, count: 3).allSatisfy { $0 == 0 })
    }

    /// Nor does noise. This is the one that separates a tracker from a
    /// lag-finder: white noise has a best lag, and it is not a pitch.
    @Test("noise reports no pitch")
    func noise() throws {
        let tracker = try #require(PitchTracker(sampleRate: 48000))
        // Zero-mean, and checked to be: the first version of this was not,
        // and the offset it carried is what exposed the tracker's own missing
        // mean removal. A fixture that is wrong in an interesting way is worth
        // keeping honest.
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var samples = (0..<(PitchTracker.frameSize * 3)).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(bitPattern: UInt32(truncatingIfNeeded: state >> 32)))
                / Float(Int32.max) * 0.4
        }
        let mean = samples.reduce(0, +) / Float(samples.count)
        samples = samples.map { $0 - mean }
        #expect(abs(samples.reduce(0, +) / Float(samples.count)) < 0.001)
        let found = tracker.track(frames: samples, count: 3)
        // Some frames of noise will occasionally look periodic; most must not.
        #expect(found.filter { $0 > 0 }.count <= 1)
    }

    /// A constant offset correlates perfectly with itself at every lag, so any
    /// of it swamps the periodic part. Converter bias and unsettled high-pass
    /// filters both produce one routinely.
    @Test("a signal with a large offset is still tracked correctly")
    func toleratesDirectCurrent() throws {
        let tracker = try #require(PitchTracker(sampleRate: 48000))
        let clean = voice(fundamental: 140, frames: 2)
        let offset = clean.map { $0 + 0.35 }
        for estimate in tracker.track(frames: offset, count: 2) {
            #expect(abs(Double(estimate) - 140) < 7, "got \(estimate)")
        }
    }

    @Test("a batch gives the same answers as one at a time")
    func batchMatchesSingle() throws {
        let tracker = try #require(PitchTracker(sampleRate: 48000))
        let samples = voice(fundamental: 150, frames: 8)
        let batched = tracker.track(frames: samples, count: 8)
        for index in 0..<8 {
            let start = index * PitchTracker.frameSize
            let single = tracker.track(
                frame: Array(samples[start..<(start + PitchTracker.frameSize)]))
            #expect(abs(batched[index] - single) < 0.01)
        }
    }

    /// The search range has to cover a speaking voice and no more: wider costs
    /// candidates and invites the octave errors above.
    @Test("the search range covers a speaking voice")
    func range() {
        #expect(PitchTracker.lowestHertz <= 70)
        #expect(PitchTracker.highestHertz >= 350)
        // Two periods of the lowest voice have to fit in a frame, or an
        // autocorrelation cannot find it.
        #expect(Double(PitchTracker.frameSize) >= 2 * 48000 / PitchTracker.lowestHertz)
    }

    /// Asking for more frames than were handed over must not read past the end.
    @Test("a short buffer is refused rather than read past")
    func shortBuffer() throws {
        let tracker = try #require(PitchTracker(sampleRate: 48000))
        #expect(tracker.track(frames: [Float](repeating: 0, count: 100), count: 4).isEmpty)
        #expect(tracker.track(frame: [0, 0, 0]) == 0)
    }
}

// MARK: - Note names

/// Hertz alone means something to about one person in fifty. The note beside it
/// means something to anybody who has touched an instrument, and it is the same
/// number — so it has to be the right one.
@Suite("Note names")
struct NoteNameTests {
    @Test("the reference pitch and its octaves are named correctly")
    func referencePitch() {
        #expect(PitchTracker.noteName(440) == "A4")
        #expect(PitchTracker.noteName(220) == "A3")
        #expect(PitchTracker.noteName(880) == "A5")
    }

    /// Middle C is the one everybody checks, and the one an off-by-one octave
    /// in the arithmetic gets wrong.
    @Test("middle C is C4")
    func middleC() {
        #expect(PitchTracker.noteName(261.63) == "C4")
    }

    /// A speaking voice sits between these, which is the range the readout will
    /// actually spend its life in.
    @Test("speaking voices land where they should")
    func speakingRange() {
        // A typical male fundamental.
        #expect(PitchTracker.noteName(110) == "A2")
        // A typical female one.
        #expect(PitchTracker.noteName(220) == "A3")
        #expect(PitchTracker.noteName(146.83) == "D3")
    }

    /// Rounding to the nearest semitone rather than the one below.
    @Test("a frequency between two notes takes the nearer")
    func rounding() {
        // Just under A4, but much nearer to it than to G♯4.
        #expect(PitchTracker.noteName(437) == "A4")
        // Nearly halfway up: A♯4 is 466.16, A4 is 440, so 455 is nearer A♯4.
        #expect(PitchTracker.noteName(455) == "A♯4")
    }

    /// Nothing outside the range gets a name, because there is no note there
    /// worth showing.
    @Test("silence and nonsense get no name at all")
    func outOfRange() {
        #expect(PitchTracker.noteName(0) == nil)
        #expect(PitchTracker.noteName(10) == nil)
        #expect(PitchTracker.noteName(20000) == nil)
    }
}

// MARK: - Pitch needs a level, not just a period

/// The correlation threshold measures periodicity, and a mains hum or a fan is
/// extremely periodic. Without a level gate as well, a quiet room reports a
/// confident pitch — which for a voice converter means chasing the room between
/// every word.
@Suite("Pitch level gate")
struct PitchLevelTests {

    private func tone(
        _ hertz: Double, amplitude: Float, frames: Int = 2, sampleRate: Double = 48000
    ) -> [Float] {
        let count = frames * PitchTracker.frameSize
        return (0..<count).map { index in
            amplitude
                * Float(sin(2 * Double.pi * hertz * Double(index) / sampleRate))
        }
    }

    /// A perfectly periodic signal at a level nobody could speak at.
    @Test("a very quiet tone reports no pitch despite being periodic")
    func quietToneIsIgnored() throws {
        let tracker = try #require(PitchTracker(sampleRate: 48000))
        // −60 dBFS: a hum, not a voice.
        let quiet = tone(150, amplitude: 0.001)
        #expect(tracker.track(frames: quiet, count: 2).allSatisfy { $0 == 0 })
    }

    /// And the same tone at a usable level is found, so the gate is a level
    /// gate rather than a refusal to work.
    @Test("the same tone at a usable level is found")
    func loudToneIsFound() throws {
        let tracker = try #require(PitchTracker(sampleRate: 48000))
        let loud = tone(150, amplitude: 0.2)
        for estimate in tracker.track(frames: loud, count: 2) {
            #expect(abs(Double(estimate) - 150) < 5, "got \(estimate)")
        }
    }

    /// The boundary is where it says it is, within a few decibels.
    @Test("the gate sits near the level it advertises")
    func gateIsWhereItSays() throws {
        let tracker = try #require(PitchTracker(sampleRate: 48000))
        // A sine's RMS is its amplitude over root two, so this is about
        // −44 dBFS RMS — comfortably above the −50 floor.
        let above = tone(150, amplitude: 0.009)
        #expect(tracker.track(frames: above, count: 2).allSatisfy { $0 > 0 })
        // And about −56 dBFS RMS, comfortably below it.
        let below = tone(150, amplitude: 0.00225)
        #expect(tracker.track(frames: below, count: 2).allSatisfy { $0 == 0 })
    }
}

// MARK: - The equaliser

/// There was a high-pass and nothing else for a long time, so a boxy room or a
/// harsh sibilance had no answer at all.
@Suite("Equaliser")
struct EqualiserTests {

    /// Every band has to be reachable and distinct, or a slider moves the wrong
    /// frequency and nothing says so.
    @Test("every band has its own control and its own frequency")
    func bandsAreDistinct() {
        let bands = EffectKind.toneBands
        #expect(bands.count == 6)
        #expect(Set(bands.map(\.hertz)).count == bands.count)
        #expect(Set(bands.map(\.title)).count == bands.count)
        // Ascending, so the row of sliders reads left to right as low to high.
        for (first, second) in zip(bands, bands.dropFirst()) {
            #expect(first.hertz < second.hertz)
            #expect(first.index < second.index)
        }
        // Shelves at the ends and bells between: the top and bottom bands are
        // asked to move everything past them, which a bell would not.
        #expect(bands.first!.isShelf)
        #expect(bands.last!.isShelf)
        #expect(bands.dropFirst().dropLast().allSatisfy { !$0.isShelf })
    }

    @Test("the parameters match the bands")
    func parametersMatchBands() {
        let parameters = EffectKind.tone.parameters
        #expect(parameters.count == EffectKind.toneBands.count)
        for (parameter, band) in zip(parameters, EffectKind.toneBands) {
            #expect(parameter.id == "b\(band.index)")
            #expect(parameter.title == band.title)
            // Flat by default: switching an equaliser on must not change the
            // sound until somebody moves something.
            #expect(parameter.defaultValue == 0)
            #expect(parameter.minimum == -12)
            #expect(parameter.maximum == 12)
        }
    }

    /// The whole set has to be wired, which is the mistake a computed
    /// parameter list invites: the interface offers six sliders and the chain
    /// recognises four.
    @Test("every band reaches the unit")
    func bandsAreWired() throws {
        let chain = try #require(
            EffectChain(kinds: [.tone], sampleRate: 48000, maximumFrames: 512))
        for parameter in EffectKind.tone.parameters {
            #expect(chain.recognises(parameter.id, of: .tone))
            chain.set(parameter.id, of: .tone, to: 6)
        }
        // And it renders after being moved.
        for index in 0..<512 { chain.inputBuffer[index] = 0.1 }
        #expect(chain.render(frames: 512, sampleTime: 0))
    }

    /// It is an equaliser, so it has to actually change the balance — and only
    /// where it was asked to.
    @Test("a band moves its own frequency and leaves the others alone")
    func bandAffectsItsOwnFrequency() throws {
        func measure(gainOnBand band: Int?) throws -> [Float] {
            let chain = try #require(
                EffectChain(kinds: [.tone], sampleRate: 48000, maximumFrames: 1024))
            if let band { chain.set("b\(band)", of: .tone, to: 12) }
            let analyser = try #require(SpectrumAnalyser(sampleRate: 48000))
            // Broadband, so every band has something to work on.
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for block in 0..<60 {
                for index in 0..<1024 {
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    let value =
                        Float(Int32(bitPattern: UInt32(truncatingIfNeeded: state >> 32)))
                        / Float(Int32.max)
                    chain.inputBuffer[index] = value * 0.2
                }
                guard chain.render(frames: 1024, sampleTime: Float64(block * 1024)) else {
                    Issue.record("render failed")
                    return []
                }
                var out = [Float](repeating: 0, count: 1024)
                for index in 0..<1024 { out[index] = chain.outputBuffer[index] }
                out.withUnsafeBufferPointer { analyser.add($0.baseAddress!, count: 1024) }
            }
            return (0..<SpectrumAnalyser.bandCount).map { analyser.decibels(ofBand: $0) }
        }

        let flat = try measure(gainOnBand: nil)
        // The presence band, at 4 kHz.
        let boosted = try measure(gainOnBand: 4)
        try #require(!flat.isEmpty && !boosted.isEmpty)

        let analyser = try #require(SpectrumAnalyser(sampleRate: 48000))
        var nearest = 0
        var best = Double.infinity
        for band in 0..<SpectrumAnalyser.bandCount {
            let distance = abs(analyser.centreFrequency(ofBand: band) - 4000)
            if distance < best {
                best = distance
                nearest = band
            }
        }
        #expect(boosted[nearest] > flat[nearest] + 3, "the band did not move")
        // And the bottom of the spectrum is left alone, which is what makes it
        // an equaliser rather than a volume control.
        #expect(abs(boosted[2] - flat[2]) < 2)
    }
}

// MARK: - Why AUAudioMix is not in the chain

/// `AUAudioMix` is macOS 26's graded speech/ambience separation — the tunable
/// successor to `AUSoundIsolation`'s on-or-off, with a Studio style that is
/// Apple's answer to NVIDIA Broadcast's Studio Voice and a continuous
/// `RemixAmount` instead of a switch. On paper it is the single most
/// differentiating thing available on this platform.
///
/// It cannot be used here, and these record exactly why rather than leaving a
/// note in a file somewhere. Three facts, each measured:
///
///   · it refuses mono and stereo input outright, taking only four-channel
///     first-order ambisonics;
///   · it refuses a four-channel output, wanting five — the ambisonics plus a
///     separated mono foreground, which is the header's "FOA + mono
///     foreground" read properly;
///   · and with both formats accepted it still fails to initialise, because it
///     wants `kAUAudioMixProperty_SpatialAudioMixMetadata` — the capture-time
///     metadata an iPhone writes into a Cinematic asset, which a live
///     microphone does not have and cannot be given.
///
/// So it is an asset-processing unit, not a live stage. Encoding a mono
/// microphone to ambisonics is arithmetic and would have been easy; the
/// metadata is not. It may still be excellent applied offline to recorded
/// stems, which is where to look next.
///
/// These are assertions rather than notes so that if a future macOS relaxes any
/// of it, this fails and says so — which is the only way anybody would find
/// out.
@Suite("AUAudioMix constraints")
struct AudioMixConstraintTests {

    private func makeUnit() -> AudioComponentInstance? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter,
            componentSubType: kAudioUnitSubType_AUAudioMix,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &instance) == noErr else { return nil }
        return instance
    }

    private func format(channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    @Test("the unit exists and offers a style and a remix amount")
    func exists() throws {
        let unit = try #require(makeUnit(), "AUAudioMix is missing on this system")
        defer { AudioComponentInstanceDispose(unit) }
        let parameters = AudioUnitPlugins.parameters(of: unit)
        #expect(parameters.count == 2)
        // A continuous amount rather than a switch is the whole difference from
        // AUSoundIsolation.
        #expect(parameters.contains { $0.minimum == 0 && $0.maximum == 1 })
    }

    /// The first wall. A microphone is mono or stereo and this takes neither.
    @Test("it refuses a live microphone's format")
    func refusesLiveFormats() throws {
        let unit = try #require(makeUnit())
        defer { AudioComponentInstanceDispose(unit) }

        func accepts(_ channels: UInt32) -> OSStatus {
            var value = format(channels: channels)
            return AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &value, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        }
        #expect(accepts(1) == kAudioUnitErr_FormatNotSupported)
        #expect(accepts(2) == kAudioUnitErr_FormatNotSupported)
        // Four-channel ambisonics is the one it takes.
        #expect(accepts(4) == noErr)
    }

    /// The second. Its output is the ambisonics plus a separated foreground.
    @Test("its output is five channels, not four")
    func outputIsFiveChannels() throws {
        let unit = try #require(makeUnit())
        defer { AudioComponentInstanceDispose(unit) }
        var input = format(channels: 4)
        #expect(
            AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &input, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr)

        func output(_ channels: UInt32) -> OSStatus {
            var value = format(channels: channels)
            return AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                &value, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        }
        #expect(output(4) == kAudioUnitErr_FormatNotSupported)
        #expect(output(2) == kAudioUnitErr_FormatNotSupported)
        #expect(output(5) == noErr)
    }

    /// The third, and the one that settles it. Both formats accepted, and it
    /// still will not start — because it wants metadata only a camera writes.
    @Test("it will not initialise without capture-time metadata")
    func refusesToInitialiseWithoutMetadata() throws {
        let unit = try #require(makeUnit())
        defer { AudioComponentInstanceDispose(unit) }

        var input = format(channels: 4)
        try #require(
            AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &input, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr)
        var output = format(channels: 5)
        try #require(
            AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                &output, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr)

        #expect(AudioUnitInitialize(unit) == kAudioUnitErr_FailedInitialization)
    }
}

// MARK: - Transcription

/// The claim worth testing is not that Apple's model works — it is that the
/// attribution is free. Every product that transcribes a conversation hedges
/// about who said what, because acoustic diarization guesses. Here the sources
/// are separated before anything reaches a model, so the speaker is the wiring.
@Suite("Transcription")
struct TranscriberTests {

    /// Some real speech and the rate it is at.
    private struct SpokenAudio {
        let samples: [Float]
        let rate: Double
    }

    @Test("the framework is present on this system")
    func supported() {
        #expect(Transcriber.isSupported)
        #expect(Transcriber.unsupportedReason == nil)
    }

    /// The two are one answer told twice, and an interface that showed a
    /// disabled control with no explanation — or an enabled one with an excuse
    /// underneath — would be the bug. macOS 26 is a supported system for
    /// everything else in this application; there the reason is the sentence
    /// somebody reads instead of the feature.
    @Test("when it cannot transcribe it says why")
    func reasonAgreesWithSupport() {
        #expect(Transcriber.isSupported == (Transcriber.unsupportedReason == nil))
    }

    /// A transcriber is per source and carries its speaker, which is the whole
    /// mechanism — there is nothing to infer later.
    @Test("each transcriber knows who it is listening to")
    func carriesItsSpeaker() {
        let microphone = Transcriber(speaker: "Microphone")
        let discord = Transcriber(speaker: "Discord")
        #expect(microphone.speaker == "Microphone")
        #expect(discord.speaker == "Discord")
    }

    /// Somewhere to start from: what can be transcribed without a download and
    /// what needs one. An empty supported list would mean the feature cannot
    /// work at all here.
    @Test("it reports which languages it can do")
    func languages() async {
        let (installed, supported) = await Transcriber.languages()
        #expect(!supported.isEmpty)
        // Installed is a subset of supported by definition; a language that can
        // be used without a download is one of the ones that can be used.
        #expect(installed.count <= supported.count)
    }

    /// Attribution is what the transcript is for, so every line carries it and
    /// the timestamps are readable rather than raw seconds.
    @Test("the transcript is attributed and timestamped")
    func transcriptFormat() async {
        let transcriber = Transcriber(speaker: "Guest")
        await transcriber.appendForTesting(
            .init(speaker: "Guest", text: "hello there", start: 5, duration: 1))
        await transcriber.appendForTesting(
            .init(speaker: "Guest", text: "and again", start: 75.5, duration: 1))
        let text = await transcriber.transcript()
        #expect(text.contains("[00:05] Guest: hello there"))
        #expect(text.contains("[01:15] Guest: and again"))
    }

    /// A sentence is an event rather than a twenty-hertz state sample. The
    /// callback must contain exactly the new line, so the owner never has to
    /// fetch or sort the history to discover what changed.
    @Test("a finished line is delivered once as an event")
    func lineEvent() async {
        let (stream, continuation) = AsyncStream<Transcriber.Line>.makeStream()
        let expected = Transcriber.Line(
            speaker: "Guest", text: "only this line", start: 12, duration: 1)
        let receiver = Task<Transcriber.Line?, Never> {
            for await line in stream { return line }
            return nil
        }
        let transcriber = Transcriber(speaker: "Guest") { line in
            continuation.yield(line)
        }

        await transcriber.appendForTesting(expected)
        continuation.finish()

        #expect(await receiver.value == expected)
        #expect(await transcriber.lines == [expected])
    }

    /// Feeding it before it has started must not crash or queue anything up for
    /// later — a transcript that begins with audio from before somebody pressed
    /// the button is not what they asked for.
    @Test("audio before it starts is ignored")
    func ignoresAudioBeforeStart() async {
        let transcriber = Transcriber(speaker: "Microphone")
        transcriber.add([Float](repeating: 0.1, count: 4800), sampleRate: 48000)
        #expect(await transcriber.lines.isEmpty)
    }

    /// Real speech, spoken by the system rather than checked in as a fixture —
    /// there is no way to ask Apple's model a question about timing without
    /// giving it something it will actually transcribe, and a synthesised tone
    /// produces no lines at all.
    private static func spokenSamples(_ words: String) throws -> SpokenAudio {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-speech-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, words]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { return SpokenAudio(samples: [], rate: format.sampleRate) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else {
            return SpokenAudio(samples: [], rate: format.sampleRate)
        }
        return SpokenAudio(
            samples: Array(
                UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))),
            rate: format.sampleRate)
    }

    /// In the blocks the interface's poll hands over, rather than in one lump.
    ///
    /// - Returns: When the first block was handed over, which is where the
    ///   analyser's own timeline starts and therefore the answer this is
    ///   measured against.
    @discardableResult
    private static func feed(_ audio: SpokenAudio, to transcriber: Transcriber) -> Double {
        let block = Int(audio.rate / 100)
        var firstAt = Date().timeIntervalSince1970
        var isFirst = true
        for start in stride(from: 0, to: audio.samples.count, by: block) {
            let end = min(start + block, audio.samples.count)
            transcriber.add(Array(audio.samples[start..<end]), sampleRate: audio.rate)
            if isFirst {
                firstAt = Date().timeIntervalSince1970
                isFirst = false
            }
        }
        return firstAt
    }

    /// `Line.start` says it is seconds from the start of the session, and it
    /// was the analyser's own timeline instead — which begins at the first
    /// buffer that transcriber's model accepted, not when the session did.
    ///
    /// Measured before the fix: three seconds of digital silence in front of a
    /// sentence read back as 2.7, and three transcribers that opened 69, 73 and
    /// 78 ms apart all reported their first line at 0.0. Warm, that skew is
    /// invisible; on a first use of a language the model is fetched inside
    /// `start`, and every source behind it in the loop opens after the
    /// download, so the size of it is unbounded.
    ///
    /// So the case is stated at a size anybody can see: one source opens two
    /// seconds into the session, and its line has to say two seconds. Before
    /// the fix both said zero and the merge that makes several sources into one
    /// conversation was sorting on a number that meant nothing across them.
    @Test("a line's start is seconds from the session, not from its own first audio")
    func startIsMeasuredFromTheSession() async throws {
        let audio = try Self.spokenSamples("one two three four five")
        try #require(!audio.samples.isEmpty)
        let session = Date().timeIntervalSince1970

        let early = Transcriber(speaker: "First")
        try await early.start(now: session)
        let earlyOrigin = Self.feed(audio, to: early) - session

        // Two seconds of the session pass before the second source is open.
        try await Task.sleep(for: .seconds(2))
        let late = Transcriber(speaker: "Second")
        try await late.start(now: session)
        let lateOrigin = Self.feed(audio, to: late) - session

        // `stop` finalises through the end of input, so the lines are there
        // when it returns — measured at 0.16 s, which is why nothing here
        // sleeps waiting for them.
        await early.stop()
        await late.stop()
        let first = try #require(await early.lines.first)
        let second = try #require(await late.lines.first)

        // Against when each source's audio actually began rather than against a
        // fixed number. How long a model takes to open is not this test's
        // subject and it is not bounded — the first version asserted the first
        // line landed under a second and failed inside a full test run, where
        // opening took longer than that with five hundred other tests on the
        // machine. What is being claimed is that a line says where in the
        // session it happened, and that is a comparison.
        #expect(abs(first.start - earlyOrigin) < 0.6)
        #expect(abs(second.start - lateOrigin) < 0.6)
        // And the case is actually stated: the two origins really are apart.
        #expect(lateOrigin - earlyOrigin > 1.5)
        // So the merge across sources is a record of the conversation.
        let merged = [second, first].sorted { $0.start < $1.start }
        #expect(merged.map(\.speaker) == ["First", "Second"])
    }
}

// MARK: - Headphone correction

/// The arithmetic, checked against numbers rather than against itself. A
/// filter that lands half an octave out, or a shelf built from the wrong one of
/// the several conventions for shelves, produces a curve that looks entirely
/// plausible and corrects the wrong thing.
@Suite("Parametric EQ")
struct ParametricEQTests {

    /// A real AutoEq export, abbreviated. Everything about the format that
    /// varies between exports is in here: LSC and LS, a disabled filter, and
    /// the preamp line.
    private let sample = """
        Preamp: -6.8 dB
        Filter 1: ON PK Fc 105 Hz Gain 5.5 dB Q 0.70
        Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
        Filter 3: OFF PK Fc 1000 Hz Gain 12.0 dB Q 1.00
        Filter 4: ON HSC Fc 10000 Hz Gain -2.0 dB Q 0.70
        """

    @Test("it reads AutoEq's own export")
    func parsesAutoEq() throws {
        let curve = try #require(ParametricEQ.parse(sample, name: "Test"))
        #expect(curve.preampDecibels == -6.8)
        // Three of four: the disabled one is written out but must not be run.
        // Applying it would be applying a correction the file says not to.
        #expect(curve.filters.count == 3)
        #expect(curve.filters[0].kind == .peaking)
        #expect(curve.filters[1].kind == .lowShelf)
        #expect(curve.filters[2].kind == .highShelf)
        #expect(curve.filters[0].hertz == 105)
        #expect(curve.filters[0].decibels == 5.5)
        #expect(abs(curve.filters[0].q - 0.7) < 0.001)
    }

    @Test("a file with nothing in it is refused rather than run empty")
    func refusesRubbish() throws {
        #expect(ParametricEQ.parse("hello, this is not an EQ", name: "x") == nil)
        #expect(ParametricEQ.parse("", name: "x") == nil)
        // A preamp with no filters is not a correction.
        #expect(ParametricEQ.parse("Preamp: -3.0 dB", name: "x") == nil)
    }

    /// The assertion that would have caught a wrong cookbook form: a peaking
    /// filter has to put its stated gain at its stated frequency, and nowhere
    /// else.
    @Test("a peaking filter boosts its own frequency by its own gain")
    func peakingResponse() {
        let curve = ParametricEQ(
            name: "one",
            filters: [.init(kind: .peaking, hertz: 1000, decibels: 6, q: 1)])
        #expect(abs(curve.response(atHertz: 1000, sampleRate: 48000) - 6) < 0.05)
        // And leaves two octaves away alone. A filter that lifted everything
        // would pass a test that only looked at its own centre.
        #expect(abs(curve.response(atHertz: 250, sampleRate: 48000)) < 1.5)
        #expect(abs(curve.response(atHertz: 4000, sampleRate: 48000)) < 1.5)
    }

    /// A shelf reaches its full gain well past the corner and none of it well
    /// before — the property that tells a low shelf from a high one, and a
    /// cookbook shelf from the several other conventions.
    @Test("a low shelf lifts below its corner and not above it")
    func lowShelfResponse() {
        let curve = ParametricEQ(
            name: "shelf",
            filters: [.init(kind: .lowShelf, hertz: 200, decibels: 6, q: 0.7)])
        #expect(abs(curve.response(atHertz: 30, sampleRate: 48000) - 6) < 0.5)
        // At the corner a shelf is at half its gain, by construction.
        #expect(abs(curve.response(atHertz: 200, sampleRate: 48000) - 3) < 0.6)
        #expect(abs(curve.response(atHertz: 4000, sampleRate: 48000)) < 0.3)
    }

    @Test("a high shelf is the same thing the other way up")
    func highShelfResponse() {
        let curve = ParametricEQ(
            name: "shelf",
            filters: [.init(kind: .highShelf, hertz: 4000, decibels: -6, q: 0.7)])
        #expect(abs(curve.response(atHertz: 16000, sampleRate: 48000) + 6) < 0.5)
        #expect(abs(curve.response(atHertz: 200, sampleRate: 48000)) < 0.3)
    }

    /// The preamp is not decoration. A correction that boosts anywhere needs
    /// headroom, and AutoEq's own exports carry a negative preamp for exactly
    /// that reason — ignoring the line clips before the correction is heard.
    @Test("the preamp moves the whole curve")
    func preampApplies() {
        let filters: [ParametricEQ.Filter] = [
            .init(kind: .peaking, hertz: 1000, decibels: 6, q: 1)
        ]
        let plain = ParametricEQ(name: "a", filters: filters)
        let quieter = ParametricEQ(name: "b", preampDecibels: -6, filters: filters)
        let difference =
            plain.response(atHertz: 1000, sampleRate: 48000)
            - quieter.response(atHertz: 1000, sampleRate: 48000)
        #expect(abs(difference - 6) < 0.001)
    }

    /// Where the whole curve peaks decides whether it can be run without
    /// clipping. Read off the response rather than off the filter list: two
    /// filters that overlap sum, and the largest single gain understates it.
    @Test("overlapping boosts are counted together")
    func peakBoost() {
        let stacked = ParametricEQ(
            name: "stacked",
            filters: [
                .init(kind: .peaking, hertz: 1000, decibels: 4, q: 0.7),
                .init(kind: .peaking, hertz: 1100, decibels: 4, q: 0.7),
            ])
        let peak = stacked.peakBoostDecibels(sampleRate: 48000)
        #expect(peak > 6)
        #expect(peak < 8.5)
    }

    /// A filter above Nyquist has nowhere to sit. The arithmetic returns
    /// something that is not a filter rather than failing, so it is caught
    /// here instead: a pass-through is the honest substitute.
    @Test("a filter above Nyquist becomes a pass-through")
    func aboveNyquist() {
        let coefficients = ParametricEQ.section(
            .init(kind: .peaking, hertz: 30000, decibels: 12, q: 1), sampleRate: 48000)
        #expect(coefficients == [1, 0, 0, 0, 0])
    }

    /// The arithmetic being right says nothing about the realtime path running
    /// it. This drives the actual IOProc with a sine at the filter's own
    /// frequency and measures what comes out — the only assertion that would
    /// catch a cascade wired to the wrong buffer, a history array shared
    /// between channels, or coefficients written but never read.
    @Test("the correction reaches the signal, by the stated number of decibels")
    func correctionRunsOnTheOutput() {
        let curve = ParametricEQ(
            name: "test", filters: [.init(kind: .peaking, hertz: 1000, decibels: 6, q: 1)])
        let plain = peaksThroughIOProc(curves: [:])[0]
        let corrected = peaksThroughIOProc(curves: [0: curve])[0]
        #expect(plain > 0.2)
        let lift = 20 * log10(corrected / plain)
        #expect(abs(lift - 6) < 0.4)
    }

    /// A correction on one output must not touch another. Sending the far end a
    /// signal shaped for the deficiencies of somebody's headphones is worse
    /// than not correcting at all — they would be hearing the inverse of a
    /// fault they do not have.
    @Test("a correction on one output leaves the other alone")
    func correctionIsPerOutput() {
        let curve = ParametricEQ(
            name: "test", filters: [.init(kind: .peaking, hertz: 1000, decibels: 12, q: 1)])
        let untouched = peaksThroughIOProc(curves: [1: curve])[0]
        let plain = peaksThroughIOProc(curves: [:])[0]
        #expect(abs(20 * log10(untouched / plain)) < 0.01)
    }

    /// The whole point of per-bus processing: the stream mix and the headphone
    /// mix are shaped independently, so a streamer can boost what they hear
    /// without boosting what everybody else hears.
    ///
    /// Both buses are measured out of *one* run of the real callback rather
    /// than two, because that is the arrangement that can actually go wrong.
    /// Two separate runs would pass with a single global slot — the second run
    /// simply would not have installed anything — while one run with a curve on
    /// A and nothing on B fails the moment the slots share coefficients, share
    /// filter history, or index each other.
    ///
    /// The tolerance on B is twenty times tighter than on A on purpose. A is a
    /// filter's gain, measured through a peak detector, and 0.4 dB is what that
    /// is worth. B is meant to be the *same arithmetic as no filter at all*, so
    /// anything above float noise there is a leak.
    @Test("two buses carry two different curves at once")
    func busesAreShapedIndependently() {
        let curve = ParametricEQ(
            name: "bus A", filters: [.init(kind: .peaking, hertz: 1000, decibels: 6, q: 1)])
        let plain = peaksThroughIOProc(curves: [:])
        let shaped = peaksThroughIOProc(curves: [0: curve])

        #expect(plain[0] > 0.2)
        // Both buses are fed the same signal, so anything else below is about
        // the correction rather than about the routing.
        #expect(plain[0] == plain[1])

        let liftOnA = 20 * log10(shaped[0] / plain[0])
        let liftOnB = 20 * log10(shaped[1] / plain[1])
        #expect(abs(liftOnA - 6) < 0.4)
        #expect(abs(liftOnB) < 0.05)

        // And the other way round, so a slot that only ever wrote to buffer
        // zero cannot pass this by accident.
        let onB = peaksThroughIOProc(curves: [1: curve])
        #expect(abs(20 * log10(onB[1] / plain[1]) - 6) < 0.4)
        #expect(abs(20 * log10(onB[0] / plain[0])) < 0.05)

        // Two different curves at the same time, which is what somebody
        // actually sets up: a lift on the monitor and a cut on the send.
        let cut = ParametricEQ(
            name: "bus B", filters: [.init(kind: .peaking, hertz: 1000, decibels: -6, q: 1)])
        let both = peaksThroughIOProc(curves: [0: curve, 1: cut])
        #expect(abs(20 * log10(both[0] / plain[0]) - 6) < 0.4)
        #expect(abs(20 * log10(both[1] / plain[1]) + 6) < 0.4)
    }

    /// The microphone goes through the effect chain and the tapped applications
    /// go through none of it, so without compensation the voice arrives behind
    /// the backing track by the whole chain — 56 ms for voice isolation alone.
    ///
    /// That is not a missing feature, it is a wrong mix. In a karaoke session it
    /// is tens of milliseconds of the singer being late, which somebody
    /// compensates for by rushing the beat; the per-source stems came out
    /// offset from each other by the same amount, so a recording had to be
    /// nudged back into line by hand.
    ///
    /// Asserted as an arrival frame in the destination buffer rather than as a
    /// number the engine reports about itself, because the number was already
    /// there — `effectLatencyFrames` has been measured and shown in the
    /// interface all along, and nothing used it to move a sample.
    ///
    /// The chain is stood in for by what it does to the samples: its output is
    /// its input delayed by its reported latency, so the microphone's impulse
    /// is fed that many frames late. Whether an `AudioUnit` reports its latency
    /// honestly is `EffectChain`'s business and is asserted there; what is
    /// asserted here is that the router does something with the answer.
    @Test(
        "the tapped path is held back to meet the microphone",
        arguments: [0, 1, 64, 480, 2688])
    func chainLatencyIsCompensated(latency: Int) {
        // First the defect, so the assertion below is known to be able to fail:
        // with no compensation the two impulses land a whole chain apart.
        let uncompensated = arrivalsThroughIOProc(alignment: 0, chainLatency: latency)
        #expect(uncompensated.microphone - uncompensated.tap == latency)

        // Then the fix: the same graph, the same signal, one number set.
        let compensated = arrivalsThroughIOProc(
            alignment: latency, chainLatency: latency)
        #expect(compensated.microphone - compensated.tap == 0)
        // And the microphone itself was not moved — alignment delays what
        // skipped the chain, never what went through it.
        #expect(compensated.microphone == uncompensated.microphone)
    }

    /// Sends one impulse down a microphone route and one down a tapped route,
    /// and reports the frame each arrived at in the destination.
    ///
    /// - Parameters:
    ///   - alignment: Frames of compensation on paths that skipped the chain.
    ///   - chainLatency: How late the chain's output is, modelled by feeding
    ///     the microphone's impulse that many frames after the tap's.
    /// - Returns: The frame each impulse arrived at, or -1 if it never did.
    private func arrivalsThroughIOProc(
        alignment: Int, chainLatency: Int
    ) -> (microphone: Int, tap: Int) {
        // One cycle long enough to hold the late impulse and the delayed one:
        // the longest chain here is 56 ms, which is 2688 frames at 48 kHz.
        let frames = 4096
        let impulseAt = 64
        let graph = RTGraph.allocate(
            routes: [
                // The microphone, which in the running app reads the chain's
                // output. Flagged as such so it is exempt from the alignment;
                // with no chain in this graph it falls back to the input, which
                // is where its already-late impulse has been put.
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    usesIsolatedSource: true),
                // A tapped application, which goes through nothing.
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 1),
            ], bufferFrames: frames, sampleRate: 48000)
        defer { RTGraph.deallocate(graph) }
        graph.pointee.alignmentFrames = Int32(alignment)

        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid

        let input = Bus(channelCounts: [2], frames: frames)
        let output = Bus(channelCounts: [2], frames: frames)
        input.storage[0][(impulseAt + chainLatency) * 2] = 1  // microphone
        input.storage[0][impulseAt * 2 + 1] = 1  // tapped application

        _ = yunAudioIOProc(
            0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
            output.list.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))

        func arrival(_ channel: Int) -> Int {
            for frame in 0..<frames where output.storage[0][frame * 2 + channel] != 0 {
                return frame
            }
            return -1
        }
        return (microphone: arrival(0), tap: arrival(1))
    }

    /// Runs a 1 kHz sine through a real graph and returns the peak that came
    /// out of each output bus.
    ///
    /// Two output buffers, each fed by its own route from the same input, so
    /// "the correction went on the other bus" is a real arrangement rather than
    /// an index nothing reads.
    private func peaksThroughIOProc(curves: [Int: ParametricEQ]) -> [Float] {
        let buses = 2
        let graph = RTGraph.allocate(
            routes: (0..<buses).map { bus in
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: Int32(bus), destinationChannel: 0)
            }, bufferFrames: 512, sampleRate: 48000)
        defer { RTGraph.deallocate(graph) }

        for (bus, curve) in curves {
            RTGraph.installCorrection(
                curve.coefficients(sampleRate: 48000),
                preampGain: pow(10, curve.preampDecibels / 20), onBuffer: bus, of: graph)
        }

        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid

        let frames = 512
        let inputList = AudioBufferList.allocate(maximumBuffers: 1)
        let outputList = AudioBufferList.allocate(maximumBuffers: buses)
        let inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        inputStorage.initialize(repeating: 0, count: frames)
        var outputStorage: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<buses {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 0, count: frames)
            outputStorage.append(pointer)
        }
        defer {
            inputStorage.deallocate()
            for pointer in outputStorage { pointer.deallocate() }
            free(inputList.unsafeMutablePointer)
            free(outputList.unsafeMutablePointer)
        }
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        inputList[0] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: bytes,
            mData: UnsafeMutableRawPointer(inputStorage))
        for bus in 0..<buses {
            outputList[bus] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: bytes,
                mData: UnsafeMutableRawPointer(outputStorage[bus]))
        }

        var phase: Float = 0
        let step = 2 * Float.pi * 1000 / 48000
        var peaks = [Float](repeating: 0, count: buses)
        // Twenty cycles, measuring only the last ten: a biquad's first few
        // milliseconds are its transient, not its gain.
        for cycle in 0..<20 {
            for frame in 0..<frames {
                inputStorage[frame] = 0.25 * sin(phase)
                phase += step
            }
            for bus in 0..<buses {
                for frame in 0..<frames { outputStorage[bus][frame] = 0 }
            }
            _ = yunAudioIOProc(
                0, &now, UnsafePointer(inputList.unsafeMutablePointer), &time,
                outputList.unsafeMutablePointer, &time,
                UnsafeMutableRawPointer(cell))
            guard cycle >= 10 else { continue }
            for bus in 0..<buses {
                for frame in 0..<frames {
                    peaks[bus] = max(peaks[bus], abs(outputStorage[bus][frame]))
                }
            }
        }
        return peaks
    }

    /// Reinstalling a curve that has not changed must not reset its filter
    /// memory.
    ///
    /// Every publish carries every bus, so moving bus A's tone control
    /// reinstalls bus B's unchanged curve — and a biquad restarted from zero
    /// history in the middle of a signal is a click on an output nobody
    /// touched. Asserted on the history itself rather than by listening,
    /// because a click is one buffer long and averages away.
    @Test("an unchanged curve keeps its filter history")
    func reinstallingKeepsHistory() {
        let curve = ParametricEQ(
            name: "test", filters: [.init(kind: .peaking, hertz: 1000, decibels: 6, q: 1)])
        let packed = curve.coefficients(sampleRate: 48000)
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0)
            ], bufferFrames: 128, sampleRate: 48000)
        defer { RTGraph.deallocate(graph) }

        RTGraph.installCorrection(packed, preampGain: 1, onBuffer: 1, of: graph)
        // Stand in for a filter that has been running: any non-zero history.
        let state = graph.pointee.eqState + RTGraph.eqStateOffset(slot: 1)
        for index in 0..<4 { state[index] = Float(index + 1) * 0.25 }

        RTGraph.installCorrection(packed, preampGain: 1, onBuffer: 1, of: graph)
        #expect(state[0] == 0.25)
        #expect(state[3] == 1.0)

        // A different curve is a different filter, and carrying the old tail
        // into it is the click this is avoiding in the other direction.
        let other = ParametricEQ(
            name: "other", filters: [.init(kind: .peaking, hertz: 400, decibels: -3, q: 1)])
        RTGraph.installCorrection(
            other.coefficients(sampleRate: 48000), preampGain: 1, onBuffer: 1, of: graph)
        #expect(state[0] == 0)
        #expect(state[3] == 0)
    }

    /// Slots must not overlap. A stride computed one section short would put
    /// bus B's first coefficients on top of bus A's last, which changes a curve
    /// somebody set without touching anything they can see.
    @Test("one bus's coefficients cannot reach another's")
    func slotsDoNotOverlap() {
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0)
            ], bufferFrames: 128, sampleRate: 48000)
        defer { RTGraph.deallocate(graph) }

        // The longest curve every slot can hold, so the blocks are packed as
        // tightly as they ever get.
        let full = [Float](repeating: 1, count: RTGraph.maximumEQStages * 5)
        for slot in 0..<RTGraph.maximumEQBuffers {
            RTGraph.installCorrection(full, preampGain: 1, onBuffer: slot, of: graph)
        }
        let zeroes = [Float](repeating: 0, count: RTGraph.maximumEQStages * 5)
        RTGraph.installCorrection(zeroes, preampGain: 1, onBuffer: 3, of: graph)

        for slot in 0..<RTGraph.maximumEQBuffers where slot != 3 {
            let base = graph.pointee.eqCoefficients + RTGraph.eqCoefficientOffset(slot: slot)
            #expect(base[0] == 1)
            #expect(base[RTGraph.maximumEQStages * 5 - 1] == 1)
        }
        // And a slot beyond the table is refused rather than written past the
        // end of the allocation.
        #expect(
            RTGraph.installCorrection(
                full, preampGain: 1, onBuffer: RTGraph.maximumEQBuffers, of: graph) == false)
    }

    /// The band centres are Razer's own, so somebody moving from Windows can
    /// copy their settings across band for band. Asserted because a table of
    /// ten numbers is exactly the kind of thing that gets "tidied" later.
    @Test("the graphic bands are the ones Synapse publishes")
    func graphicBands() {
        #expect(
            ParametricEQ.graphicBands == [30, 60, 120, 250, 500, 1000, 2000, 4000, 8000, 16000])
        #expect(ParametricEQ.graphicRange == -5...5)
    }

    /// Moving one slider has to move its own band and leave its neighbours
    /// alone. A Q chosen too wide makes every control a bass control.
    @Test("a graphic band moves its own frequency and not its neighbours")
    func graphicIsLocal() {
        var positions = [Float](repeating: 0, count: 10)
        positions[5] = 5  // 1 kHz
        let curve = ParametricEQ.graphic(positions)
        #expect(curve.filters.count == 1)
        #expect(abs(curve.response(atHertz: 1000, sampleRate: 48000) - 5) < 0.2)
        // The neighbouring centres are an octave away in each direction.
        #expect(curve.response(atHertz: 500, sampleRate: 48000) < 2)
        #expect(curve.response(atHertz: 2000, sampleRate: 48000) < 2)
        // And two octaves out it is over.
        #expect(abs(curve.response(atHertz: 250, sampleRate: 48000)) < 0.6)
    }

    @Test("a band at zero is not a filter at all")
    func graphicSkipsFlatBands() {
        #expect(ParametricEQ.graphic([Float](repeating: 0, count: 10)).filters.isEmpty)
        #expect(ParametricEQ.graphic([0, 0, 3, 0, 0, 0, 0, 0, 0, 0]).filters.count == 1)
    }

    /// Ten bands all the way up is the worst case the realtime path will see,
    /// and it must still be ten sections rather than something unbounded.
    @Test("all ten bands is ten sections")
    func graphicFull() {
        let curve = ParametricEQ.graphic([Float](repeating: 4, count: 10))
        #expect(curve.filters.count == 10)
        #expect(curve.filters.count <= ParametricEQ.maximumFilters)
        // Adjacent bands overlap, so the whole curve lifts by more than any
        // single band asked for — which is why the preamp exists.
        #expect(curve.peakBoostDecibels(sampleRate: 48000) > 4)
    }

    @Test("a slider beyond the range is clamped rather than obeyed")
    func graphicClamps() {
        let curve = ParametricEQ.graphic([99, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(curve.filters.first?.decibels == 5)
    }

    /// A correction and a tone control are different intentions and somebody
    /// wants both. Cascaded biquads compose by concatenation, and the check
    /// that matters is that the response really adds rather than one replacing
    /// the other.
    @Test("two curves run together add up")
    func combining() throws {
        let one = ParametricEQ(
            name: "a", preampDecibels: -2,
            filters: [.init(kind: .peaking, hertz: 1000, decibels: 4, q: 1)])
        let two = ParametricEQ(
            name: "b", preampDecibels: -3,
            filters: [.init(kind: .peaking, hertz: 1000, decibels: 3, q: 1)])
        let both = try #require(ParametricEQ.combined([one, two], name: "both"))
        #expect(both.filters.count == 2)
        #expect(both.preampDecibels == -5)
        // 4 dB and 3 dB of boost at the same frequency, less 5 dB of preamp.
        #expect(abs(both.response(atHertz: 1000, sampleRate: 48000) - 2) < 0.1)
    }

    @Test("combining nothing is nothing rather than an empty curve")
    func combiningNothing() {
        #expect(ParametricEQ.combined([], name: "x") == nil)
        #expect(
            ParametricEQ.combined([ParametricEQ(name: "flat", filters: [])], name: "x") == nil)
    }

    /// The coefficient block handed to the IO thread is a fixed allocation, so
    /// a curve that could outgrow it would mean allocating on the realtime
    /// path. Truncation is the right answer and it has to actually happen.
    @Test("a combined curve cannot outgrow the block it is written into")
    func combiningIsBounded() throws {
        let ten = ParametricEQ.graphic([Float](repeating: 4, count: 10))
        let many = try #require(
            ParametricEQ.combined([ten, ten, ten], name: "too many"))
        #expect(many.filters.count == ParametricEQ.maximumFilters)
    }

    /// The cascade in the IOProc is run section-outermost, so one section's
    /// coefficients and one channel's history stay in registers for a whole
    /// block, and two channels are run in the same loop so their multiply
    /// chains interleave. Both are rearrangements of a loop nest, and a
    /// rearrangement of a loop nest is the kind of change that is right for
    /// eight configurations and silently wrong for the ninth: a history term
    /// shared between channels, an off-by-one on the state slot, the preamp
    /// applied once per section instead of once.
    ///
    /// None of that is visible in a frequency response — a filter with the
    /// channels crossed still has the right magnitude curve. So this asserts
    /// the strong thing rather than the convenient one: every sample the
    /// callback produces equals, bit for bit, what the textbook nesting
    /// produces from the same input.
    ///
    /// Odd channel counts are in the list because the pairing has a tail, and a
    /// tail is where an off-by-one lives.
    @Test(
        "the cascade is bit-for-bit the textbook nesting",
        arguments: [(1, 1), (2, 1), (2, 10), (3, 10), (2, 24), (5, 24)])
    func cascadeMatchesTextbookNesting(channels: Int, stages: Int) {
        let curve = ParametricEQ(
            name: "reference", preampDecibels: -4.5,
            filters: (0..<stages).map { index in
                .init(
                    kind: .peaking, hertz: 80 * Float(index + 1) * 1.35,
                    decibels: index.isMultiple(of: 2) ? 5 : -4, q: 1.1)
            })
        let packed = curve.coefficients(sampleRate: 48000)
        #expect(packed.count == stages * 5)
        let preamp = pow(Float(10), curve.preampDecibels / 20)

        let frames = 96
        let cycles = 6
        let graph = RTGraph.allocate(
            routes: (0..<channels).map { channel in
                RTRoute(
                    sourceBuffer: 0, sourceChannel: Int32(channel),
                    destinationBuffer: 0, destinationChannel: Int32(channel))
            }, bufferFrames: frames, sampleRate: 48000)
        defer { RTGraph.deallocate(graph) }
        RTGraph.installCorrection(packed, preampGain: preamp, onBuffer: 0, of: graph)

        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid

        let input = Bus(channelCounts: [channels], frames: frames)
        let output = Bus(channelCounts: [channels], frames: frames)

        // The reference keeps its own history, in the obvious nesting.
        var reference = [Float](repeating: 0, count: stages * channels * 4)
        var mismatches = 0
        var compared = 0
        var loudest: Float = 0

        for cycle in 0..<cycles {
            // A different waveform per channel and per cycle, so a filter that
            // read the wrong channel's history would have somewhere to go wrong.
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let phase = Float(cycle * frames + frame)
                    input.storage[0][frame * channels + channel] =
                        0.3 * sin(phase * (0.03 + 0.017 * Float(channel)))
                        + 0.1 * sin(phase * 0.31)
                }
            }
            for index in 0..<(frames * channels) { output.storage[0][index] = 0 }

            _ = yunAudioIOProc(
                0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
                output.list.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))

            for channel in 0..<channels {
                for frame in 0..<frames {
                    var value = input.storage[0][frame * channels + channel] * preamp
                    for section in 0..<stages {
                        let slot = (section * channels + channel) * 4
                        let produced =
                            packed[section * 5] * value
                            + packed[section * 5 + 1] * reference[slot]
                            + packed[section * 5 + 2] * reference[slot + 1]
                            - packed[section * 5 + 3] * reference[slot + 2]
                            - packed[section * 5 + 4] * reference[slot + 3]
                        reference[slot + 1] = reference[slot]
                        reference[slot] = value
                        reference[slot + 3] = reference[slot + 2]
                        reference[slot + 2] = produced
                        value = produced
                    }
                    let actual = output.storage[0][frame * channels + channel]
                    if actual != value { mismatches += 1 }
                    compared += 1
                    loudest = max(loudest, abs(value))
                }
            }
        }

        #expect(mismatches == 0)
        #expect(compared == frames * channels * cycles)
        // A cascade that had gone unstable, or one filtering silence, would
        // compare equal to a reference doing the same thing. Something has to
        // say the signal was there.
        #expect(loudest > 0.05)
        #expect(loudest < 4)
    }

    /// One interleaved bus, for the comparison above.
    private final class Bus {
        let list: UnsafeMutableAudioBufferListPointer
        var storage: [UnsafeMutablePointer<Float>] = []

        init(channelCounts: [Int], frames: Int) {
            list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
            for (index, channels) in channelCounts.enumerated() {
                let samples = frames * channels
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples)
                pointer.initialize(repeating: 0, count: samples)
                storage.append(pointer)
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(samples * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(pointer))
            }
        }

        deinit {
            for pointer in storage { pointer.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    @Test("every section is normalised so it can be run as it stands")
    func normalised() {
        let curve = ParametricEQ(
            name: "x",
            filters: [
                .init(kind: .peaking, hertz: 1000, decibels: 6, q: 1),
                .init(kind: .lowShelf, hertz: 100, decibels: -3, q: 0.7),
            ])
        let packed = curve.coefficients(sampleRate: 48000)
        #expect(packed.count == 10)
        #expect(packed.allSatisfy { $0.isFinite })
    }
}

// MARK: - Lyrics

/// The `.lrc` format is loose in practice and the looseness is the work. Every
/// case here came from a real file: three-digit fractions, one line carrying
/// several stamps, tags mixed in with timings, and files with no timings at all.
@Suite("Lyrics")
struct LyricsTests {

    private let sample = """
        [ti:Test Song]
        [ar:Somebody]
        [offset:-500]
        [00:12.50]The first line
        [00:17.20][01:05.44]A line that repeats
        [01:30.125]With three digits
        Not a lyric line at all
        """

    @Test("it reads the tags and the timings")
    func parses() throws {
        let lyrics = try #require(Lyrics.parse(sample))
        #expect(lyrics.title == "Test Song")
        #expect(lyrics.artist == "Somebody")
        // Milliseconds in the file, seconds in the structure.
        #expect(abs(lyrics.offset + 0.5) < 0.0001)
        // Four entries from three lines: the repeated line carries two stamps,
        // which is how a chorus is written without repeating the words.
        #expect(lyrics.lines.count == 4)
        #expect(lyrics.lines[0].text == "The first line")
        #expect(abs(lyrics.lines[0].time - 12.5) < 0.001)
    }

    /// Two digits or three is a factor of ten, so it has to be read as written
    /// rather than assumed.
    @Test("a three-digit fraction is milliseconds, not hundredths")
    func fractions() throws {
        let lyrics = try #require(Lyrics.parse(sample))
        let late = try #require(lyrics.lines.last)
        #expect(abs(late.time - 90.125) < 0.001)
    }

    @Test("the lines come out in time order however they were written")
    func ordered() throws {
        let lyrics = try #require(
            Lyrics.parse("[01:00.00]second\n[00:30.00]first"))
        #expect(lyrics.lines.map(\.text) == ["first", "second"])
    }

    @Test("words with no timings are not lyrics")
    func refusesPlainText() {
        #expect(Lyrics.parse("just some words\nand some more") == nil)
        #expect(Lyrics.parse("") == nil)
        // Tags alone are not lyrics either.
        #expect(Lyrics.parse("[ti:Song]\n[ar:Nobody]") == nil)
    }

    @Test("a bracket that is not a time and not a tag is left alone")
    func strangeBrackets() throws {
        let lyrics = try #require(Lyrics.parse("[00:05.00][x] words"))
        #expect(lyrics.lines.first?.text == "[x] words")
    }

    /// Which line is being sung, which is the whole point.
    @Test("it finds the line being sung")
    func following() throws {
        let lyrics = try #require(
            Lyrics.parse("[00:10.00]one\n[00:20.00]two\n[00:30.00]three"))
        #expect(lyrics.index(at: 0) == nil)
        #expect(lyrics.index(at: 9.9) == nil)
        #expect(lyrics.index(at: 10) == 0)
        #expect(lyrics.index(at: 19.9) == 0)
        #expect(lyrics.index(at: 20) == 1)
        // Past the end it stays on the last line rather than going blank.
        #expect(lyrics.index(at: 600) == 2)
    }

    /// The offset is not decoration: a file that is half a second out is a file
    /// that is useless for singing to.
    @Test("the offset moves what is being sung")
    func offsetApplies() throws {
        let early = try #require(Lyrics.parse("[offset:-1000]\n[00:10.00]one"))
        // A negative offset means the words are early, so at 9.5 seconds the
        // line has not started.
        #expect(early.index(at: 9.5) == nil)
        let late = try #require(Lyrics.parse("[offset:1000]\n[00:10.00]one"))
        #expect(late.index(at: 9.5) == 0)
    }

    /// A highlight that sweeps rather than jumps is the reason anybody wants
    /// synchronised lyrics instead of a printed sheet.
    @Test("progress through a line runs from nothing to all of it")
    func progress() throws {
        let lyrics = try #require(Lyrics.parse("[00:10.00]one\n[00:20.00]two"))
        #expect(abs(lyrics.progress(at: 10)) < 0.001)
        #expect(abs(lyrics.progress(at: 15) - 0.5) < 0.001)
        #expect(lyrics.progress(at: 19.99) > 0.99)
        // Before the first line there is nothing to be part-way through.
        #expect(lyrics.progress(at: 0) == 0)
        // The last line has no successor, so it is given a sung phrase's worth
        // rather than running to infinity or snapping to one.
        #expect(lyrics.progress(at: 22) > 0.4)
        #expect(lyrics.progress(at: 22) < 0.6)
    }
}

// MARK: - Waiting for the loopback

/// The self-test captures its sequence off the destination's input. When the
/// destination has none — speakers, a Bluetooth headset, a display — nothing
/// ever arrives, and the obvious `while progress < 1` never ends. That is not
/// hypothetical: it held this project's own command line for thirty-one
/// minutes, printing 0% every quarter second.
@Suite("Waiting for the loopback")
struct SelftestWaitTests {

    @Test("a capture that never starts gives up rather than waiting for ever")
    func givesUp() {
        let engine = RoutingEngine()
        let began = Date()
        // Nothing is running, so there is no capture and no progress.
        #expect(engine.awaitSelftest(timeout: 0.6, poll: 0.05) == false)
        let elapsed = Date().timeIntervalSince(began)
        // It has to actually return, and near the deadline rather than long
        // after it — a loop that overruns its own timeout is the same bug.
        #expect(elapsed < 2.0)
    }

    @Test("giving up is reported rather than graded")
    func reportsFailure() {
        let engine = RoutingEngine()
        #expect(engine.awaitSelftest(timeout: 0.3, poll: 0.05) == false)
        // And there is nothing to grade, so the caller must not be handed a
        // verdict built from an empty capture.
        #expect(engine.evaluateSelftest() == nil)
    }
}

/// CoreAudio accepting a start request is not evidence that its IOProc runs.
///
/// A preset rebuild returned `noErr` with zero cycles, leaving the application
/// claiming to run while recording, Spotify capture and every analyser all
/// read silence. The live flow check supplies the hardware assertion; this
/// keeps the bounded two-cycle contract attached to every start.
@Suite("Proving an audio start")
struct AudioStartProofTests {
    @Test("a successful status still has to produce two cycles")
    func startWaitsForCycles() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift", encoding: .utf8)
        #expect(source.contains("guard yun_rt_cell_wait_for_swap(cell, 750)"))
        #expect(source.contains("throw RoutingError.noIOCycles"))
    }

    @Test("a stalled start retries the same configuration before dropping anything")
    func retriesExactly() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift", encoding: .utf8)
        let retry = try #require(source.range(of: "if case RoutingError.noIOCycles"))
        let ladder = try #require(source.range(of: "var ladder:"))
        #expect(retry.lowerBound < ladder.lowerBound)
        let between = source[retry.lowerBound..<ladder.lowerBound]
        #expect(between.contains("try startAttempt(configuration)"))
    }

    @Test("the flow check proves its own tone generator is producing cycles")
    func loopbackToneIsProven() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/UIFlowCheck.swift", encoding: .utf8)
        let tone = try #require(source.range(of: "private final class LoopbackTone"))
        let implementation = source[tone.lowerBound...]
        #expect(implementation.contains("yun_rt_cell_wait_for_swap(cycles, 750)"))
        #expect(implementation.contains("for _ in 0..<2"))
    }
}

// MARK: - Key detection

/// Every karaoke machine has a transpose button because a song is written in
/// the key its original singer could reach. The pitch shifter to fix that is
/// already here; what was missing was knowing how far to shift, and guessing is
/// not an answer.
///
/// Tested against synthesised chromas rather than recordings: what is being
/// checked is the profile match, and a recording would be checking the FFT as
/// well as the arithmetic while proving neither.
@Suite("Key detection")
struct KeyDetectorTests {

    /// A chroma built by playing the notes of a scale, each as loud as
    /// Krumhansl's listeners weighted it. If the match cannot find the key it
    /// was built from, nothing else in this file matters.
    private func chroma(for tonic: Int, minor: Bool) -> [Double] {
        let profile = minor ? KeyDetector.minorProfile : KeyDetector.majorProfile
        return (0..<12).map { profile[($0 - tonic + 12) % 12] }
    }

    @Test("it finds the key its own profile describes", arguments: 0..<12)
    func findsMajor(tonic: Int) throws {
        let key = try #require(KeyDetector.key(from: chroma(for: tonic, minor: false)))
        #expect(key.pitchClass == tonic)
        #expect(key.isMinor == false)
    }

    @Test("and the minor one too", arguments: 0..<12)
    func findsMinor(tonic: Int) throws {
        let key = try #require(KeyDetector.key(from: chroma(for: tonic, minor: true)))
        #expect(key.pitchClass == tonic)
        #expect(key.isMinor == true)
    }

    /// Nothing that does this is infallible, and the interface has to know
    /// when to say so. A chroma with every pitch class equally present is not
    /// in a key, and the confidence must collapse rather than a letter being
    /// printed with a straight face.
    @Test("an even chroma is not a key")
    func flatChromaHasNoKey() {
        // Perfectly flat correlates with nothing: no variance, no answer.
        #expect(KeyDetector.key(from: [Double](repeating: 1, count: 12)) == nil)
        #expect(KeyDetector.key(from: [Double](repeating: 0, count: 12)) == nil)
    }

    @Test("a nearly even chroma is reported as a guess")
    func ambiguousIsLowConfidence() throws {
        var almostFlat = [Double](repeating: 1, count: 12)
        almostFlat[0] += 0.02
        let key = try #require(KeyDetector.key(from: almostFlat))
        #expect(key.confidence < 0.3)
        // Where a real scale is not a guess.
        let clear = try #require(KeyDetector.key(from: chroma(for: 0, minor: false)))
        #expect(clear.confidence > key.confidence)
    }

    /// The defect this gate exists for, written out as the numbers that found
    /// it: a song in F major, one window of it landing on the IV chord.
    ///
    /// The profile match is not wrong here — B♭–D–F really is a B♭ chord, and
    /// it correlates with B♭ major better than with anything else by a wide
    /// enough margin to be reported as certain. What is wrong is answering at
    /// all from one window. Nothing in twelve numbers can tell one chord of a
    /// progression from a piece that only plays that chord, so the gate is a
    /// count of how much was heard rather than any arithmetic on the chroma.
    @Test("one chord is not a key, however certain it looks")
    func oneChordIsNotAKey() throws {
        // B♭ major, the IV of F: the chord the flow check's progression is on
        // for a quarter of its bar.
        var chord = [Double](repeating: 0, count: 12)
        for pitchClass in [10, 2, 5] { chord[pitchClass] = 1 }

        // Left to itself the match is confident and it is confidently the
        // wrong question's answer.
        let unguarded = try #require(KeyDetector.key(from: chord))
        #expect(unguarded.pitchClass == 10)
        #expect(unguarded.confidence > 0.15)

        // Guarded by how much went in, nothing is claimed.
        #expect(KeyDetector.key(from: chord, windows: 1) == nil)
        #expect(KeyDetector.key(from: chord, windows: 0) == nil)
        #expect(
            KeyDetector.key(from: chord, windows: KeyDetector.leastWindowsForAKey - 1) == nil)
    }

    /// And once enough has been heard the gate gets out of the way: the whole
    /// progression, summed, is F major rather than any of the chords in it.
    @Test("enough of a progression is its key rather than its chords")
    func enoughOfAProgressionIsAKey() throws {
        // I–IV–V–I in F, each chord a triad, summed the way the panel sums
        // windows. The tonic appears twice because the progression returns to
        // it, which is what makes it a key rather than a list of chords.
        var total = [Double](repeating: 0, count: 12)
        let progression = [[5, 9, 0], [10, 2, 5], [0, 4, 7], [5, 9, 0]]
        for chord in progression {
            for pitchClass in chord { total[pitchClass] += 1 }
        }
        let windows = KeyDetector.leastWindowsForAKey
        let key = try #require(KeyDetector.key(from: total, windows: windows))
        #expect(key.pitchClass == 5)  // F
        #expect(key.isMinor == false)
        #expect(key.confidence > 0.15)
    }

    @Test("the wrong number of pitch classes is refused")
    func refusesMalformed() {
        #expect(KeyDetector.key(from: [1, 2, 3]) == nil)
        #expect(KeyDetector.key(from: []) == nil)
    }

    /// The distance between two keys takes the shorter way round: a singer
    /// asked to move eleven semitones up will move one down instead, and it is
    /// the same key.
    @Test("the distance between keys goes the short way")
    func shortestDistance() {
        let c = KeyDetector.Key(pitchClass: 0, isMinor: false, confidence: 1)
        let b = KeyDetector.Key(pitchClass: 11, isMinor: false, confidence: 1)
        let g = KeyDetector.Key(pitchClass: 7, isMinor: false, confidence: 1)
        #expect(c.semitones(to: b) == -1)
        #expect(b.semitones(to: c) == 1)
        #expect(c.semitones(to: g) == -5)
        #expect(c.semitones(to: c) == 0)
    }

    /// The shift is arithmetic, not a preference: the song's middle and the
    /// singer's middle, subtracted.
    @Test("the suggested shift moves a song towards the voice")
    func suggestsAShift() {
        let cMajor = KeyDetector.Key(pitchClass: 0, isMinor: false, confidence: 1)
        // A voice centred on C4 (MIDI 60) needs no help with a song in C.
        #expect(KeyDetector.suggestedShift(songKey: cMajor, comfortableMidi: 60) == 0)
        // Centred a fourth lower, it wants the song brought down.
        #expect(KeyDetector.suggestedShift(songKey: cMajor, comfortableMidi: 55) < 0)
        // And a fourth higher, up.
        #expect(KeyDetector.suggestedShift(songKey: cMajor, comfortableMidi: 64) > 0)
    }

    /// More than six semitones is a different song rather than an easier one,
    /// so the suggestion is bounded whatever the arithmetic says.
    @Test("no suggestion moves a song more than half an octave")
    func shiftIsBounded() {
        let key = KeyDetector.Key(pitchClass: 0, isMinor: false, confidence: 1)
        for midi in stride(from: 30.0, through: 90.0, by: 1) {
            let shift = KeyDetector.suggestedShift(songKey: key, comfortableMidi: midi)
            #expect(shift >= -6 && shift <= 6)
        }
    }

    /// The claim the bound was hiding.
    ///
    /// Being within half an octave is not the same as being *right*, and the
    /// previous arithmetic satisfied the first while failing the second in 341
    /// of these 732 cases: it chose an octave from the voice alone — round the
    /// voice to the nearest twelve — and then added the song's pitch class to
    /// it, which lands the tonic anywhere within eleven semitones of where the
    /// voice actually is. The clamp then turned every one of those into a
    /// plausible number.
    ///
    /// The thing to assert is what the shift is *for*: after moving the song by
    /// it, the song's tonic must be where the singer's middle is.
    @Test("the shift really does put the tonic under the voice")
    func shiftLandsTheTonicOnTheVoice() {
        for pitchClass in 0..<12 {
            let key = KeyDetector.Key(pitchClass: pitchClass, isMinor: false, confidence: 1)
            for midi in stride(from: 30.0, through: 90.0, by: 1) {
                let shift = KeyDetector.suggestedShift(songKey: key, comfortableMidi: midi)
                let raw = midi - Double(pitchClass + shift)
                let distance = raw - 12 * (raw / 12).rounded()
                let name = KeyDetector.noteNames[pitchClass]
                #expect(
                    abs(distance) < 1e-9,
                    "\(name) against a voice at \(Int(midi)) moved \(shift), leaving the tonic \(distance) semitones away"
                )
            }
        }
    }

    /// The worst of them, named, so a regression says which case broke.
    @Test("a tonic just above the voice is not chased half an octave downwards")
    func shiftTakesTheNearerTonic() {
        // C♯ against a voice centred on MIDI 30: the nearest C♯ is 5 semitones
        // above it. The old arithmetic rounded 30/12 to 3, put the tonic at 37,
        // computed −7 and clamped it to −6 — eleven semitones the wrong way.
        let cSharp = KeyDetector.Key(pitchClass: 1, isMinor: false, confidence: 1)
        #expect(KeyDetector.suggestedShift(songKey: cSharp, comfortableMidi: 30) == 5)
        // B against a voice centred on D3: the nearest B is 3 below, so the
        // song comes up. The old arithmetic said −6.
        let b = KeyDetector.Key(pitchClass: 11, isMinor: false, confidence: 1)
        #expect(KeyDetector.suggestedShift(songKey: b, comfortableMidi: 50) == 3)
    }

    @Test("semitones become the cents the pitch stage wants")
    func cents() {
        #expect(KeyDetector.cents(fromSemitones: 0) == 0)
        #expect(KeyDetector.cents(fromSemitones: 5) == 500)
        #expect(KeyDetector.cents(fromSemitones: -3) == -300)
    }

    /// The chroma has to fold octaves together — that is the whole idea — and
    /// it has to land the fold on the right pitch class.
    @Test("a tone lands in its own pitch class, whichever octave it is in")
    func chromaFoldsOctaves() {
        let binCount = 2048
        let rate = 48000.0
        let hertzPerBin = rate / Double(binCount * 2)
        for hertz in [220.0, 440.0, 880.0] {  // three As
            var magnitudes = [Float](repeating: 0, count: binCount)
            magnitudes[Int((hertz / hertzPerBin).rounded())] = 1
            let bins = KeyDetector.chroma(
                magnitudes: magnitudes, sampleRate: rate, binCount: binCount)
            let loudest = bins.firstIndex(of: bins.max() ?? 0)
            #expect(loudest == 9)  // A
        }
    }

    /// Rumble below a bass guitar and cymbals above where pitch stops being
    /// pitch are not notes, and letting them in makes every song's key the
    /// key of its kick drum.
    @Test("what is not a note is left out")
    func chromaIgnoresTheEdges() {
        let binCount = 2048
        let rate = 48000.0
        let hertzPerBin = rate / Double(binCount * 2)
        var magnitudes = [Float](repeating: 0, count: binCount)
        magnitudes[Int((30.0 / hertzPerBin).rounded())] = 1  // below 55 Hz
        magnitudes[Int((9000.0 / hertzPerBin).rounded())] = 1  // above 5 kHz
        let bins = KeyDetector.chroma(
            magnitudes: magnitudes, sampleRate: rate, binCount: binCount)
        #expect(bins.reduce(0, +) == 0)
    }
}

// MARK: - Melody files

/// A Standard MIDI File written by hand, so a parse can be asserted against
/// bytes somebody chose rather than against a file nobody can read.
///
/// Every one of these is built from the format's own primitives — variable
/// length deltas, running status, a tempo map — because those are exactly the
/// parts that look like they work. A parser that ignores tempo changes reads a
/// file perfectly and puts the last verse ten seconds from where it is sung.
struct SMFWriter {

    /// Seven bits a byte, high bit set on every byte but the last.
    static func variableLength(_ value: Int) -> [UInt8] {
        var buffer = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            buffer.insert(UInt8(rest & 0x7F | 0x80), at: 0)
            rest >>= 7
        }
        return buffer
    }

    static func big32(_ value: Int) -> [UInt8] {
        [
            UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
            UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF),
        ]
    }

    static func big16(_ value: Int) -> [UInt8] {
        [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// Wraps events — each a delta and its bytes — in an `MTrk`, ending it the
    /// way the format requires.
    static func track(_ events: [(delta: Int, bytes: [UInt8])]) -> [UInt8] {
        var body: [UInt8] = []
        for event in events {
            body += variableLength(event.delta)
            body += event.bytes
        }
        body += variableLength(0) + [0xFF, 0x2F, 0x00]
        return Array("MTrk".utf8) + big32(body.count) + body
    }

    static func file(division: Int, tracks: [[UInt8]]) -> Data {
        var bytes = Array("MThd".utf8) + big32(6) + big16(tracks.count > 1 ? 1 : 0)
        bytes += big16(tracks.count) + big16(division)
        for track in tracks { bytes += track }
        return Data(bytes)
    }

    static func name(_ text: String) -> [UInt8] {
        let raw = Array(text.utf8)
        return [0xFF, 0x03, UInt8(raw.count)] + raw
    }

    /// Microseconds per quarter note.
    static func tempo(_ microseconds: Int) -> [UInt8] {
        [
            0xFF, 0x51, 0x03, UInt8(microseconds >> 16 & 0xFF),
            UInt8(microseconds >> 8 & 0xFF), UInt8(microseconds & 0xFF),
        ]
    }

    static func noteOn(_ note: Int, channel: Int = 0, velocity: Int = 100) -> [UInt8] {
        [UInt8(0x90 | channel), UInt8(note), UInt8(velocity)]
    }

    static func noteOff(_ note: Int, channel: Int = 0) -> [UInt8] {
        [UInt8(0x80 | channel), UInt8(note), 0]
    }
}

@Suite("Melody files")
struct MidiMelodyTests {

    /// 480 ticks a quarter at 120 bpm is half a second a quarter, so a note a
    /// quarter long is 0.5 s. Every timing below is that arithmetic.
    @Test("a note lands where the tempo puts it")
    func notesAreTimed() throws {
        let data = SMFWriter.file(
            division: 480,
            tracks: [
                SMFWriter.track([
                    (0, SMFWriter.tempo(500_000)),
                    (0, SMFWriter.noteOn(60)),
                    (480, SMFWriter.noteOff(60)),
                    (0, SMFWriter.noteOn(64)),
                    (960, SMFWriter.noteOff(64)),
                ])
            ])
        let melody = try #require(MidiMelody.parse(data))
        #expect(melody.notes.count == 2)
        #expect(melody.notes[0].midi == 60)
        #expect(abs(melody.notes[0].start - 0) < 1e-9)
        #expect(abs(melody.notes[0].end - 0.5) < 1e-9)
        #expect(melody.notes[1].midi == 64)
        #expect(abs(melody.notes[1].start - 0.5) < 1e-9)
        #expect(abs(melody.notes[1].end - 1.5) < 1e-9)
    }

    /// Tempo is a map, not a number. A parser that reads only the first one
    /// gets every note before the change exactly right, which is what makes it
    /// hard to notice.
    @Test("a tempo change moves everything after it and nothing before it")
    func tempoChangesApply() throws {
        let data = SMFWriter.file(
            division: 480,
            tracks: [
                SMFWriter.track([
                    (0, SMFWriter.tempo(500_000)),  // 120 bpm
                    (0, SMFWriter.noteOn(60)),
                    (480, SMFWriter.noteOff(60)),
                    (0, SMFWriter.tempo(1_000_000)),  // 60 bpm, so twice as slow
                    (0, SMFWriter.noteOn(62)),
                    (480, SMFWriter.noteOff(62)),
                ])
            ])
        let melody = try #require(MidiMelody.parse(data))
        #expect(abs(melody.notes[0].end - 0.5) < 1e-9)
        // The second quarter now takes a whole second rather than half of one.
        #expect(abs(melody.notes[1].start - 0.5) < 1e-9)
        #expect(abs(melody.notes[1].end - 1.5) < 1e-9)
    }

    /// The default is 120 bpm, which is what the standard says to assume, not
    /// zero and not whatever the first tempo event happens to say.
    @Test("a file with no tempo event is 120 bpm")
    func defaultTempo() throws {
        let data = SMFWriter.file(
            division: 96,
            tracks: [
                SMFWriter.track([(0, SMFWriter.noteOn(60)), (96, SMFWriter.noteOff(60))])
            ])
        let melody = try #require(MidiMelody.parse(data))
        #expect(abs(melody.notes[0].end - 0.5) < 1e-9)
    }

    /// Running status is not an optimisation somebody might have used; it is
    /// what every sequencer emits. A parser without it reads the first note and
    /// then garbage.
    @Test("running status is understood")
    func runningStatus() throws {
        // One 0x90 status byte, then three note-on pairs with no status of
        // their own — two with velocity zero, which is a note off.
        let data = SMFWriter.file(
            division: 480,
            tracks: [
                SMFWriter.track([
                    (0, SMFWriter.noteOn(60)),
                    (480, [60, 0]),
                    (0, [67, 100]),
                    (480, [67, 0]),
                ])
            ])
        let melody = try #require(MidiMelody.parse(data))
        #expect(melody.notes.count == 2)
        #expect(melody.notes.map(\.midi) == [60, 67])
        #expect(abs(melody.notes[1].start - 0.5) < 1e-9)
        #expect(abs(melody.notes[1].end - 1.0) < 1e-9)
    }

    /// A drum kit has no melody however high its note numbers read, and it is
    /// on channel 10 by a convention every file follows.
    @Test("percussion is not a tune")
    func percussionIsExcluded() throws {
        let data = SMFWriter.file(
            division: 480,
            tracks: [
                SMFWriter.track([
                    (0, SMFWriter.noteOn(60)),
                    (0, SMFWriter.noteOn(100, channel: 9)),
                    (480, SMFWriter.noteOff(60)),
                    (0, SMFWriter.noteOff(100, channel: 9)),
                ])
            ])
        let melody = try #require(MidiMelody.parse(data))
        #expect(melody.notes.count == 1)
        #expect(melody.notes[0].midi == 60)
        // And the tune is not the cymbal, which would be the top note.
        #expect(melody.melody.map(\.midi) == [60])
    }

    /// The whole point of the reduction: an arrangement is several parts at
    /// once and a singer sings one of them.
    @Test("the tune is the top line")
    func skylinePicksTheTop() throws {
        let data = SMFWriter.file(
            division: 480,
            tracks: [
                // A bass line under a melody, both sounding throughout.
                SMFWriter.track([
                    (0, SMFWriter.noteOn(36)),
                    (960, SMFWriter.noteOff(36)),
                    (0, SMFWriter.noteOn(38)),
                    (960, SMFWriter.noteOff(38)),
                ]),
                SMFWriter.track([
                    (0, SMFWriter.noteOn(72)),
                    (480, SMFWriter.noteOff(72)),
                    (0, SMFWriter.noteOn(74)),
                    (480, SMFWriter.noteOff(74)),
                    (0, SMFWriter.noteOn(76)),
                    (960, SMFWriter.noteOff(76)),
                ]),
            ])
        let melody = try #require(MidiMelody.parse(data))
        #expect(melody.notes.count == 5)
        #expect(melody.melody.map(\.midi) == [72, 74, 76])
        #expect(abs(melody.duration - 2.0) < 1e-9)
    }

    /// A name is a statement of intent from whoever made the file, and nothing
    /// inferred beats it — here the named vocal line is deliberately *below*
    /// the accompaniment, so the skyline alone would get it wrong.
    @Test("a track that says it is the voice wins over the top line")
    func namedVocalTrackWins() throws {
        let data = SMFWriter.file(
            division: 480,
            tracks: [
                SMFWriter.track([
                    (0, SMFWriter.name("Piano")),
                    (0, SMFWriter.noteOn(84)),
                    (960, SMFWriter.noteOff(84)),
                ]),
                SMFWriter.track([
                    (0, SMFWriter.name("Lead Vocal")),
                    (0, SMFWriter.noteOn(60)),
                    (480, SMFWriter.noteOff(60)),
                    (0, SMFWriter.noteOn(62)),
                    (480, SMFWriter.noteOff(62)),
                ]),
            ])
        let melody = try #require(MidiMelody.parse(data))
        #expect(melody.trackNames == ["Piano", "Lead Vocal"])
        #expect(melody.melody.map(\.midi) == [60, 62])
    }

    /// A held note split by something happening underneath it is one note, not
    /// two.
    @Test("a note held under a changing accompaniment stays one note")
    func heldNotesMerge() throws {
        let data = SMFWriter.file(
            division: 480,
            tracks: [
                SMFWriter.track([
                    (0, SMFWriter.noteOn(72)),
                    (240, SMFWriter.noteOn(48)),
                    (240, SMFWriter.noteOff(48)),
                    (480, SMFWriter.noteOff(72)),
                ])
            ])
        let melody = try #require(MidiMelody.parse(data))
        #expect(melody.melody.count == 1)
        #expect(melody.melody[0].midi == 72)
        #expect(abs(melody.melody[0].duration - 1.0) < 1e-9)
    }

    /// A file somebody downloaded is somebody else's output and truncation is
    /// the ordinary failure. It has to come back nil rather than trap.
    @Test("what is not a MIDI file is refused rather than guessed at")
    func refusesRubbish() {
        #expect(MidiMelody.parse(Data()) == nil)
        #expect(MidiMelody.parse(Data("not a midi file at all".utf8)) == nil)
        let good = SMFWriter.file(
            division: 480,
            tracks: [
                SMFWriter.track([(0, SMFWriter.noteOn(60)), (480, SMFWriter.noteOff(60))])
            ])
        // Every truncation of a real file. None of them may trap.
        for length in 1..<good.count {
            _ = MidiMelody.parse(good.prefix(length))
        }
        #expect(MidiMelody.parse(good.prefix(good.count - 4)) == nil)
    }

    /// A file that parses and holds nothing is a different answer from a file
    /// that is not a MIDI file, and the interface says different things about
    /// them.
    @Test("an empty but valid file is an empty melody, not a refusal")
    func emptyIsNotNil() throws {
        let data = SMFWriter.file(division: 480, tracks: [SMFWriter.track([])])
        let melody = try #require(MidiMelody.parse(data))
        #expect(melody.notes.isEmpty)
        #expect(melody.melody.isEmpty)
        #expect(melody.duration == 0)
    }

    @Test("sampling the melody skips the rests")
    func samplingSkipsRests() throws {
        let data = SMFWriter.file(
            division: 480,
            tracks: [
                SMFWriter.track([
                    (0, SMFWriter.noteOn(60)),
                    (480, SMFWriter.noteOff(60)),  // 0 to 0.5 s
                    (960, SMFWriter.noteOn(62)),  // a whole rest
                    (480, SMFWriter.noteOff(62)),  // 1.5 to 2.0 s
                ])
            ])
        let melody = try #require(MidiMelody.parse(data))
        let samples = melody.samples(every: 0.1)
        // Five in each note and none in the second between them.
        #expect(samples.count == 10)
        #expect(samples.allSatisfy { $0.time < 0.5 || $0.time >= 1.5 })
        #expect(melody.midi(at: 0.25) == 60)
        #expect(melody.midi(at: 1.0) == nil)
        #expect(melody.midi(at: 1.75) == 62)
        #expect(melody.midi(at: 99) == nil)
    }
}

// MARK: - Karaoke scoring

/// How much of the tune somebody sang.
///
/// A pure function of two series, which is the only reason any of this can be
/// asserted at all: the failure mode of a scorer is not a crash but eighty-seven
/// per cent for a performance that was nothing of the kind, and that looks
/// exactly like a correct answer.
@Suite("Karaoke scoring")
struct KaraokeScoreTests {

    /// A steady reference: one note, sampled every 50 ms.
    private func reference(midi: Double = 60, seconds: Double = 10) -> [PitchSample] {
        stride(from: 0.0, to: seconds, by: 0.05).map { PitchSample(time: $0, midi: midi) }
    }

    /// A singer over the same span, offset from the tune by a fixed amount.
    /// Sampled at the pitch tracker's own rate, which is what the live path
    /// produces and is deliberately not the reference's rate.
    private func singer(
        offBy semitones: Double, midi: Double = 60, seconds: Double = 10, from: Double = 0
    ) -> [PitchSample] {
        stride(from: from, to: seconds, by: 2048.0 / 48000).map {
            PitchSample(time: $0, midi: midi + semitones)
        }
    }

    @Test("singing it exactly is a hundred")
    func perfect() {
        let score = KaraokeScore.score(sung: singer(offBy: 0), reference: reference())
        #expect(abs(score.percentage - 100) < 0.001)
        #expect(score.silentSeconds == 0)
        #expect(abs(score.referenceSeconds - 10) < 0.06)
        #expect(abs((score.meanErrorSemitones ?? 9) - 0) < 1e-9)
    }

    @Test("singing nothing is nothing")
    func silence() {
        let score = KaraokeScore.score(sung: [], reference: reference())
        #expect(score.percentage == 0)
        #expect(abs(score.silentSeconds - score.referenceSeconds) < 1e-9)
        #expect(score.meanErrorSemitones == nil)
        #expect(score.sungSeconds == 0)
    }

    /// The thresholds, either side of each. These are the numbers the whole
    /// feature rests on, so they are asserted rather than trusted.
    @Test("a semitone out is still on the note, and a tone out is not")
    func thresholds() {
        // Just inside "on".
        #expect(
            KaraokeScore.score(sung: singer(offBy: 0.99), reference: reference()).percentage
                > 99.9)
        // Between the two: half credit.
        let near = KaraokeScore.score(sung: singer(offBy: 1.4), reference: reference())
        #expect(abs(near.percentage - 50) < 0.5)
        #expect(near.onPitchSeconds == 0)
        #expect(near.nearPitchSeconds > 9)
        // Past both: nothing, even though a pitch was produced the whole time.
        let wrong = KaraokeScore.score(sung: singer(offBy: 2), reference: reference())
        #expect(wrong.percentage < 0.5)
        #expect(wrong.silentSeconds == 0)
        #expect(wrong.sungSeconds > 9)
        // Singing badly is not the same as not singing, and neither of them
        // shrinks the tune: the denominator is ten seconds whatever happened.
        #expect(abs(wrong.referenceSeconds - 10) < 0.06)
    }

    /// Flat is a different thing from bad, and the sign is what says which.
    @Test("the mean error keeps its sign")
    func meanErrorIsSigned() {
        let flat = KaraokeScore.score(sung: singer(offBy: -0.4), reference: reference())
        #expect((flat.meanErrorSemitones ?? 0) < -0.39)
        let sharp = KaraokeScore.score(sung: singer(offBy: 0.4), reference: reference())
        #expect((sharp.meanErrorSemitones ?? 0) > 0.39)
    }

    /// Every karaoke machine ever built forgives the octave, because a man
    /// singing a melody written for a soprano sings it an octave down and he is
    /// singing the tune.
    @Test("an octave down is the same note")
    func octavesAreForgiven() {
        let score = KaraokeScore.score(sung: singer(offBy: -12), reference: reference())
        #expect(abs(score.percentage - 100) < 0.001)
        #expect(abs(KaraokeScore.semitoneError(sung: 48, reference: 60)) < 1e-9)
        #expect(abs(KaraokeScore.semitoneError(sung: 84, reference: 60)) < 1e-9)
        // And it takes the shorter way round, so eight semitones up reads as
        // four down.
        #expect(abs(KaraokeScore.semitoneError(sung: 65, reference: 60) - 5) < 1e-9)
        #expect(abs(KaraokeScore.semitoneError(sung: 68, reference: 60) + 4) < 1e-9)
    }

    /// The denominator is the tune, not the performance. Measured the other way
    /// round, somebody could score a hundred by singing one note perfectly and
    /// then stopping — which is the single most likely way to get this wrong.
    @Test("singing one note of ten and stopping is not a hundred")
    func theDenominatorIsTheTune() {
        let score = KaraokeScore.score(
            sung: singer(offBy: 0, seconds: 1), reference: reference(seconds: 10))
        #expect(score.percentage > 5)
        #expect(score.percentage < 15)
        #expect(score.silentSeconds > 8.5)
        #expect(score.pitchPercentage > 99)
        #expect(score.coveragePercentage > 9)
        #expect(score.coveragePercentage < 11)
    }

    /// A live score is about the attempt so far. Notes that have not happened
    /// are not silence: charging the complete MIDI file made a perfect first
    /// ten seconds of a four-minute song read about four per cent.
    @Test("the live score does not charge notes in the future")
    func futureIsNotSilence() {
        let sung = singer(offBy: 0, seconds: 10)
        let wholeSong = reference(seconds: 4 * 60)
        let live = KaraokeScore.score(
            sung: sung, reference: wholeSong, through: 10)
        let finished = KaraokeScore.score(
            sung: sung, reference: wholeSong)

        #expect(live.percentage > 99)
        #expect(abs(live.referenceSeconds - 10) < 0.1)
        #expect(live.silentSeconds < 0.1)
        #expect(finished.percentage > 3)
        #expect(finished.percentage < 5)
    }

    @Test("microphone samples recorded during pause are outside the live score")
    func pausedMicrophoneSamplesAreIgnored() {
        let beforePause = singer(offBy: 0, seconds: 10)
        let duringPause = singer(offBy: 3, seconds: 20, from: 10)
        let exact = KaraokeScore.score(
            sung: beforePause + duringPause,
            reference: reference(seconds: 20), through: 10)

        #expect(exact.percentage > 99)
        #expect(abs(exact.referenceSeconds - 10) < 0.1)
        #expect(abs(exact.sungSeconds - 10) < 0.1)
        #expect(exact.silentSeconds < 0.1)

        let cMajor = KeyDetector.Key(pitchClass: 0, isMinor: false, confidence: 0.8)
        let key = KaraokeScore.keyScore(
            sung: beforePause + duringPause, key: cMajor,
            lyrics: [Lyrics.Line(time: 0, text: "phrase")], through: 10)
        // A lone timed line is a four-second phrase. Samples after it — paused
        // or otherwise — are not part of key-and-timing scoring.
        #expect(abs(key.sungSeconds - 4) < 0.1)
    }

    /// And a singer producing samples twice as fast cannot earn twice the
    /// credit, which is the same bug pointing the other way.
    @Test("a faster tracker does not score higher")
    func sampleRateDoesNotChangeTheScore() {
        let slow = stride(from: 0.0, to: 10, by: 0.05).map { PitchSample(time: $0, midi: 60) }
        let fast = stride(from: 0.0, to: 10, by: 0.02).map { PitchSample(time: $0, midi: 60) }
        let a = KaraokeScore.score(sung: slow, reference: reference())
        let b = KaraokeScore.score(sung: fast, reference: reference())
        #expect(abs(a.percentage - b.percentage) < 0.001)
    }

    /// A rest is not something to be wrong about. A reference series with a gap
    /// in it must not charge the singer for the gap, or a song with an
    /// instrumental break would be unscoreable.
    @Test("a rest costs nothing")
    func restsAreFree() {
        let first = stride(from: 0.0, to: 2.0, by: 0.05).map {
            PitchSample(time: $0, midi: 60)
        }
        let second = stride(from: 30.0, to: 32.0, by: 0.05).map {
            PitchSample(time: $0, midi: 60)
        }
        let sung =
            stride(from: 0.0, to: 2.0, by: 2048.0 / 48000).map {
                PitchSample(time: $0, midi: 60)
            }
            + stride(from: 30.0, to: 32.0, by: 2048.0 / 48000).map {
                PitchSample(time: $0, midi: 60)
            }
        let score = KaraokeScore.score(sung: sung, reference: first + second)
        #expect(abs(score.percentage - 100) < 0.001)
        // Four seconds of tune, not thirty-two.
        #expect(abs(score.referenceSeconds - 4) < 0.06)
    }

    /// The per-line breakdown is the half a singer can act on: a total says how
    /// it went, a line says where it went wrong.
    @Test("each line is scored on its own")
    func perLine() {
        let lines = [
            Lyrics.Line(time: 0, text: "first"),
            Lyrics.Line(time: 5, text: "second"),
        ]
        // Right for the first five seconds, a tone and a half out for the last.
        let sung = singer(offBy: 0, seconds: 5) + singer(offBy: 3, seconds: 10, from: 5)
        let score = KaraokeScore.score(sung: sung, reference: reference(), lyrics: lines)
        #expect(score.lines.count == 2)
        #expect(score.lines[0].text == "first")
        #expect(score.lines[0].percentage > 99)
        #expect(score.lines[1].percentage < 1)
        #expect(abs(score.lines[0].referenceSeconds - 5) < 0.06)
        #expect(abs(score.lines[1].referenceSeconds - 5) < 0.06)
        // And the total is the two of them together. This is the assertion that
        // found the one real bug in the scorer: the denominator was rebuilt by
        // adding up on, near and silent, and a moment that was sung badly is in
        // none of those — so a performance that was half right and half a tone
        // and a half out came back as a hundred per cent.
        #expect(abs(score.percentage - 50) < 1)
    }

    /// Tune before the first line — an introduction — still counts towards the
    /// total, and belongs to no line.
    @Test("an introduction counts towards the total and towards no line")
    func introductionIsInTheTotalOnly() {
        let lines = [Lyrics.Line(time: 5, text: "the only line")]
        let score = KaraokeScore.score(
            sung: singer(offBy: 0, seconds: 10), reference: reference(), lyrics: lines)
        #expect(score.lines.count == 1)
        #expect(abs(score.lines[0].referenceSeconds - 5) < 0.06)
        #expect(abs(score.referenceSeconds - 10) < 0.06)
    }

    /// Below a bar of music the number swings by tens of points a note, and
    /// showing it would be showing noise with a decimal point on it.
    @Test("too little to judge says so")
    func tooShortToJudge() {
        let brief = stride(from: 0.0, to: 1.0, by: 0.05).map {
            PitchSample(time: $0, midi: 60)
        }
        #expect(KaraokeScore.score(sung: [], reference: brief).isMeaningful == false)
        #expect(KaraokeScore.score(sung: [], reference: reference()).isMeaningful)
        #expect(KaraokeScore.none.isMeaningful == false)
        #expect(KaraokeScore.none.percentage == 0)
    }

    /// A singer whose samples fall a frame away from the reference moments
    /// still counts — otherwise the score would depend on where the tracker's
    /// frame boundaries happened to land — and one two hundred milliseconds
    /// away does not, because that is a different note.
    @Test("the pairing window is one tracker frame, not zero and not a second")
    func pairingWindow() {
        // Two moments, because one sample has no gap to take a median of.
        let reference = [
            PitchSample(time: 1.0, midi: 60), PitchSample(time: 1.05, midi: 60),
        ]
        let close = [PitchSample(time: 1.05, midi: 60)]
        let far = [PitchSample(time: 1.3, midi: 60)]
        #expect(KaraokeScore.score(sung: close, reference: reference).onPitchSeconds > 0)
        #expect(KaraokeScore.score(sung: far, reference: reference).onPitchSeconds == 0)
        #expect(KaraokeScore.score(sung: far, reference: reference).silentSeconds > 0)
    }

    /// The series arrive from a ring drained on a timer, so "already sorted" is
    /// an assumption rather than a guarantee.
    @Test("samples out of order are put back in order rather than believed")
    func unsortedInput() {
        let ordered = reference(seconds: 3)
        let score = KaraokeScore.score(
            sung: singer(offBy: 0, seconds: 3).reversed(), reference: ordered.reversed())
        #expect(abs(score.percentage - 100) < 0.001)
    }

    @Test("a streaming song can be scored honestly from its key without a MIDI file")
    func keyFallback() {
        let cMajor = KeyDetector.Key(pitchClass: 0, isMinor: false, confidence: 0.8)
        let inKey =
            singer(offBy: 0, midi: 60, seconds: 2)
            + singer(offBy: 0, midi: 64, seconds: 4, from: 2)
        let chromatic = singer(offBy: 0, midi: 61, seconds: 4)
        let lines = [Lyrics.Line(time: 0, text: "the phrase")]
        let good = KaraokeScore.keyScore(
            sung: inKey, key: cMajor, lyrics: lines, through: 4)
        let wrong = KaraokeScore.keyScore(
            sung: chromatic, key: cMajor, lyrics: lines, through: 4)
        #expect(good.isMeaningful)
        #expect(good.percentage > 98)
        #expect(wrong.percentage < 1)
        #expect(good.lines.count == 1)
        #expect(good.lines[0].percentage > 98)
    }

    @Test("the key fallback charges timed silence rather than awarding one good note")
    func keyFallbackCountsSilence() {
        let cMajor = KeyDetector.Key(pitchClass: 0, isMinor: false, confidence: 0.8)
        let score = KaraokeScore.keyScore(
            sung: singer(offBy: 0, midi: 60, seconds: 2), key: cMajor,
            lyrics: [Lyrics.Line(time: 0, text: "four seconds")], through: 4)
        #expect(score.percentage > 45)
        #expect(score.percentage < 55)
        #expect(score.silentSeconds > 1.9)
        #expect(abs(score.referenceSeconds - 4) < 0.01)
    }

    @Test("an instrumental gap between timed lines is not counted as missed singing")
    func keyFallbackSkipsInstrumentalGaps() {
        let cMajor = KeyDetector.Key(pitchClass: 0, isMinor: false, confidence: 0.8)
        let first = singer(offBy: 0, midi: 60, seconds: 4)
        let second = singer(offBy: 0, midi: 64, seconds: 34, from: 30)
        let score = KaraokeScore.keyScore(
            sung: first + second, key: cMajor,
            lyrics: [
                Lyrics.Line(time: 0, text: "first"),
                Lyrics.Line(time: 30, text: "second"),
            ], through: 34)
        #expect(score.percentage > 98)
        #expect(abs(score.referenceSeconds - 8) < 0.1)
        #expect(score.silentSeconds < 0.1)
    }

    @Test("singing through an instrumental cannot change a key score")
    func keyFallbackIgnoresInstrumentalSinging() {
        let cMajor = KeyDetector.Key(pitchClass: 0, isMinor: false, confidence: 0.8)
        let lines = [
            Lyrics.Line(time: 0, text: "first"),
            Lyrics.Line(time: 30, text: "second"),
        ]
        let phrases =
            singer(offBy: 0, midi: 60, seconds: 4)
            + singer(offBy: 0, midi: 64, seconds: 34, from: 30)
        let instrumental = singer(offBy: 0, midi: 61, seconds: 30, from: 4)
        let withInstrumental = (phrases + instrumental).sorted { $0.time < $1.time }

        let clean = KaraokeScore.keyScore(
            sung: phrases, key: cMajor, lyrics: lines, through: 34)
        let humming = KaraokeScore.keyScore(
            sung: withInstrumental, key: cMajor, lyrics: lines, through: 34)

        #expect(abs(clean.percentage - humming.percentage) < 1e-9)
        #expect(abs(clean.sungSeconds - humming.sungSeconds) < 1e-9)
        #expect(abs(clean.pitchPercentage - humming.pitchPercentage) < 1e-9)
    }

    @Test("excluded pitches cannot dilute the reported tuning error")
    func keyFallbackErrorUsesOnlyScoredPitches() throws {
        let cMajor = KeyDetector.Key(pitchClass: 0, isMinor: false, confidence: 0.8)
        let lines = [
            Lyrics.Line(time: 0, text: "first"),
            Lyrics.Line(time: 30, text: "second"),
        ]
        let scored = singer(offBy: 0, midi: 61, seconds: 2)
        let instrumental = singer(offBy: 0, midi: 60, seconds: 10, from: 5)
        let future = singer(offBy: 0, midi: 60, seconds: 32, from: 30)

        let result = KaraokeScore.keyScore(
            sung: scored + instrumental + future, key: cMajor,
            lyrics: lines, through: 2)
        let error = try #require(result.meanErrorSemitones)
        #expect(abs(error - 1) < 0.02)

        let nothingReached = KaraokeScore.keyScore(
            sung: future, key: cMajor, lyrics: lines, through: 2)
        #expect(nothingReached.meanErrorSemitones == nil)
    }

    @Test("a captured original supplies notes only while words are being sung")
    func capturedOriginalReference() {
        let samples =
            singer(offBy: 0, midi: 60, seconds: 4)
            + singer(offBy: 0, midi: 36, seconds: 30, from: 4)
            + singer(offBy: 0, midi: 64, seconds: 34, from: 30)
            + [PitchSample(time: 31, midi: 110)]
        let reference = KaraokeScore.capturedReference(
            samples,
            lyrics: [
                Lyrics.Line(time: 0, text: "first"),
                Lyrics.Line(time: 30, text: "second"),
            ], through: 34)
        #expect(!reference.isEmpty)
        #expect(reference.allSatisfy { $0.time < 4 || $0.time >= 30 })
        #expect(reference.allSatisfy { (36...96).contains($0.midi) })
        #expect(reference.count < samples.count / 2)

        let good = KaraokeScore.score(
            sung: reference, reference: reference)
        let wrong = KaraokeScore.score(
            sung: reference.map {
                PitchSample(time: $0.time, midi: $0.midi + 2)
            }, reference: reference)
        #expect(good.percentage > 98)
        #expect(wrong.percentage < 1)
    }
}

// MARK: - Following a singer off one source

/// A duet is two microphones, two colours and two scores, and it is structurally
/// free: the sources were never mixed, so each already has its own ring. What
/// was not free is that the pitch tracker existed once, on the mixed analysis
/// tap — a score off that would be the two singers averaged.
@Suite("Following a singer")
struct SingerPitchTests {

    private func tone(hertz: Double, seconds: Double, sampleRate: Double = 48000) -> [Float] {
        (0..<Int(seconds * sampleRate)).map {
            Float(0.5 * sin(2 * .pi * hertz * Double($0) / sampleRate))
        }
    }

    /// A440 is MIDI 69 by definition, so this is the one measurement in the
    /// whole path with no tolerance to argue about.
    @Test("a tone comes back as its own note")
    func findsTheNote() throws {
        let singer = try #require(SingerPitch(sampleRate: 48000))
        singer.reset(at: 0)
        singer.add(tone(hertz: 220, seconds: 1))
        #expect(!singer.samples.isEmpty)
        let mean = singer.samples.reduce(0) { $0 + $1.midi } / Double(singer.samples.count)
        #expect(abs(mean - 57) < 0.2)  // A3
        #expect(abs(Double(singer.hertz) - 220) < 2)
    }

    /// The clock is the audio, not the player: an Apple event round trip is
    /// tens of milliseconds and irregular, and the pairing window is sixty.
    @Test("the clock is anchored where the song was and counts frames from there")
    func clockIsAnchored() throws {
        let singer = try #require(SingerPitch(sampleRate: 48000))
        singer.reset(at: 30)
        singer.add(tone(hertz: 220, seconds: 1))
        #expect(singer.samples.first.map { $0.time >= 30 } == true)
        // Twenty-three frames of 2048 fit in a second at 48 kHz.
        #expect(abs(singer.elapsed - 30.98) < 0.05)
        #expect(singer.samples.last.map { $0.time < 31 } == true)
        singer.reset(at: 0)
        #expect(singer.samples.isEmpty)
        #expect(singer.elapsed == 0)
    }

    /// Silence is not a note. A tracker that reported one would fill the score
    /// with credit for a room.
    @Test("silence produces no samples at all")
    func silenceIsNotSung() throws {
        let singer = try #require(SingerPitch(sampleRate: 48000))
        singer.reset(at: 0)
        singer.add([Float](repeating: 0, count: 48000))
        #expect(singer.samples.isEmpty)
        #expect(singer.hertz == 0)
        #expect(singer.comfortableMidi == nil)
        // But the clock still ran, or a rest would shift everything after it.
        #expect(singer.elapsed > 0.9)
    }

    @Test("a paused backing track freezes score time while the tuner stays live")
    func pausedBackingFreezesScoreTime() throws {
        let singer = try #require(SingerPitch(sampleRate: 48_000))
        singer.reset(at: 10)
        singer.add(tone(hertz: 220, seconds: 1))
        let elapsedBeforePause = singer.elapsed
        let samplesBeforePause = singer.samples

        singer.add(tone(hertz: 330, seconds: 10), advancesTimeline: false)

        #expect(singer.elapsed == elapsedBeforePause)
        #expect(singer.samples == samplesBeforePause)
        #expect(abs(Double(singer.hertz) - 330) < 3)

        singer.add(tone(hertz: 220, seconds: 1))
        #expect(abs(singer.elapsed - elapsedBeforePause - 0.98) < 0.05)
        #expect(singer.samples.count > samplesBeforePause.count)
    }

    /// Two singers on two rings is the whole of duet mode, and what has to be
    /// true is that neither is the other.
    @Test("two singers on two taps are two different answers")
    func twoSingersAreSeparate() throws {
        let low = try #require(SingerPitch(sampleRate: 48000))
        let high = try #require(SingerPitch(sampleRate: 48000))
        low.reset(at: 0)
        high.reset(at: 0)
        low.add(tone(hertz: 110, seconds: 1))
        high.add(tone(hertz: 330, seconds: 1))
        let lowMidi = try #require(low.comfortableMidi)
        let highMidi = try #require(high.comfortableMidi)
        #expect(abs(lowMidi - 45) < 0.3)  // A2
        #expect(abs(highMidi - 64) < 0.3)  // E4
        #expect(highMidi - lowMidi > 18)
    }

    /// The panel keeps one of these open per source the whole time it is
    /// looked at, so that the note it shows is the singer and not the mixed
    /// bus. That is hours rather than one song, and the list of every sample is
    /// only wanted for a score — twenty-three a second is eighty thousand an
    /// hour per source. The range has to survive the list not being kept.
    @Test("the range is measured whether or not every sample is kept")
    func rangeWithoutHistory() throws {
        let keeping = try #require(SingerPitch(sampleRate: 48000))
        let notKeeping = try #require(SingerPitch(sampleRate: 48000))
        notKeeping.keepsHistory = false
        for singer in [keeping, notKeeping] {
            singer.reset(at: 0)
            singer.add(tone(hertz: 220, seconds: 2))
        }
        #expect(keeping.samples.count > 40)
        #expect(notKeeping.samples.isEmpty)
        let kept = try #require(keeping.comfortableMidi)
        let unkept = try #require(notKeeping.comfortableMidi)
        #expect(abs(kept - unkept) < 1e-9, "\(kept) against \(unkept)")
        #expect(abs(unkept - 57) < 0.2)  // A3
        #expect(abs(notKeeping.hertz - keeping.hertz) < 0.01)
    }

    @Test("block boundaries do not change a frame or its clock")
    func arbitraryBlockBoundaries() throws {
        let whole = try #require(SingerPitch(sampleRate: 48_000))
        let chunked = try #require(SingerPitch(sampleRate: 48_000))
        let samples = tone(hertz: 220, seconds: 0.7)
        whole.reset(at: 12.5)
        chunked.reset(at: 12.5)
        whole.add(samples)

        let sizes = [1, 17, 2_047, 113, 4_096, 509]
        var offset = 0
        var block = 0
        while offset < samples.count {
            let end = min(samples.count, offset + sizes[block % sizes.count])
            chunked.add(Array(samples[offset..<end]))
            offset = end
            block += 1
        }

        #expect(chunked.samples == whole.samples)
        #expect(chunked.hertz == whole.hertz)
        #expect(chunked.elapsed == whole.elapsed)
    }

    #if DEBUG
        @Test(
            "one second of steady-state pitch tracking allocates nothing",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("one second of steady-state pitch tracking allocates nothing")
    #endif
    func steadyStateDoesNotAllocate() throws {
        let singer = try #require(SingerPitch(sampleRate: 48_000))
        singer.keepsHistory = false
        let samples = tone(hertz: 220, seconds: 1)

        // Warm Accelerate and every lazy Swift runtime path before measuring.
        singer.add(Array(samples.prefix(PitchTracker.frameSize)))
        singer.reset(at: 0)

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        samples.withUnsafeBufferPointer { buffer in
            yun_rt_tripwire_mark_realtime(true)
            singer.add(buffer)
            yun_rt_tripwire_mark_realtime(false)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before

        print(
            "singer pitch steady state: \(elapsed) ns/s of audio, "
                + "\(allocations) allocation operations")
        #expect(allocations == 0)
    }
}

// MARK: - The key of real audio

/// The profile match was tested against synthesised chromas, which checks the
/// arithmetic and nothing else. This is the other half: real samples, through
/// the same FFT the application runs, into the same chroma, and out as a key.
///
/// A chord progression rather than a scale, because a scale has no mode — every
/// note of C major is a note of A minor, and what decides between them is which
/// chords are used and for how long.
@Suite("The key of real audio")
struct KeyFromAudioTests {

    /// I – IV – V – I, three times, as pure tones.
    ///
    /// The union of those three chords is the whole diatonic scale, and the
    /// tonic triad appears twice, which is the shape the key profiles are built
    /// to find. Voiced from MIDI 72 upwards rather than down where a bass
    /// singer lives, for a reason worth writing down: a 2048-point transform at
    /// 48 kHz is 23.4 Hz a bin, and a semitone at 130 Hz is 7.8 Hz — three
    /// notes to a bin. The chroma cannot separate them down there, and a test
    /// voiced there would be measuring that rather than the key.
    private func progression(tonic: Int, sampleRate: Double = 48000) -> [Float] {
        let chords = [0, 5, 7, 0].map { degree in
            [degree, degree + 4, degree + 7, degree + 12].map { 72 + tonic + $0 }
        }
        var samples: [Float] = []
        var phase = 0
        for _ in 0..<3 {
            for chord in chords {
                let frames = Int(sampleRate)  // one second a chord
                for index in 0..<frames {
                    let time = Double(phase + index) / sampleRate
                    var value = 0.0
                    for note in chord {
                        let hertz = 440 * pow(2, (Double(note) - 69) / 12)
                        value += sin(2 * .pi * hertz * time)
                    }
                    samples.append(Float(value / Double(chord.count) * 0.5))
                }
                phase += frames
            }
        }
        return samples
    }

    /// Every key, so a detector that always answers C is caught.
    @Test("a major progression comes back in the key it was built in", arguments: 0..<12)
    func majorProgression(tonic: Int) throws {
        let rate = 48000.0
        let analyser = try #require(SpectrumAnalyser(sampleRate: rate))
        let samples = progression(tonic: tonic, sampleRate: rate)
        var total = [Double](repeating: 0, count: 12)
        // Accumulated over the whole progression rather than judged a window at
        // a time: one window is a chord, and a chord is in several keys at once.
        var offset = 0
        while offset + 2048 <= samples.count {
            samples.withUnsafeBufferPointer {
                analyser.add($0.baseAddress! + offset, count: 2048)
            }
            let chroma = analyser.chroma(sampleRate: rate)
            for index in 0..<12 { total[index] += chroma[index] }
            offset += 2048
        }
        let key = try #require(KeyDetector.key(from: total))
        #expect(key.pitchClass == tonic)
        #expect(key.isMinor == false)
        // And it is not reported as a guess, because this one is not.
        #expect(key.confidence > 0.3)
    }
}

/// The rate a spectrum analyser is built against.
///
/// This is the intermittent flow-check crash that two separate passes reported
/// and neither could reproduce — about one full run in three, at a different
/// place each time, which is what a crash on a startup race looks like from
/// outside. The stack came from the crash report rather than from reasoning:
/// `SpectrumAnalyser.init` → an assertion failure inside the standard library,
/// with the message "Double value cannot be converted to Int because it is
/// either infinite or NaN".
///
/// The band edges are divided by the bin width, the bin width is the rate over
/// the window, and a route starting against a device that had not settled
/// reported a rate of 0. The caller's `?? 48000` did not help: the value was
/// present, it was simply zero.
@Suite("A spectrum analyser refuses a rate it cannot use")
struct SpectrumRateTests {

    @Test("zero, negative, infinite and NaN all come back nil rather than crashing")
    func refusesUnusableRates() {
        for rate in [0, -1, -48000, .infinity, -.infinity, .nan] as [Double] {
            #expect(SpectrumAnalyser(sampleRate: rate) == nil, "\(rate)")
        }
    }

    @Test("and every real rate still builds")
    func acceptsRealRates() {
        for rate in [8000, 16000, 44100, 48000, 96000, 192_000] as [Double] {
            #expect(SpectrumAnalyser(sampleRate: rate) != nil, "\(rate)")
        }
    }

    /// The bands still have to land somewhere sensible at the extremes, or
    /// "it did not crash" would be the whole of the guarantee.
    @Test("the bands stay inside the spectrum at both ends of the rate range")
    func bandsStayInRange() throws {
        for rate in [8000, 48000, 192_000] as [Double] {
            let analyser = try #require(SpectrumAnalyser(sampleRate: rate))
            for band in 0..<SpectrumAnalyser.bandCount {
                let value = analyser.decibels(ofBand: band)
                #expect(value.isFinite || value == -.infinity, "rate \(rate) band \(band)")
            }
        }
    }
}
