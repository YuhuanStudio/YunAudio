import AudioToolbox
import AVFoundation
import Foundation

/// Hosts `AUSoundIsolation` on the audio path.
///
/// Measured on this machine before being wired in: the unit reports 56.35 ms of
/// latency but costs at most half a millisecond per render, which is under a
/// quarter of the IO deadline at every block size from 64 to 512 frames. So it
/// runs inline on the IO thread; the workgroup-thread plan the architecture kept
/// in reserve turned out to be unnecessary.
///
/// The latency, though, is the headline. Enabling this trades 56 ms and
/// bit-exactness for Apple's voice isolation model, and the UI has to say so —
/// it is a completely different product decision from the 1.3 ms bypass path.
///
/// One further measured caveat: with this stage active the allocation tripwire
/// records roughly 0.3 allocations per IO cycle. They come from inside
/// `AudioUnitRender`, not from this file — Apple's model allocates on the
/// realtime thread. The bypass path stays at exactly zero, so enabling
/// isolation also gives up the no-allocation guarantee. It has not produced a
/// dropout in testing, but it is a broken realtime contract and is recorded
/// here rather than smoothed over.
final class VoiceIsolationUnit {
    let unit: AudioComponentInstance
    let maximumFrames: Int

    /// Filled by the IOProc before each render; the unit's input callback
    /// copies out of it.
    let inputBuffer: UnsafeMutablePointer<Float>
    let outputBuffer: UnsafeMutablePointer<Float>
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private var timestamp = AudioTimeStamp()

    /// Latency the unit reports, in frames at the configured rate.
    let latencyFrames: Int

    init?(sampleRate: Double, maximumFrames: Int) {
        self.maximumFrames = maximumFrames

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: SoundIsolation.componentSubType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }

        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &instance) == noErr,
            let created = instance
        else { return nil }
        unit = created

        inputBuffer = .allocate(capacity: maximumFrames)
        inputBuffer.initialize(repeating: 0, count: maximumFrames)
        outputBuffer = .allocate(capacity: maximumFrames)
        outputBuffer.initialize(repeating: 0, count: maximumFrames)

        bufferList = AudioBufferList.allocate(maximumBuffers: 1)
        bufferList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(maximumFrames * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(outputBuffer))

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

        var frames = UInt32(maximumFrames)
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &frames, UInt32(MemoryLayout<UInt32>.size))

        // The input callback reads from `inputBuffer`, which the IOProc fills
        // just before calling render. Passing the buffer pointer rather than
        // self keeps the callback free of any object reference.
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, ioData in
                guard let ioData else { return noErr }
                let source = refCon.assumingMemoryBound(to: Float.self)
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                for index in 0..<buffers.count {
                    guard let data = buffers[index].mData else { continue }
                    data.assumingMemoryBound(to: Float.self)
                        .update(from: source, count: Int(frameCount))
                }
                return noErr
            },
            inputProcRefCon: UnsafeMutableRawPointer(inputBuffer))
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        guard AudioUnitInitialize(unit) == noErr else {
            AudioComponentInstanceDispose(unit)
            inputBuffer.deallocate()
            outputBuffer.deallocate()
            return nil
        }

        var latency: Float64 = 0
        var latencySize = UInt32(MemoryLayout<Float64>.size)
        AudioUnitGetProperty(
            unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
            &latency, &latencySize)
        latencyFrames = Int(latency * sampleRate)

        timestamp.mFlags = .sampleTimeValid
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        free(bufferList.unsafeMutablePointer)
        inputBuffer.deallocate()
        outputBuffer.deallocate()
    }

    /// Sets the wet/dry mix, 0…100.
    func setMix(_ percent: Float) {
        AudioUnitSetParameter(
            unit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
            kAudioUnitScope_Global, 0, percent, 0)
    }

    /// What the unit is holding, rather than what it was last told.
    ///
    /// The distinction matters: a unit rebuilt on a route edit comes up at its
    /// own default, and nothing but asking it can tell that apart from the
    /// value somebody chose.
    var mix: Float {
        var value: AudioUnitParameterValue = 0
        guard
            AudioUnitGetParameter(
                unit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
                kAudioUnitScope_Global, 0, &value) == noErr
        else { return 0 }
        return value
    }

    /// Chooses the model. High quality is macOS 15+.
    func setHighQuality(_ isHighQuality: Bool) {
        AudioUnitSetParameter(
            unit, AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate),
            kAudioUnitScope_Global, 0,
            isHighQuality
                ? Float(kAUSoundIsolationSoundType_HighQualityVoice)
                : Float(kAUSoundIsolationSoundType_Voice),
            0)
    }

    /// Renders `frames` from `inputBuffer` into `outputBuffer`.
    ///
    /// Called on the IO thread. Nothing here allocates, but `AudioUnitRender`
    /// itself does — see the note on the type. Do not restore a
    /// "allocates nothing" claim to this comment.
    @inline(__always)
    func render(frames: Int, sampleTime: Float64) -> Bool {
        timestamp.mSampleTime = sampleTime
        bufferList[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
        var flags = AudioUnitRenderActionFlags()
        return AudioUnitRender(
            unit, &flags, &timestamp, 0, UInt32(frames),
            bufferList.unsafeMutablePointer) == noErr
    }
}

