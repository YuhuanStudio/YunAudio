import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

#if !DEBUG
    /// The implementation shipped before latency-changing paths gained their
    /// bounded splice. Keeping it beside the release benchmark makes the ten
    /// per cent budget a comparison with the replaced work, not an arbitrary
    /// number that can stay green as the machine changes.
    private final class LinearLatencyHandover {
        private let progress: UnsafeMutablePointer<Float>
        private let warmupFrames: Int
        private let fadeFrames: Int
        private var warmupPosition = 0
        private var fadePosition = 0

        init(sampleRate: Double, newLatencyFrames: Int) {
            warmupFrames = max(0, newLatencyFrames)
            fadeFrames =
                max(1, Int((sampleRate * EffectTransition.fadeSeconds).rounded()))
            progress = .allocate(capacity: fadeFrames)
            for frame in 0..<fadeFrames {
                let value =
                    fadeFrames == 1
                    ? Float(1) : Float(frame) / Float(fadeFrames - 1)
                (progress + frame).initialize(to: value)
            }
        }

        deinit {
            progress.deinitialize(count: fadeFrames)
            progress.deallocate()
        }

        @inline(never)
        func process(
            old: UnsafePointer<Float>, new: UnsafePointer<Float>,
            output: UnsafeMutablePointer<Float>, frames: Int
        ) {
            guard frames > 0 else { return }
            var offset = 0
            if warmupPosition < warmupFrames {
                let count = min(frames, warmupFrames - warmupPosition)
                for frame in 0..<count {
                    output[frame] = sanitisedAudioSample(old[frame])
                }
                warmupPosition += count
                offset = count
            }
            if offset < frames, fadePosition < fadeFrames {
                let count = min(frames - offset, fadeFrames - fadePosition)
                for frame in 0..<count {
                    let input = offset + frame
                    let oldSample = sanitisedAudioSample(old[input])
                    let newSample = sanitisedAudioSample(new[input])
                    let amount = progress[fadePosition + frame]
                    output[input] =
                        oldSample + (newSample - oldSample) * amount
                }
                fadePosition += count
                offset += count
            }
            if offset < frames {
                for frame in offset..<frames {
                    output[frame] = sanitisedAudioSample(new[frame])
                }
            }
        }
    }
#endif

@Suite("Effect transition")
struct EffectTransitionTests {
    private let sampleRate = 48_000.0
    private let oldLatency = 1_024
    private let startFrame = 4_096
    private let frames = 8_192

