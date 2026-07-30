import AudioToolbox
import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

private final class NumericalSafetyBus {
    let list: UnsafeMutableAudioBufferListPointer
    let storage: [UnsafeMutablePointer<Float>]
    let frames: Int

    init(channelCounts: [Int], frames: Int) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
        var allocated: [UnsafeMutablePointer<Float>] = []
        for (buffer, channels) in channelCounts.enumerated() {
            let pointer = UnsafeMutablePointer<Float>.allocate(
                capacity: frames * channels)
            pointer.initialize(repeating: 0, count: frames * channels)
            allocated.append(pointer)
            list[buffer] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(
                    frames * channels * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer))
        }
        storage = allocated
    }

    func set(_ buffer: Int, _ channel: Int, _ frame: Int, to value: Float) {
        let stride = Int(list[buffer].mNumberChannels)
        storage[buffer][frame * stride + channel] = value
    }

    func sample(_ buffer: Int, _ channel: Int, _ frame: Int) -> Float {
        let stride = Int(list[buffer].mNumberChannels)
        return storage[buffer][frame * stride + channel]
    }

    deinit {
        for pointer in storage { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

@Suite("Realtime mixer numerical safety")
struct MixerNumericalSafetyTests {
    @Test("a non-finite output correction is refused before realtime")
    func invalidCorrectionIsNotPublished() {
        let frames = 8
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0)
            ], bufferFrames: frames)
        defer { RTGraph.deallocate(graph) }

        #expect(
            !RTGraph.installCorrection(
                [1, 0, .nan, 0, 0], preampGain: 1, onBuffer: 0, of: graph))
        #expect(graph.pointee.eqStages[0] == 0)

        let input = NumericalSafetyBus(channelCounts: [1], frames: frames)
        let output = NumericalSafetyBus(channelCounts: [1], frames: frames)
        for frame in 0..<frames {
            input.set(0, 0, frame, to: 0.25)
        }
        cycle(graph: graph, input: input, output: output)

        for frame in 0..<frames {
            #expect(output.sample(0, 0, frame) == 0.25)
        }
        #expect(graph.pointee.outputPeak == 0.25)
        #expect(graph.pointee.outputClipped == 0)
    }

    @Test("invalid routes cannot poison a healthy stereo pair")
    func invalidRouteIsContained() {
        let frames = 8
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 1,
                    gain: -1),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 1),
            ], bufferFrames: frames)
        defer { RTGraph.deallocate(graph) }

        let input = NumericalSafetyBus(channelCounts: [2], frames: frames)
        let output = NumericalSafetyBus(channelCounts: [2], frames: frames)
        let invalid: [Float] = [
            .nan, .infinity, -.infinity, .leastNonzeroMagnitude,
            -.leastNonzeroMagnitude, .nan, .infinity, -.infinity,
        ]
        for frame in 0..<frames {
            input.set(0, 0, frame, to: 0.25)
            input.set(0, 1, frame, to: invalid[frame])
        }

        cycle(graph: graph, input: input, output: output)

        for frame in 0..<frames {
            let left = output.sample(0, 0, frame)
            let right = output.sample(0, 1, frame)
            #expect(left == 0.25)
            #expect(right == -0.25)
            #expect(left + right == 0)
            #expect(left.isFinite && right.isFinite)
        }
        #expect(graph.pointee.peaks[1] == 0)
        #expect(graph.pointee.rms[1] == 0)
        #expect(graph.pointee.peaks[3] == 0)
        #expect(graph.pointee.rms[3] == 0)
        #expect(graph.pointee.outputPeak == 0.25)
        #expect(graph.pointee.outputClipped == 0)
    }

    @Test("invalid live gains leave the last complete mixer state in force")
    func invalidCommandsAreRejected() throws {
        let frames = 8
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    appliesInputTrim: true),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 1, destinationChannel: 0,
                    appliesInputTrim: true),
            ], bufferFrames: frames)
        defer { RTGraph.deallocate(graph) }
        graph.pointee.mainOutputBuffer = 1
        graph.pointee.masterExemptBuffer = 0
        graph.pointee.outputGain = 0.5
        let commands = try #require(graph.pointee.commands)
        #expect(
            yun_rt_queue_push(
                commands,
                YunRTCommand(
                    kind: Int32(kYunRTCommandSetInputGain.rawValue),
                    index: 0, value: -.infinity)))
        #expect(
            yun_rt_queue_push(
                commands,
                YunRTCommand(
                    kind: Int32(kYunRTCommandSetOutputGain.rawValue),
                    index: 0, value: .nan)))
        #expect(
            yun_rt_queue_push(
                commands,
                YunRTCommand(
                    kind: Int32(kYunRTCommandSetGain.rawValue),
                    index: 1, value: .infinity)))

        let input = NumericalSafetyBus(channelCounts: [1], frames: frames)
        let output = NumericalSafetyBus(channelCounts: [1, 1], frames: frames)
        for frame in 0..<frames {
            input.set(0, 0, frame, to: 0.25)
        }
        cycle(graph: graph, input: input, output: output)

        for frame in 0..<frames {
            #expect(output.sample(0, 0, frame) == 0.25)
            #expect(output.sample(1, 0, frame) == 0.125)
        }
        #expect(graph.pointee.inputGain == 1)
        #expect(graph.pointee.outputGain == 0.5)
        #expect(graph.pointee.routes[1].gain == 1)
    }

    @Test("an invalid transition path never turns into a full-scale click")
    func invalidTransitionPathIsSilent() {
        let transition = EffectTransition(
            sampleRate: 48_000, oldLatencyFrames: 0,
            newLatencyFrames: 0)
        let old = [Float](repeating: 0.25, count: transition.fadeFrames)
        let new = [Float](repeating: .nan, count: transition.fadeFrames)
        var output = [Float](repeating: 0, count: transition.fadeFrames)
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

        #expect(output.allSatisfy { $0.isFinite })
        #expect((output.map(abs).max() ?? 1) <= 0.25)
        #expect(output.first == 0.25)
        #expect(output.last == 0)
        let bypass = transition.sample(
            old: 0.25, new: .nan,
            at: transition.fadeFrames / 2)
        #expect(bypass.isFinite)
        #expect(abs(bypass) <= 0.25)
    }

    private func cycle(
        graph: UnsafeMutablePointer<RTGraph>,
        input: NumericalSafetyBus, output: NumericalSafetyBus
    ) {
        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        _ = yunAudioIOProc(
            0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
            output.list.unsafeMutablePointer, &time,
            UnsafeMutableRawPointer(cell))
    }
}
