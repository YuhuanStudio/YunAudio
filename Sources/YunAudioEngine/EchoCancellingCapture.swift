import AudioToolbox
import AVFoundation
import Foundation
import YunAudioHAL

/// Captures a microphone with acoustic echo cancellation.
///
/// `AUVoiceProcessingIO` is one IO unit bound to one device, so the microphone
/// it cancels for and the speaker it cancels against have to be the same
/// CoreAudio object. A laptop's built-in microphone and speakers are two
/// separate devices, which is why binding the unit directly to the microphone
/// fails with `kAudioUnitErr_FormatNotSupported`.
///
/// The fix is to give it a device that is both: a private aggregate holding the
/// chosen microphone and the chosen speaker. That is the same machinery the
/// router already uses, pointed at a different problem.
///
/// The far end — what the other person is saying — has to be rendered *through*
/// this unit for it to have anything to cancel. Feeding it from a process tap on
/// the conferencing application is what closes that loop without asking the user
/// to reconfigure anything.
public final class EchoCancellingCapture {
    /// Frames of echo-cancelled microphone audio, mono float32.
    public typealias CaptureHandler =
        @Sendable (
            UnsafePointer<Float>, Int, AudioTimeStamp
        ) -> Void

    /// Fills the far-end buffer with what should be played to the speaker.
    /// Return the number of frames written; anything short is treated as silence.
    public typealias FarEndProvider =
        @Sendable (
            UnsafeMutablePointer<Float>, Int
        ) -> Int

    private let unit: AudioComponentInstance
    private let aggregate: AggregateDevice?
    private let maximumFrames: Int
    public let sampleRate: Double

    private let captureBuffer: UnsafeMutablePointer<Float>
    private let bufferList: UnsafeMutableAudioBufferListPointer

    /// Blocks the device asked for that did not fit and were truncated.
    ///
    /// Manually allocated rather than a stored property because the callback
    /// reaches it from a realtime thread through an unowned reference, and a
    /// non-zero value has to be reportable rather than merely not crashing.
    private let truncatedBlocks: UnsafeMutablePointer<UInt64>

    /// Non-zero means the device handed over more frames per pull than this
    /// object was sized for, and some audio was dropped.
    public var truncatedBlockCount: UInt64 { truncatedBlocks.pointee }

    /// Boxed so the C render callbacks can reach them through a raw pointer
    /// without any Swift object being retained on the realtime thread.
    private final class Callbacks {
        var capture: CaptureHandler?
        var farEnd: FarEndProvider?
        /// Set immediately after init so the C callbacks can reach the owning
        /// instance. Unowned because they never outlive it — `stop()` runs in
        /// `deinit` before anything is torn down.
        unowned var owner: EchoCancellingCapture?
    }
    private let callbacks = Callbacks()
    private var isRunning = false
    /// Rates to put back when this capture goes away.
    private var restorableRates: [String: Double] = [:]

    /// - Parameters:
    ///   - microphoneUID: The microphone to capture.
    ///   - speakerUID: The speaker whose output should be cancelled out of it.
    ///     Pass nil to leave the unit on the system defaults, which the HAL will
    ///     pair for it.
    ///   - maximumFrames: Lower bound on the block size to allocate for. The
    ///     actual size comes from the device this unit ends up bound to, which
    ///     is the only thing that decides how much it will hand over per pull.
    ///
    ///     Passing the router's own buffer size here was the mistake that made
    ///     this class corrupt the heap: the canceller's aggregate is a different
    ///     device with a buffer size of its own, and it was observed asking for
    ///     1394 frames against the 512 the caller had derived from the router.
    ///     `AudioUnitRender` then wrote 3528 bytes past the end of the capture
    ///     buffer on every cycle. The clamp in the callback below means an
    ///     underestimate can now only cost audio, never memory.
    public init?(microphoneUID: String, speakerUID: String?, maximumFrames: Int = 512) {

        // Bind the two devices into one duplex object when both are named.
        var builtAggregate: AggregateDevice?
        var boundDeviceID: AudioObjectID?
        var rate: Double = 48000

        if let speakerUID,
            let microphone = try? AudioDevices.device(uid: microphoneUID),
            let speaker = try? AudioDevices.device(uid: speakerUID)
        {
            let members = [microphone, speaker]
            // 48 kHz unless neither device offers it: echo cancellation is a
            // voice feature and gains nothing from a higher rate.
            let shared = Set(microphone.availableSampleRates)
                .intersection(speaker.availableSampleRates)
            rate = shared.contains(48000) ? 48000 : (shared.max() ?? 48000)
            restorableRates =
                (try? AggregateDevice.alignSampleRate(rate, across: members)) ?? [:]

            builtAggregate = try? AggregateDevice(
                name: "YunAudio Echo Cancellation",
                subDevices: [
                    .init(uid: microphoneUID, driftCompensation: false),
                    .init(uid: speakerUID, driftCompensation: true),
                ],
                clockMasterUID: microphoneUID)
            boundDeviceID = builtAggregate?.id
        } else if let microphone = try? AudioDevices.device(uid: microphoneUID) {
            rate = microphone.currentSampleRate ?? 48000
        }
        aggregate = builtAggregate
        sampleRate = rate

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: EchoCancellation.componentSubType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }

        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let created = instance
        else { return nil }
        unit = created

