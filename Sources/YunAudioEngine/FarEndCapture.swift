import CoreAudio
import Foundation
import YunAudioHAL
import YunAudioRT

/// Observable shutdown result for the process-tap half of echo cancellation.
public enum FarEndCaptureTeardownResult: Sendable, Equatable {
    case complete
    case ioProcStopFailed(OSStatus)
    case ioProcDestroyFailed(OSStatus)
    case ioProcTimedOut(step: AudioIOProcTeardownStep)
    case aggregate(HALDestructionResult)
    case processTap(uid: String, result: HALDestructionResult)

    public var isComplete: Bool { self == .complete }
}

/// What the far end is saying, taken straight from the conferencing
/// application, so echo cancellation has something real to cancel.
///
/// `AUVoiceProcessingIO` removes from the microphone whatever is rendered
/// through it. Until now the only thing this project could render through it
/// was a tone it generated itself, which proved the unit works but cancelled
/// nothing anyone would encounter: the actual echo in a call is the other
/// person's voice coming out of the speakers.
///
/// A process tap on the conferencing application is that signal. The tap is not
/// readable on its own, so it goes into a private aggregate of its own with an
/// IOProc that does one thing — downmix to mono and push into a lock-free ring.
/// The voice processing unit's render callback drains that ring on a different
/// realtime thread, which is why the ring is the whole point rather than an
/// implementation detail: two IO threads, no lock between them, no allocation
/// on either.
///
/// Pair this with `CATapMuteBehavior.mutedWhenTapped` and the loop closes
/// properly: the application stops playing to the speaker itself, and what
/// reaches the speaker is what came through the canceller, so what the
/// canceller subtracts is exactly what the microphone hears.
///
/// `@unchecked Sendable` because the sharing is deliberate and narrow: the ring
/// is lock-free by construction, the IOProc context is a POD allocation that
/// outlives every callback, and the Swift object itself is never touched from
/// the realtime thread.
public final class FarEndCapture: @unchecked Sendable {

    /// Handed to the IOProc as its client data. A plain C struct: nothing here
    /// is a Swift object, so the realtime thread never touches ARC.
    private struct Context {
        var ring: OpaquePointer
        var scratch: UnsafeMutablePointer<Float>
        var scratchCapacity: UInt32
        var callbacks: OpaquePointer
    }

    private let tap: ProcessTap
    private let aggregate: AggregateDevice
    private let context: UnsafeMutablePointer<Context>
    private let ring: OpaquePointer
    private let callbacks: OpaquePointer
    private var procID: AudioDeviceIOProcID?
    private var ioProcTeardownState = AudioIOProcTeardownState()
    private var isRunning = false
    private var isFullyTornDown = false
    public private(set) var lastTeardownResult: FarEndCaptureTeardownResult?

    /// Rate the tap delivers at. The canceller has to run at the same rate;
    /// resampling here would mean cancelling a signal that no longer lines up
    /// with what the microphone heard.
    public let sampleRate: Double
    /// Channels the tap presents, before the downmix.
    public let sourceChannels: Int

    /// - Parameters:
    ///   - processIDs: HAL process objects to capture. Pass every process an
    ///     application owns — a browser splits its audio across helpers.
    ///   - muteBehavior: `.mutedWhenTapped` is the one that closes the loop;
    ///     `.unmuted` leaves the application playing to the speaker as well,
    ///     which is useful for measuring but doubles the audio.
    ///   - ringSeconds: How much slack the ring carries between the two IO
    ///     threads. A quarter second is far more than the few milliseconds of
    ///     jitter expected, and costs 48 kB.
    public convenience init?(
        processIDs: [AudioObjectID],
        muteBehavior: TapMuteBehavior = .mutedWhenTapped,
        ringSeconds: Double = 0.25
    ) {
        self.init(
            processIDs: processIDs, muteBehavior: muteBehavior,
            ringSeconds: ringSeconds, constructionContext: nil)
    }

