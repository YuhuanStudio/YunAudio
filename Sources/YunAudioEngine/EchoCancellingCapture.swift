import AudioToolbox
import AVFoundation
import Foundation
import YunAudioHAL

enum EchoCancellationUnitSetupStep: String, CaseIterable, Sendable {
    case enableInput
    case enableOutput
    case setCurrentDevice
    case readCurrentDevice
    case setCaptureFormat
    case setRenderFormat
    case setMaximumFrames
    case disableAutomaticGain
    case setInputCallback
    case setRenderCallback
    case initialise
}

struct EchoCancellationUnitSetupFailure: Sendable, Equatable {
    let step: EchoCancellationUnitSetupStep
    let status: OSStatus
    let expectedDeviceID: AudioObjectID?
    let actualDeviceID: AudioObjectID?

    init(
        step: EchoCancellationUnitSetupStep,
        status: OSStatus,
        expectedDeviceID: AudioObjectID? = nil,
        actualDeviceID: AudioObjectID? = nil
    ) {
        self.step = step
        self.status = status
        self.expectedDeviceID = expectedDeviceID
        self.actualDeviceID = actualDeviceID
    }
}

struct EchoCancellationUnitSetupOperations {
    let setProperty:
        (
            AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
            UnsafeRawPointer, UInt32
        ) -> OSStatus
    let getProperty:
        (
            AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
            UnsafeMutableRawPointer, inout UInt32
        ) -> OSStatus
    let initialise: () -> OSStatus
}

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
    private struct CallbackDiagnostics {
        var inputCallbacks: UInt64 = 0
        var farEndCallbacks: UInt64 = 0
        var renderFailures: UInt64 = 0
        var lastRenderStatus: OSStatus = noErr
    }
    private let callbackDiagnostics: UnsafeMutablePointer<CallbackDiagnostics>

    /// Non-zero means the device handed over more frames per pull than this
    /// object was sized for, and some audio was dropped.
    public var truncatedBlockCount: UInt64 { truncatedBlocks.pointee }
    public var inputCallbackCount: UInt64 { callbackDiagnostics.pointee.inputCallbacks }
    public var farEndCallbackCount: UInt64 { callbackDiagnostics.pointee.farEndCallbacks }
    public var renderFailureCount: UInt64 { callbackDiagnostics.pointee.renderFailures }
    public var lastRenderStatus: OSStatus { callbackDiagnostics.pointee.lastRenderStatus }

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
    ///   - requiredSampleRate: Rate of the frame consumer. A ring does not
    ///     resample, so a dedicated microphone/speaker pair has to present this
    ///     exact rate before the unit may exchange frames with that consumer.
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
    public init?(
        microphoneUID: String,
        speakerUID: String?,
        requiredSampleRate: Double? = nil,
        maximumFrames: Int = 512
    ) {

        // Bind the two devices into one duplex object when both are named.
        var builtAggregate: AggregateDevice?
        var boundDeviceID: AudioObjectID?
        var rate: Double = 48000
        var ratesToRestoreOnFailure: [String: Double] = [:]
        var keepsAlignedRates = false
        defer {
            if !keepsAlignedRates {
                AggregateDevice.restoreSampleRates(ratesToRestoreOnFailure)
            }
        }

        if let speakerUID {
            guard
                let microphone = try? AudioDevices.device(uid: microphoneUID),
                let speaker = try? AudioDevices.device(uid: speakerUID),
                let selectedRate = Self.sampleRate(
                    microphoneRates: microphone.availableSampleRates,
                    speakerRates: speaker.availableSampleRates,
                    requiredRate: requiredSampleRate)
            else { return nil }
            let members = [microphone, speaker]
            rate = selectedRate
            guard
                let alignedRates = try? AggregateDevice.alignSampleRate(
                    rate, across: members)
            else { return nil }
            ratesToRestoreOnFailure = alignedRates
            restorableRates = alignedRates

            guard
                let dedicated = try? AggregateDevice(
                    name: "YunAudio Echo Cancellation",
                    subDevices: [
                        .init(uid: microphoneUID, driftCompensation: false),
                        .init(uid: speakerUID, driftCompensation: true),
                    ],
                    clockMasterUID: microphoneUID)
            else { return nil }
            builtAggregate = dedicated
            boundDeviceID = dedicated.id
        } else if let microphone = try? AudioDevices.device(uid: microphoneUID) {
            let currentRate = microphone.currentSampleRate ?? 48000
            if let requiredSampleRate,
                !EchoCancellationRateContract.ratesMatch(
                    currentRate, requiredSampleRate)
            {
                return nil
            }
            rate = currentRate
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
        callbackDiagnostics = .allocate(capacity: 1)
        callbackDiagnostics.initialize(to: CallbackDiagnostics())
        bufferList = AudioBufferList.allocate(maximumBuffers: 1)
        bufferList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(capacity * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(captureBuffer))

        let context = Unmanaged.passUnretained(callbacks).toOpaque()

        var inputCallback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timestamp, bus, frameCount, _ -> OSStatus in
                let box = Unmanaged<Callbacks>.fromOpaque(refCon).takeUnretainedValue()
                guard let handler = box.capture else { return noErr }
                // Pull the cancelled microphone out of element 1.
                let owner = box.owner
                guard let owner else { return noErr }
                owner.callbackDiagnostics.pointee.inputCallbacks &+= 1
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
                guard status == noErr else {
                    owner.callbackDiagnostics.pointee.renderFailures &+= 1
                    owner.callbackDiagnostics.pointee.lastRenderStatus = status
                    return status
                }
                handler(owner.captureBuffer, frames, timestamp.pointee)
                return noErr
            },
            inputProcRefCon: context)

        var renderCallback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, ioData -> OSStatus in
                guard let ioData else { return noErr }
                let box = Unmanaged<Callbacks>.fromOpaque(refCon).takeUnretainedValue()
                box.owner?.callbackDiagnostics.pointee.farEndCallbacks &+= 1
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                for index in 0..<buffers.count {
                    guard let data = buffers[index].mData else { continue }
                    let buffer = buffers[index]
                    guard buffer.mNumberChannels == 1 else {
                        // The unit is explicitly configured as mono. If it ever
                        // hands over another layout, silence only the storage it
                        // actually supplied rather than guessing a stride.
                        memset(data, 0, Int(buffer.mDataByteSize))
                        continue
                    }
                    let destination = data.assumingMemoryBound(to: Float.self)
                    _ = EchoCancellingCapture.fillFarEnd(
                        into: destination,
                        requestedFrames: Int(frameCount),
                        sampleCapacity: Int(buffer.mDataByteSize)
                            / MemoryLayout<Float>.size,
                        provider: box.farEnd)
                }
                return noErr
            },
            inputProcRefCon: context)

        callbacks.owner = self

        let operations = EchoCancellationUnitSetupOperations(
            setProperty: { property, scope, element, data, size in
                AudioUnitSetProperty(
                    created, property, scope, element, data, size)
            },
            getProperty: { property, scope, element, data, size in
                AudioUnitGetProperty(
                    created, property, scope, element, data, &size)
            },
            initialise: { AudioUnitInitialize(created) })
        let setupFailure = Self.setupVoiceProcessingUnit(
            boundDeviceID: boundDeviceID,
            sampleRate: rate,
            maximumFrames: maximumFrames,
            inputCallback: &inputCallback,
            renderCallback: &renderCallback,
            operations: operations)
        guard setupFailure == nil else {
            AudioComponentInstanceDispose(unit)
            captureBuffer.deallocate()
            truncatedBlocks.deinitialize(count: 1)
            truncatedBlocks.deallocate()
            callbackDiagnostics.deinitialize(count: 1)
            callbackDiagnostics.deallocate()
            free(bufferList.unsafeMutablePointer)
            builtAggregate?.destroy()
            return nil
        }
        keepsAlignedRates = true
    }

    /// Chooses one exact clock for the microphone and speaker.
    ///
    /// The standalone capture keeps its established voice-oriented preference
    /// for 48 kHz. A bridge supplies `requiredRate`, because frames crossing a
    /// ring have no metadata with which a downstream consumer could discover
    /// that they need resampling.
    static func sampleRate(
        microphoneRates: [Double],
        speakerRates: [Double],
        requiredRate: Double?
    ) -> Double? {
        let microphone = Set(microphoneRates.filter { $0.isFinite && $0 > 0 })
        let speaker = Set(speakerRates.filter { $0.isFinite && $0 > 0 })
        let shared = microphone.intersection(speaker)
        guard !shared.isEmpty else { return nil }

        if let requiredRate {
            guard requiredRate.isFinite, requiredRate > 0 else { return nil }
            return shared.first {
                EchoCancellationRateContract.ratesMatch($0, requiredRate)
            }
        }
        return shared.contains(48_000) ? 48_000 : shared.max()
    }

    /// Applies every property required for the callback's memory and device
    /// contracts, then initialises the unit only after they have all held.
    ///
    /// Keeping the operations injectable makes the failure order measurable
    /// without opening a microphone or changing the machine's default device.
    static func setupVoiceProcessingUnit(
        boundDeviceID: AudioObjectID?,
        sampleRate: Double,
        maximumFrames: Int,
        inputCallback: inout AURenderCallbackStruct,
        renderCallback: inout AURenderCallbackStruct,
        operations: EchoCancellationUnitSetupOperations
    ) -> EchoCancellationUnitSetupFailure? {
        func failure(
            _ step: EchoCancellationUnitSetupStep, _ status: OSStatus
        ) -> EchoCancellationUnitSetupFailure? {
            status == noErr ? nil : .init(step: step, status: status)
        }

        var enable: UInt32 = 1
        let valueSize = UInt32(MemoryLayout<UInt32>.size)
        var status = operations.setProperty(
            kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enable, valueSize)
        if let failure = failure(.enableInput, status) { return failure }

        status = operations.setProperty(
            kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &enable, valueSize)
        if let failure = failure(.enableOutput, status) { return failure }

        if let boundDeviceID {
            var requestedDeviceID = boundDeviceID
            let deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
            status = operations.setProperty(
                kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &requestedDeviceID, deviceSize)
            if let failure = failure(.setCurrentDevice, status) { return failure }

            var actualDeviceID = AudioObjectID(kAudioObjectUnknown)
            var actualSize = deviceSize
            status = operations.getProperty(
                kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &actualDeviceID, &actualSize)
            if status != noErr || actualSize != deviceSize {
                return .init(
                    step: .readCurrentDevice,
                    status: status == noErr ? OSStatus(-50) : status,
                    expectedDeviceID: boundDeviceID,
                    actualDeviceID: actualDeviceID)
            }
            guard actualDeviceID == boundDeviceID else {
                return .init(
                    step: .readCurrentDevice,
                    status: noErr,
                    expectedDeviceID: boundDeviceID,
                    actualDeviceID: actualDeviceID)
            }
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        // Element 1 output scope is the microphone as this unit hands it out;
        // element 0 input scope is the far end going towards the speaker.
        status = operations.setProperty(
            kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &format, formatSize)
        if let failure = failure(.setCaptureFormat, status) { return failure }

        status = operations.setProperty(
            kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, formatSize)
        if let failure = failure(.setRenderFormat, status) { return failure }

        guard maximumFrames > 0, maximumFrames <= Int(UInt32.max) else {
            return .init(step: .setMaximumFrames, status: OSStatus(-50))
        }
        var frames = UInt32(maximumFrames)
        status = operations.setProperty(
            kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &frames, valueSize)
        if let failure = failure(.setMaximumFrames, status) { return failure }

        // Automatic gain control belongs to the conferencing application, not
        // to a router sitting in front of it. Two AGCs fighting is what makes a
        // voice pump, so failing to turn this one off is a setup failure.
        var agc: UInt32 = 0
        status = operations.setProperty(
            AudioUnitPropertyID(kAUVoiceIOProperty_VoiceProcessingEnableAGC),
            kAudioUnitScope_Global, 0, &agc, valueSize)
        if let failure = failure(.disableAutomaticGain, status) { return failure }

        status = operations.setProperty(
            kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if let failure = failure(.setInputCallback, status) { return failure }

        status = operations.setProperty(
            kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if let failure = failure(.setRenderCallback, status) { return failure }

        status = operations.initialise()
        return failure(.initialise, status)
    }

    /// Fills one mono far-end buffer without trusting either side of the
    /// callback boundary to describe more storage than exists.
    ///
    /// `frameCount` is the unit's request; `mDataByteSize` is the buffer's hard
    /// memory bound. A provider's return value is only a report and can be
    /// negative or larger than the request. Clamping all three facts before
    /// clearing the tail keeps a short read from becoming an underwrite or
    /// overwrite.
    @inline(__always)
    static func fillFarEnd(
        into destination: UnsafeMutablePointer<Float>,
        requestedFrames: Int,
        sampleCapacity: Int,
        provider: FarEndProvider?
    ) -> FarEndFillResult {
        let request = max(0, requestedFrames)
        let capacity = max(0, sampleCapacity)
        let frames = min(request, capacity)
        let reported = frames > 0 ? (provider?(destination, frames) ?? 0) : 0
        let written = min(max(0, reported), frames)

        // Silence the tail rather than leaving stale audio there: stale
        // reference becomes a phantom the canceller then tries to remove from
        // the microphone.
        if written < frames {
            destination.advanced(by: written)
                .update(repeating: 0, count: frames - written)
        }
        return FarEndFillResult(
            requestedFrames: request,
            bufferFrames: frames,
            writtenFrames: written)
    }

    deinit {
        stop()
        AggregateDevice.restoreSampleRates(restorableRates)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        captureBuffer.deallocate()
        truncatedBlocks.deinitialize(count: 1)
        truncatedBlocks.deallocate()
        callbackDiagnostics.deinitialize(count: 1)
        callbackDiagnostics.deallocate()
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

struct FarEndFillResult: Sendable, Equatable {
    let requestedFrames: Int
    let bufferFrames: Int
    let writtenFrames: Int
}