    @Test("raw to a delayed stage warms up without silence or a step")
    func rawToStage() {
        let paths = makePaths(oldLatency: 0, newLatency: oldLatency)
        let result = run(
            old: paths.old, new: paths.new,
            oldLatency: 0, newLatency: oldLatency)

        #expect(result.silentPrefix == 0)
        #expect(
            result.maximumStep <= paths.naturalStep * 1.1,
            "transition step \(result.maximumStep), natural \(paths.naturalStep)")
        #expect(
            result.fadeRMS >= paths.referenceRMS * 0.75,
            "fade RMS \(result.fadeRMS), reference \(paths.referenceRMS)")
        #expect(
            result.maximumMagnitude <= paths.maximumMagnitude,
            "transition peak \(result.maximumMagnitude), source \(paths.maximumMagnitude)")
    }

    @Test("a delayed stage to raw audio crosses without silence or a step")
    func stageToRaw() {
        let paths = makePaths(oldLatency: oldLatency, newLatency: 0)
        let result = run(
            old: paths.old, new: paths.new,
            oldLatency: oldLatency, newLatency: 0)

        #expect(result.silentPrefix == 0)
        #expect(
            result.maximumStep <= paths.naturalStep * 1.1,
            "transition step \(result.maximumStep), natural \(paths.naturalStep)")
        #expect(
            result.fadeRMS >= paths.referenceRMS * 0.75,
            "fade RMS \(result.fadeRMS), reference \(paths.referenceRMS)")
        #expect(
            result.maximumMagnitude <= paths.maximumMagnitude,
            "transition peak \(result.maximumMagnitude), source \(paths.maximumMagnitude)")
    }

    @Test("different non-zero stage latencies retain the old path until ready")
    func stageToStage() {
        let newLatency = 1_536
        let paths = makePaths(oldLatency: 512, newLatency: newLatency)
        let result = run(
            old: paths.old, new: paths.new,
            oldLatency: 512, newLatency: newLatency)

        #expect(result.silentPrefix == 0)
        #expect(result.warmupFrames == newLatency)
        #expect(
            result.maximumStep <= paths.naturalStep * 1.1,
            "transition step \(result.maximumStep), natural \(paths.naturalStep)")
        #expect(
            result.fadeRMS >= paths.referenceRMS * 0.75,
            "fade RMS \(result.fadeRMS), reference \(paths.referenceRMS)")
        #expect(
            result.maximumMagnitude <= paths.maximumMagnitude,
            "transition peak \(result.maximumMagnitude), source \(paths.maximumMagnitude)")
    }

    @Test("identical constant paths remain at unity gain")
    func identicalConstantPaths() {
        let transition = EffectTransition(
            sampleRate: sampleRate, oldLatencyFrames: 0,
            newLatencyFrames: 0)
        let source = [Float](
            repeating: 0.9, count: transition.fadeFrames)
        let output = render(
            transition: transition, old: source, new: source)

        #expect(output.allSatisfy { $0 == 0.9 })
        #expect(output.map(abs).max() == 0.9)
    }

    @Test("identical sine paths add no gain or distortion")
    func identicalSinePaths() {
        let transition = EffectTransition(
            sampleRate: sampleRate, oldLatencyFrames: 0,
            newLatencyFrames: 0)
        let source = (0..<transition.fadeFrames).map {
            0.9
                * Float(
                    sin(
                        2 * Double.pi * 997 * Double($0) / sampleRate
                            + 0.37))
        }
        let output = render(
            transition: transition, old: source, new: source)
        let residualRMS = rms(zip(output, source).map { $0.0 - $0.1 })

        #expect(output == source)
        #expect(output.map(abs).max() == source.map(abs).max())
        #expect(residualRMS == 0)
    }

    @Test(
        "latency-alignment tap fades retain short-window energy",
        arguments: [440.0, 445.3125])
    func latencyAlignmentEnergy(frequency: Double) {
        let latency = 1_024
        let transition = EffectTransition(
            sampleRate: sampleRate, oldLatencyFrames: 0,
            newLatencyFrames: latency)
        let count = latency + transition.fadeFrames + 256
        let old = (0..<count).map {
            0.4
                * Float(
                    sin(
                        2 * Double.pi * frequency * Double($0) / sampleRate
                            + 0.37))
        }
        let new = (0..<count).map {
            $0 < latency
                ? 0
                : 0.4
                    * Float(
                        sin(
                            2 * Double.pi * frequency * Double($0 - latency)
                                / sampleRate + 0.37))
        }
        let output = render(transition: transition, old: old, new: new)
        let fadeStart = transition.warmupFrames
        let fadeEnd = fadeStart + transition.fadeFrames
        let fade = output[fadeStart..<fadeEnd]
        let minimum = minimumWindowRMS(Array(fade), frames: 96)
        let reference = 0.4 / sqrt(2.0)
        let attenuationDB = 20 * log10(minimum / reference)

        print(
            "\(frequency) Hz, 1024-frame tap fade: "
                + "minimum 96-frame RMS \(attenuationDB) dB relative, "
                + "splice \(transition.spliceFrame ?? -1)")
        // Every continuous dual-tap fade passes through equal gains, where a
        // half-cycle offset cancels exactly. The latency-changing path therefore
        // has to splice rather than pretending a different gain curve can mix
        // two points in time without a notch.
        #expect(
            attenuationDB >= -3,
            "alignment window lost \(attenuationDB) dB at \(frequency) Hz")
        #expect(
            maximumStep(output) <= maximumStep(old) * 1.1,
            "splice exceeded the source's natural step at \(frequency) Hz")
        #expect(transition.spliceFrame != nil)
        #expect(
            (transition.spliceFrame ?? .max)
                <= transition.warmupFrames + transition.fadeFrames - 1)
    }

    @Test("latency-changing splices do not depend on callback size")
    func latencySpliceIsPartitionInvariant() {
        let latency = 1_024
        let count = latency + 960 + 256
        let old = (0..<count).map {
            0.4
                * Float(
                    sin(
                        2 * Double.pi * 445.3125 * Double($0) / sampleRate
                            + 0.37))
        }
        let new = (0..<count).map {
            $0 < latency
                ? 0
                : 0.4
                    * Float(
                        sin(
                            2 * Double.pi * 445.3125 * Double($0 - latency)
                                / sampleRate + 0.37))
        }
        let partitions = [
            [count],
            [64],
            [128],
            [256],
            [64, 192, 128, 384, 256],
        ]
        var referenceOutput: [Float]?
        var referenceSplice: Int?

        for callbacks in partitions {
            let transition = EffectTransition(
                sampleRate: sampleRate, oldLatencyFrames: 0,
                newLatencyFrames: latency)
            let output = render(
                transition: transition, old: old, new: new,
                callbacks: callbacks)
            if let referenceOutput {
                #expect(output == referenceOutput)
                #expect(transition.spliceFrame == referenceSplice)
            } else {
                referenceOutput = output
                referenceSplice = transition.spliceFrame
            }
            #expect(transition.isComplete)
        }
    }

    @Test("processed and bypass paths splice on one absolute frame")
    func processedAndBypassSpliceTogether() {
        let latency = 1_024
        let transition = EffectTransition(
            sampleRate: sampleRate, oldLatencyFrames: 0,
            newLatencyFrames: latency)
        let count = latency + transition.fadeFrames + 64
        let old = (0..<count).map {
            0.4
                * Float(
                    sin(
                        2 * Double.pi * 445.3125 * Double($0) / sampleRate
                            + 0.37))
        }
        let new = (0..<count).map {
            $0 < latency
                ? 0
                : 0.4
                    * Float(
                        sin(
                            2 * Double.pi * 445.3125 * Double($0 - latency)
                                / sampleRate + 0.37))
        }
        let processed = render(
            transition: transition, old: old, new: new,
            callbacks: [64, 192, 128, 384, 256])
        let splice = transition.spliceFrame
        let bypass = (0..<count).map {
            transition.sample(old: 0.25, new: -0.4, at: $0)
        }

        #expect(splice != nil)
        guard let frame = splice else { return }
        #expect(bypass[..<frame].allSatisfy { $0 == 0.25 })
        #expect(bypass[frame...].allSatisfy { $0 == -0.4 })
        #expect(processed[frame] == new[frame])
        #expect(frame == bypass.firstIndex(of: -0.4))
    }

    @Test("a missing splice falls back and completes by the same deadline")
    func latencySpliceDeadline() {
        let latency = 1_024
        let transition = EffectTransition(
            sampleRate: sampleRate, oldLatencyFrames: 0,
            newLatencyFrames: latency)
        let deadline =
            transition.warmupFrames + transition.fadeFrames
        let old = [Float](repeating: 0.25, count: deadline + 64)
        let new = [Float](repeating: -0.25, count: deadline + 64)
        let output = render(
            transition: transition, old: old, new: new,
            callbacks: [64, 192, 128, 384, 256])

        #expect(transition.spliceFrame == nil)
        #expect(transition.isComplete)
        #expect(output[deadline - 1] == -0.25)
        #expect(output[deadline...].allSatisfy { $0 == -0.25 })
        #expect(
            maximumStep(output) <= 0.25 / 100,
            "fallback step \(maximumStep(output))")
        for frame in 0..<output.count {
            #expect(
                transition.sample(old: 0.25, new: -0.25, at: frame)
                    == output[frame])
        }
    }

    private struct Paths {
        let old: [Float]
        let new: [Float]
        let naturalStep: Float
        let referenceRMS: Double
        let maximumMagnitude: Float
    }

    private struct Result {
        let silentPrefix: Int
        let maximumStep: Float
        let fadeRMS: Double
        let maximumMagnitude: Float
        let warmupFrames: Int
    }

    private func makePaths(oldLatency: Int, newLatency: Int) -> Paths {
        let source = (0..<(startFrame + frames)).map {
            0.4
                * Float(
                    sin(
                        2 * Double.pi * 997 * Double($0) / sampleRate
                            + 0.37))
        }
        let old = (0..<frames).map {
            source[startFrame + $0 - oldLatency]
        }
        let new = (0..<frames).map {
            $0 < newLatency ? 0 : source[startFrame + $0 - newLatency]
        }
        return Paths(
            old: old, new: new,
            naturalStep: maximumStep(Array(source[startFrame...])),
            referenceRMS: rms(Array(source[startFrame...])),
            maximumMagnitude: source.map(abs).max() ?? 0)
    }

    private func run(
        old: [Float], new: [Float],
        oldLatency: Int, newLatency: Int
    ) -> Result {
        let transition = EffectTransition(
            sampleRate: sampleRate, oldLatencyFrames: oldLatency,
            newLatencyFrames: newLatency)
        var output = [Float](repeating: 0, count: old.count)
        let callbacks = [64, 192, 128, 384, 256]
        let outputCount = output.count
        var start = 0
        var callback = 0
        old.withUnsafeBufferPointer { oldBuffer in
            new.withUnsafeBufferPointer { newBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    while start < outputCount {
                        let frames = min(
                            callbacks[callback % callbacks.count],
                            outputCount - start)
                        transition.process(
                            old: oldBuffer.baseAddress! + start,
                            new: newBuffer.baseAddress! + start,
                            output: outputBuffer.baseAddress! + start,
                            frames: frames)
                        start += frames
                        callback += 1
                    }
                }
            }
        }

        let fadeStart = transition.warmupFrames
        let fadeEnd = fadeStart + transition.fadeFrames
        return Result(
            silentPrefix: output.prefix { abs($0) < 1e-7 }.count,
            maximumStep: maximumStep(output),
            fadeRMS: rms(Array(output[fadeStart..<fadeEnd])),
            maximumMagnitude: output.map(abs).max() ?? 0,
            warmupFrames: transition.warmupFrames)
    }

    private func render(
        transition: EffectTransition, old: [Float], new: [Float],
        callbacks: [Int] = [.max]
    ) -> [Float] {
        var output = [Float](repeating: 0, count: old.count)
        var start = 0
        var callback = 0
        old.withUnsafeBufferPointer { oldBuffer in
            new.withUnsafeBufferPointer { newBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    while start < outputBuffer.count {
                        let frames = min(
                            callbacks[callback % callbacks.count],
                            outputBuffer.count - start)
                        transition.process(
                            old: oldBuffer.baseAddress! + start,
                            new: newBuffer.baseAddress! + start,
                            output: outputBuffer.baseAddress! + start,
                            frames: frames)
                        start += frames
                        callback += 1
                    }
                }
            }
        }
        return output
    }

    private func maximumStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).reduce(0) {
            max($0, abs($1.1 - $1.0))
        }
    }

    private func rms(_ samples: [Float]) -> Double {
        sqrt(
            samples.reduce(0) { $0 + Double($1 * $1) }
                / Double(samples.count))
    }

    private func minimumWindowRMS(_ samples: [Float], frames: Int) -> Double {
        guard frames > 0, frames <= samples.count else { return 0 }
        var energy = samples.prefix(frames).reduce(0.0) {
            $0 + Double($1 * $1)
        }
        var minimum = energy
        if samples.count > frames {
            for end in frames..<samples.count {
                energy += Double(samples[end] * samples[end])
                energy -= Double(samples[end - frames] * samples[end - frames])
                minimum = min(minimum, energy)
            }
        }
        return sqrt(max(0, minimum) / Double(frames))
    }
}

