import CoreAudio
import Foundation
import YunAudioRT

/// One source channel copied into one destination channel.
///
/// Deliberately a fixed-layout struct of scalars: the realtime callback walks
/// an array of these, and anything with a reference count in it would mean ARC
/// traffic on a time-constrained thread.
public struct RTRoute: Sendable, Equatable {
    /// Index into the IOProc's input `AudioBufferList`.
    public var sourceBuffer: Int32
    /// Channel within that buffer (buffers from an aggregate are interleaved).
    public var sourceChannel: Int32
    public var destinationBuffer: Int32
    public var destinationChannel: Int32
    public var gain: Float
    /// Int32 rather than Bool so the struct stays a fixed-layout scalar record
    /// that the command queue can update without any bridging.
    public var muted: Int32
    /// Non-zero when this route should read the voice-isolated signal instead
    /// of the raw input buffer.
    public var usesIsolatedSource: Int32

    public init(
        sourceBuffer: Int32, sourceChannel: Int32,
        destinationBuffer: Int32, destinationChannel: Int32,
        gain: Float = 1.0,
        muted: Bool = false,
        usesIsolatedSource: Bool = false
    ) {
        self.sourceBuffer = sourceBuffer
        self.sourceChannel = sourceChannel
        self.destinationBuffer = destinationBuffer
        self.destinationChannel = destinationChannel
        self.gain = gain
        self.muted = muted ? 1 : 0
        self.usesIsolatedSource = usesIsolatedSource ? 1 : 0
    }
}

/// The realtime-visible state of the router.
///
/// Plain old data behind a manually managed pointer. It is never a Swift class
/// and never contains one, so the IOProc can read it without retain/release.
/// Allocation and deallocation happen only on the control thread.
struct RTGraph {
    var routes: UnsafeMutablePointer<RTRoute>
    var routeCount: Int32

    /// Peak magnitude per route since the last read. Written by the realtime
    /// thread and read by the UI; a torn float is not worth a lock here,
    /// because the worst case is one frame of a meter being stale.
    var peaks: UnsafeMutablePointer<Float>

    /// Incremented once per IO cycle. The control thread watches this to know
    /// the realtime thread has moved past a graph it is about to free, and it
    /// doubles as the sequence number guarding the clock anchor below.
    var cycleCounter: UnsafeMutablePointer<UInt64>

    /// Per-cycle decay applied to the peak meters.
    ///
    /// Computed from the buffer size so the meter falls at the same rate in
    /// wall-clock terms whatever the buffer is. A fixed per-cycle factor ties
    /// the ballistics to the IO rate: at 128 frames the meter decays four times
    /// faster than at 512, for the same signal.
    var peakDecay: Float

    /// Most recent input timestamp from the aggregate, which is the clock
    /// master's own sample time. Published to the virtual driver so it can lock
    /// its clock to the microphone instead of free-running on the host clock.
    /// Written before `cycleCounter` is bumped, so a reader that sees the same
    /// counter either side of its read got a consistent pair.
    var clockSampleTime: UnsafeMutablePointer<Float64>
    var clockHostTime: UnsafeMutablePointer<UInt64>

    /// The voice isolation stage, or null when it is not in use.
    var voiceIsolation: UnsafeMutablePointer<RTVoiceIsolation>?
    /// Non-zero when the isolation slot holds a multi-stage chain rather than
    /// the single isolation unit. They render through different types.
    var isolationIsChain: Int32

    /// Ring the recorder drains, or null when nothing is recording. Fed with
    /// the destination bus after all processing, so what lands on disk is what
    /// the far end hears.
    var recordRing: OpaquePointer?
    /// Channels the recorder expects per frame.
    var recordChannels: Int32
    /// Scratch for de-striding the destination bus before it goes into the ring.
    /// Allocated with the graph, because the IO thread cannot allocate and the
    /// destination is usually wider than the recording — BlackHole presents
    /// sixteen channels for a two-channel capture.
    var recordScratch: UnsafeMutablePointer<Float>
    var recordScratchCapacity: Int32

    /// Parameter changes waiting to be applied. Drained at the top of each
    /// cycle so a fader move lands without rebuilding anything.
    var commands: OpaquePointer?

    /// Null unless a loopback integrity check is running. Checked once per
    /// cycle, so the normal path costs one predictable branch.
    var selftest: UnsafeMutablePointer<RTSelftest>?

