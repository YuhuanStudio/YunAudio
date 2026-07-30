import CoreAudio
import Foundation
import Testing
import YunAudioRT

@testable import YunAudioEngine

/// Synthetic buffers for exercising the complete IOProc without opening a device.
private final class FinalLimiterBus {
    let list: UnsafeMutableAudioBufferListPointer
    let frames: Int
    private let storage: [UnsafeMutablePointer<Float>]

    init(channelCounts: [Int], frames: Int) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: channelCounts.count)
        var pointers: [UnsafeMutablePointer<Float>] = []
        for (index, channels) in channelCounts.enumerated() {
            let count = frames * channels
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            pointers.append(pointer)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer))
        }
        storage = pointers
    }

    func fill(buffer: Int, channel: Int, with value: Float) {
        let channels = Int(list[buffer].mNumberChannels)
        for frame in 0..<frames {
            storage[buffer][frame * channels + channel] = value
        }
    }

    func set(buffer: Int, channel: Int, frame: Int, to value: Float) {
        let channels = Int(list[buffer].mNumberChannels)
        storage[buffer][frame * channels + channel] = value
    }

    func sample(buffer: Int, channel: Int, frame: Int) -> Float {
        let channels = Int(list[buffer].mNumberChannels)
        return storage[buffer][frame * channels + channel]
    }

    deinit {
        for pointer in storage { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

private func finalLimiterCycle(
    cell: OpaquePointer, input: FinalLimiterBus, output: FinalLimiterBus,
    sampleTime: Float64 = 0
) {
    var now = AudioTimeStamp()
    var time = AudioTimeStamp()
    time.mSampleTime = sampleTime
    time.mFlags = .sampleTimeValid
    _ = yunAudioIOProc(
        0, &now, UnsafePointer(input.list.unsafeMutablePointer), &time,
        output.list.unsafeMutablePointer, &time, UnsafeMutableRawPointer(cell))
}

private func oneStereoRouteGraph(frames: Int) -> UnsafeMutablePointer<RTGraph> {
    RTGraph.allocate(
        routes: [
            RTRoute(
                sourceBuffer: 0, sourceChannel: 0,
                destinationBuffer: 0, destinationChannel: 0),
            RTRoute(
                sourceBuffer: 0, sourceChannel: 1,
                destinationBuffer: 0, destinationChannel: 1),
        ], bufferFrames: frames, sampleRate: 48_000)
}

@Suite("Final limiter in the realtime graph")
struct FinalOutputLimiterGraphTests {
    @Test("the final stage catches sums, master gain and per-bus correction")
    func completeMixIsLimitedOnEveryBus() throws {
        let frames = 128
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 1),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 1),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 1, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 1, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 1, destinationChannel: 1),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 1, destinationChannel: 1),
            ], bufferFrames: frames, sampleRate: 48_000)
        defer { RTGraph.deallocate(graph) }
        let limiter = try #require(
            OutputLimiterBank(channelCounts: [2, 2], sampleRate: 48_000))
        graph.pointee.outputLimiter = Unmanaged.passUnretained(limiter).toOpaque()
        graph.pointee.outputLimiterEnabled = 1
        graph.pointee.mainOutputBuffer = 1
        graph.pointee.masterExemptBuffer = 0
        graph.pointee.outputGain = 1.5
        graph.pointee.analysisEnabled = 1
        #expect(
            RTGraph.installCorrection(
                [1, 0, 0, 0, 0], preampGain: 2,
                onBuffer: 1, of: graph))

        let input = FinalLimiterBus(channelCounts: [2], frames: frames)
        input.fill(buffer: 0, channel: 0, with: 0.6)
        input.fill(buffer: 0, channel: 1, with: 0.15)
        let output = FinalLimiterBus(channelCounts: [2, 2], frames: frames)
        let cell = try #require(yun_rt_cell_create(UnsafeMutableRawPointer(graph)))
        defer { yun_rt_cell_free(cell) }

        finalLimiterCycle(cell: cell, input: input, output: output)

        for bus in 0..<2 {
            var peak: Float = 0
            var ratioError: Float = 0
            for frame in limiter.latencyFrames..<frames {
                let left = output.sample(buffer: bus, channel: 0, frame: frame)
                let right = output.sample(buffer: bus, channel: 1, frame: frame)
                peak = max(peak, abs(left))
                if abs(left) > 0.01 {
                    ratioError = max(ratioError, abs(right / left - 0.25))
                }
            }
            #expect(peak <= limiter.ceiling + 0.000_001)
            #expect(peak >= limiter.ceiling - 0.001)
            #expect(ratioError < 0.000_001)
        }
        #expect(graph.pointee.outputPeak <= limiter.ceiling + 0.000_001)
        #expect(graph.pointee.outputClipped == 0)

        var analysis = [Float](repeating: 0, count: frames)
        let read = analysis.withUnsafeMutableBufferPointer {
            yun_rt_ring_read(graph.pointee.analysisRing!, $0.baseAddress!, UInt32($0.count))
        }
        #expect(read == UInt32(frames))
        // Main bus before its ×2 correction and before limiting:
        // ((0.6 × 2 routes × 1.5 master) + (0.15 × 2 × 1.5)) / 2 channels.
        #expect(analysis.allSatisfy { abs($0 - 1.125) < 0.000_001 })
    }

    @Test("bypass keeps high samples exact and post-stage telemetry reports them")
    func bypassTelemetry() throws {
        let frames = 128
        let graph = oneStereoRouteGraph(frames: frames)
        defer { RTGraph.deallocate(graph) }
        let limiter = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        graph.pointee.outputLimiter = Unmanaged.passUnretained(limiter).toOpaque()
        graph.pointee.outputLimiterEnabled = 0

        let input = FinalLimiterBus(channelCounts: [2], frames: frames)
        input.fill(buffer: 0, channel: 0, with: 1.25)
        input.fill(buffer: 0, channel: 1, with: -0.25)
        let output = FinalLimiterBus(channelCounts: [2], frames: frames)
        let cell = try #require(yun_rt_cell_create(UnsafeMutableRawPointer(graph)))
        defer { yun_rt_cell_free(cell) }

        finalLimiterCycle(cell: cell, input: input, output: output)

        #expect(output.sample(buffer: 0, channel: 0, frame: 0) == 0)
        #expect(
            output.sample(
                buffer: 0, channel: 0, frame: limiter.latencyFrames) == 1.25)
        #expect(
            output.sample(
                buffer: 0, channel: 1, frame: limiter.latencyFrames) == -0.25)
        #expect(graph.pointee.outputPeak == 1.25)
        #expect(graph.pointee.outputClipped == UInt64(frames - limiter.latencyFrames))
    }

    @Test("a graph publication keeps one bank and its delayed signal")
    func graphSwapKeepsBankIdentityAndContinuity() throws {
        let frames = 64
        let first = oneStereoRouteGraph(frames: frames)
        let second = oneStereoRouteGraph(frames: frames)
        defer {
            RTGraph.deallocate(first)
            RTGraph.deallocate(second)
        }
        let limiter = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        first.pointee.outputLimiter = Unmanaged.passUnretained(limiter).toOpaque()
        first.pointee.outputLimiterEnabled = 0
        RTGraph.carryOutputStages(from: first, to: second)
        #expect(first.pointee.outputLimiter == second.pointee.outputLimiter)
        #expect(
            first.pointee.outputLimiter
                == Unmanaged.passUnretained(limiter).toOpaque())

        let input = FinalLimiterBus(channelCounts: [2], frames: frames)
        let output = FinalLimiterBus(channelCounts: [2], frames: frames)
        let cell = try #require(yun_rt_cell_create(UnsafeMutableRawPointer(first)))
        defer { yun_rt_cell_free(cell) }
        var source = [Float]()
        var rendered = [Float]()

        for cycle in 0..<2 {
            for frame in 0..<frames {
                let value = Float(cycle * frames + frame + 1) / 256
                source.append(value)
                input.set(buffer: 0, channel: 0, frame: frame, to: value)
                input.set(buffer: 0, channel: 1, frame: frame, to: -value)
            }
            if cycle == 1 {
                let retired = yun_rt_cell_publish(cell, UnsafeMutableRawPointer(second))
                #expect(retired == UnsafeMutableRawPointer(first))
            }
            finalLimiterCycle(
                cell: cell, input: input, output: output,
                sampleTime: Float64(cycle * frames))
            for frame in 0..<frames {
                rendered.append(output.sample(buffer: 0, channel: 0, frame: frame))
            }
        }

        #expect(rendered.prefix(limiter.latencyFrames).allSatisfy { $0 == 0 })
        for frame in limiter.latencyFrames..<rendered.count {
            #expect(rendered[frame] == source[frame - limiter.latencyFrames])
        }
        #expect(rendered[frames] != 0)
    }

    @Test("a stale output topology fails closed")
    func topologyMismatchIsSilent() throws {
        let frames = 64
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0)
            ], bufferFrames: frames)
        defer { RTGraph.deallocate(graph) }
        let limiter = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        graph.pointee.outputLimiter = Unmanaged.passUnretained(limiter).toOpaque()
        graph.pointee.outputLimiterEnabled = 1

        let input = FinalLimiterBus(channelCounts: [1], frames: frames)
        input.fill(buffer: 0, channel: 0, with: 0.5)
        let output = FinalLimiterBus(channelCounts: [1], frames: frames)
        let cell = try #require(yun_rt_cell_create(UnsafeMutableRawPointer(graph)))
        defer { yun_rt_cell_free(cell) }

        finalLimiterCycle(cell: cell, input: input, output: output)

        #expect(
            (0..<frames).allSatisfy {
                output.sample(buffer: 0, channel: 0, frame: $0) == 0
            })
        #expect(graph.pointee.outputLimiterFailures == 1)
    }

    @Test("limiter drive changes through the queue at the next cycle boundary")
    func preGainCommand() throws {
        let frames = 128
        let graph = oneStereoRouteGraph(frames: frames)
        defer { RTGraph.deallocate(graph) }
        let limiter = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        graph.pointee.outputLimiter = Unmanaged.passUnretained(limiter).toOpaque()
        graph.pointee.outputLimiterEnabled = 1
        let commands = try #require(graph.pointee.commands)
        #expect(
            yun_rt_queue_push(
                commands,
                YunRTCommand(
                    kind: Int32(kYunRTCommandSetLimiterPreGain.rawValue),
                    index: 0, value: 4)))

        let input = FinalLimiterBus(channelCounts: [2], frames: frames)
        input.fill(buffer: 0, channel: 0, with: 0.2)
        input.fill(buffer: 0, channel: 1, with: -0.1)
        let output = FinalLimiterBus(channelCounts: [2], frames: frames)
        let cell = try #require(yun_rt_cell_create(UnsafeMutableRawPointer(graph)))
        defer { yun_rt_cell_free(cell) }

        #expect(graph.pointee.outputLimiterPreGain == 1)
        finalLimiterCycle(cell: cell, input: input, output: output)

        #expect(graph.pointee.outputLimiterPreGain == 4)
        #expect(
            output.sample(
                buffer: 0, channel: 0,
                frame: limiter.latencyFrames) == 0.8)
        #expect(
            output.sample(
                buffer: 0, channel: 1,
                frame: limiter.latencyFrames) == -0.4)
    }

    @Test("the control-thread limiter value does not read the realtime graph")
    func preGainControlValue() throws {
        let engine = RoutingEngine()
        engine.setEffectParameter("gain", of: .limiter, to: 6)

        let value = try #require(engine.effectParameter("gain", of: .limiter))
        #expect(abs(value - 6) < 0.000_001)
    }

    #if DEBUG
        @Test(
            "the complete callback with final limiting allocates nothing",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("the complete callback with final limiting allocates nothing")
    #endif
    func callbackDoesNotAllocate() throws {
        let frames = 128
        let graph = oneStereoRouteGraph(frames: frames)
        defer { RTGraph.deallocate(graph) }
        let limiter = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        graph.pointee.outputLimiter = Unmanaged.passUnretained(limiter).toOpaque()
        graph.pointee.outputLimiterEnabled = 1
        #expect(
            RTGraph.installCorrection(
                [1, 0, 0, 0, 0], preampGain: 1.5,
                onBuffer: 0, of: graph))

        let input = FinalLimiterBus(channelCounts: [2], frames: frames)
        input.fill(buffer: 0, channel: 0, with: 0.9)
        input.fill(buffer: 0, channel: 1, with: -0.45)
        let output = FinalLimiterBus(channelCounts: [2], frames: frames)
        let cell = try #require(yun_rt_cell_create(UnsafeMutableRawPointer(graph)))
        defer { yun_rt_cell_free(cell) }
        finalLimiterCycle(cell: cell, input: input, output: output)

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        let before = RoutingEngine.allocationViolations
        for cycle in 0..<3_750 {
            finalLimiterCycle(
                cell: cell, input: input, output: output,
                sampleTime: Float64(cycle * frames))
        }
        #expect(RoutingEngine.allocationViolations - before == 0)
    }
}