/// The primitive is called from the IO thread once it is wired into the graph.
/// Its curves and storage therefore have to be paid for at construction, never
/// during the handover itself.
@Suite("Effect transition realtime", .serialized)
struct EffectTransitionPerformanceTests {
    #if DEBUG
        @Test(
            "a complete handover allocates nothing",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("a complete handover allocates nothing")
    #endif
    func noRealtimeAllocations() {
        let frames = 8_192
        let source = (0..<frames).map {
            0.4
                * Float(
                    sin(
                        2 * Double.pi * 997 * Double($0) / 48_000
                            + 0.37))
        }
        let delayed = (0..<frames).map {
            $0 < 1_024 ? 0 : source[$0 - 1_024]
        }
        var output = [Float](repeating: 0, count: frames)
        let transition = EffectTransition(
            sampleRate: 48_000, oldLatencyFrames: 0,
            newLatencyFrames: 1_024)

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        let before = RoutingEngine.allocationViolations
        source.withUnsafeBufferPointer { oldBuffer in
            delayed.withUnsafeBufferPointer { newBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    yun_rt_tripwire_mark_realtime(true)
                    var start = 0
                    while start < frames {
                        let count = min(128, frames - start)
                        transition.process(
                            old: oldBuffer.baseAddress! + start,
                            new: newBuffer.baseAddress! + start,
                            output: outputBuffer.baseAddress! + start,
                            frames: count)
                        start += count
                    }
                    yun_rt_tripwire_mark_realtime(false)
                }
            }
        }
        let allocations = RoutingEngine.allocationViolations - before
        RoutingEngine.disableAllocationTripwire()

        #expect(transition.isComplete)
        #expect(output.contains { abs($0) > 0.1 })
        #expect(allocations == 0, "transition allocated \(allocations) times")
    }