    /// Peak meters fall by 20 dB per second, which is the usual ballistic for
    /// a peak-reading meter and slow enough to read.
    static func decay(bufferFrames: Int, sampleRate: Double) -> Float {
        guard bufferFrames > 0, sampleRate > 0 else { return 0.85 }
        let secondsPerCycle = Double(bufferFrames) / sampleRate
        return Float(pow(10.0, -20.0 * secondsPerCycle / 20.0))
    }

    static func allocate(
        routes routeList: [RTRoute], bufferFrames: Int = 128, sampleRate: Double = 48000
    ) -> UnsafeMutablePointer<RTGraph> {
        let count = max(routeList.count, 1)

        let routeStorage = UnsafeMutablePointer<RTRoute>.allocate(capacity: count)
        routeStorage.initialize(
            repeating: RTRoute(
                sourceBuffer: 0, sourceChannel: 0,
                destinationBuffer: 0, destinationChannel: 0, gain: 0, muted: true,
                usesIsolatedSource: false), count: count)
        for (index, route) in routeList.enumerated() {
            routeStorage[index] = route
        }

        let peakStorage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        peakStorage.initialize(repeating: 0, count: count)

        let counterStorage = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        counterStorage.initialize(to: 0)

        // Sized for the largest block the device is likely to ask for, times a
        // stereo frame.
        let scratchCapacity = max(bufferFrames, 4096) * 2
        let scratchStorage = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratchStorage.initialize(repeating: 0, count: scratchCapacity)

        let clockSampleStorage = UnsafeMutablePointer<Float64>.allocate(capacity: 1)
        clockSampleStorage.initialize(to: 0)
        let clockHostStorage = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        clockHostStorage.initialize(to: 0)

        let graph = UnsafeMutablePointer<RTGraph>.allocate(capacity: 1)
        graph.initialize(
            to: RTGraph(
                routes: routeStorage,
                routeCount: Int32(routeList.count),
                peaks: peakStorage,
                cycleCounter: counterStorage,
                peakDecay: decay(bufferFrames: bufferFrames, sampleRate: sampleRate),
                clockSampleTime: clockSampleStorage,
                clockHostTime: clockHostStorage,
                voiceIsolation: nil,
                isolationIsChain: 0,
                recordRing: nil,
                recordChannels: 0,
                recordScratch: scratchStorage,
                recordScratchCapacity: Int32(scratchCapacity),
                commands: yun_rt_queue_create(256),
                selftest: nil))
        return graph
    }

    static func deallocate(_ graph: UnsafeMutablePointer<RTGraph>) {
        let count = max(Int(graph.pointee.routeCount), 1)
        graph.pointee.routes.deinitialize(count: count)
        graph.pointee.routes.deallocate()
        graph.pointee.peaks.deinitialize(count: count)
        graph.pointee.peaks.deallocate()
        graph.pointee.cycleCounter.deinitialize(count: 1)
        graph.pointee.cycleCounter.deallocate()
        graph.pointee.recordScratch.deinitialize(
            count: Int(graph.pointee.recordScratchCapacity))
        graph.pointee.recordScratch.deallocate()
        graph.pointee.clockSampleTime.deinitialize(count: 1)
        graph.pointee.clockSampleTime.deallocate()
        graph.pointee.clockHostTime.deinitialize(count: 1)
        graph.pointee.clockHostTime.deallocate()
        if let commands = graph.pointee.commands { yun_rt_queue_free(commands) }
        graph.deinitialize(count: 1)
        graph.deallocate()
    }
}

// MARK: - The realtime callback

