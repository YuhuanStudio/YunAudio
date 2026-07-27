import AVFoundation
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
                yun_rt_cell_retire(cell)
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
        #expect(ordered == [.voiceIsolation, .equaliser, .gate, .compressor, .limiter])
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

        var written = [Float](repeating: 0.5, count: 300)
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

        var samples = [Float](repeating: 1, count: 2000)
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
        var spike: [Float] = [1.0]
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
