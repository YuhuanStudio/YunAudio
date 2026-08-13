import AudioToolbox
import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

private final class GainIntegrationBus {
    let list: UnsafeMutableAudioBufferListPointer
    private let storage: [UnsafeMutablePointer<Float>]
    let frames: Int

    init(channelCounts: [Int], frames: Int) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
        var pointers: [UnsafeMutablePointer<Float>] = []
        for (index, channels) in channelCounts.enumerated() {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
            pointer.initialize(repeating: 0, count: frames * channels)
            pointers.append(pointer)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer))
        }
        storage = pointers
    }

    func fill(_ buffer: Int, channel: Int, with value: Float) {
        let channels = Int(list[buffer].mNumberChannels)
        for frame in 0..<frames {
            storage[buffer][frame * channels + channel] = value
        }
    }

    func samples(_ buffer: Int, channel: Int) -> [Float] {
        let channels = Int(list[buffer].mNumberChannels)
        return (0..<frames).map { storage[buffer][$0 * channels + channel] }
    }

    deinit {
        for pointer in storage { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

@Suite("Realtime gain envelopes")
struct RTGainIntegrationTests {
    private func graph(
        routes: [RTRoute]? = nil, bufferFrames: Int = 512
    ) -> UnsafeMutablePointer<RTGraph> {
        RTGraph.allocate(
            routes: routes ?? [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    appliesInputTrim: true)
            ],
            bufferFrames: bufferFrames, sampleRate: 48_000)
    }

    private func cycle(
        _ graph: UnsafeMutablePointer<RTGraph>, frames: Int,
        inputChannels: Int = 1, outputChannels: Int = 1,
        inputValues: [Float] = [1]
    ) -> [[Float]] {
        let input = GainIntegrationBus(channelCounts: [inputChannels], frames: frames)
        for channel in 0..<min(inputChannels, inputValues.count) {
            input.fill(0, channel: channel, with: inputValues[channel])
        }
        let output = GainIntegrationBus(channelCounts: [outputChannels], frames: frames)
        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        _ = yunAudioIOProc(
            0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
            output.list.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))
        return (0..<outputChannels).map { output.samples(0, channel: $0) }
    }

    private func render(
        _ graph: UnsafeMutablePointer<RTGraph>, totalFrames: Int,
        blocks: [Int], inputChannels: Int = 1, outputChannels: Int = 1,
        inputValues: [Float] = [1]
    ) -> [[Float]] {
        var result = Array(repeating: [Float](), count: outputChannels)
        var rendered = 0
        var block = 0
        while rendered < totalFrames {
            let frames = min(blocks[block % blocks.count], totalFrames - rendered)
            let next = cycle(
                graph, frames: frames, inputChannels: inputChannels,
                outputChannels: outputChannels, inputValues: inputValues)
            for channel in 0..<outputChannels {
                result[channel].append(contentsOf: next[channel])
            }
            rendered += frames
            block += 1
        }
        return result
    }

    private func push(
        _ graph: UnsafeMutablePointer<RTGraph>, _ kind: YunRTCommandKind,
        index: Int = 0, value: Float
    ) {
        let commands = graph.pointee.commands!
        #expect(
            yun_rt_queue_push(
                commands,
                YunRTCommand(kind: Int32(kind.rawValue), index: Int32(index), value: value)))
    }

    @Test("a fresh graph starts on its stored gain and mute")
    func freshGraphFirstSample() {
        let graph = graph()
        defer { RTGraph.deallocate(graph) }
        graph.pointee.routes[0].gain = 0.5
        graph.pointee.inputGain = 0.25
        graph.pointee.outputGain = 0.4

        let audible = cycle(graph, frames: 8)[0]
        #expect(audible.allSatisfy { abs($0 - 0.05) < 0.000_001 })
        #expect(graph.pointee.routeGainSlews[0].current == 0.5)
        #expect(graph.pointee.inputGainSlew.current == 0.25)
        #expect(graph.pointee.outputGainSlew.current == 0.4)

        let muted = self.graph()
        defer { RTGraph.deallocate(muted) }
        muted.pointee.inputMuted = 1
        #expect(cycle(muted, frames: 8)[0].allSatisfy { $0 == 0 })
        #expect(muted.pointee.inputGainSlew.current == 0)
    }

    @Test("a final microphone mute survives a full legacy command queue")
    func finalMuteCannotBeDropped() throws {
        let graph = graph()
        defer { RTGraph.deallocate(graph) }
        let queue = try #require(graph.pointee.commands)
        while yun_rt_queue_push(
            queue,
            YunRTCommand(
                kind: Int32(kYunRTCommandSetInputMute.rawValue), index: 0, value: 0))
        {}

        let mailbox = try #require(graph.pointee.controlMailbox)
        #expect(
            yun_rt_control_mailbox_publish(
                mailbox,
                YunRTCommand(
                    kind: Int32(kYunRTCommandSetInputMute.rawValue), index: 0, value: 1)))
        let output = cycle(graph, frames: 128)[0]

        #expect(graph.pointee.inputMuted == 1)
        #expect(output.allSatisfy { $0 == 0 })
        #expect(
            yun_rt_control_mailbox_desired_generation(mailbox)
                == yun_rt_control_mailbox_applied_generation(mailbox))
    }

    @Test("every global mailbox control applies on one callback boundary")
    func globalMailboxControlsAreCompleteAndCoalesced() throws {
        let graph = graph()
        let recording = try #require(yun_rt_ring_create(4_096))
        defer {
            RTGraph.deallocate(graph)
            yun_rt_ring_free(recording)
        }
        graph.pointee.recordRing = recording
        graph.pointee.recordChannels = 1
        graph.pointee.outputClipped = 17
        let mailbox = try #require(graph.pointee.controlMailbox)

        func publish(_ kind: YunRTCommandKind, _ value: Float) {
            #expect(
                yun_rt_control_mailbox_publish(
                    mailbox,
                    YunRTCommand(
                        kind: Int32(kind.rawValue), index: 0, value: value)))
        }
        publish(kYunRTCommandSetDuckingEnabled, 1)
        publish(kYunRTCommandSetDuckingDepth, 0.8)
        publish(kYunRTCommandSetDuckingDepth, 0.25)
        publish(kYunRTCommandSetDuckingAllowed, 1)
        publish(kYunRTCommandSetAnalysisEnabled, 1)
        publish(kYunRTCommandSetRecordingPaused, 1)
        publish(kYunRTCommandSetCalibrating, Float(bitPattern: 7))
        publish(kYunRTCommandClearOutputClipping, Float(bitPattern: 9))

        _ = cycle(graph, frames: 128, inputValues: [0])

        #expect(graph.pointee.duckEnabled == 1)
        #expect(graph.pointee.duckDepth == 0.25)
        #expect(graph.pointee.duckAllowed == 1)
        #expect(graph.pointee.analysisEnabled == 1)
        #expect(graph.pointee.recordPaused == 1)
        #expect(graph.pointee.calibrating == 1)
        #expect(graph.pointee.calibrationEpoch == 7)
        #expect(graph.pointee.calibrationEnergy[0] == 0)
        #expect(graph.pointee.calibrationFrames[0] == 0)
        #expect(graph.pointee.outputClipped == 0)
        #expect(graph.pointee.outputClippingEpoch == 9)
        #expect(yun_rt_ring_written(recording) == 0)
        let analysis = try #require(graph.pointee.analysisRing)
        #expect(yun_rt_ring_written(analysis) == 128)
        #expect(
            yun_rt_control_mailbox_desired_generation(mailbox)
                == yun_rt_control_mailbox_applied_generation(mailbox))

        publish(kYunRTCommandSetRecordingPaused, 0)
        publish(kYunRTCommandSetCalibrating, 0)
        _ = cycle(graph, frames: 64, inputValues: [0.5])
        #expect(graph.pointee.recordPaused == 0)
        #expect(graph.pointee.calibrating == 0)
        #expect(yun_rt_ring_written(recording) == 64)
    }

    @Test("persisted mix state synchronises its first audible sample")
    func persistedMixStateSynchronisesSlews() {
        let graph = graph()
        defer { RTGraph.deallocate(graph) }
        RoutingEngine.initialisePersistedMixState(
            inputGain: 0.3, inputMuted: true,
            outputGain: 0.6, outputMuted: false,
            on: graph)

        #expect(graph.pointee.inputGainSlew == RTGainSlew(0))
        #expect(graph.pointee.outputGainSlew == RTGainSlew(0.6))
        #expect(cycle(graph, frames: 8)[0].allSatisfy { $0 == 0 })
    }

    @Test("a command queued after publication still ramps on the first callback")
    func firstLiveCommandAfterSynchronisationRamps() {
        let graph = graph()
        defer { RTGraph.deallocate(graph) }
        RTGraph.synchroniseGainSlews(on: graph)
        #expect(graph.pointee.hasRendered == 1)

        push(graph, kYunRTCommandSetGain, value: 0)
        let samples = render(graph, totalFrames: 480, blocks: [128, 17, 256])[0]
        #expect(samples[0] > 0)
        #expect(samples[0] < 1)
        #expect(samples[478] > 0)
        #expect(samples[479] == 0)
    }

    @Test("callback boundaries cannot change a route fade")
    func routeFadeIsCallbackInvariant() {
        var reference: [Float] = []
        for blocks in [[64], [128], [256], [17, 113, 7, 251]] {
            let graph = graph()
            _ = cycle(graph, frames: 8)
            push(graph, kYunRTCommandSetGain, value: 0.25)
            let samples = render(graph, totalFrames: 960, blocks: blocks)[0]
            RTGraph.deallocate(graph)
            if reference.isEmpty {
                reference = samples
            } else {
                #expect(
                    zip(reference, samples).allSatisfy { abs($0 - $1) < 0.000_002 },
                    "partition \(blocks)")
            }
        }
    }

    @Test("route gain, mute and unmute have bounded exact ramps")
    func routeEndpointsAndDerivative() {
        let graph = graph()
        defer { RTGraph.deallocate(graph) }
        _ = cycle(graph, frames: 8)

        push(graph, kYunRTCommandSetGain, value: 0.25)
        let gain = render(graph, totalFrames: 480, blocks: [137, 11, 256])[0]
        #expect(gain[0] < 1)
        #expect(gain[479] == 0.25)
        // Float accumulation leaves the exact endpoint assignment a few parts
        // in a thousand wider than the nominal step.
        #expect(maximumDerivative(gain, from: 1) <= 0.75 / 480 + 0.000_01)

        push(graph, kYunRTCommandSetMute, value: 1)
        let mute = render(graph, totalFrames: 240, blocks: [64, 17, 128])[0]
        #expect(mute[0] < 0.25)
        #expect(mute[239] == 0)
        #expect(maximumDerivative(mute, from: 0.25) <= 0.25 / 240 + 0.000_01)

        push(graph, kYunRTCommandSetMute, value: 0)
        let unmute = render(graph, totalFrames: 480, blocks: [256, 7, 64])[0]
        #expect(unmute[0] > 0)
        #expect(unmute[479] == 0.25)
        #expect(maximumDerivative(unmute, from: 0) <= 0.25 / 480 + 0.000_01)
    }

    @Test("input trim and master use the same per-sample contract")
    func globalEndpoints() {
        let graph = graph()
        defer { RTGraph.deallocate(graph) }
        _ = cycle(graph, frames: 8)

        push(graph, kYunRTCommandSetInputGain, value: 0.5)
        let input = render(graph, totalFrames: 480, blocks: [31, 128, 257])[0]
        #expect(input[0] < 1)
        #expect(input[479] == 0.5)

        push(graph, kYunRTCommandSetOutputGain, value: 0.5)
        let output = render(graph, totalFrames: 480, blocks: [64, 256, 19])[0]
        #expect(output[0] < 0.5)
        #expect(output[479] == 0.25)

        push(graph, kYunRTCommandSetInputMute, value: 1)
        #expect(render(graph, totalFrames: 240, blocks: [113, 127])[0].last == 0)
        push(graph, kYunRTCommandSetInputMute, value: 0)
        #expect(render(graph, totalFrames: 480, blocks: [73, 128])[0].last == 0.25)
        push(graph, kYunRTCommandSetOutputMute, value: 1)
        #expect(render(graph, totalFrames: 240, blocks: [64])[0].last == 0)
    }

    @Test("the master still skips monitor while input mute reaches it")
    func monitorContractDuringRamps() {
        let graph = self.graph(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    appliesInputTrim: true),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 1, destinationChannel: 0,
                    appliesInputTrim: true),
            ])
        defer { RTGraph.deallocate(graph) }
        graph.pointee.mainOutputBuffer = 1
        graph.pointee.masterExemptBuffer = 0
        _ = monitorCycle(graph, frames: 8)

        push(graph, kYunRTCommandSetOutputMute, value: 1)
        let master = monitorCycle(graph, frames: 240)
        #expect(master[0].allSatisfy { $0 == 1 })
        #expect(master[1].first! < 1)
        #expect(master[1].last == 0)

        push(graph, kYunRTCommandSetInputMute, value: 1)
        let input = monitorCycle(graph, frames: 240)
        #expect(input[0].first! < 1)
        #expect(input[0].last == 0)
        #expect(input[1].allSatisfy { $0 == 0 })
    }

    @Test("duck attack and release are sample-time invariant")
    func duckTimeConstants() {
        var attackReference: [Float] = []
        for blocks in [[64], [128], [512], [17, 251, 3]] {
            let graph = duckingGraph(initial: 1)
            graph.pointee.micPeak = 0.5
            let attack = render(
                graph, totalFrames: 3_840, blocks: blocks,
                inputChannels: 2, outputChannels: 2, inputValues: [0.5, 1])[1]
            #expect(abs(attack.last! - 0.431_091_5) < 0.000_3)
            RTGraph.deallocate(graph)
            if attackReference.isEmpty {
                attackReference = attack
            } else {
                #expect(
                    zip(attackReference, attack).allSatisfy { abs($0 - $1) < 0.000_003 },
                    "attack partition \(blocks)")
            }
        }

        for blocks in [[64], [512], [23, 109, 257]] {
            let graph = duckingGraph(initial: 0.1)
            graph.pointee.micPeak = 0
            let release = render(
                graph, totalFrames: 28_800, blocks: blocks,
                inputChannels: 2, outputChannels: 2, inputValues: [0, 1])[1]
            #expect(abs(release.last! - 0.668_908_5) < 0.000_4)
            RTGraph.deallocate(graph)
        }
    }

    @Test("an inaudible duck tail settles onto the scalar fast path")
    func duckTailSettlesExactly() {
        let graph = duckingGraph(initial: 0.1)
        defer { RTGraph.deallocate(graph) }
        graph.pointee.micPeak = 0

        _ = render(
            graph, totalFrames: 240_000, blocks: [512],
            inputChannels: 2, outputChannels: 2, inputValues: [0, 1])
        #expect(graph.pointee.duckGainSlew.current == 1)
        #expect(graph.pointee.duckGain == 1)

        let settled = cycle(
            graph, frames: 512, inputChannels: 2,
            outputChannels: 2, inputValues: [0, 1])[1]
        #expect(settled.allSatisfy { $0 == 1 })
        #expect(graph.pointee.duckGainSlew.current == 1)
    }

    @Test("duck settling happens only after Float can no longer advance")
    func duckRepresentabilityEndpoint() {
        let coefficient = RTGraph.sampleCoefficient(seconds: 0.6, sampleRate: 48_000)
        var slew = RTGainSlew(0.1)
        var previous = slew.current
        var frames = 0
        while slew.current != 1, frames < 240_000 {
            previous = slew.current
            _ = slew.nextOnePole(towards: 1, coefficient: coefficient)
            frames += 1
        }

        print(
            "600 ms duck release becomes exact after \(frames) frames; "
                + "final residual \(1 - previous)")
        #expect(slew.current == 1)
        #expect(frames > 100_000)
        #expect(frames < 240_000)
        // Less than −60 dB as an absolute gain discontinuity.
        #expect(1 - previous < 0.001)
    }

    @Test("a graph rebuild carries every in-flight envelope")
    func graphRebuildCarry() {
        let previous = graph()
        defer { RTGraph.deallocate(previous) }
        _ = cycle(previous, frames: 8)
        push(previous, kYunRTCommandSetGain, value: 0)
        push(previous, kYunRTCommandSetInputGain, value: 0.4)
        push(previous, kYunRTCommandSetOutputGain, value: 0.6)
        _ = cycle(previous, frames: 137)

        let next = graph(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    gain: 0, appliesInputTrim: true)
            ])
        defer { RTGraph.deallocate(next) }
        next.pointee.inputGain = previous.pointee.inputGain
        next.pointee.inputMuted = previous.pointee.inputMuted
        next.pointee.outputGain = previous.pointee.outputGain
        next.pointee.outputMuted = previous.pointee.outputMuted
        RTGraph.carryGlobalGainSlews(from: previous, to: next)
        RTGraph.carryRouteGainSlew(from: previous, slot: 0, to: next, slot: 0)

        #expect(next.pointee.routeGainSlews[0] == previous.pointee.routeGainSlews[0])
        #expect(next.pointee.inputGainSlew == previous.pointee.inputGainSlew)
        #expect(next.pointee.outputGainSlew == previous.pointee.outputGainSlew)
        #expect(next.pointee.hasRendered == 1)

        var expected = previous.pointee.routeGainSlews[0]
        let nextRouteGain = expected.nextLinear()
        _ = cycle(next, frames: 1)
        #expect(abs(next.pointee.routeGainSlews[0].current - nextRouteGain) < 0.000_001)
        #expect(next.pointee.routeGainSlews[0].remainingFrames == expected.remainingFrames)
    }

    #if DEBUG
        @Test(
            "the complete moving gain path allocates nothing",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("the complete moving gain path allocates nothing")
    #endif
    func movingPathDoesNotAllocate() {
        let graph = graph(bufferFrames: 128)
        defer { RTGraph.deallocate(graph) }
        let input = GainIntegrationBus(channelCounts: [1], frames: 128)
        input.fill(0, channel: 0, with: 0.25)
        let output = GainIntegrationBus(channelCounts: [1], frames: 128)
        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        _ = yunAudioIOProc(
            0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
            output.list.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))
        push(graph, kYunRTCommandSetGain, value: 0.2)
        push(graph, kYunRTCommandSetInputGain, value: 0.5)
        push(graph, kYunRTCommandSetOutputGain, value: 0.7)

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<4_000 {
            _ = yunAudioIOProc(
                0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
                output.list.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let allocations = RoutingEngine.allocationViolations - before
        print(
            "moving gain callback: \(Double(elapsed) / 4_000) ns/cycle, "
                + "\(allocations) allocation operations")
        #expect(allocations == 0)
    }

    private func duckingGraph(initial: Float) -> UnsafeMutablePointer<RTGraph> {
        let graph = self.graph(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0,
                    appliesInputTrim: true),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 1,
                    isDuckable: true),
            ])
        graph.pointee.duckEnabled = 1
        graph.pointee.duckAllowed = 1
        graph.pointee.duckDepth = 0.1
        graph.pointee.duckThreshold = 0.02
        graph.pointee.duckGain = initial
        graph.pointee.duckGainSlew = RTGainSlew(initial)
        graph.pointee.hasRendered = 1
        return graph
    }

    private func monitorCycle(
        _ graph: UnsafeMutablePointer<RTGraph>, frames: Int
    ) -> [[Float]] {
        let input = GainIntegrationBus(channelCounts: [1], frames: frames)
        input.fill(0, channel: 0, with: 1)
        let output = GainIntegrationBus(channelCounts: [1, 1], frames: frames)
        let cell = yun_rt_cell_create(UnsafeMutableRawPointer(graph))!
        defer { yun_rt_cell_free(cell) }
        var now = AudioTimeStamp()
        var time = AudioTimeStamp()
        _ = yunAudioIOProc(
            0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
            output.list.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))
        return [output.samples(0, channel: 0), output.samples(1, channel: 0)]
    }

    private func maximumDerivative(_ values: [Float], from initial: Float) -> Float {
        var previous = initial
        var maximum: Float = 0
        for value in values {
            maximum = max(maximum, abs(value - previous))
            previous = value
        }
        return maximum
    }
}
