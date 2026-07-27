import AudioToolbox
import AVFoundation
import Foundation

/// What `AUSoundIsolation` actually costs, measured rather than assumed.
///
/// The plan for this feature was written on the strength of the header alone.
/// Before it goes anywhere near the IO thread, the numbers that decide the
/// architecture — added latency, and whether a render fits inside an IO cycle —
/// have to come from the machine.
public struct SoundIsolationReport: Sendable {
    public let isAvailable: Bool
    public let sampleRate: Double
    public let blockFrames: Int
    /// Latency the unit reports, in seconds.
    public let latencySeconds: Double
    /// Tail beyond the latency, in seconds.
    public let tailSeconds: Double
    /// Median wall-clock time for one render of `blockFrames`.
    public let medianRenderSeconds: Double
    public let worstRenderSeconds: Double
    /// Time available per IO cycle at this block size.
    public var cycleBudgetSeconds: Double { Double(blockFrames) / sampleRate }
    /// Fraction of the deadline a render consumes at its worst.
    public var worstDeadlineUse: Double { worstRenderSeconds / cycleBudgetSeconds }
    /// Whether it is safe to render inline on the IO thread.
    ///
    /// A quarter of the budget is the threshold: the IOProc also has routing,
    /// metering and the rest of the graph to do, and a realtime deadline that is
    /// merely usually met is a deadline that produces crackle under load.
    public var fitsInline: Bool { worstDeadlineUse < 0.25 }

    public var summary: String {
        guard isAvailable else { return "AUSoundIsolation could not be instantiated" }
        return String(
            format: """
                AUSoundIsolation @ %d Hz, %d-frame blocks
                  reported latency  %.2f ms
                  reported tail     %.2f ms
                  render time       %.3f ms median, %.3f ms worst
                  cycle budget      %.3f ms
                  worst-case use    %.1f%% of the deadline
                  verdict           %@
                """,
            Int(sampleRate), blockFrames,
            latencySeconds * 1000, tailSeconds * 1000,
            medianRenderSeconds * 1000, worstRenderSeconds * 1000,
            cycleBudgetSeconds * 1000,
            worstDeadlineUse * 100,
            fitsInline
                ? "safe to render inline on the IO thread"
                : "too slow for the IO thread — must run on a workgroup thread with latency compensation"
        )
    }
}

public enum SoundIsolation {
    public static let componentSubType: OSType = 0x766F_6973  // 'vois'

    /// Instantiates the unit and times it against a real block size.
    public static func probe(
        sampleRate: Double = 48000,
        blockFrames: Int = 128,
        iterations: Int = 400
    ) -> SoundIsolationReport {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: componentSubType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)

        guard let component = AudioComponentFindNext(nil, &description) else {
            return .init(
                isAvailable: false, sampleRate: sampleRate, blockFrames: blockFrames,
                latencySeconds: 0, tailSeconds: 0,
                medianRenderSeconds: 0, worstRenderSeconds: 0)
        }

        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &instance) == noErr,
            let unit = instance
        else {
            return .init(
                isAvailable: false, sampleRate: sampleRate, blockFrames: blockFrames,
                latencySeconds: 0, tailSeconds: 0,
                medianRenderSeconds: 0, worstRenderSeconds: 0)
        }
        defer { AudioComponentInstanceDispose(unit) }

        // Mono float32, non-interleaved: the capsule is mono and isolation is a
        // per-voice operation, so there is nothing to gain from feeding it two
        // copies of the same signal.
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)

        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, formatSize)
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
            &format, formatSize)

        var maximumFrames = UInt32(blockFrames)
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maximumFrames, UInt32(MemoryLayout<UInt32>.size))

        // Feed it band-limited noise. Silence would let a model that gates on
        // input level skip its work entirely and report a flattering time.
        let input = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        defer { input.deallocate() }
        var state: UInt32 = 0x1234_5678
        for index in 0..<blockFrames {
            state = state &* 1_664_525 &+ 1_013_904_223
            input[index] = (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.5
        }

        final class RenderContext {
            let source: UnsafeMutablePointer<Float>
            let frames: Int
            init(source: UnsafeMutablePointer<Float>, frames: Int) {
                self.source = source
                self.frames = frames
            }
        }
        let context = RenderContext(source: input, frames: blockFrames)

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, ioData in
                let context = Unmanaged<RenderContext>
                    .fromOpaque(refCon).takeUnretainedValue()
                guard let ioData else { return noErr }
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                for index in 0..<buffers.count {
                    if let data = buffers[index].mData {
                        let destination = data.assumingMemoryBound(to: Float.self)
                        let count = min(Int(frameCount), context.frames)
                        destination.update(from: context.source, count: count)
                    }
                }
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())

        AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        guard AudioUnitInitialize(unit) == noErr else {
            return .init(
                isAvailable: false, sampleRate: sampleRate, blockFrames: blockFrames,
                latencySeconds: 0, tailSeconds: 0,
                medianRenderSeconds: 0, worstRenderSeconds: 0)
        }
        defer { AudioUnitUninitialize(unit) }

        var latency: Float64 = 0
        var latencySize = UInt32(MemoryLayout<Float64>.size)
        AudioUnitGetProperty(
            unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
            &latency, &latencySize)

        var tail: Float64 = 0
        var tailSize = UInt32(MemoryLayout<Float64>.size)
        AudioUnitGetProperty(
            unit, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0,
            &tail, &tailSize)

        // Render repeatedly and time each pass.
        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        defer { outputStorage.deallocate() }
        let bufferList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(bufferList.unsafeMutablePointer) }
        bufferList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(blockFrames * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(outputStorage))

        var timings: [Double] = []
        timings.reserveCapacity(iterations)
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let secondsPerTick =
            (Double(timebase.numer) / Double(timebase.denom)) / 1_000_000_000

        for iteration in 0..<iterations {
            timestamp.mSampleTime = Float64(iteration * blockFrames)
            var flags = AudioUnitRenderActionFlags()
            let start = mach_absolute_time()
            let status = AudioUnitRender(
                unit, &flags, &timestamp, 0, UInt32(blockFrames),
                bufferList.unsafeMutablePointer)
            let elapsed = mach_absolute_time() - start
            guard status == noErr else { continue }
            // Discard the first few: the model's buffers and any lazy weight
            // loading land on the first renders and are not representative.
            if iteration >= 20 { timings.append(Double(elapsed) * secondsPerTick) }
        }

        guard !timings.isEmpty else {
            return .init(
                isAvailable: false, sampleRate: sampleRate, blockFrames: blockFrames,
                latencySeconds: latency, tailSeconds: tail,
                medianRenderSeconds: 0, worstRenderSeconds: 0)
        }
        let sorted = timings.sorted()
        return .init(
            isAvailable: true,
            sampleRate: sampleRate,
            blockFrames: blockFrames,
            latencySeconds: latency,
            tailSeconds: tail,
            medianRenderSeconds: sorted[sorted.count / 2],
            worstRenderSeconds: sorted[sorted.count - 1])
    }
}