/// The IO callback. Runs on a time-constrained thread.
///
/// Rules that hold for every line below, without exception: no allocation, no
/// ARC, no locks, no syscalls, no Swift runtime calls that could do any of
/// those. Everything it touches was allocated before the device started.
func yunAudioIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    // The graph is reached through a cell rather than directly, so the control
    // thread can swap in a new one between cycles instead of stopping the
    // device to change a route.
    let cell = OpaquePointer(clientData)
    guard let raw = yun_rt_cell_load(cell) else { return noErr }
    let graph = raw.assumingMemoryBound(to: RTGraph.self)
    defer { yun_rt_cell_retire(cell) }

    // Anything allocated between here and the matching call at the end is a
    // violation of the realtime contract and gets counted.
    //
    // Not gated on DEBUG: the allocator hook is only installed when the
    // tripwire is explicitly enabled, so the cost when it is off is two relaxed
    // atomic stores per cycle. Gating it on the build configuration made the
    // optimised build — the only one whose allocation behaviour actually
    // matters — report a meaningless zero.
    yun_rt_tripwire_mark_realtime(true)
    defer { yun_rt_tripwire_mark_realtime(false) }

    // Apply any pending parameter changes before touching audio, so a whole
    // cycle uses one consistent set of values.
    if let commands = graph.pointee.commands {
        var command = YunRTCommand(kind: 0, index: 0, value: 0)
        while yun_rt_queue_pop(commands, &command) {
            let index = Int(command.index)
            guard index >= 0, index < Int(graph.pointee.routeCount) else { continue }
            switch command.kind {
            case Int32(kYunRTCommandSetGain.rawValue):
                graph.pointee.routes[index].gain = command.value
            case Int32(kYunRTCommandSetMute.rawValue):
                graph.pointee.routes[index].muted = command.value != 0 ? 1 : 0
            default:
                break
            }
        }
    }

    let input = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inputData))
    let output = UnsafeMutableAudioBufferListPointer(outputData)

    // CoreAudio does not promise a zeroed output buffer, and routes accumulate
    // into it, so clear first. Any channel with no route feeding it must end up
    // silent rather than replaying whatever was left in the buffer.
    for index in 0..<output.count {
        if let data = output[index].mData {
            memset(data, 0, Int(output[index].mDataByteSize))
        }
    }

    // Voice isolation runs once per cycle, ahead of routing, so several routes
    // can share one pass over the model rather than each paying for it.
    var isolatedFrames = 0
    if let isolation = graph.pointee.voiceIsolation, isolation.pointee.enabled != 0 {
        let sourceIndex = Int(isolation.pointee.sourceBuffer)
        if sourceIndex < input.count, let data = input[sourceIndex].mData {
            let stride = Int(input[sourceIndex].mNumberChannels)
            let channel = Int(isolation.pointee.sourceChannel)
            if stride > 0, channel < stride {
                let available =
                    Int(input[sourceIndex].mDataByteSize)
                    / (MemoryLayout<Float>.size * stride)
                let frames = min(available, Int(isolation.pointee.maximumFrames))
                let source = data.assumingMemoryBound(to: Float.self)
                let staging = isolation.pointee.inputBuffer
                for frame in 0..<frames {
                    staging[frame] = source[frame * stride + channel]
                }
                let rendered: Bool
                if graph.pointee.isolationIsChain != 0 {
                    rendered = Unmanaged<EffectChain>
                        .fromOpaque(isolation.pointee.unit).takeUnretainedValue()
                        .render(frames: frames, sampleTime: inputTime.pointee.mSampleTime)
                } else {
                    rendered = Unmanaged<VoiceIsolationUnit>
                        .fromOpaque(isolation.pointee.unit).takeUnretainedValue()
                        .render(frames: frames, sampleTime: inputTime.pointee.mSampleTime)
                }
                if rendered {
                    isolatedFrames = frames
                } else {
                    isolation.pointee.renderFailures.pointee &+= 1
                }
            }
        }
    }

    let routeCount = Int(graph.pointee.routeCount)
    let routes = graph.pointee.routes
    let peaks = graph.pointee.peaks

    for index in 0..<routeCount {
        let route = routes[index]

        let sourceIndex = Int(route.sourceBuffer)
        let destinationIndex = Int(route.destinationBuffer)
        guard sourceIndex < input.count, destinationIndex < output.count else { continue }

        let sourceBuffer = input[sourceIndex]
        let destinationBuffer = output[destinationIndex]
        guard let sourceData = sourceBuffer.mData,
            let destinationData = destinationBuffer.mData
        else { continue }

        // An isolated route reads the model's mono output, which is packed, so
        // its stride is one and its channel index is zero.
        let useIsolated = route.usesIsolatedSource != 0 && isolatedFrames > 0
        let sourceStride = useIsolated ? 1 : Int(sourceBuffer.mNumberChannels)
        let destinationStride = Int(destinationBuffer.mNumberChannels)
        let sourceChannel = useIsolated ? 0 : Int(route.sourceChannel)
        let destinationChannel = Int(route.destinationChannel)
        guard sourceChannel < sourceStride, destinationChannel < destinationStride,
            sourceStride > 0, destinationStride > 0
        else { continue }

        // Both endpoints present 32-bit float physical formats, and the HAL's
        // virtual format is float32 regardless, so no conversion is needed.
        let sourceFrames =
            useIsolated
            ? isolatedFrames
            : Int(sourceBuffer.mDataByteSize) / (MemoryLayout<Float>.size * sourceStride)
        let destinationFrames =
            Int(destinationBuffer.mDataByteSize)
            / (MemoryLayout<Float>.size * destinationStride)
        let frames = min(sourceFrames, destinationFrames)
        guard frames > 0 else { continue }

        let source =
            useIsolated
            ? graph.pointee.voiceIsolation!.pointee.outputBuffer
            : sourceData.assumingMemoryBound(to: Float.self)
        let destination = destinationData.assumingMemoryBound(to: Float.self)
        let gain = route.muted != 0 ? 0 : route.gain

        var peak: Float = 0
        for frame in 0..<frames {
            let sample = source[frame * sourceStride + sourceChannel]
            destination[frame * destinationStride + destinationChannel] += sample * gain
            // Metered before gain: a meter should show what arrived, not what
            // the fader did to it. It also lets a gain-0 route act as a pure
            // probe, which is how the loopback verification works.
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }

        // Decay towards the new peak so the meter falls smoothly instead of
        // flickering, without needing any timer on the UI side.
        let previous = peaks[index]
        peaks[index] = peak > previous ? peak : previous * graph.pointee.peakDecay
    }

    // Loopback integrity check. Overwrites the destination channel with a
    // deterministic sequence and records what comes back, so the return path
    // can be compared sample for sample rather than trusted.
    if let selftest = graph.pointee.selftest {
        let outIndex = Int(selftest.pointee.outBuffer)
        let inIndex = Int(selftest.pointee.inBuffer)

        if outIndex < output.count, let data = output[outIndex].mData {
            let stride = Int(output[outIndex].mNumberChannels)
            let channel = Int(selftest.pointee.outChannel)
            if stride > 0, channel < stride {
                let frames =
                    Int(output[outIndex].mDataByteSize)
                    / (MemoryLayout<Float>.size * stride)
                let pointer = data.assumingMemoryBound(to: Float.self)
                var generated = selftest.pointee.generatedFrames.pointee
                for frame in 0..<frames {
                    pointer[frame * stride + channel] = selftestSample(generated)
                    generated &+= 1
                }
                selftest.pointee.generatedFrames.pointee = generated
            }
        }

        if inIndex < input.count, let data = input[inIndex].mData {
            let stride = Int(input[inIndex].mNumberChannels)
            let channel = Int(selftest.pointee.inChannel)
            let capacity = Int(selftest.pointee.captureCapacity)
            var stored = Int(selftest.pointee.captureCount.pointee)
            if stride > 0, channel < stride, stored < capacity {
                if stored == 0 {
                    selftest.pointee.captureStartFrame.pointee =
                        selftest.pointee.generatedFrames.pointee
                }
                let frames =
                    Int(input[inIndex].mDataByteSize)
                    / (MemoryLayout<Float>.size * stride)
                let pointer = data.assumingMemoryBound(to: Float.self)
                let capture = selftest.pointee.capture
                for frame in 0..<frames where stored < capacity {
                    capture[stored] = pointer[frame * stride + channel]
                    stored += 1
                }
                selftest.pointee.captureCount.pointee = Int32(stored)
            }
        }
    }

    // Feed the recorder from the destination bus: what is written to disk
    // should be what the far end receives, not what arrived at the input.
    if let ring = graph.pointee.recordRing, output.count > 0 {
        let channels = Int(graph.pointee.recordChannels)
        if let data = output[0].mData, channels > 0 {
            let stride = Int(output[0].mNumberChannels)
            let frames = Int(output[0].mDataByteSize) / (MemoryLayout<Float>.size * stride)
            let source = data.assumingMemoryBound(to: Float.self)
            if stride == channels {
                _ = yun_rt_ring_write(ring, source, UInt32(frames * channels))
            } else {
                // The destination is wider than the recording, so the wanted
                // channels are gathered into the graph's own scratch first.
                let scratch = graph.pointee.recordScratch
                let usable = min(frames, Int(graph.pointee.recordScratchCapacity) / channels)
                for frame in 0..<usable {
                    for channel in 0..<channels {
                        scratch[frame * channels + channel] =
                            source[frame * stride + channel]
                    }
                }
                if usable > 0 {
                    _ = yun_rt_ring_write(ring, scratch, UInt32(usable * channels))
                }
            }
        }
    }

    // Capture the master's clock before bumping the counter: readers use the
    // counter as a sequence number, so the values must already be in place.
    graph.pointee.clockSampleTime.pointee = inputTime.pointee.mSampleTime
    graph.pointee.clockHostTime.pointee = inputTime.pointee.mHostTime

    graph.pointee.cycleCounter.pointee &+= 1
    return noErr
}