    /// Route construction passes its cancellation boundary so a process-tap
    /// retry or aggregate creation cannot begin after the caller timed out.
    init?(
        processIDs: [AudioObjectID],
        muteBehavior: TapMuteBehavior,
        ringSeconds: Double = 0.25,
        constructionContext: AudioUnitConstructionContext?
    ) {
        guard !processIDs.isEmpty,
            EchoCancellationCapacityPolicy.isValidRingSeconds(ringSeconds),
            constructionContext?.mayBeginOperation ?? true,
            let tap = try? ProcessTap(
                processIDs: processIDs, muteBehavior: muteBehavior,
                retryAdmission: { constructionContext?.mayBeginOperation ?? true })
        else { return nil }
        constructionContext?.record(.processTap)
        guard constructionContext?.mayBeginOperation ?? true else {
            constructionContext?.retainAfterCancellation(tap)
            return nil
        }
        self.tap = tap

        // Unknown is not 48 kHz. Treating a missing format as that convenient
        // default would let this ring pass the rate contract with no evidence
        // that its frames use the same clock as the canceller.
        guard let format = tap.format,
            Self.supportsTapFormat(format),
            let allocation = EchoCancellationCapacityPolicy.ringAllocation(
                sampleRate: format.mSampleRate,
                seconds: ringSeconds,
                requestedSliceFrames:
                    AudioProcessingContract.maximumFramesPerSlice,
                sourceChannels: format.mChannelsPerFrame)
        else { return nil }
        sampleRate = format.mSampleRate
        sourceChannels = Int(format.mChannelsPerFrame)

        guard constructionContext?.mayBeginOperation ?? true else {
            constructionContext?.retainAfterCancellation(tap)
            return nil
        }
        let aggregate = try? AggregateDevice(
            name: "YunAudio Far End", tapsOnly: [tap])
        guard let aggregate else {
            if constructionContext?.mayBeginOperation == false {
                constructionContext?.retainAfterCancellation(tap)
            }
            return nil
        }
        constructionContext?.record(.aggregate)
        guard constructionContext?.mayBeginOperation ?? true else {
            constructionContext?.retainAfterCancellation(aggregate)
            constructionContext?.retainAfterCancellation(tap)
            return nil
        }
        self.aggregate = aggregate

        guard constructionContext?.mayBeginOperation ?? true else {
            constructionContext?.retainAfterCancellation(aggregate)
            constructionContext?.retainAfterCancellation(tap)
            return nil
        }
        guard let ring = yun_rt_ring_create(allocation.ringFrames) else {
            return nil
        }
        self.ring = ring
        guard let callbacks = yun_rt_counter_create(0) else {
            yun_rt_ring_free(ring)
            return nil
        }
        self.callbacks = callbacks

        // Sized for a generous block; the IOProc refuses to write more than
        // this rather than growing a buffer on the realtime thread.
        let scratchCapacity = allocation.scratchFrames
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)

