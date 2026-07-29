import CoreAudio
import Foundation
import YunAudioHAL
import YunAudioRT

/// What the router asks for when it wants the microphone echo-cancelled.
public struct EchoCancellationSettings: Sendable {
    /// The speaker whose output should be removed from the microphone. It has
    /// to be a real output the user is listening to; cancelling against a
    /// virtual endpoint cancels nothing, because nothing acoustic came from it.
    public var speakerUID: String
    /// HAL process objects whose audio is the far end — the conferencing
    /// application. Empty means the canceller runs with no reference, which is
    /// still useful against steady noise but will not remove a voice.
    public var farEndProcessIDs: [AudioObjectID]
    /// Whether the far-end application keeps playing to the speaker itself.
    ///
    /// `.mutedWhenTapped` is the one that closes the loop properly: the
    /// application goes quiet and what reaches the speaker is what came through
    /// the canceller, so what is subtracted is exactly what the microphone
    /// heard. Leaving it unmuted means two copies reach the speaker and only
    /// one of them is known to the canceller.
    public var tapMuteBehavior: TapMuteBehavior

    public init(
        speakerUID: String,
        farEndProcessIDs: [AudioObjectID] = [],
        tapMuteBehavior: TapMuteBehavior = .mutedWhenTapped
    ) {
        self.speakerUID = speakerUID
        self.farEndProcessIDs = farEndProcessIDs
        self.tapMuteBehavior = tapMuteBehavior
    }
}

/// Wires the echo canceller into the router.
///
/// Three realtime threads meet here and none of them may block, so both meeting
/// points are lock-free rings:
///
/// ```
/// far-end tap IOProc ──▶ ring ──▶ AUVoiceProcessingIO render callback
///                                            │  (plays to the speaker)
///                                            ▼
///                        microphone ──▶ input callback ──▶ ring ──▶ router IOProc
/// ```
///
/// The shape is forced rather than chosen. `AUVoiceProcessingIO` is one IO unit
/// bound to one device, and it can only cancel a speaker it is itself driving,
/// so it needs an aggregate of the microphone and the speaker together — which
/// means the router cannot also hold the microphone, and the cancelled signal
/// has to travel to it. The far end has to be rendered *through* the unit for
/// there to be anything to cancel, and it comes from a process tap living in a
/// third aggregate of its own.
///
/// What this costs, stated plainly because the interface has to say it: one
/// buffer of latency in each direction, no clock lock (the router's master is
/// now the destination, not the microphone's crystal), and no bit-exactness —
/// the canceller is arithmetic on the signal by definition.
///
/// `@unchecked Sendable` for the usual narrow reason: the only state crossing
/// threads is the two rings, which are lock-free by construction, and the
/// closures handed to the unit touch nothing else.
public final class EchoCancellationBridge: @unchecked Sendable {

    /// Frames of cancelled microphone waiting for the router.
    public var ring: OpaquePointer { cancelledRing }

    public let sampleRate: Double
    /// True when a far-end reference was actually obtained. False means the
    /// canceller is running blind — worth saying, since it changes what it can
    /// remove.
    public var hasFarEndReference: Bool { farEnd != nil }

    private let capture: EchoCancellingCapture
    private let farEnd: FarEndCapture?
    private let cancelledRing: OpaquePointer
    /// Scratch the render callback fills from the far-end ring. Allocated here
    /// because that callback runs on a realtime thread and cannot allocate.
    private let farEndScratch: UnsafeMutablePointer<Float>
    private let farEndScratchCapacity: Int
    private var isRunning = false

    /// - Parameters:
    ///   - microphoneUID: The microphone to capture and cancel for.
    ///   - settings: Speaker and far-end reference.
    ///   - maximumFrames: Largest block the unit will be asked for.
    public init?(
        microphoneUID: String,
        settings: EchoCancellationSettings,
        maximumFrames: Int = 512
    ) {
        // The far end first: its rate decides the canceller's, and building the
        // unit against one rate and then discovering the tap runs at another
        // would mean cancelling a signal that no longer lines up in time.
        let reference =
            settings.farEndProcessIDs.isEmpty
            ? nil
            : FarEndCapture(
                processIDs: settings.farEndProcessIDs,
                muteBehavior: settings.tapMuteBehavior)
        farEnd = reference

        guard
            let capture = EchoCancellingCapture(
                microphoneUID: microphoneUID, speakerUID: settings.speakerUID,
                maximumFrames: maximumFrames)
        else { return nil }
        self.capture = capture
        sampleRate = capture.sampleRate

        // A quarter of a second, as on the far-end side. Both ends of this ring
        // are realtime threads on the same nominal clock, so the standing fill
        // is a buffer or two; the rest is there so a stall costs latency rather
        // than a gap.
        guard let ring = yun_rt_ring_create(UInt32(capture.sampleRate * 0.25)) else {
            return nil
        }
        cancelledRing = ring

        farEndScratchCapacity = max(maximumFrames, 4096)
        farEndScratch = .allocate(capacity: farEndScratchCapacity)
        farEndScratch.initialize(repeating: 0, count: farEndScratchCapacity)
    }

