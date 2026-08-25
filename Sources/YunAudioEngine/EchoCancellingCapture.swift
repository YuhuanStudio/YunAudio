import AudioToolbox
import AVFoundation
import Foundation
import YunAudioHAL
import YunAudioRT

public enum EchoCancellationUnitSetupStep: String, CaseIterable, Sendable {
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

public struct EchoCancellationUnitSetupFailure: Sendable, Equatable {
    public let step: EchoCancellationUnitSetupStep
    public let status: OSStatus
    public let expectedDeviceID: AudioObjectID?
    public let actualDeviceID: AudioObjectID?

    public init(
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

/// Why the echo canceller could not be put into the path.
///
/// One case per distinct refusal, because until this existed every one of them
/// was the same `return nil`, became the same sentence — "the echo canceller
/// could not be built" — and told nobody what to do about it. A missing device,
/// a rate the microphone cannot produce and an audio unit that would not
/// instantiate are three different problems with three different answers, and
/// the one that actually happens on this machine is a Bluetooth headset chosen
/// as the speaker, which is a *choice the user can change* if anybody tells
/// them so.
///
/// The payloads are not shown to the user; they are what the command-line
/// harness prints, so a report of this failure carries the numbers that decided
/// it rather than a description of the code.
public enum EchoCancellationSetupError: Error, Sendable, Equatable {
    case microphoneNotFound(uid: String)
    case speakerNotFound(uid: String)
    /// The router fixed the clock and the microphone cannot produce it. Frames
    /// cross a ring with no metadata, so nothing downstream could resample
    /// them: this one is a genuine refusal rather than a preference.
    case microphoneCannotPresentRouterRate(
        microphoneRates: [Double], routerRate: Double)
    /// Nothing fixed the clock and the pair has no rate in common at all.
    case noSharedSampleRate(microphoneRates: [Double], speakerRates: [Double])
    case sampleRateNotApplied(rate: Double)
    case aggregateNotCreated
    /// Process-lifetime residue or an in-flight AU transaction has closed
    /// admission. Creating another owner would compound the uncertain graph.
    case audioOwnershipQuarantined
    case componentMissing
    case unitNotInstantiated(status: OSStatus)
    case unitSetupFailed(EchoCancellationUnitSetupFailure)
    case captureClockDiffersFromRouter(captureRate: Double, routerRate: Double)
    case cancelledRingNotAllocated(frames: Int)
    /// A HAL value or caller-supplied bound could not describe a bounded
    /// allocation. Strings preserve malformed non-finite values without an
    /// integer conversion which could itself trap while reporting the error.
    case unsafeCapacity(field: String, value: String)

    /// The stable identifier the application matches on to choose a sentence.
    ///
    /// A constant rather than an interpolated phrase, for the reason
    /// `IsolationFailure` is: matching on wording somebody later rewords puts
    /// the raw English silently back in front of the user.
    public var reason: String {
        switch self {
        case .microphoneNotFound: RoutingEngine.EchoFailure.microphoneMissing
        case .speakerNotFound: RoutingEngine.EchoFailure.speakerMissing
        case .microphoneCannotPresentRouterRate:
            RoutingEngine.EchoFailure.microphoneCannotPresentRouterRate
        case .noSharedSampleRate: RoutingEngine.EchoFailure.noSharedSampleRate
        case .sampleRateNotApplied: RoutingEngine.EchoFailure.sampleRateNotApplied
        case .aggregateNotCreated: RoutingEngine.EchoFailure.aggregateNotCreated
        case .audioOwnershipQuarantined, .componentMissing, .unitNotInstantiated:
            RoutingEngine.EchoFailure.unitNotInstantiated
        case .unitSetupFailed, .unsafeCapacity:
            RoutingEngine.EchoFailure.unitRefusedSetup
        case .captureClockDiffersFromRouter:
            RoutingEngine.EchoFailure.clockDiffersFromRouter
        case .cancelledRingNotAllocated: RoutingEngine.EchoFailure.ringNotAllocated
        }
    }

    /// The numbers behind the refusal, for a report rather than for a person.
    public var detail: String {
        switch self {
        case .microphoneNotFound(let uid): "microphone \(uid)"
        case .speakerNotFound(let uid): "speaker \(uid)"
        case .microphoneCannotPresentRouterRate(let rates, let routerRate):
            "router \(Self.describe(routerRate)) Hz, microphone offers \(Self.list(rates))"
        case .noSharedSampleRate(let microphone, let speaker):
            "microphone offers \(Self.list(microphone)),"
                + " speaker offers \(Self.list(speaker))"
        case .sampleRateNotApplied(let rate): "\(Self.describe(rate)) Hz"
        case .aggregateNotCreated: "AggregateDevice refused the pair"
        case .audioOwnershipQuarantined: "Audio Unit lifecycle is quarantined"
        case .componentMissing: "AUVoiceProcessingIO is not installed"
        case .unitNotInstantiated(let status):
            "AudioComponentInstanceNew \(fourCharDescription(status))"
        case .unitSetupFailed(let failure):
            "\(failure.step.rawValue) \(fourCharDescription(failure.status))"
        case .captureClockDiffersFromRouter(let capture, let router):
            "canceller \(Self.describe(capture)) Hz, router \(Self.describe(router)) Hz"
        case .cancelledRingNotAllocated(let frames): "\(frames) frame(s)"
        case .unsafeCapacity(let field, let value): "\(field) \(value)"
        }
    }

    private static func list(_ rates: [Double]) -> String {
        rates.isEmpty
            ? "nothing"
            : rates.map(Self.describe).sorted().joined(separator: "/") + " Hz"
    }

    private static func describe(_ value: Double) -> String {
        guard AudioProcessingContract.supports(sampleRate: value)
        else { return String(describing: value) }
        return "\(Int(value))"
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

/// The exact boundary which prevented an echo-cancellation unit from closing.
public enum EchoCancellationTeardownResult: Sendable, Equatable {
    /// The unit is disposed, its aggregate is absent and changed rates arrived
    /// back at their original values.
    case complete
    /// The voice-processing unit refused one ordered lifecycle operation.
    case audioUnit(step: AudioUnitTeardownStep, status: OSStatus)
    /// The shared route budget expired before this operation could begin.
    case audioUnitTimedOut(step: AudioUnitTeardownStep)
    /// The sole lifecycle worker did not return before the caller's absolute
    /// deadline. A nil step means the worker was between named AU operations or
    /// inside the aggregate/rate portion of the same transaction.
    case lifecycleTimedOut(step: AudioUnitTeardownStep?)
    /// The dedicated aggregate was not proven absent from HAL.
    case aggregate(HALDestructionResult)
    /// These devices did not arrive back at their pre-capture sample rates.
    case sampleRatesNotRestored([String])

    public var isComplete: Bool { self == .complete }
}

public enum AudioUnitTeardownStep: String, Sendable, Equatable {
    case start
    case property
    case stop
    case uninitialise
    case dispose
}

/// One coherent render-failure observation from the realtime callback.
public struct EchoCancellationRenderDiagnostics: Sendable, Equatable {
    public let failureCount: UInt64
    public let lastStatus: OSStatus
}

/// Result of changing a live VoiceProcessingIO property.
public enum EchoCancellationControlResult: Sendable, Equatable {
    case applied
    case failed(OSStatus)
    case lifecycleTimedOut(step: AudioUnitTeardownStep?)

    public var isApplied: Bool { self == .applied }
}

/// A retryable state machine for an initialised output Audio Unit.
///
/// The operations are injected so a refusal at every boundary can be proved
/// without opening the microphone. A phase advances only after `noErr`, which
/// prevents a later call from disposing storage while a failed stop can still
/// deliver a callback.
struct AudioUnitTeardownState: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// Instantiated but never successfully initialised.
        case instantiated
        /// Initialised but not currently driving callbacks.
        case ready
        case running
        case uninitialised
        case disposed
    }

    private(set) var phase: Phase = .instantiated

    mutating func didInitialise() {
        precondition(phase == .instantiated)
        phase = .ready
    }

    mutating func didStart() {
        precondition(phase == .ready)
        phase = .running
    }

    @discardableResult
    mutating func pause(using stop: () -> OSStatus) -> OSStatus {
        guard phase == .running else { return noErr }
        let status = stop()
        if status == noErr { phase = .ready }
        return status
    }

    mutating func tearDown(
        stop: () -> OSStatus?,
        uninitialise: () -> OSStatus?,
        dispose: () -> OSStatus?
    ) -> EchoCancellationTeardownResult {
        if phase == .running {
            guard let status = stop() else {
                return .audioUnitTimedOut(step: .stop)
            }
            guard status == noErr else {
                return .audioUnit(step: .stop, status: status)
            }
            phase = .ready
        }
        if phase == .ready {
            guard let status = uninitialise() else {
                return .audioUnitTimedOut(step: .uninitialise)
            }
            guard status == noErr else {
                return .audioUnit(step: .uninitialise, status: status)
            }
            phase = .uninitialised
        }
        if phase == .instantiated || phase == .uninitialised {
            guard let status = dispose() else {
                return .audioUnitTimedOut(step: .dispose)
            }
            guard status == noErr else {
                return .audioUnit(step: .dispose, status: status)
            }
            phase = .disposed
        }
        return .complete
    }
}

/// Captures a microphone with acoustic echo cancellation.
///
/// `AUVoiceProcessingIO` is one IO unit bound to one device, so the microphone
/// it cancels for and the speaker it cancels against have to be the same
/// CoreAudio object. A laptop's built-in microphone and speakers are two
/// separate devices, which is why binding the unit directly to the microphone
/// fails with `kAudioUnitErr_FormatNotSupported`.
///
/// When those roles already belong to one duplex device the unit binds to that
/// device directly. Otherwise the fix is a private aggregate holding the chosen
/// microphone and speaker — the same machinery the router already uses,
/// pointed at a different problem.
///
/// The far end — what the other person is saying — has to be rendered *through*
/// this unit for it to have anything to cancel. Feeding it from a process tap on
/// the conferencing application is what closes that loop without asking the user
/// to reconfigure anything.
public final class EchoCancellingCapture {
    /// The physical binding required by one named microphone/speaker pair.
    ///
    /// A duplicate UID is one duplex device, not two aggregate members. Keeping
    /// that decision pure makes both lookup and sample-rate alignment provably
    /// unique before either operation can touch hardware.
    enum DeviceBindingPlan: Sendable, Equatable {
        case directDuplex(uid: String)
        case aggregate(microphoneUID: String, speakerUID: String)

        var alignmentUIDs: [String] {
            switch self {
            case .directDuplex(let uid): [uid]
            case .aggregate(let microphoneUID, let speakerUID):
                [microphoneUID, speakerUID]
            }
        }
    }

    static func deviceBindingPlan(
        microphoneUID: String, speakerUID: String
    ) -> DeviceBindingPlan {
        microphoneUID == speakerUID
            ? .directDuplex(uid: microphoneUID)
            : .aggregate(
                microphoneUID: microphoneUID, speakerUID: speakerUID)
    }

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
    /// C11 atomics because the input and render callbacks are independent
    /// realtime writers while the interface is a third reader. A Swift struct
    /// behind an ordinary pointer lost increments and raced every diagnostic
    /// poll even though the owning object stayed alive.
    private let truncatedBlocks: OpaquePointer
    private let inputCallbacks: OpaquePointer
    private let farEndCallbacks: OpaquePointer
    private let renderDiagnostics: OpaquePointer
    private let callbackContext: OpaquePointer

    /// Non-zero means the device handed over more frames per pull than this
    /// object was sized for, and some audio was dropped.
    public var truncatedBlockCount: UInt64 { yun_rt_counter_load(truncatedBlocks) }
    public var inputCallbackCount: UInt64 { yun_rt_counter_load(inputCallbacks) }
    public var farEndCallbackCount: UInt64 { yun_rt_counter_load(farEndCallbacks) }
    public var renderDiagnosticsSnapshot: EchoCancellationRenderDiagnostics? {
        var failureCount: UInt64 = 0
        var status = noErr
        guard
            yun_rt_echo_render_diagnostics_load(
                renderDiagnostics, &failureCount, &status)
        else { return nil }
        return EchoCancellationRenderDiagnostics(
            failureCount: failureCount, lastStatus: status)
    }
    public var renderFailureCount: UInt64 {
        renderDiagnosticsSnapshot?.failureCount ?? 0
    }
    public var lastRenderStatus: OSStatus {
        renderDiagnosticsSnapshot?.lastStatus ?? noErr
    }
    public var callbackOverlapCount: UInt64 {
        yun_rt_echo_callback_context_overlaps(callbackContext)
    }

    /// One immutable closure value allocated before Core Audio starts.
    ///
    /// The C callback context carries only this allocation's raw address.
    /// Control code destroys it only after `AudioOutputUnitStop` has fenced
    /// every invocation, so the callback needs no retain to establish lifetime.
    private struct CaptureBinding: @unchecked Sendable {
        let handler: CaptureHandler

        init(_ handler: @escaping CaptureHandler) {
            self.handler = handler
        }

        @inline(__always)
        borrowing func call(
            _ samples: UnsafePointer<Float>, frames: UInt32,
            timestamp: UnsafePointer<AudioTimeStamp>
        ) {
            handler(samples, Int(frames), timestamp.pointee)
        }
    }

    private struct FarEndBinding: @unchecked Sendable {
        let provider: FarEndProvider

        init(_ provider: @escaping FarEndProvider) {
            self.provider = provider
        }

        @inline(__always)
        borrowing func fill(
            _ destination: UnsafeMutablePointer<Float>, frames: UInt32
        ) -> Int64 {
            Int64(provider(destination, Int(frames)))
        }
    }

    private static let captureTrampoline:
        @convention(c) (
            UnsafeMutableRawPointer, UnsafePointer<Float>, UInt32,
            UnsafePointer<AudioTimeStamp>
        ) -> Void = { context, samples, frames, timestamp in
            context.assumingMemoryBound(to: CaptureBinding.self).pointee
                .call(samples, frames: frames, timestamp: timestamp)
        }

    private static let farEndTrampoline:
        @convention(c) (
            UnsafeMutableRawPointer, UnsafeMutablePointer<Float>, UInt32
        ) -> Int64 = { context, destination, frames in
            context.assumingMemoryBound(to: FarEndBinding.self).pointee
                .fill(destination, frames: frames)
        }

    /// Raw allocations owned by the control thread while callbacks can run.
    private var activeCaptureBinding: UnsafeMutablePointer<CaptureBinding>?
    private var activeFarEndBinding: UnsafeMutablePointer<FarEndBinding>?
    private var teardownState = AudioUnitTeardownState()
    private let lifecycleLock = NSLock()
    private var teardownOwner: EchoCancellationCaptureTeardownOwner?
    private var lifecycleCommandInFlight = false
    public private(set) var lastTeardownResult: EchoCancellationTeardownResult?
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
    ///   - maximumFrames: Largest slice the caller expects the unit to exchange.
    ///     The allocation also accounts for the bound device's reported slice,
    ///     because that device can hand over a different-sized block.
    ///
    ///     Passing the router's own buffer size here was the mistake that made
    ///     this class corrupt the heap: the canceller's aggregate is a different
    ///     device with a buffer size of its own, and it was observed asking for
    ///     1394 frames against the 512 the caller had derived from the router.
    ///     `AudioUnitRender` then wrote 3528 bytes past the end of the capture
    ///     buffer on every cycle. The clamp in the callback below means an
    ///     underestimate can now only cost audio, never memory.
    /// - Throws: `EchoCancellationSetupError`, one case per distinct refusal.
    ///   Every one of them used to be the same `return nil`, which is why the
    ///   feature could switch itself off without anybody being able to say what
    ///   had stopped it.
    public convenience init(
        microphoneUID: String,
        speakerUID: String?,
        requiredSampleRate: Double? = nil,
        maximumFrames: Int = 512
    ) throws(EchoCancellationSetupError) {
        try self.init(
            microphoneUID: microphoneUID, speakerUID: speakerUID,
            requiredSampleRate: requiredSampleRate,
            maximumFrames: maximumFrames, constructionContext: nil)
    }

    /// Construction-lane entry point. Every synchronous HAL and Audio Unit
    /// stage asks the same cancellation context before it begins.
    init(
        microphoneUID: String,
        speakerUID: String?,
        requiredSampleRate: Double?,
        maximumFrames: Int,
        constructionContext: AudioUnitConstructionContext?,
        graphAdmission suppliedGraphAdmission: BoundedAudioUnitDisposer.GraphAdmission? = nil
    ) throws(EchoCancellationSetupError) {
        guard
            EchoCancellationCapacityPolicy.requestedSliceFrames(maximumFrames) != nil
        else {
            throw .unsafeCapacity(
                field: "maximum slice", value: String(describing: maximumFrames))
        }
        if let requiredSampleRate,
            !EchoCancellationCapacityPolicy.isValidSampleRate(requiredSampleRate)
        {
            throw .unsafeCapacity(
                field: "required sample rate",
                value: String(describing: requiredSampleRate))
        }
        guard constructionContext?.mayBeginOperation ?? true else {
            throw .audioOwnershipQuarantined
        }

        // The lease spans every HAL and AudioComponent owner created below.
        // A read-only `admitsNewGraph` check has a check/use race: a timed-out
        // teardown can enter quarantine after the check and before InstanceNew.
        let acquiredAdmission: BoundedAudioUnitDisposer.GraphAdmission
        if let suppliedGraphAdmission {
            acquiredAdmission = suppliedGraphAdmission
        } else {
            guard
                let admission = BoundedAudioUnitDisposer.shared.acquireGraphAdmission(
                    waitingUpTo: constructionContext?.deadline.remainingTimeInterval ?? 2)
            else { throw .audioOwnershipQuarantined }
            acquiredAdmission = admission
        }
        let partialMutation = AggregateRateMutationOwner()
        let partialOwner = EchoCancellationPartialConstructionOwner(
            mutation: partialMutation, admission: acquiredAdmission)
        var graphAdmission: BoundedAudioUnitDisposer.GraphAdmission?
        defer { graphAdmission?.release() }
        let retainAdmissionAfterCancellation = {
            partialOwner.retainOnce(afterCancellationIn: constructionContext)
        }
        guard constructionContext?.mayBeginOperation ?? true else {
            retainAdmissionAfterCancellation()
            throw .audioOwnershipQuarantined
        }

        // Bind one duplex device directly, or combine two distinct devices.
        var builtAggregate: AggregateDevice?
        var boundDeviceID: AudioObjectID?
        var rate: Double = 48000
        var ratesToRestoreOnFailure: [String: Double] = [:]
        let partialCleanupRegistration: AudioUnitConstructionCleanupRegistration?
        if let constructionContext {
            guard
                let registration = constructionContext.deferCleanupAfterCancellation({
                    [partialOwner] in
                    _ = partialOwner.handOffForDisposal(
                        until: HALTeardownDeadline(timeout: 2))
                })
            else {
                retainAdmissionAfterCancellation()
                throw .audioOwnershipQuarantined
            }
            partialCleanupRegistration = registration
        } else {
            partialCleanupRegistration = nil
        }
        var transferredPartialMutation = false
        defer {
            if !transferredPartialMutation,
                constructionContext?.hasBeenCancelled != true
            {
                // A timed-out constructor runs this same cleanup on its sole worker
                // only after the blocking call and the constructor stack return.
                partialCleanupRegistration?.cancel()
                _ = partialOwner.handOffForDisposal(
                    until: HALTeardownDeadline(timeout: 2))
            }
        }

        if let speakerUID {
            guard constructionContext?.mayBeginOperation ?? true else {
                retainAdmissionAfterCancellation()
                throw .audioOwnershipQuarantined
            }
            let bindingPlan = Self.deviceBindingPlan(
                microphoneUID: microphoneUID, speakerUID: speakerUID)
            let microphoneLookup: AudioDevice?
            if let constructionContext {
                microphoneLookup = try? AudioDevices.device(
                    uid: microphoneUID,
                    operationAdmission: { constructionContext.mayBeginOperation })
            } else {
                microphoneLookup = try? AudioDevices.device(uid: microphoneUID)
            }
            guard let microphone = microphoneLookup else {
                if constructionContext?.mayBeginOperation == false {
                    retainAdmissionAfterCancellation()
                    throw .audioOwnershipQuarantined
                }
                throw .microphoneNotFound(uid: microphoneUID)
            }
            guard constructionContext?.mayBeginOperation ?? true else {
                retainAdmissionAfterCancellation()
                throw .audioOwnershipQuarantined
            }
            let speaker: AudioDevice
            switch bindingPlan {
            case .directDuplex:
                speaker = microphone
            case .aggregate(_, let separateSpeakerUID):
                guard constructionContext?.mayBeginOperation ?? true else {
                    retainAdmissionAfterCancellation()
                    throw .audioOwnershipQuarantined
                }
                let speakerLookup: AudioDevice?
                if let constructionContext {
                    speakerLookup = try? AudioDevices.device(
                        uid: separateSpeakerUID,
                        operationAdmission: { constructionContext.mayBeginOperation })
                } else {
                    speakerLookup = try? AudioDevices.device(uid: separateSpeakerUID)
                }
                guard let separateSpeaker = speakerLookup else {
                    if constructionContext?.mayBeginOperation == false {
                        retainAdmissionAfterCancellation()
                        throw .audioOwnershipQuarantined
                    }
                    throw .speakerNotFound(uid: separateSpeakerUID)
                }
                speaker = separateSpeaker
            }
            guard constructionContext?.mayBeginOperation ?? true else {
                retainAdmissionAfterCancellation()
                throw .audioOwnershipQuarantined
            }
            guard
                let selectedRate = Self.sampleRate(
                    microphoneRates: microphone.availableSampleRates,
                    speakerRates: speaker.availableSampleRates,
                    requiredRate: requiredSampleRate)
            else {
                // With a required rate the only way to arrive here is that the
                // microphone itself cannot produce it; the speaker is allowed
                // to disagree, see `sampleRate` below.
                if let requiredSampleRate {
                    throw .microphoneCannotPresentRouterRate(
                        microphoneRates: microphone.availableSampleRates,
                        routerRate: requiredSampleRate)
                }
                throw .noSharedSampleRate(
                    microphoneRates: microphone.availableSampleRates,
                    speakerRates: speaker.availableSampleRates)
            }
            rate = selectedRate
            // Only the members that can actually present it, exactly as the
            // route's own alignment does. Asking a 16 kHz Bluetooth headset for
            // 48 throws, and that throw used to be the whole feature rather
            // than the one member that could not oblige — the canceller simply
            // never appeared, and the interface said "could not be built".
            let alignmentCandidates: [AudioDevice]
            switch bindingPlan {
            case .directDuplex:
                alignmentCandidates = [microphone]
            case .aggregate:
                alignmentCandidates = [microphone, speaker]
            }
            let alignable = alignmentCandidates.filter { device in
                device.availableSampleRates.contains {
                    EchoCancellationRateContract.ratesMatch($0, rate)
                }
            }
            let alignedRates: [String: Double]?
            if let constructionContext {
                alignedRates = try? AggregateDevice.alignSampleRate(
                    rate, across: alignable, until: constructionContext.deadline,
                    operationAdmission: { constructionContext.mayBeginOperation },
                    recordOriginal: { uid, previous in
                        if ratesToRestoreOnFailure[uid] == nil {
                            ratesToRestoreOnFailure[uid] = previous
                        }
                        partialMutation.recordOriginal(uid: uid, rate: previous)
                        constructionContext.record(.changedSampleRate)
                    },
                    callerOwnsPublishedOriginals: true)
            } else {
                alignedRates = try? AggregateDevice.alignSampleRate(
                    rate, across: alignable,
                    recordOriginal: { uid, previous in
                        if ratesToRestoreOnFailure[uid] == nil {
                            ratesToRestoreOnFailure[uid] = previous
                        }
                        partialMutation.recordOriginal(uid: uid, rate: previous)
                    })
            }
            guard let alignedRates else {
                if constructionContext?.mayBeginOperation == false {
                    retainAdmissionAfterCancellation()
                    throw .audioOwnershipQuarantined
                }
                throw .sampleRateNotApplied(rate: rate)
            }
            for (uid, previous) in alignedRates where ratesToRestoreOnFailure[uid] == nil {
                ratesToRestoreOnFailure[uid] = previous
            }
            restorableRates = ratesToRestoreOnFailure
            guard constructionContext?.mayBeginOperation ?? true else {
                retainAdmissionAfterCancellation()
                throw .audioOwnershipQuarantined
            }

            switch bindingPlan {
            case .directDuplex:
                // The physical object already owns both streams. An aggregate
                // containing its UID twice is invalid and can leave HAL cleanup
                // residue after the failed creation attempt.
                boundDeviceID = microphone.id
            case .aggregate(let aggregateMicrophoneUID, let aggregateSpeakerUID):
                guard constructionContext?.mayBeginOperation ?? true else {
                    retainAdmissionAfterCancellation()
                    throw .audioOwnershipQuarantined
                }
                guard
                    let dedicated = try? AggregateDevice(
                        name: "YunAudio Echo Cancellation",
                        subDevices: [
                            .init(
                                uid: aggregateMicrophoneUID,
                                driftCompensation: false),
                            .init(
                                uid: aggregateSpeakerUID,
                                driftCompensation: true),
                        ],
                        clockMasterUID: aggregateMicrophoneUID)
                else { throw .aggregateNotCreated }
                partialMutation.adopt(dedicated)
                constructionContext?.record(.aggregate)
                builtAggregate = dedicated
                guard constructionContext?.mayBeginOperation ?? true else {
                    retainAdmissionAfterCancellation()
                    throw .audioOwnershipQuarantined
                }
                boundDeviceID = dedicated.id
            }
        } else {
            guard constructionContext?.mayBeginOperation ?? true else {
                retainAdmissionAfterCancellation()
                throw .audioOwnershipQuarantined
            }
            let microphoneLookup: AudioDevice?
            if let constructionContext {
                microphoneLookup = try? AudioDevices.device(
                    uid: microphoneUID,
                    operationAdmission: { constructionContext.mayBeginOperation })
            } else {
                microphoneLookup = try? AudioDevices.device(uid: microphoneUID)
            }
            guard let microphone = microphoneLookup else {
                if constructionContext?.mayBeginOperation == false {
                    retainAdmissionAfterCancellation()
                    throw .audioOwnershipQuarantined
                }
                throw .microphoneNotFound(uid: microphoneUID)
            }
            guard constructionContext?.mayBeginOperation ?? true else {
                retainAdmissionAfterCancellation()
                throw .audioOwnershipQuarantined
            }
            guard let currentRate = microphone.currentSampleRate else {
                throw .unsafeCapacity(
                    field: "microphone sample rate", value: "unavailable")
            }
            guard EchoCancellationCapacityPolicy.isValidSampleRate(currentRate) else {
                throw .unsafeCapacity(
                    field: "microphone sample rate",
                    value: String(describing: currentRate))
            }
            if let requiredSampleRate,
                !EchoCancellationRateContract.ratesMatch(
                    currentRate, requiredSampleRate)
            {
                throw .microphoneCannotPresentRouterRate(
                    microphoneRates: [currentRate], routerRate: requiredSampleRate)
            }
            rate = currentRate
        }
        guard constructionContext?.mayBeginOperation ?? true else {
            retainAdmissionAfterCancellation()
            throw .audioOwnershipQuarantined
        }
        aggregate = builtAggregate
        sampleRate = rate

        // Read and validate the HAL slice before instantiating an Audio Unit or
        // allocating memory. A successful property read carrying UInt32.max is
        // malformed data, not permission to ask the allocator for 16 GiB.
        var reportedDeviceFrames: UInt32 = 0
        if let boundDeviceID {
            guard constructionContext?.mayBeginOperation ?? true else {
                retainAdmissionAfterCancellation()
                throw .audioOwnershipQuarantined
            }
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectGetPropertyData(
                boundDeviceID, &address, 0, nil, &size, &reportedDeviceFrames)
            guard constructionContext?.mayBeginOperation ?? true else {
                retainAdmissionAfterCancellation()
                throw .audioOwnershipQuarantined
            }
            guard status == noErr, size == UInt32(MemoryLayout<UInt32>.size) else {
                throw .unsafeCapacity(
                    field: "device slice",
                    value: status == noErr ? "size \(size)" : fourCharDescription(status))
            }
        }
        guard
            let allocation = EchoCancellationCapacityPolicy.captureAllocation(
                requestedSliceFrames: maximumFrames,
                deviceSliceFrames: reportedDeviceFrames)
        else {
            throw .unsafeCapacity(
                field: "device slice",
                value: String(describing: reportedDeviceFrames))
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: EchoCancellation.componentSubType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard constructionContext?.mayBeginOperation ?? true else {
            retainAdmissionAfterCancellation()
            throw .audioOwnershipQuarantined
        }
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw .componentMissing
        }
        guard constructionContext?.mayBeginOperation ?? true else {
            retainAdmissionAfterCancellation()
            throw .audioOwnershipQuarantined
        }
        guard !AudioUnitPlugins.requiresAsyncInstantiation(component) else {
            throw .componentMissing
        }

        var instance: AudioComponentInstance?
        guard
            let instantiation = performAudioUnitConstruction(
                until: constructionContext?.deadline
                    ?? HALTeardownDeadline(timeout: 2),
                context: constructionContext,
                { AudioComponentInstanceNew(component, &instance) })
        else {
            retainAdmissionAfterCancellation()
            throw .audioOwnershipQuarantined
        }
        let ownership = AudioComponentCreationOwnership(
            status: instantiation, instance: instance)
        if ownership.createdInstance != nil || ownership.orphanedInstance != nil {
            constructionContext?.record(.audioUnit)
            constructionContext?.record(.echoCancellation)
        }
        if let owned = ownership.createdInstance ?? ownership.orphanedInstance {
            partialOwner.adopt(owned)
        }
        if constructionContext?.mayBeginOperation == false {
            retainAdmissionAfterCancellation()
            throw .audioOwnershipQuarantined
        }
        guard let created = ownership.createdInstance else {
            // An out parameter is still an owner when the API reports failure.
            // It shares the aggregate and rate journal with the same combined
            // partial owner. The defer submits their ordered disposal without
            // reopening graph admission in between.
            throw .unitNotInstantiated(status: instantiation)
        }
        unit = created

        // Sized from the validated device slice, with four slices of headroom.
        // The policy has already proved the frame and byte counts bounded and
        // UInt32-representable before this first allocation.
        let capacity = allocation.bufferFrames
        self.maximumFrames = capacity

        captureBuffer = .allocate(capacity: capacity)
        captureBuffer.initialize(repeating: 0, count: capacity)
        truncatedBlocks = Self.allocateRealtimeCounter()
        inputCallbacks = Self.allocateRealtimeCounter()
        farEndCallbacks = Self.allocateRealtimeCounter()
        guard let rawRenderDiagnostics = yun_rt_echo_render_diagnostics_create() else {
            preconditionFailure("could not allocate echo-cancellation render diagnostics")
        }
        renderDiagnostics = rawRenderDiagnostics
        bufferList = AudioBufferList.allocate(maximumBuffers: 1)
        bufferList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: allocation.bufferBytes,
            mData: UnsafeMutableRawPointer(captureBuffer))

        guard
            let rawCallbackContext = yun_rt_echo_callback_context_create(
                created, allocation.unitSliceFrames,
                bufferList.unsafeMutablePointer,
                captureBuffer, truncatedBlocks, inputCallbacks, farEndCallbacks,
                rawRenderDiagnostics)
        else {
            preconditionFailure("could not allocate echo-cancellation callback context")
        }
        callbackContext = rawCallbackContext

        var inputCallback = AURenderCallbackStruct(
            inputProc: yun_rt_echo_input_callback,
            inputProcRefCon: UnsafeMutableRawPointer(rawCallbackContext))

        var renderCallback = AURenderCallbackStruct(
            inputProc: yun_rt_echo_render_callback,
            inputProcRefCon: UnsafeMutableRawPointer(rawCallbackContext))

        // From here every stored property exists, so a throwing initializer
        // runs `deinit`. That teardown must own the rate restoration because it
        // can first dispose the unit and confirm the aggregate is absent. The
        // local defer remains responsible for every earlier failure.
        graphAdmission = partialOwner.commit()
        partialMutation.relinquish()
        partialCleanupRegistration?.cancel()
        transferredPartialMutation = true

        let constructionDeadline =
            constructionContext?.deadline ?? HALTeardownDeadline(timeout: 2)
        let operations = EchoCancellationUnitSetupOperations(
            setProperty: { property, scope, element, data, size in
                performAudioUnitConstruction(
                    until: constructionDeadline, context: constructionContext
                ) {
                    AudioUnitSetProperty(
                        created, property, scope, element, data, size)
                } ?? kAudioHardwareNotReadyError
            },
            getProperty: { property, scope, element, data, size in
                performAudioUnitConstruction(
                    until: constructionDeadline, context: constructionContext
                ) {
                    AudioUnitGetProperty(
                        created, property, scope, element, data, &size)
                } ?? kAudioHardwareNotReadyError
            },
            initialise: {
                performAudioUnitConstruction(
                    until: constructionDeadline, context: constructionContext
                ) {
                    AudioUnitInitialize(created)
                } ?? kAudioHardwareNotReadyError
            })
        let setupFailure = Self.setupVoiceProcessingUnit(
            boundDeviceID: boundDeviceID,
            sampleRate: rate,
            maximumFrames: Int(allocation.unitSliceFrames),
            inputCallback: &inputCallback,
            renderCallback: &renderCallback,
            operations: operations)
        if let setupFailure {
            // Atomically turn construction admission into teardown. Releasing
            // the lease first would let another graph enter between the failed
            // setup and ownership of this partially configured unit.
            let teardownDeadline = HALTeardownDeadline(timeout: 2)
            let detached = detachForTeardown(until: teardownDeadline)
            _ = graphAdmission?.handOffForDisposal(
                detached, until: teardownDeadline)
            graphAdmission = nil
            throw .unitSetupFailed(setupFailure)
        }
        teardownState.didInitialise()
        guard constructionContext?.mayBeginOperation ?? true else {
            // Setup crossed one or more Audio Unit calls before cancellation
            // became visible. Hand the full callback-storage owner over while
            // the same admission is still held; retaining `self` and releasing
            // the lease would briefly admit another graph before deinit submits
            // this teardown.
            let teardownDeadline = HALTeardownDeadline(timeout: 2)
            let detached = detachForTeardown(until: teardownDeadline)
            _ = graphAdmission?.handOffForDisposal(
                detached, until: teardownDeadline)
            graphAdmission = nil
            throw .audioOwnershipQuarantined
        }
        graphAdmission?.release()
        graphAdmission = nil
    }

    /// Chooses one clock for the canceller's bound device pair.
    ///
    /// The standalone capture keeps its established voice-oriented preference
    /// for 48 kHz across whatever the pair both offer. A bridge supplies
    /// `requiredRate`, because frames crossing a ring have no metadata with
    /// which a downstream consumer could discover that they need resampling.
    ///
    /// **Only the microphone has to agree with `requiredRate`.** It is the
    /// clock source and the one device whose samples travel that metadata-free
    /// ring, so a rate it cannot produce is a real refusal. For a separate
    /// speaker, that device is a drift-compensated follower and the HAL converts
    /// for it — exactly the rule the route itself already follows for a
    /// destination that cannot present the target rate.
    ///
    /// Requiring a *shared* rate here is what killed the feature on this
    /// machine. A Seiren V3 Pro offers 48 k and 96 k and nothing else; a
    /// Razer Barracuda over Bluetooth negotiates HFP and offers 16 k. Their
    /// intersection is empty, so a router at 48 kHz — a rate the microphone
    /// presents perfectly — got nil, and echo cancellation silently did not
    /// happen. Nothing about that pair prevents the canceller from running at
    /// 48 kHz; it only prevents the speaker from being fed without conversion,
    /// and a Bluetooth speaker was never going to be fed without conversion.
    static func sampleRate(
        microphoneRates: [Double],
        speakerRates: [Double],
        requiredRate: Double?
    ) -> Double? {
        let microphone = Set(
            microphoneRates.filter(EchoCancellationCapacityPolicy.isValidSampleRate))
        let speaker = Set(
            speakerRates.filter(EchoCancellationCapacityPolicy.isValidSampleRate))

        if let requiredRate {
            guard EchoCancellationCapacityPolicy.isValidSampleRate(requiredRate) else {
                return nil
            }
            return microphone.first {
                EchoCancellationRateContract.ratesMatch($0, requiredRate)
            }.map { _ in requiredRate }
        }

        // No consumer fixed the clock, so there is no reason to make either
        // device convert: prefer what they both present.
        let shared = microphone.intersection(speaker)
        guard !shared.isEmpty else { return nil }
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

        guard EchoCancellationCapacityPolicy.isValidSampleRate(sampleRate) else {
            return .init(step: .setCaptureFormat, status: OSStatus(-50))
        }
        guard
            let validatedFrames =
                EchoCancellationCapacityPolicy.requestedSliceFrames(maximumFrames)
        else {
            return .init(step: .setMaximumFrames, status: OSStatus(-50))
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

        var frames = validatedFrames
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
        guard requestedFrames >= 0,
            requestedFrames <= AudioProcessingContract.maximumFramesPerSlice,
            sampleCapacity >= 0,
            sampleCapacity
                <= EchoCancellationCapacityPolicy.maximumCaptureBufferFrames
        else {
            return FarEndFillResult(
                requestedFrames: 0, bufferFrames: 0, writtenFrames: 0)
        }
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
        // `deinit` must never wait in Core Audio. The detached owner contains no
        // reference back to this object, so handing it to the sole worker does
        // not attempt to resurrect an instance whose reference count is zero.
        let existing = lifecycleLock.withLock { teardownOwner }
        guard existing == nil, lastTeardownResult == nil else { return }
        let detached = detachForTeardown(until: HALTeardownDeadline(timeout: 2))
        BoundedAudioUnitDisposer.shared.disposeAfterFence(detached)
    }

    public func start(capture: @escaping CaptureHandler, farEnd: FarEndProvider? = nil) -> Bool
    {
        guard canBeginLifecycleCommand(), teardownState.phase == .ready else {
            return false
        }
        precondition(activeCaptureBinding == nil && activeFarEndBinding == nil)

        let captureBinding = UnsafeMutablePointer<CaptureBinding>.allocate(capacity: 1)
        captureBinding.initialize(to: CaptureBinding(capture))
        let farEndBinding = farEnd.map {
            let binding = UnsafeMutablePointer<FarEndBinding>.allocate(capacity: 1)
            binding.initialize(to: FarEndBinding($0))
            return binding
        }
        activeCaptureBinding = captureBinding
        activeFarEndBinding = farEndBinding
        yun_rt_echo_callback_context_bind(
            callbackContext, Self.captureTrampoline,
            UnsafeMutableRawPointer(captureBinding),
            farEndBinding == nil ? nil : Self.farEndTrampoline,
            farEndBinding.map(UnsafeMutableRawPointer.init))
        return startBoundUnit(until: HALTeardownDeadline(timeout: 2))
    }

    /// Starts with caller-owned raw handlers, avoiding closure ARC entirely.
    ///
    /// The caller must retain both contexts until `stop` or `pauseForRetry`
    /// succeeds. The route bridge uses this form because all of its realtime
    /// state is POD; the closure overload remains for standalone diagnostics.
    func startRaw(
        captureContext: UnsafeMutableRawPointer,
        captureHandler:
            @convention(c) (
                UnsafeMutableRawPointer, UnsafePointer<Float>, UInt32,
                UnsafePointer<AudioTimeStamp>
            ) -> Void,
        farEndContext: UnsafeMutableRawPointer? = nil,
        farEndProvider: (
            @convention(c) (
                UnsafeMutableRawPointer, UnsafeMutablePointer<Float>, UInt32
            ) -> Int64
        )? = nil,
        until deadline: HALTeardownDeadline = HALTeardownDeadline(timeout: 2)
    ) -> Bool {
        guard canBeginLifecycleCommand(), teardownState.phase == .ready else {
            return false
        }
        precondition(activeCaptureBinding == nil && activeFarEndBinding == nil)
        yun_rt_echo_callback_context_bind(
            callbackContext, captureHandler, captureContext,
            farEndProvider, farEndContext)
        return startBoundUnit(until: deadline)
    }

    private func startBoundUnit(until deadline: HALTeardownDeadline) -> Bool {
        let prepared:
            (
                command: EchoCancellationStartCommand,
                rollback: EchoCancellationCaptureTeardownOwner
            )? = lifecycleLock.withLock {
                guard teardownOwner == nil, lastTeardownResult == nil,
                    !lifecycleCommandInFlight, teardownState.phase == .ready
                else { return nil }
                lifecycleCommandInFlight = true

                // A returned Start error cannot prove that callbacks never
                // began. Roll back from the conservative running phase so Stop
                // is always the first fence before any callback storage moves.
                var rollbackState = teardownState
                rollbackState.didStart()
                let rollback = makeTeardownOwnerLocked(
                    state: rollbackState, until: deadline)
                let command = EchoCancellationStartCommand(
                    retaining: self,
                    start: { [unit] in AudioOutputUnitStart(unit) },
                    rollback: rollback,
                    transferRollbackOwnership: { [self, rollback] in
                        lifecycleLock.withLock {
                            adoptTeardownOwnerLocked(rollback)
                        }
                    })
                return (command, rollback)
            }
        guard let prepared else { return false }

        let commandResult = BoundedAudioUnitDisposer.shared.dispose(
            prepared.command, until: deadline)
        if case .blockedByRetainedTransaction = commandResult {
            prepared.command.cancelBeforeStart()
        }

        let started: Bool
        if commandResult.isComplete, prepared.command.startStatus == noErr {
            teardownState.didStart()
            started = true
        } else {
            let terminal: EchoCancellationTeardownResult
            if prepared.command.startStatus != nil {
                // A returned error has already transferred ownership and run
                // its rollback inside the same worker transaction.
                terminal = captureResult(
                    from: prepared.command.rollbackResult ?? commandResult,
                    owner: prepared.rollback)
            } else {
                switch commandResult {
                case .timedOut(let step, _):
                    terminal = .lifecycleTimedOut(step: step)
                case .blockedByRetainedTransaction:
                    terminal = .lifecycleTimedOut(step: nil)
                case .operationFailed(let step, let status, _):
                    terminal = .audioUnit(step: step, status: status)
                case .ownerRetained:
                    terminal = .lifecycleTimedOut(step: .start)
                case .complete:
                    terminal = .lifecycleTimedOut(step: .start)
                }
            }
            lifecycleLock.withLock {
                if lastTeardownResult == nil { lastTeardownResult = terminal }
            }
            started = false
        }
        lifecycleLock.withLock { lifecycleCommandInFlight = false }
        return started
    }

    /// Turns the voice processing off while leaving the same IO path in place.
    ///
    /// This is what makes the effect measurable: with bypass on and off the
    /// acoustic path, the devices, the buffer size and the signal are all
    /// identical, so the difference in what the microphone returns is the
    /// cancellation and nothing else.
    @discardableResult
    public func setBypassed(
        _ bypassed: Bool, timeout: TimeInterval = 0.5
    ) -> EchoCancellationControlResult {
        final class PropertyValue: @unchecked Sendable {
            var value: UInt32

            init(_ value: UInt32) { self.value = value }
        }

        let propertyValue = PropertyValue(bypassed ? 1 : 0)
        let status = performLifecycleCommand(
            step: .property, until: HALTeardownDeadline(timeout: timeout),
            quarantineOnError: false
        ) { [unit, propertyValue] in
            AudioUnitSetProperty(
                unit,
                AudioUnitPropertyID(kAUVoiceIOProperty_BypassVoiceProcessing),
                kAudioUnitScope_Global, 0, &propertyValue.value,
                UInt32(MemoryLayout<UInt32>.size))
        }
        guard let status else {
            let step: AudioUnitTeardownStep? = {
                guard
                    case .lifecycleTimedOut(let step) = terminalLifecycleResult
                else { return nil }
                return step
            }()
            return .lifecycleTimedOut(step: step)
        }
        return status == noErr ? .applied : .failed(status)
    }

    @discardableResult
    func pauseForRetry(
        until deadline: HALTeardownDeadline = HALTeardownDeadline(timeout: 2)
    ) -> OSStatus {
        guard teardownState.phase == .running else { return noErr }
        let status =
            performLifecycleCommand(
                step: .stop, until: deadline, quarantineOnError: true,
                operation: { [unit] in AudioOutputUnitStop(unit) })
            ?? kAudioUnitErr_CannotDoInCurrentContext
        if status == noErr {
            _ = teardownState.pause { noErr }
            clearCallbackBindings()
        }
        return status
    }

    /// Stops callbacks, disposes the unit, removes its private aggregate when
    /// present and only then restores the physical devices' sample rates.
    ///
    /// Every failure leaves the phase and owners intact in process quarantine.
    /// In particular, a failed stop never clears the callbacks and a failed
    /// aggregate census never restores rates underneath a device HAL may still
    /// be using. The transaction is terminal: retrying an uncertain Core Audio
    /// boundary on another thread would make the original hang worse.
    @discardableResult
    public func stop(timeout: TimeInterval = 2) -> EchoCancellationTeardownResult {
        stop(until: HALTeardownDeadline(timeout: timeout))
    }

    /// Uses the remaining portion of the enclosing route teardown.
    @discardableResult
    public func stop(until deadline: HALTeardownDeadline) -> EchoCancellationTeardownResult {
        if let terminal = lifecycleLock.withLock({ lastTeardownResult }) {
            return terminal
        }
        let detached = detachForTeardown(until: deadline)
        let disposal = BoundedAudioUnitDisposer.shared.dispose(detached, until: deadline)
        let result = captureResult(from: disposal, owner: detached)
        lifecycleLock.withLock {
            // A timeout is terminal even if the uncancellable call later
            // returns. Never let that late result reopen admission or replace
            // the diagnostic observed by the caller.
            if lastTeardownResult == nil { lastTeardownResult = result }
        }
        return lifecycleLock.withLock { lastTeardownResult ?? result }
    }

    /// Exactly-once transfer of every pointer reachable from an AU callback.
    ///
    /// The outer object deliberately keeps its immutable pointer values so
    /// diagnostics remain readable until it deinitialises. Ownership, however,
    /// moves to the returned capsule and no outer cleanup path touches them.
    func detachForTeardown(
        until deadline: HALTeardownDeadline
    ) -> EchoCancellationCaptureTeardownOwner {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if let teardownOwner { return teardownOwner }
        precondition(!lifecycleCommandInFlight)

        let owner = makeTeardownOwnerLocked(state: teardownState, until: deadline)
        adoptTeardownOwnerLocked(owner)
        return owner
    }

    /// Builds a possible teardown capsule without transferring ownership yet.
    ///
    /// Start needs this distinction: a successful Start leaves every pointer
    /// with the capture, while a returned error transfers the exact same owner
    /// before its mandatory Stop fence begins.
    private func makeTeardownOwnerLocked(
        state: AudioUnitTeardownState,
        until deadline: HALTeardownDeadline
    ) -> EchoCancellationCaptureTeardownOwner {
        precondition(teardownOwner == nil)

        let capturedUnit = unit
        let capturedAggregate = aggregate
        let capturedBuffer = captureBuffer
        let capturedBufferList = bufferList
        let capturedTruncatedBlocks = truncatedBlocks
        let capturedInputCallbacks = inputCallbacks
        let capturedFarEndCallbacks = farEndCallbacks
        let capturedRenderDiagnostics = renderDiagnostics
        let capturedCallbackContext = callbackContext
        let captureBinding = activeCaptureBinding
        let farEndBinding = activeFarEndBinding
        let rates = restorableRates

        let operations = EchoCancellationCaptureTeardownOperations(
            stop: { AudioOutputUnitStop(capturedUnit) },
            uninitialise: { AudioUnitUninitialize(capturedUnit) },
            dispose: { AudioComponentInstanceDispose(capturedUnit) },
            clearCallbackBindings: {
                yun_rt_echo_callback_context_clear(capturedCallbackContext)
                if let captureBinding {
                    captureBinding.deinitialize(count: 1)
                    captureBinding.deallocate()
                }
                if let farEndBinding {
                    farEndBinding.deinitialize(count: 1)
                    farEndBinding.deallocate()
                }
            },
            destroyAggregate: { transactionDeadline in
                capturedAggregate?.destroyAndWait(until: transactionDeadline)
                    ?? .destroyed
            },
            restoreSampleRates: { transactionDeadline in
                AggregateDevice.restoreSampleRates(rates, until: transactionDeadline)
            },
            releaseStorage: {
                yun_rt_echo_callback_context_free(capturedCallbackContext)
                capturedBuffer.deallocate()
                yun_rt_counter_free(capturedTruncatedBlocks)
                yun_rt_counter_free(capturedInputCallbacks)
                yun_rt_counter_free(capturedFarEndCallbacks)
                yun_rt_echo_render_diagnostics_free(capturedRenderDiagnostics)
                free(capturedBufferList.unsafeMutablePointer)
            })
        return EchoCancellationCaptureTeardownOwner(
            state: state, deadline: deadline, operations: operations)
    }

    /// Marks the capsule as the only owner of callback-transitive resources.
    private func adoptTeardownOwnerLocked(
        _ owner: EchoCancellationCaptureTeardownOwner
    ) {
        if let teardownOwner {
            precondition(teardownOwner === owner)
            return
        }
        teardownOwner = owner
        activeCaptureBinding = nil
        activeFarEndBinding = nil
        restorableRates.removeAll()
    }

    var terminalLifecycleResult: EchoCancellationTeardownResult? {
        lifecycleLock.withLock { lastTeardownResult }
    }

    private func captureResult(
        from disposal: AudioUnitOwnerDisposalResult,
        owner: EchoCancellationCaptureTeardownOwner
    ) -> EchoCancellationTeardownResult {
        switch disposal {
        case .complete:
            return owner.teardownResult ?? .complete
        case .operationFailed(let step, let status, _):
            return owner.teardownResult ?? .audioUnit(step: step, status: status)
        case .timedOut(let step, _):
            return .lifecycleTimedOut(step: step)
        case .blockedByRetainedTransaction:
            return .lifecycleTimedOut(step: nil)
        case .ownerRetained:
            return owner.teardownResult ?? .lifecycleTimedOut(step: nil)
        }
    }

    private func canBeginLifecycleCommand() -> Bool {
        lifecycleLock.withLock {
            teardownOwner == nil && lastTeardownResult == nil
                && !lifecycleCommandInFlight
        }
    }

    private func performLifecycleCommand(
        step: AudioUnitTeardownStep,
        until deadline: HALTeardownDeadline,
        quarantineOnError: Bool,
        operation: @escaping () -> OSStatus
    ) -> OSStatus? {
        let admitted = lifecycleLock.withLock {
            guard teardownOwner == nil, lastTeardownResult == nil,
                !lifecycleCommandInFlight
            else { return false }
            lifecycleCommandInFlight = true
            return true
        }
        guard admitted else { return nil }

        let command = BoundedAudioUnitLifecycleCommand(
            retaining: self, step: step, quarantineOnError: quarantineOnError,
            operation: operation)
        let commandResult = BoundedAudioUnitDisposer.shared.dispose(
            command, until: deadline)
        let returnedStatus: OSStatus?
        switch commandResult {
        case .complete:
            returnedStatus = command.completedStatus
        case .operationFailed(let failedStep, let status, _):
            returnedStatus = status
            lifecycleLock.withLock {
                if lastTeardownResult == nil {
                    lastTeardownResult = .audioUnit(step: failedStep, status: status)
                }
            }
        case .timedOut(let timedOutStep, _):
            returnedStatus = nil
            lifecycleLock.withLock {
                if lastTeardownResult == nil {
                    lastTeardownResult = .lifecycleTimedOut(step: timedOutStep)
                }
            }
        case .blockedByRetainedTransaction:
            // The disposer cancelled the command under its own lock before it
            // could be promoted, so the operation provably never ran and the
            // unit is untouched. Both callers here are live control — setting
            // the bypass property, pausing for a start retry — and both already
            // treat a nil status as "it did not happen".
            //
            // Recording a teardown verdict for it was the wider copy of the
            // dropout defect: `lastTeardownResult` gates `stop()`, which
            // returns it before tearing anything down, and it also gates
            // `canBeginLifecycleCommand`, so every later command is refused
            // too. One deferred bypass toggle at the wrong instant poisoned the
            // capture for the life of the process.
            command.cancelBeforeStart()
            returnedStatus = nil
        case .ownerRetained:
            returnedStatus = nil
            lifecycleLock.withLock {
                if lastTeardownResult == nil {
                    lastTeardownResult = .lifecycleTimedOut(step: step)
                }
            }
        }
        lifecycleLock.withLock { lifecycleCommandInFlight = false }
        return returnedStatus
    }

    /// Releases closure owners only after the Audio Unit has fenced callbacks.
    private func clearCallbackBindings() {
        yun_rt_echo_callback_context_clear(callbackContext)
        if let activeCaptureBinding {
            activeCaptureBinding.deinitialize(count: 1)
            activeCaptureBinding.deallocate()
            self.activeCaptureBinding = nil
        }
        if let activeFarEndBinding {
            activeFarEndBinding.deinitialize(count: 1)
            activeFarEndBinding.deallocate()
            self.activeFarEndBinding = nil
        }
    }

    private static func allocateRealtimeCounter() -> OpaquePointer {
        guard let counter = yun_rt_counter_create(0) else {
            preconditionFailure("could not allocate echo-cancellation diagnostics")
        }
        return counter
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