        context = .allocate(capacity: 1)
        context.initialize(
            to: Context(
                ring: ring, scratch: scratch,
                scratchCapacity: allocation.scratchFrameCount,
                callbacks: callbacks))
    }

    /// Whether the callback can interpret the tap without conversion.
    ///
    /// The realtime path reads `Float` directly and derives each buffer's
    /// stride from `mNumberChannels`. Packed float32 is therefore a contract,
    /// not a convenient cast; padded or integer PCM would need an explicit
    /// converter before it reached this callback.
    static func supportsTapFormat(_ format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM,
            EchoCancellationCapacityPolicy.isValidSampleRate(format.mSampleRate),
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
            format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
            format.mBitsPerChannel == 32,
            EchoCancellationCapacityPolicy.isValidChannelCount(
                format.mChannelsPerFrame),
            format.mFramesPerPacket == 1,
            format.mReserved == 0
        else { return false }

        let nonInterleaved =
            format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard
            let expectedBytes = EchoCancellationCapacityPolicy.bytesPerFrame(
                channels: format.mChannelsPerFrame,
                nonInterleaved: nonInterleaved)
        else { return false }
        return format.mBytesPerFrame == expectedBytes
            && format.mBytesPerPacket == expectedBytes
    }

    deinit {
        // The bridge already ran the complete lifecycle on the sole bounded
        // worker. Re-entering aggregate and tap destruction here would put
        // synchronous HAL IPC back onto whichever thread released the bridge.
        let result: FarEndCaptureTeardownResult =
            isFullyTornDown ? .complete : stop()
        guard result.isComplete else {
            // A failed callback fence makes bounded leakage the only safe
            // deinitialisation policy. Keep both HAL owners; the POD callback
            // context and ring below deliberately remain allocated as well.
            _ = Unmanaged.passRetained(aggregate).toOpaque()
            _ = Unmanaged.passRetained(tap).toOpaque()
            return
        }
        context.pointee.scratch.deallocate()
        context.deinitialize(count: 1)
        context.deallocate()
        yun_rt_counter_free(callbacks)
        yun_rt_ring_free(ring)
    }

    /// Moves a partially built or unselected reference off its releasing thread.
    ///
    /// Bridge construction can reject this reference after its tap and private
    /// aggregate already exist. Letting the local value simply fall out of scope
    /// would run synchronous HAL removal in `deinit`, including on a route or UI
    /// caller. The sole lifecycle worker either proves complete teardown or
    /// retains this entire object in its process quarantine.
    func disposeAfterFence() {
        let command = BoundedAudioUnitLifecycleCommand(
            retaining: self, step: .stop, quarantineOnError: true
        ) { [self] in
            stop(until: HALTeardownDeadline(timeout: 2)).isComplete
                ? noErr : kAudioHardwareUnspecifiedError
        }
        BoundedAudioUnitDisposer.shared.disposeAfterFence(command)
    }

    public func start() -> Bool {
        guard !isRunning else { return true }
        guard !isFullyTornDown, procID == nil, ioProcTeardownState.phase == .absent else {
            return false
        }
        lastTeardownResult = nil

        let callbacksBefore = callbackCount
        var created: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            aggregate.id, Self.ioProc, UnsafeMutableRawPointer(context), &created)
        if let created {
            procID = created
            ioProcTeardownState.didCreate()
        }
        guard status == noErr, let created else {
            if let created {
                let result = ioProcTeardownState.tearDown(
                    stop: { noErr },
                    destroy: { AudioDeviceDestroyIOProcID(aggregate.id, created) })
                if result == .complete { procID = nil }
                if case .destroyFailed(let status) = result {
                    lastTeardownResult = .ioProcDestroyFailed(status)
                }
            }
            return false
        }

        guard AudioDeviceStart(aggregate.id, created) == noErr else {
            let result = ioProcTeardownState.tearDown(
                stop: { noErr },
                destroy: { AudioDeviceDestroyIOProcID(aggregate.id, created) })
            if result == .complete { procID = nil }
            if case .destroyFailed(let status) = result {
                lastTeardownResult = .ioProcDestroyFailed(status)
            }
            return false
        }
        isRunning = true
        ioProcTeardownState.didStart()
        // `AudioDeviceStart` acknowledges a request; it does not prove that
        // the tap aggregate delivered anything. Two callback entries are the
        // same numeric start boundary used by the main router, and distinguish
        // a silent application from an IOProc which never ran at all.
        let deadline = DispatchTime.now() + .milliseconds(750)
        while DispatchTime.now() < deadline {
            if Self.startWasProven(
                callbacksBefore: callbacksBefore,
                callbacksAfter: callbackCount)
            {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        // Keep the aggregate and tap owned for the bridge's ordinary Stop, but
        // fence this unproven callback before allowing blind AEC to continue.
        let cleanupDeadline = HALTeardownDeadline(timeout: 2)
        let result = ioProcTeardownState.tearDown(
            stop: {
                cleanupDeadline.perform {
                    AudioDeviceStop(aggregate.id, created)
                }
            },
            destroy: {
                cleanupDeadline.perform {
                    AudioDeviceDestroyIOProcID(aggregate.id, created)
                }
            })
        isRunning = ioProcTeardownState.phase == .running
        switch result {
        case .complete:
            procID = nil
        case .stopFailed(let status):
            lastTeardownResult = .ioProcStopFailed(status)
        case .destroyFailed(let status):
            lastTeardownResult = .ioProcDestroyFailed(status)
        case .timedOut(let step):
            lastTeardownResult = .ioProcTimedOut(step: step)
        }
        return false
    }

    /// Callback proof separated from the wait so silence and exact boundaries
    /// can be asserted without starting a live aggregate.
    static func startWasProven(
        callbacksBefore: UInt64, callbacksAfter: UInt64
    ) -> Bool {
        callbacksAfter &- callbacksBefore >= 2
    }

    /// Stops and destroys the IOProc before removing its aggregate and tap.
    /// A failed phase is retained and retried by the next call.
    @discardableResult
    public func stop(timeout: TimeInterval = 2) -> FarEndCaptureTeardownResult {
        stop(until: HALTeardownDeadline(timeout: timeout))
    }

    /// Uses the remaining portion of the enclosing route teardown.
    @discardableResult
    public func stop(until deadline: HALTeardownDeadline) -> FarEndCaptureTeardownResult {
        if let procID {
            let ioResult = ioProcTeardownState.tearDown(
                stop: {
                    deadline.perform {
                        AudioDeviceStop(aggregate.id, procID)
                    }
                },
                destroy: {
                    deadline.perform {
                        AudioDeviceDestroyIOProcID(aggregate.id, procID)
                    }
                })
            isRunning = ioProcTeardownState.phase == .running
            switch ioResult {
            case .complete:
                self.procID = nil
            case .stopFailed(let status):
                let result = FarEndCaptureTeardownResult.ioProcStopFailed(status)
                lastTeardownResult = result
                return result
            case .destroyFailed(let status):
                let result = FarEndCaptureTeardownResult.ioProcDestroyFailed(status)
                lastTeardownResult = result
                return result
            case .timedOut(let step):
                let result = FarEndCaptureTeardownResult.ioProcTimedOut(step: step)
                lastTeardownResult = result
                return result
            }
        } else if ioProcTeardownState.phase != .absent {
            let result = FarEndCaptureTeardownResult.ioProcDestroyFailed(
                kAudioHardwareBadObjectError)
            lastTeardownResult = result
            return result
        }
        isRunning = false

        let aggregateResult = aggregate.destroyAndWait(until: deadline)
        guard aggregateResult == .destroyed else {
            let result = FarEndCaptureTeardownResult.aggregate(aggregateResult)
            lastTeardownResult = result
            return result
        }

        let tapResult = tap.destroyAndWait(until: deadline)
        guard tapResult == .destroyed else {
            let result = FarEndCaptureTeardownResult.processTap(
                uid: tap.uid, result: tapResult)
            lastTeardownResult = result
            return result
        }
        isFullyTornDown = true
        lastTeardownResult = .complete
        return .complete
    }

    /// Drains mono frames for the canceller to render. Realtime-safe on the
    /// caller's thread: never blocks, never allocates.
    ///
    /// - Returns: Frames actually available, which may be fewer than asked for
    ///   while the tap is still filling. The caller is expected to silence the
    ///   tail rather than leave stale audio there.
    @inline(__always)
    public func read(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard
            let frames = EchoCancellationCapacityPolicy.requestedSliceFrames(frames)
        else { return 0 }
        return Int(yun_rt_ring_read(ring, buffer, frames))
    }

    /// Discards only the backlog visible when this call begins.
    ///
    /// Used between voice-processing start attempts, when this object remains
    /// the ring's sole consumer but its producer is still running. Draining
    /// until empty could chase that producer forever; taking one availability
    /// snapshot removes the stale attempt without consuming audio that arrives
    /// after it.
    @discardableResult
    func discardBufferedFrames(
        into scratch: UnsafeMutablePointer<Float>, capacity: Int
    ) -> Int {
        Self.discardBufferedFrames(
            from: ring, into: scratch, capacity: capacity)
    }

    static func discardBufferedFrames(
        from ring: OpaquePointer,
        into scratch: UnsafeMutablePointer<Float>,
        capacity: Int
    ) -> Int {
        guard capacity > 0,
            capacity <= EchoCancellationCapacityPolicy.scratchFrames,
            let capacity = UInt32(exactly: capacity)
        else { return 0 }
        let target = min(
            Int(yun_rt_ring_available(ring)),
            Int(EchoCancellationCapacityPolicy.maximumRingStorageFrames))
        var discarded = 0
        while discarded < target {
            let wanted = min(Int(capacity), target - discarded)
            guard let wantedFrames = UInt32(exactly: wanted) else { break }
            let taken = Int(yun_rt_ring_read(ring, scratch, wantedFrames))
            guard taken > 0 else { break }
            discarded += taken
        }
        return discarded
    }

    /// Frames the tap produced that the canceller never collected. Non-zero
    /// means the two threads are running at genuinely different rates, not that
    /// one of them stuttered — the ring holds a quarter of a second.
    public var droppedFrames: UInt64 { yun_rt_ring_dropped(ring) }

    /// Frames the tap has produced. Distinguishes "the application is silent"
    /// from "the tap never started", which the fill level alone cannot: a ring
    /// that is being drained as fast as it fills looks empty either way.
    public var producedFrames: UInt32 { yun_rt_ring_written(ring) }

    /// IOProc entries, including silent blocks. Unlike ring fill this proves
    /// that Core Audio is driving the tap even when the application emits zero.
    public var callbackCount: UInt64 { yun_rt_counter_load(callbacks) }

    /// Frames sitting in the ring. Steady is healthy; climbing means the
    /// canceller is consuming slower than the tap produces.
    public var bufferedFrames: UInt32 { yun_rt_ring_available(ring) }

    /// Raw consumer handle retained by `EchoCancellationBridge` until both
    /// callback fences hold. Exposing the ring avoids borrowing this Swift
    /// owner from AUVoiceProcessingIO's realtime render callback.
    var realtimeRing: OpaquePointer { ring }

    // MARK: Realtime

    /// The IOProc. A free C function: no Swift object is reachable from here,
    /// so nothing can retain, release or allocate.
    private static let ioProc: AudioDeviceIOProc = {
        _, _, inputData, _, _, _, clientData in
        yun_rt_tripwire_mark_realtime(true)
        defer { yun_rt_tripwire_mark_realtime(false) }
        guard let clientData else { return noErr }
        let context = clientData.assumingMemoryBound(to: Context.self)
        yun_rt_counter_increment(context.pointee.callbacks)
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        let frames = FarEndCapture.downmix(
            buffers,
            into: context.pointee.scratch,
            capacity: Int(context.pointee.scratchCapacity))
        guard
            let frameCount = EchoCancellationCapacityPolicy.requestedSliceFrames(frames)
        else { return noErr }
        _ = yun_rt_ring_write(
            context.pointee.ring, context.pointee.scratch, frameCount)
        return noErr
    }

    /// Folds every buffer and channel in one IO cycle to mono.
    ///
    /// An `AudioBufferList` may describe one interleaved buffer, one buffer per
    /// channel, or several interleaved groups. `mNumberChannels` is therefore
    /// the stride of each buffer, not a property the first buffer can stand in
    /// for. The shortest populated buffer bounds the cycle so no group can be
    /// read past its own byte count.
    @inline(__always)
    static func downmix(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        into destination: UnsafeMutablePointer<Float>,
        capacity: Int
    ) -> Int {
        guard AudioProcessingContract.supports(framesPerSlice: capacity)
        else { return 0 }

        var totalChannels = 0
        var frames = capacity
        var hasPopulatedBuffer = false
        for buffer in buffers {
            guard
                let channels = AudioProcessingContract.admittedChannelCount(
                    buffer.mNumberChannels), channels > 0
            else { return 0 }
            let (nextTotal, channelOverflow) =
                totalChannels.addingReportingOverflow(channels)
            guard !channelOverflow,
                nextTotal <= AudioProcessingContract.maximumChannelTopology
            else { return 0 }
            totalChannels = nextTotal
            guard buffer.mData != nil else { continue }
            guard
                let bytesPerFrame = EchoCancellationCapacityPolicy.bytesPerFrame(
                    channels: buffer.mNumberChannels,
                    nonInterleaved: false),
                buffer.mDataByteSize % bytesPerFrame == 0
            else { return 0 }
            frames = min(frames, Int(buffer.mDataByteSize / bytesPerFrame))
            hasPopulatedBuffer = true
        }
        guard hasPopulatedBuffer, totalChannels > 0, frames > 0 else { return 0 }

        // Average rather than sum: a stereo far end summed to mono would sit
        // 6 dB hot, and the canceller matches levels as well as waveforms.
        let scale = 1 / Float(totalChannels)
        for frame in 0..<frames {
            var total: Float = 0
            for buffer in buffers {
                guard
                    let channels = AudioProcessingContract.admittedChannelCount(
                        buffer.mNumberChannels), channels > 0
                else { return 0 }
                guard let raw = buffer.mData else { continue }
                let source = raw.assumingMemoryBound(to: Float.self)
                let (offset, offsetOverflow) =
                    frame.multipliedReportingOverflow(by: channels)
                guard !offsetOverflow else { return 0 }
                for channel in 0..<channels {
                    total += source[offset + channel]
                }
            }
            destination[frame] = total * scale
        }
        return frames
    }
}
