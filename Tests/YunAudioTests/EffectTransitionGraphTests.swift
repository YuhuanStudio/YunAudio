import AudioToolbox
import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

/// A synthetic graph with the same unmanaged ownership shape as a live swap.
///
/// No audio device is opened. The real IOProc is driven against one mono input
/// and output buffer, with raw audio as the old path and a cold formant chain
/// as the new one.
private final class EffectTransitionGraphHarness {
    struct Rendered {
        let processed: [Float]
        let bypass: [Float]
    }

    let controller: EffectTransition

    private let chain: EffectChain
    private let counter: UnsafeMutablePointer<UInt64>
    private let stage: UnsafeMutablePointer<RTVoiceIsolation>
    private let handover: UnsafeMutablePointer<RTEffectTransition>
    private let initialGraph: UnsafeMutablePointer<RTGraph>
    private var transitionGraph: UnsafeMutablePointer<RTGraph>?
    private let cell: OpaquePointer
    private let inputList: UnsafeMutableAudioBufferListPointer
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let input: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>
    private let blockFrames = 128

    init?() {
        guard
            let chain = EffectChain(
                kinds: [.formant], sampleRate: 48_000,
                maximumFrames: blockFrames)
        else { return nil }
        self.chain = chain

        counter = .allocate(capacity: 1)
        counter.initialize(to: 0)
        stage = .allocate(capacity: 1)
        stage.initialize(
            to: RTVoiceIsolation(
                enabled: 1,
                sourceBuffer: 0,
                sourceChannel: 0,
                sourceIsCancelled: 0,
                unit: Unmanaged.passUnretained(chain).toOpaque(),
                inputBuffer: chain.inputBuffer,
                outputBuffer: chain.outputBuffer,
                maximumFrames: Int32(blockFrames),
                renderFailures: counter))

        controller = EffectTransition(
            sampleRate: 48_000, oldLatencyFrames: 0,
            newLatencyFrames: chain.latencyFrames)
        handover = RTEffectTransition.allocate(
            sourceBuffer: 0, sourceChannel: 0, sourceIsCancelled: false,
            oldStage: nil, oldIsChain: false,
            newStage: stage, newIsChain: true,
            controller: controller, maximumFrames: blockFrames,
            oldAlignmentFrames: 0,
            newAlignmentFrames: chain.latencyFrames)

        initialGraph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    usesIsolatedSource: true),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 1),
            ], bufferFrames: blockFrames, sampleRate: 48_000)
        guard let cell = yun_rt_cell_create(UnsafeMutableRawPointer(initialGraph)) else {
            RTGraph.deallocate(initialGraph)
            RTEffectTransition.deallocate(handover)
            stage.deinitialize(count: 1)
            stage.deallocate()
            counter.deinitialize(count: 1)
            counter.deallocate()
            return nil
        }
        self.cell = cell

        input = .allocate(capacity: blockFrames * 2)
        input.initialize(repeating: 0, count: blockFrames * 2)
        output = .allocate(capacity: blockFrames * 2)
        output.initialize(repeating: 0, count: blockFrames * 2)
        inputList = AudioBufferList.allocate(maximumBuffers: 1)
        inputList[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(blockFrames * 2 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(input))
        outputList = AudioBufferList.allocate(maximumBuffers: 1)
        outputList[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(blockFrames * 2 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(output))
    }

    deinit {
        yun_rt_cell_free(cell)
        if let transitionGraph { RTGraph.deallocate(transitionGraph) }
        RTGraph.deallocate(initialGraph)
        RTEffectTransition.deallocate(handover)
        stage.deinitialize(count: 1)
        stage.deallocate()
        counter.deinitialize(count: 1)
        counter.deallocate()
        input.deinitialize(count: blockFrames * 2)
        input.deallocate()
        output.deinitialize(count: blockFrames * 2)
        output.deallocate()
        free(inputList.unsafeMutablePointer)
        free(outputList.unsafeMutablePointer)
        withExtendedLifetime(chain) {}
    }

    @discardableResult
    func beginTransition() -> Bool {
        guard transitionGraph == nil else { return false }
        let next = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    usesIsolatedSource: true),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 1),
            ], bufferFrames: blockFrames, sampleRate: 48_000)
        next.pointee.voiceIsolation = stage
        next.pointee.isolationIsChain = 1
        next.pointee.effectTransition = handover
        next.pointee.alignmentFrames = Int32(chain.latencyFrames)
        var carriedEveryRoute = true
        for slot in 0..<Int(next.pointee.routeCount) {
            carriedEveryRoute =
                RTGraph.carryAlignment(
                    from: initialGraph, slot: slot,
                    to: next, slot: slot)
                && carriedEveryRoute
        }
        let retired = yun_rt_cell_publish(cell, UnsafeMutableRawPointer(next))
        transitionGraph = next
        return carriedEveryRoute && retired == UnsafeMutableRawPointer(initialGraph)
    }

    func render(_ source: [Float]) -> Rendered {
        var processed = [Float](repeating: 0, count: source.count)
        var bypass = [Float](repeating: 0, count: source.count)
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        time.mFlags = .sampleTimeValid

        source.withUnsafeBufferPointer { sourceBuffer in
            processed.withUnsafeMutableBufferPointer { processedBuffer in
                bypass.withUnsafeMutableBufferPointer { bypassBuffer in
                    var start = 0
                    while start < source.count {
                        let frames = min(blockFrames, source.count - start)
                        for frame in 0..<frames {
                            let sample = sourceBuffer[start + frame]
                            input[frame * 2] = sample
                            input[frame * 2 + 1] = sample
                        }
                        inputList[0].mDataByteSize =
                            UInt32(frames * 2 * MemoryLayout<Float>.size)
                        outputList[0].mDataByteSize =
                            UInt32(frames * 2 * MemoryLayout<Float>.size)
                        time.mSampleTime = Float64(start)
                        _ = yunAudioIOProc(
                            0, &now, UnsafePointer(inputList.unsafeMutablePointer),
                            &time, outputList.unsafeMutablePointer, &time,
                            UnsafeMutableRawPointer(cell))
                        for frame in 0..<frames {
                            processedBuffer[start + frame] = output[frame * 2]
                            bypassBuffer[start + frame] = output[frame * 2 + 1]
                        }
                        start += frames
                    }
                }
            }
        }
        return Rendered(processed: processed, bypass: bypass)
    }
}