/// Realtime-visible handle to the isolation stage.
///
/// The unit itself is a Swift class, so the IOProc never touches it directly —
/// it goes through the unmanaged pointer stored here, which costs no retain.
struct RTVoiceIsolation {
    /// Non-zero when the stage should run.
    var enabled: Int32
    /// Which input buffer and channel feed the model. Ignored when
    /// `sourceIsCancelled` is set, since that signal is not in the input list.
    var sourceBuffer: Int32
    var sourceChannel: Int32
    /// Non-zero when the model should read the echo-cancelled microphone
    /// instead. Processing the aggregate's input while the canceller owns the
    /// microphone would process the wrong signal and then discard it.
    var sourceIsCancelled: Int32
    /// `Unmanaged<VoiceIsolationUnit>.toOpaque()`.
    var unit: UnsafeMutableRawPointer
    var inputBuffer: UnsafeMutablePointer<Float>
    var outputBuffer: UnsafeMutablePointer<Float>
    var maximumFrames: Int32
    /// Set by the IOProc when a render fails, so the control thread can report
    /// it instead of the stage silently passing audio through unprocessed.
    var renderFailures: UnsafeMutablePointer<UInt64>
}

/// Realtime-visible state for handing one processing path to another.
///
/// The Swift objects behind `oldStage`, `newStage` and `controller` are retained
/// by `RoutingEngine`; this record contains only unmanaged pointers and
/// preallocated mono buffers. It is moved between graphs using the same cycle
/// fence as `RTVoiceIsolation`.
struct RTEffectTransition {
    var sourceBuffer: Int32
    var sourceChannel: Int32
    var sourceIsCancelled: Int32
    var oldStage: UnsafeMutablePointer<RTVoiceIsolation>?
    var oldIsChain: Int32
    var newStage: UnsafeMutablePointer<RTVoiceIsolation>?
    var newIsChain: Int32
    var controller: UnsafeMutableRawPointer
    var rawBuffer: UnsafeMutablePointer<Float>
    var outputBuffer: UnsafeMutablePointer<Float>
    var maximumFrames: Int32
    var oldAlignmentFrames: Int32
    var newAlignmentFrames: Int32
    /// Timeline position at the start of this IO cycle. Published before the
    /// route loop so every bypass path uses the same crossfade gains.
    var cycleTimelineStart: Int64

    static func allocate(
        sourceBuffer: Int32, sourceChannel: Int32, sourceIsCancelled: Bool,
        oldStage: UnsafeMutablePointer<RTVoiceIsolation>?, oldIsChain: Bool,
        newStage: UnsafeMutablePointer<RTVoiceIsolation>?, newIsChain: Bool,
        controller: EffectTransition, maximumFrames: Int,
        oldAlignmentFrames: Int, newAlignmentFrames: Int
    ) -> UnsafeMutablePointer<RTEffectTransition> {
        let capacity = max(1, maximumFrames)
        let raw = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        raw.initialize(repeating: 0, count: capacity)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        output.initialize(repeating: 0, count: capacity)
        let block = UnsafeMutablePointer<RTEffectTransition>.allocate(capacity: 1)
        block.initialize(
            to: RTEffectTransition(
                sourceBuffer: sourceBuffer,
                sourceChannel: sourceChannel,
                sourceIsCancelled: sourceIsCancelled ? 1 : 0,
                oldStage: oldStage,
                oldIsChain: oldIsChain ? 1 : 0,
                newStage: newStage,
                newIsChain: newIsChain ? 1 : 0,
                controller: Unmanaged.passUnretained(controller).toOpaque(),
                rawBuffer: raw,
                outputBuffer: output,
                maximumFrames: Int32(capacity),
                oldAlignmentFrames: Int32(max(0, oldAlignmentFrames)),
                newAlignmentFrames: Int32(max(0, newAlignmentFrames)),
                cycleTimelineStart: 0))
        return block
    }

    static func deallocate(_ block: UnsafeMutablePointer<RTEffectTransition>) {
        let capacity = Int(block.pointee.maximumFrames)
        block.pointee.rawBuffer.deinitialize(count: capacity)
        block.pointee.rawBuffer.deallocate()
        block.pointee.outputBuffer.deinitialize(count: capacity)
        block.pointee.outputBuffer.deallocate()
        block.deinitialize(count: 1)
        block.deallocate()
    }
}