    #if !DEBUG
        @Test("a latency-changing handover stays inside its realtime budget")
        func latencyMismatchCost() {
            let frames = 2_048
            let iterations = 4_000
            let source = (0..<frames).map {
                0.4
                    * Float(
                        sin(
                            2 * Double.pi * 445.3125 * Double($0) / 48_000
                                + 0.37))
            }
            let delayed = (0..<frames).map {
                $0 < 1_024 ? 0 : source[$0 - 1_024]
            }
            var spliceMeasurements: [Double] = []
            var linearMeasurements: [Double] = []
            var checksum: Float = 0
            for round in 0..<5 {
                if round.isMultiple(of: 2) {
                    let splice = measureSplice(
                        source: source, delayed: delayed,
                        iterations: iterations)
                    spliceMeasurements.append(splice.nanosecondsPerFrame)
                    checksum += splice.checksum
                    let linear = measureLinear(
                        source: source, delayed: delayed,
                        iterations: iterations)
                    linearMeasurements.append(linear.nanosecondsPerFrame)
                    checksum += linear.checksum
                } else {
                    let linear = measureLinear(
                        source: source, delayed: delayed,
                        iterations: iterations)
                    linearMeasurements.append(linear.nanosecondsPerFrame)
                    checksum += linear.checksum
                    let splice = measureSplice(
                        source: source, delayed: delayed,
                        iterations: iterations)
                    spliceMeasurements.append(splice.nanosecondsPerFrame)
                    checksum += splice.checksum
                }
            }
            let spliceCost = spliceMeasurements.sorted()[2]
            let linearCost = linearMeasurements.sorted()[2]
            let ratio = spliceCost / linearCost

            print(
                "latency-changing transition: \(spliceCost) ns/frame, "
                    + "linear predecessor \(linearCost) ns/frame, "
                    + "ratio \(ratio), checksum \(checksum)")
            #expect(spliceCost < 20)
            #expect(
                ratio <= 1.1,
                "bounded splice cost \(ratio)x the replaced linear handover")
        }

        private func measureSplice(
            source: [Float], delayed: [Float], iterations: Int
        ) -> (nanosecondsPerFrame: Double, checksum: Float) {
            let frames = source.count
            let transitions = (0..<iterations).map { _ in
                EffectTransition(
                    sampleRate: 48_000, oldLatencyFrames: 0,
                    newLatencyFrames: 1_024)
            }
            var output = [Float](repeating: 0, count: frames)
            var changingDelayed = delayed
            var checksum: Float = 0
            let started = DispatchTime.now().uptimeNanoseconds
            source.withUnsafeBufferPointer { oldBuffer in
                changingDelayed.withUnsafeMutableBufferPointer { newBuffer in
                    output.withUnsafeMutableBufferPointer { outputBuffer in
                        for (iteration, transition) in transitions.enumerated() {
                            newBuffer[frames - 1] =
                                iteration.isMultiple(of: 2) ? 0.125 : -0.125
                            process(
                                transition,
                                old: oldBuffer.baseAddress!,
                                new: newBuffer.baseAddress!,
                                output: outputBuffer.baseAddress!,
                                frames: frames)
                            checksum += outputBuffer[frames - 1]
                        }
                    }
                }
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            return (
                Double(elapsed) / Double(iterations * frames),
                checksum
            )
        }

        private func measureLinear(
            source: [Float], delayed: [Float], iterations: Int
        ) -> (nanosecondsPerFrame: Double, checksum: Float) {
            let frames = source.count
            let transitions = (0..<iterations).map { _ in
                LinearLatencyHandover(
                    sampleRate: 48_000, newLatencyFrames: 1_024)
            }
            var output = [Float](repeating: 0, count: frames)
            var changingDelayed = delayed
            var checksum: Float = 0
            let started = DispatchTime.now().uptimeNanoseconds
            source.withUnsafeBufferPointer { oldBuffer in
                changingDelayed.withUnsafeMutableBufferPointer { newBuffer in
                    output.withUnsafeMutableBufferPointer { outputBuffer in
                        for (iteration, transition) in transitions.enumerated() {
                            newBuffer[frames - 1] =
                                iteration.isMultiple(of: 2) ? 0.125 : -0.125
                            process(
                                transition,
                                old: oldBuffer.baseAddress!,
                                new: newBuffer.baseAddress!,
                                output: outputBuffer.baseAddress!,
                                frames: frames)
                            checksum += outputBuffer[frames - 1]
                        }
                    }
                }
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            return (
                Double(elapsed) / Double(iterations * frames),
                checksum
            )
        }

        @inline(__always)
        private func process(
            _ transition: EffectTransition,
            old: UnsafePointer<Float>, new: UnsafePointer<Float>,
            output: UnsafeMutablePointer<Float>, frames: Int
        ) {
            var start = 0
            while start < frames {
                let count = min(128, frames - start)
                transition.process(
                    old: old + start, new: new + start,
                    output: output + start, frames: count)
                start += count
            }
        }

        @inline(__always)
        private func process(
            _ transition: LinearLatencyHandover,
            old: UnsafePointer<Float>, new: UnsafePointer<Float>,
            output: UnsafeMutablePointer<Float>, frames: Int
        ) {
            var start = 0
            while start < frames {
                let count = min(128, frames - start)
                transition.process(
                    old: old + start, new: new + start,
                    output: output + start, frames: count)
                start += count
            }
        }
    #endif
}
