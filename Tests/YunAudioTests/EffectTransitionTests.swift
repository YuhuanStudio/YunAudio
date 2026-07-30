import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

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
            result.fadeRMS <= paths.referenceRMS,
            "fade RMS \(result.fadeRMS), reference \(paths.referenceRMS)")
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
            result.fadeRMS <= paths.referenceRMS,
            "fade RMS \(result.fadeRMS), reference \(paths.referenceRMS)")
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
            result.fadeRMS <= paths.referenceRMS,
            "fade RMS \(result.fadeRMS), reference \(paths.referenceRMS)")
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

    private struct Paths {
        let old: [Float]
        let new: [Float]
        let naturalStep: Float
        let referenceRMS: Double
    }

    private struct Result {
        let silentPrefix: Int
        let maximumStep: Float
        let fadeRMS: Double
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
            referenceRMS: rms(Array(source[startFrame...])))
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
            warmupFrames: transition.warmupFrames)
    }

    private func render(
        transition: EffectTransition, old: [Float], new: [Float]
    ) -> [Float] {
        var output = [Float](repeating: 0, count: old.count)
        old.withUnsafeBufferPointer { oldBuffer in
            new.withUnsafeBufferPointer { newBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    transition.process(
                        old: oldBuffer.baseAddress!,
                        new: newBuffer.baseAddress!,
                        output: outputBuffer.baseAddress!,
                        frames: outputBuffer.count)
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
}