@Suite("Recording limiter branch")
struct RecordingOutputLimiterTests {
    private func recordedSequence(frames: Int) throws -> ([Float], [Float]) {
        let blockFrames = frames
        let graph = RTGraph.allocate(
            routes: [
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 0,
                    destinationBuffer: 0, destinationChannel: 0),
                RTRoute(
                    sourceBuffer: 0, sourceChannel: 1,
                    destinationBuffer: 0, destinationChannel: 1),
            ], bufferFrames: blockFrames, sampleRate: 48_000)
        defer { RTGraph.deallocate(graph) }
        let limiter = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        let ring = try #require(yun_rt_ring_create(UInt32(max(512, frames * 4))))
        defer { yun_rt_ring_free(ring) }
        graph.pointee.recordRing = ring
        graph.pointee.recordChannels = 2
        graph.pointee.recordLimiter = Unmanaged.passUnretained(limiter).toOpaque()
        graph.pointee.recordLimiterPrimingFrames = Int32(limiter.latencyFrames)
        graph.pointee.outputLimiterEnabled = 0

        let input = FinalLimiterBus(channelCounts: [2], frames: blockFrames)
        var expected = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let left = Float(frame + 1) / Float(frames + 1)
            let right = -left * 0.5
            input.set(buffer: 0, channel: 0, frame: frame, to: left)
            input.set(buffer: 0, channel: 1, frame: frame, to: right)
            expected[frame * 2] = left
            expected[frame * 2 + 1] = right
        }
        let output = FinalLimiterBus(channelCounts: [2], frames: blockFrames)
        let cell = try #require(yun_rt_cell_create(UnsafeMutableRawPointer(graph)))
        defer { yun_rt_cell_free(cell) }

        finalLimiterCycle(cell: cell, input: input, output: output)
        graph.pointee.recordRing = nil
        graph.pointee.recordLimiter = nil
        let flushed = RoutingEngine.flushRecordingLimiter(
            limiter, into: ring, channels: 2,
            primingFrames: Int(graph.pointee.recordLimiterPrimingFrames),
            limiting: false, preGain: 1)
        #expect(flushed == min(frames, limiter.latencyFrames))

        var recorded = [Float](repeating: 0, count: frames * 2 + 64)
        let taken = recorded.withUnsafeMutableBufferPointer {
            Int(yun_rt_ring_read(ring, $0.baseAddress!, UInt32($0.count)))
        }
        recorded.removeSubrange(taken..<recorded.count)
        return (expected, recorded)
    }

    @Test(
        "prime and flush preserve the exact frame count",
        arguments: [23, 257])
    func exactFrameCount(frames: Int) throws {
        let (expected, recorded) = try recordedSequence(frames: frames)

        #expect(recorded.count == expected.count)
        #expect(recorded == expected)
    }

    @Test("headphone correction is not baked into the recording")
    func recordingPrecedesCorrection() throws {
        let frames = 128
        let graph = oneStereoRouteGraph(frames: frames)
        defer { RTGraph.deallocate(graph) }
        let hardwareLimiter = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        let recordLimiter = try #require(
            OutputLimiterBank(channelCounts: [2], sampleRate: 48_000))
        let ring = try #require(yun_rt_ring_create(1024))
        defer { yun_rt_ring_free(ring) }
        graph.pointee.outputLimiter =
            Unmanaged.passUnretained(hardwareLimiter).toOpaque()
        graph.pointee.outputLimiterEnabled = 0
        graph.pointee.recordRing = ring
        graph.pointee.recordChannels = 2
        graph.pointee.recordLimiter =
            Unmanaged.passUnretained(recordLimiter).toOpaque()
        graph.pointee.recordLimiterPrimingFrames =
            Int32(recordLimiter.latencyFrames)
        #expect(
            RTGraph.installCorrection(
                [1, 0, 0, 0, 0], preampGain: 2,
                onBuffer: 0, of: graph))

        let input = FinalLimiterBus(channelCounts: [2], frames: frames)
        input.fill(buffer: 0, channel: 0, with: 0.25)
        input.fill(buffer: 0, channel: 1, with: -0.125)
        let output = FinalLimiterBus(channelCounts: [2], frames: frames)
        let cell = try #require(yun_rt_cell_create(UnsafeMutableRawPointer(graph)))
        defer { yun_rt_cell_free(cell) }
        finalLimiterCycle(cell: cell, input: input, output: output)
        graph.pointee.recordRing = nil
        graph.pointee.recordLimiter = nil
        _ = RoutingEngine.flushRecordingLimiter(
            recordLimiter, into: ring, channels: 2,
            primingFrames: Int(graph.pointee.recordLimiterPrimingFrames),
            limiting: false, preGain: 1)

        var recorded = [Float](repeating: 0, count: frames * 2)
        let taken = recorded.withUnsafeMutableBufferPointer {
            Int(yun_rt_ring_read(ring, $0.baseAddress!, UInt32($0.count)))
        }
        #expect(taken == frames * 2)
        #expect(recorded.allSatisfy { $0 == 0.25 || $0 == -0.125 })
        #expect(
            output.sample(
                buffer: 0, channel: 0,
                frame: hardwareLimiter.latencyFrames) == 0.5)
        #expect(
            output.sample(
                buffer: 0, channel: 1,
                frame: hardwareLimiter.latencyFrames) == -0.25)
    }
}