    deinit {
        stop()
        farEndScratch.deallocate()
        yun_rt_ring_free(cancelledRing)
    }

    /// - Returns: False when either unit refused to start, in which case
    ///   nothing is left running.
    public func start() -> Bool {
        guard !isRunning else { return true }

        if let farEnd, !farEnd.start() {
            // Not fatal. Without a reference the canceller still suppresses
            // steady noise; saying so beats refusing to route.
            farEndReferenceFailed = true
        }

        // Captured by the callbacks instead of `self`: these run on a realtime
        // thread, and touching a Swift object there would mean retain traffic.
        //
        // The pointers travel in a box because a raw pointer is not `Sendable`,
        // which is the compiler asking the right question — who guarantees this
        // stays alive? The answer is `stop()`, which runs before `deinit` frees
        // either of them, and `stop()` returns only once the units have been
        // stopped and no callback can still be in flight.
        let handles = RealtimeHandles(
            ring: cancelledRing, scratch: farEndScratch,
            scratchCapacity: farEndScratchCapacity, farEnd: farEnd)

        // `AudioOutputUnitStart` can return success without ever driving a
        // callback. Observed in the full flow: the route advertised a live
        // canceller and its produced-frame count stayed at zero indefinitely.
        // Success is two callbacks, not the return code; retry the unchanged
        // unit once, as CoreAudio commonly recovers on the second start.
        for _ in 0..<2 {
            let writtenBefore = producedFrames
            let started = capture.start(
                capture: { samples, count, _ in
                    _ = yun_rt_ring_write(handles.ring, samples, UInt32(count))
                },
                farEnd: { buffer, frames in
                    guard let reference = handles.farEnd else { return 0 }
                    let wanted = min(frames, handles.scratchCapacity)
                    let taken = reference.read(into: handles.scratch, frames: wanted)
                    buffer.update(from: handles.scratch, count: taken)
                    return taken
                })
            if started {
                let deadline = Date().addingTimeInterval(0.75)
                while Date() < deadline, producedFrames == writtenBefore {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if producedFrames > writtenBefore {
                    isRunning = true
                    return true
                }
                capture.stop()
            }
        }
        farEnd?.stop()
        return false
    }

    public func stop() {
        guard isRunning else { return }
        capture.stop()
        farEnd?.stop()
        isRunning = false
    }

    /// True when the far-end tap could not be started, so the canceller is
    /// running without a reference.
    public private(set) var farEndReferenceFailed = false

    /// Frames the canceller produced that the router never collected. Non-zero
    /// means the two are running at genuinely different rates.
    public var droppedFrames: UInt64 { yun_rt_ring_dropped(cancelledRing) }
    public var producedFrames: UInt32 { yun_rt_ring_written(cancelledRing) }
    public var bufferedFrames: UInt32 { yun_rt_ring_available(cancelledRing) }
    public var farEndProducedFrames: UInt32 { farEnd?.producedFrames ?? 0 }
    /// Blocks cut short because the device asked for more than fits.
    public var truncatedBlocks: UInt64 { capture.truncatedBlockCount }
    public var inputCallbacks: UInt64 { capture.inputCallbackCount }
    public var farEndCallbacks: UInt64 { capture.farEndCallbackCount }
    public var renderFailures: UInt64 { capture.renderFailureCount }
    public var lastRenderStatus: OSStatus { capture.lastRenderStatus }

    /// Turns the cancellation off while leaving the same path in place, which
    /// is what makes its effect measurable rather than merely asserted.
    public func setBypassed(_ bypassed: Bool) { capture.setBypassed(bypassed) }
}

/// The pointers the realtime callbacks need, in one `Sendable` parcel.
///
/// `@unchecked` is the honest claim here rather than a shortcut: these are raw
/// pointers, and what keeps them valid is lifetime, not synchronisation. The
/// bridge stops both units before freeing either, and a stopped unit has no
/// callback in flight.
private struct RealtimeHandles: @unchecked Sendable {
    let ring: OpaquePointer
    let scratch: UnsafeMutablePointer<Float>
    let scratchCapacity: Int
    let farEnd: FarEndCapture?
}

/// What the canceller is doing, for the interface to report.
public struct EchoCancellationStatus: Sendable, Hashable {
    /// Frames the canceller has handed to the router since it started.
    public let produced: UInt32
    /// Frames waiting in the ring. Steady is healthy; climbing means the
    /// router is the slower of the two and latency is growing.
    public let buffered: UInt32
    /// Frames the router never collected.
    public let dropped: UInt64
    /// True when the far end is actually being supplied. False means the
    /// canceller is running blind: still useful against steady noise, but it
    /// cannot remove a voice it has never heard.
    public let hasReference: Bool
    /// Blocks the device offered that were larger than the capture buffer and
    /// had to be cut short. Should be zero; anything else means the device
    /// changed its buffer size underneath the unit.
    public let truncatedBlocks: UInt64
    /// Callback counts distinguish a stopped unit from a microphone render
    /// that is still being asked for and failing.
    public let inputCallbacks: UInt64
    public let farEndCallbacks: UInt64
    public let renderFailures: UInt64
    public let lastRenderStatus: OSStatus
}