@Suite("Effect transition graph")
struct EffectTransitionGraphTests {
    @Test("a cold stage is warmed and crossed inside the real IOProc")
    func coldStage() throws {
        let harness = try #require(EffectTransitionGraphHarness())
        let before = sine(startFrame: 0, frames: 4_096)
        let beforeOutput = harness.render(before)
        #expect(harness.beginTransition())
        let after = sine(startFrame: before.count, frames: 16_384)
        let afterOutput = harness.render(after)
        let source = before + after
        let naturalStep = maximumStep(source)
        let processed =
            Array(beforeOutput.processed.suffix(128)) + afterOutput.processed
        let bypass =
            Array(beforeOutput.bypass.suffix(128)) + afterOutput.bypass

        #expect(longestSilence(in: afterOutput.processed) == 0)
        #expect(longestSilence(in: afterOutput.bypass) == 0)
        #expect(
            maximumStep(processed) <= naturalStep * 1.1,
            "processed path stepped \(maximumStep(processed)); natural \(naturalStep)")
        #expect(
            maximumStep(bypass) <= naturalStep * 1.1,
            "bypass path stepped \(maximumStep(bypass)); natural \(naturalStep)")
        let alignmentError =
            zip(
                afterOutput.processed, afterOutput.bypass
            ).map {
                abs($0 - $1)
            }.max() ?? 0
        #expect(alignmentError < 1e-6, "paths differed by \(alignmentError)")
        #expect(harness.controller.isComplete)
    }

    @Test("correlated paths do not create a gain bump")
    func correlatedPathsStayAtUnity() {
        let controller = EffectTransition(
            sampleRate: 48_000, oldLatencyFrames: 0,
            newLatencyFrames: 0)
        let old = [Float](repeating: 0.9, count: controller.fadeFrames)
        let new = old
        var output = old
        old.withUnsafeBufferPointer { oldBuffer in
            new.withUnsafeBufferPointer { newBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    controller.process(
                        old: oldBuffer.baseAddress!,
                        new: newBuffer.baseAddress!,
                        output: outputBuffer.baseAddress!,
                        frames: outputBuffer.count)
                }
            }
        }
        #expect(output.map(abs).max() == 0.9)
        #expect(output.allSatisfy { $0 == 0.9 })
    }

    private func sine(startFrame: Int, frames: Int) -> [Float] {
        (startFrame..<(startFrame + frames)).map {
            0.4
                * Float(
                    sin(
                        2 * Double.pi * 997 * Double($0) / 48_000
                            + 0.37))
        }
    }

    private func maximumStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).reduce(0) {
            max($0, abs($1.1 - $1.0))
        }
    }

    private func longestSilence(in samples: [Float]) -> Int {
        var longest = 0
        var current = 0
        for sample in samples {
            if abs(sample) < 1e-7 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}

@Suite("Effect transition graph realtime", .serialized)
struct EffectTransitionGraphPerformanceTests {
    #if DEBUG
        @Test(
            "the graph handover allocates nothing",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("the graph handover allocates nothing")
    #endif
    func noRealtimeAllocations() throws {
        let harness = try #require(EffectTransitionGraphHarness())
        let beforeSamples = (0..<4_096).map {
            0.4
                * Float(
                    sin(
                        2 * Double.pi * 997 * Double($0) / 48_000
                            + 0.37))
        }
        _ = harness.render(beforeSamples)
        #expect(harness.beginTransition())
        let source = (4_096..<12_288).map {
            0.4
                * Float(
                    sin(
                        2 * Double.pi * 997 * Double($0) / 48_000
                            + 0.37))
        }

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        let allocationBaseline = RoutingEngine.allocationViolations
        let output = harness.render(source)
        let allocations =
            RoutingEngine.allocationViolations - allocationBaseline
        RoutingEngine.disableAllocationTripwire()

        #expect(output.processed.contains { abs($0) > 0.1 })
        #expect(output.bypass.contains { abs($0) > 0.1 })
        #expect(allocations == 0, "graph transition allocated \(allocations) times")
    }
}
