import AudioToolbox
import AVFoundation
import Foundation

/// One stage of the processing chain.
public enum EffectKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case voiceIsolation
    case equaliser
    case compressor
    case limiter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .voiceIsolation: "Voice isolation"
        case .equaliser: "Equaliser"
        case .compressor: "Compressor"
        case .limiter: "Limiter"
        }
    }

    public var detail: String {
        switch self {
        case .voiceIsolation: "Apple's on-device model. Adds about 56 ms."
        case .equaliser: "Ten bands of parametric EQ."
        case .compressor: "Evens out level. Useful before a limiter, not instead of one."
        case .limiter: "Stops the signal exceeding full scale. Cheap insurance."
        }
    }

    var subType: OSType {
        switch self {
        case .voiceIsolation: SoundIsolation.componentSubType
        case .equaliser: kAudioUnitSubType_NBandEQ
        case .compressor: kAudioUnitSubType_DynamicsProcessor
        case .limiter: kAudioUnitSubType_PeakLimiter
        }
    }

    /// Effects are ordered by what makes sense signal-wise regardless of the
    /// order they were switched on: isolate, then shape, then control level,
    /// then catch anything left over. A limiter ahead of a compressor is a
    /// configuration mistake the UI should not let happen.
    var chainOrder: Int {
        switch self {
        case .voiceIsolation: 0
        case .equaliser: 1
        case .compressor: 2
        case .limiter: 3
        }
    }
}

/// A series of Audio Units rendered on the IO thread.
///
/// Each stage pulls from the previous one through a render callback, which is
/// how Audio Units are meant to be chained — the alternative, rendering each
/// into a scratch buffer by hand, means one more copy per stage and no benefit.
final class EffectChain {
    /// Buffer the first stage pulls from. The IOProc fills it before rendering.
    let inputBuffer: UnsafeMutablePointer<Float>
    let outputBuffer: UnsafeMutablePointer<Float>
    let maximumFrames: Int

    private(set) var stages: [EffectKind] = []
    private var units: [AudioComponentInstance] = []
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private var timestamp = AudioTimeStamp()

    /// Total latency the chain adds, in frames.
    private(set) var latencyFrames = 0

    init?(kinds: [EffectKind], sampleRate: Double, maximumFrames: Int) {
        guard !kinds.isEmpty else { return nil }
        self.maximumFrames = maximumFrames
        stages = kinds.sorted { $0.chainOrder < $1.chainOrder }

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

        for kind in stages {
            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kind.subType,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else { continue }
            var instance: AudioComponentInstance?
            guard AudioComponentInstanceNew(component, &instance) == noErr,
                let unit = instance
            else { continue }

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
            units.append(unit)
        }

        guard !units.isEmpty else {
            inputBuffer.deallocate()
            outputBuffer.deallocate()
            free(bufferList.unsafeMutablePointer)
            return nil
        }

        // The head pulls from our staging buffer; every later stage pulls from
        // the one before it.
        var headCallback = AURenderCallbackStruct(
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
            units[0], kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &headCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        for index in 1..<units.count {
            var connection = AudioUnitConnection(
                sourceAudioUnit: units[index - 1],
                sourceOutputNumber: 0,
                destInputNumber: 0)
            AudioUnitSetProperty(
                units[index], kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0,
                &connection, UInt32(MemoryLayout<AudioUnitConnection>.size))
        }

        for unit in units where AudioUnitInitialize(unit) != noErr {
            // A stage that will not initialise is worse than no chain: the
            // signal would silently skip it while the UI claimed it was on.
            teardown()
            inputBuffer.deallocate()
            outputBuffer.deallocate()
            free(bufferList.unsafeMutablePointer)
            return nil
        }

        latencyFrames = units.reduce(into: 0) { total, unit in
            var latency: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
                &latency, &size)
            total += Int(latency * sampleRate)
        }

        applyDefaults(sampleRate: sampleRate)
        timestamp.mFlags = .sampleTimeValid
    }

    deinit {
        teardown()
        inputBuffer.deallocate()
        outputBuffer.deallocate()
        free(bufferList.unsafeMutablePointer)
    }

    private func teardown() {
        for unit in units {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        units.removeAll()
    }

    /// Starting points chosen for a voice signal rather than the units' own
    /// defaults, which are tuned for music.
    private func applyDefaults(sampleRate: Double) {
        for (index, kind) in stages.enumerated() where index < units.count {
            let unit = units[index]
            switch kind {
            case .voiceIsolation:
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
                    kAudioUnitScope_Global, 0, 100, 0)
            case .equaliser:
                // A high-pass at 80 Hz: everything below is rumble, handling
                // noise and plosive energy, none of it voice.
                var bands: UInt32 = 1
                AudioUnitSetProperty(
                    unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0,
                    &bands, UInt32(MemoryLayout<UInt32>.size))
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kAUNBandEQParam_FilterType),
                    kAudioUnitScope_Global, 0,
                    // Butterworth rather than resonant: a resonant high-pass
                    // adds a peak right where the plosive energy is.
                    Float(kAUNBandEQFilterType_2ndOrderButterworthHighPass), 0)
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kAUNBandEQParam_Frequency),
                    kAudioUnitScope_Global, 0, 80, 0)
                AudioUnitSetParameter(
                    unit, AudioUnitParameterID(kAUNBandEQParam_BypassBand),
                    kAudioUnitScope_Global, 0, 0, 0)
            case .compressor:
                // Gentle: 3:1 above -20 dBFS. A router should even out a voice,
                // not squash it — the conferencing application will apply its
                // own dynamics after this.
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -20, 0)
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 5, 0)
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.01, 0
                )
                AudioUnitSetParameter(
                    unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.15,
                    0)
            case .limiter:
                // Just below full scale, so nothing downstream ever sees a
                // sample it has to clip.
                AudioUnitSetParameter(
                    unit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
                AudioUnitSetParameter(
                    unit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
                AudioUnitSetParameter(
                    unit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
            }
        }
    }

    /// Renders `frames` from `inputBuffer` through every stage into
    /// `outputBuffer`. Called on the IO thread.
    @inline(__always)
    func render(frames: Int, sampleTime: Float64) -> Bool {
        guard let tail = units.last else { return false }
        timestamp.mSampleTime = sampleTime
        bufferList[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
        var flags = AudioUnitRenderActionFlags()
        return AudioUnitRender(
            tail, &flags, &timestamp, 0, UInt32(frames),
            bufferList.unsafeMutablePointer) == noErr
    }
}