        // Sized from the device that will actually drive this unit, not from
        // whatever the caller guessed. A device's buffer frame size can be
        // changed underneath us as well, so the allocation carries generous
        // headroom on top of it rather than matching it exactly.
        let deviceFrames =
            boundDeviceID.flatMap { id -> Int? in
                var size = UInt32(MemoryLayout<UInt32>.size)
                var value: UInt32 = 0
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyBufferFrameSize,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                guard
                    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
                else { return nil }
                return Int(value)
            } ?? 0
        let capacity = max(maximumFrames, deviceFrames * 4, 8192)
        self.maximumFrames = capacity

        captureBuffer = .allocate(capacity: capacity)
        captureBuffer.initialize(repeating: 0, count: capacity)
        truncatedBlocks = .allocate(capacity: 1)
        truncatedBlocks.initialize(to: 0)
        bufferList = AudioBufferList.allocate(maximumBuffers: 1)
        bufferList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(capacity * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(captureBuffer))

        var enable: UInt32 = 1
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enable, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &enable, UInt32(MemoryLayout<UInt32>.size))

        if let boundDeviceID {
            var deviceID = boundDeviceID
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioObjectID>.size))
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        // Element 1 output scope is the microphone as this unit hands it out;
        // element 0 input scope is the far end going towards the speaker.
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &format, formatSize)
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, formatSize)

        var frames = UInt32(maximumFrames)
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &frames, UInt32(MemoryLayout<UInt32>.size))

        // Automatic gain control belongs to the conferencing application, not to
        // a router sitting in front of it. Two AGCs fighting is what makes a
        // voice pump.
        var agc: UInt32 = 0
        AudioUnitSetProperty(
            unit, AudioUnitPropertyID(kAUVoiceIOProperty_VoiceProcessingEnableAGC),
            kAudioUnitScope_Global, 0, &agc, UInt32(MemoryLayout<UInt32>.size))

        let context = Unmanaged.passUnretained(callbacks).toOpaque()

        var inputCallback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timestamp, bus, frameCount, _ -> OSStatus in
                let box = Unmanaged<Callbacks>.fromOpaque(refCon).takeUnretainedValue()
                guard let handler = box.capture else { return noErr }
                // Pull the cancelled microphone out of element 1.
                let owner = box.owner
                guard let owner else { return noErr }
                // Never render more than the buffer holds.
                //
                // `frameCount` comes from the device, and the buffer was sized
                // from what that device said it would ask for — but a device is
                // free to change its buffer size while running, and nothing
                // here would hear about it before the next pull. Without this
                // clamp that reconfiguration is a heap overflow rather than a
                // glitch, and the process dies somewhere unrelated minutes
                // later. Truncating loses a fraction of a block of audio and
                // says so.
                let wanted = Int(frameCount)
                let frames = min(wanted, owner.maximumFrames)
                if frames < wanted { owner.truncatedBlocks.pointee &+= 1 }
                owner.bufferList[0].mDataByteSize =
                    UInt32(frames * MemoryLayout<Float>.size)
                let status = AudioUnitRender(
                    owner.unit, flags, timestamp, bus, UInt32(frames),
                    owner.bufferList.unsafeMutablePointer)
                guard status == noErr else { return status }
                handler(owner.captureBuffer, frames, timestamp.pointee)
                return noErr
            },
            inputProcRefCon: context)
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        var renderCallback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, ioData -> OSStatus in
                guard let ioData else { return noErr }
                let box = Unmanaged<Callbacks>.fromOpaque(refCon).takeUnretainedValue()
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                for index in 0..<buffers.count {
                    guard let data = buffers[index].mData else { continue }
                    let destination = data.assumingMemoryBound(to: Float.self)
                    let written = box.farEnd?(destination, Int(frameCount)) ?? 0
                    if written < Int(frameCount) {
                        // Silence the tail rather than leaving whatever the
                        // buffer held: stale audio here becomes a phantom the
                        // canceller then tries to remove from the microphone.
                        destination.advanced(by: written)
                            .update(repeating: 0, count: Int(frameCount) - written)
                    }
                }
                return noErr
            },
            inputProcRefCon: context)
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        callbacks.owner = self

        guard AudioUnitInitialize(unit) == noErr else {
            AudioComponentInstanceDispose(unit)
            captureBuffer.deallocate()
            free(bufferList.unsafeMutablePointer)
            return nil
        }
    }

    deinit {
        stop()
        AggregateDevice.restoreSampleRates(restorableRates)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        captureBuffer.deallocate()
        truncatedBlocks.deinitialize(count: 1)
        truncatedBlocks.deallocate()
        free(bufferList.unsafeMutablePointer)
    }

    public func start(capture: @escaping CaptureHandler, farEnd: FarEndProvider? = nil) -> Bool
    {
        callbacks.capture = capture
        callbacks.farEnd = farEnd
        guard AudioOutputUnitStart(unit) == noErr else { return false }
        isRunning = true
        return true
    }

    /// Turns the voice processing off while leaving the same IO path in place.
    ///
    /// This is what makes the effect measurable: with bypass on and off the
    /// acoustic path, the devices, the buffer size and the signal are all
    /// identical, so the difference in what the microphone returns is the
    /// cancellation and nothing else.
    public func setBypassed(_ bypassed: Bool) {
        var value: UInt32 = bypassed ? 1 : 0
        AudioUnitSetProperty(
            unit, AudioUnitPropertyID(kAUVoiceIOProperty_BypassVoiceProcessing),
            kAudioUnitScope_Global, 0, &value, UInt32(MemoryLayout<UInt32>.size))
    }

    public func stop() {
        guard isRunning else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
        callbacks.capture = nil
        callbacks.farEnd = nil
    }

    /// True when the unit is bound to an aggregate built for it, rather than
    /// riding the system defaults.
    public var isBoundToDedicatedDevice: Bool { aggregate != nil }
}
