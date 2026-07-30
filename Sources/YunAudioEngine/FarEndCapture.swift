import CoreAudio
import Foundation
import YunAudioHAL
import YunAudioRT

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
        var scratchCapacity: Int32
    }

    private let tap: ProcessTap
    private let aggregate: AggregateDevice
    private let context: UnsafeMutablePointer<Context>
    private let ring: OpaquePointer
    private var procID: AudioDeviceIOProcID?
    private var isRunning = false

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
    public init?(
        processIDs: [AudioObjectID],
        muteBehavior: TapMuteBehavior = .mutedWhenTapped,
        ringSeconds: Double = 0.25
    ) {
        guard !processIDs.isEmpty,
            let tap = try? ProcessTap(processIDs: processIDs, muteBehavior: muteBehavior)
        else { return nil }
        self.tap = tap

        // Unknown is not 48 kHz. Treating a missing format as that convenient
        // default would let this ring pass the rate contract with no evidence
        // that its frames use the same clock as the canceller.
        guard let format = tap.format,
            format.mSampleRate.isFinite, format.mSampleRate > 0,
            Self.supportsTapFormat(format)
        else { return nil }
        sampleRate = format.mSampleRate
        sourceChannels = Int(format.mChannelsPerFrame)

        guard
            let aggregate = try? AggregateDevice(
                name: "YunAudio Far End", tapsOnly: [tap])
        else { return nil }
        self.aggregate = aggregate

        guard let ring = yun_rt_ring_create(UInt32(sampleRate * ringSeconds)) else {
            return nil
        }
        self.ring = ring

        // Sized for a generous block; the IOProc refuses to write more than
        // this rather than growing a buffer on the realtime thread.
        let scratchCapacity = 8192
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)

        context = .allocate(capacity: 1)
        context.initialize(
            to: Context(
                ring: ring, scratch: scratch,
                scratchCapacity: Int32(scratchCapacity)))
    }

    /// Whether the callback can interpret the tap without conversion.
    ///
    /// The realtime path reads `Float` directly and derives each buffer's
    /// stride from `mNumberChannels`. Packed float32 is therefore a contract,
    /// not a convenient cast; padded or integer PCM would need an explicit
    /// converter before it reached this callback.
    static func supportsTapFormat(_ format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
            format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
            format.mBitsPerChannel == 32,
            format.mChannelsPerFrame > 0
        else { return false }

        let nonInterleaved =
            format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let expectedBytes =
            UInt32(MemoryLayout<Float>.size)
            * (nonInterleaved ? 1 : format.mChannelsPerFrame)
        return format.mBytesPerFrame == expectedBytes
    }

    deinit {
        stop()
        if let procID { AudioDeviceDestroyIOProcID(aggregate.id, procID) }
        aggregate.destroy()
        tap.destroy()
        context.pointee.scratch.deallocate()
        context.deinitialize(count: 1)
        context.deallocate()
        yun_rt_ring_free(ring)
    }

    public func start() -> Bool {
        guard !isRunning else { return true }

        var created: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            aggregate.id, Self.ioProc, UnsafeMutableRawPointer(context), &created)
        guard status == noErr, let created else { return false }
        procID = created

        guard AudioDeviceStart(aggregate.id, created) == noErr else {
            AudioDeviceDestroyIOProcID(aggregate.id, created)
            procID = nil
            return false
        }
        isRunning = true
        return true
    }

    public func stop() {
        guard isRunning, let procID else { return }
        AudioDeviceStop(aggregate.id, procID)
        isRunning = false
    }

    /// Drains mono frames for the canceller to render. Realtime-safe on the
    /// caller's thread: never blocks, never allocates.
    ///
    /// - Returns: Frames actually available, which may be fewer than asked for
    ///   while the tap is still filling. The caller is expected to silence the
    ///   tail rather than leave stale audio there.
    @inline(__always)
    public func read(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        Int(yun_rt_ring_read(ring, buffer, UInt32(frames)))
    }

    /// Frames the tap produced that the canceller never collected. Non-zero
    /// means the two threads are running at genuinely different rates, not that
    /// one of them stuttered — the ring holds a quarter of a second.
    public var droppedFrames: UInt64 { yun_rt_ring_dropped(ring) }

    /// Frames the tap has produced. Distinguishes "the application is silent"
    /// from "the tap never started", which the fill level alone cannot: a ring
    /// that is being drained as fast as it fills looks empty either way.
    public var producedFrames: UInt32 { yun_rt_ring_written(ring) }

    /// Frames sitting in the ring. Steady is healthy; climbing means the
    /// canceller is consuming slower than the tap produces.
    public var bufferedFrames: UInt32 { yun_rt_ring_available(ring) }

    // MARK: Realtime

    /// The IOProc. A free C function: no Swift object is reachable from here,
    /// so nothing can retain, release or allocate.
    private static let ioProc: AudioDeviceIOProc = {
        _, _, inputData, _, _, _, clientData in
        guard let clientData else { return noErr }
        let context = clientData.assumingMemoryBound(to: Context.self)
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        let frames = FarEndCapture.downmix(
            buffers,
            into: context.pointee.scratch,
            capacity: Int(context.pointee.scratchCapacity))
        guard frames > 0 else { return noErr }
        _ = yun_rt_ring_write(
            context.pointee.ring, context.pointee.scratch, UInt32(frames))
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
        guard capacity > 0 else { return 0 }

        var totalChannels = 0
        var frames = capacity
        var hasPopulatedBuffer = false
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            totalChannels += channels
            guard buffer.mData != nil else { continue }
            let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            frames = min(frames, samples / channels)
            hasPopulatedBuffer = true
        }
        guard hasPopulatedBuffer, totalChannels > 0, frames > 0 else { return 0 }

        // Average rather than sum: a stereo far end summed to mono would sit
        // 6 dB hot, and the canceller matches levels as well as waveforms.
        let scale = 1 / Float(totalChannels)
        for frame in 0..<frames {
            var total: Float = 0
            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let raw = buffer.mData else { continue }
                let source = raw.assumingMemoryBound(to: Float.self)
                let offset = frame * channels
                for channel in 0..<channels {
                    total += source[offset + channel]
                }
            }
            destination[frame] = total * scale
        }
        return frames
    }
}
