import CoreAudio
import Foundation
import YunAudioHAL
import YunAudioRT

/// Observable result for both halves of an echo-cancellation bridge.
public enum EchoCancellationBridgeTeardownResult: Sendable, Equatable {
    case complete
    case capture(EchoCancellationTeardownResult)
    case farEnd(FarEndCaptureTeardownResult)
    /// The sole lifecycle worker is still inside an operation which public
    /// Core Audio APIs do not make cancellable.
    case lifecycleTimedOut(step: AudioUnitTeardownStep?)

    public var isComplete: Bool { self == .complete }
}

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

/// The clock contract across the two rings surrounding echo cancellation.
///
/// A ring carries frames, not time. Reading one 44.1 kHz frame for every
/// 48 kHz frame requested does not convert the signal: it plays it at the wrong
/// speed and drains 3,900 frames per second faster than they arrive. The same
/// rule applies on both sides of the voice-processing unit, so all three rates
/// have to agree before callbacks are allowed to exchange frames one for one.
struct EchoCancellationRateContract: Sendable, Equatable {
    let farEndRate: Double?
    let captureRate: Double
    let routerRate: Double

    static let tolerance = 0.5

    var captureMatchesRouter: Bool {
        Self.ratesMatch(captureRate, routerRate)
    }

    var farEndMatchesCapture: Bool {
        guard let farEndRate else { return false }
        return Self.ratesMatch(farEndRate, captureRate)
    }

    var canCarryCancelledAudio: Bool {
        captureMatchesRouter
    }

    var canCarryFarEndReference: Bool {
        farEndMatchesCapture && captureMatchesRouter
    }

    static func ratesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        EchoCancellationCapacityPolicy.isValidSampleRate(lhs)
            && EchoCancellationCapacityPolicy.isValidSampleRate(rhs)
            && abs(lhs - rhs) < tolerance
    }

    /// Signed ring drift when frames are exchanged one for one.
    ///
    /// Positive means the producer fills the ring; negative means the consumer
    /// asks for frames faster than they arrive.
    static func driftFramesPerSecond(
        producerRate: Double, consumerRate: Double
    )
        -> Double?
    {
        guard EchoCancellationCapacityPolicy.isValidSampleRate(producerRate),
            EchoCancellationCapacityPolicy.isValidSampleRate(consumerRate)
        else { return nil }
        return producerRate - consumerRate
    }

    /// Time for a rate mismatch to consume one ring's worth of slack.
    ///
    /// A ring that starts empty can underflow immediately; this number measures
    /// how quickly an equivalent standing fill would be lost, or an empty ring
    /// would be filled to capacity.
    static func secondsToConsumeSlack(
        capacityFrames: Int, producerRate: Double, consumerRate: Double
    ) -> Double? {
        guard capacityFrames > 0,
            capacityFrames <= Int(EchoCancellationCapacityPolicy.maximumRingFrames),
            let drift = driftFramesPerSecond(
                producerRate: producerRate, consumerRate: consumerRate),
            abs(drift) >= tolerance
        else { return nil }
        return Double(capacityFrames) / abs(drift)
    }
}

/// Owns every completed inner object until bridge construction is published.
///
/// A construction timeout does not stop the vendor call already in flight. The
/// lane therefore invokes this owner only after the constructor returns, while
/// an ordinary thrown error invokes the same exact-once handoff from its defer.
/// Keeping both paths here prevents a late successful capture from becoming a
/// process-lifetime VoiceProcessingIO graph with no teardown transaction.
final class EchoCancellationBridgePartialConstructionOwner: @unchecked Sendable,
    AudioUnitTeardownOwner
{
    typealias CaptureCleanup =
        (AudioUnitTeardownGate, HALTeardownDeadline) -> AudioUnitOwnerDisposalResult
    typealias FarEndCleanup = (HALTeardownDeadline) -> Bool
    typealias Submit = (any AudioUnitTeardownOwner) -> Void

    private let lock = NSLock()
    private let submit: Submit
    private var captureCleanup: CaptureCleanup?
    private var farEndCleanup: FarEndCleanup?
    private var cleanupDeadline: HALTeardownDeadline?
    private var cleanupWasSubmitted = false

    init(
        submit: @escaping Submit = {
            BoundedAudioUnitDisposer.shared.disposeAfterFence($0)
        }
    ) {
        self.submit = submit
    }

    func adopt(_ capture: EchoCancellingCapture) {
        adoptCapture { gate, deadline in
            capture.detachForTeardown(until: deadline)
                .tearDownAudioUnits(using: gate)
        }
    }

    func adopt(_ farEnd: FarEndCapture) {
        adoptFarEnd { deadline in farEnd.stop(until: deadline).isComplete }
    }

    func relinquishFarEnd() {
        lock.withLock {
            precondition(!cleanupWasSubmitted)
            farEndCleanup = nil
        }
    }

    func adoptCapture(_ cleanup: @escaping CaptureCleanup) {
        lock.withLock {
            precondition(captureCleanup == nil && !cleanupWasSubmitted)
            captureCleanup = cleanup
        }
    }

    func adoptFarEnd(_ cleanup: @escaping FarEndCleanup) {
        lock.withLock {
            precondition(farEndCleanup == nil && !cleanupWasSubmitted)
            farEndCleanup = cleanup
        }
    }

    /// Atomically publishes this complete partial graph to the sole disposer.
    func disposeAfterConstruction() {
        let shouldSubmit = lock.withLock { () -> Bool in
            guard !cleanupWasSubmitted,
                captureCleanup != nil || farEndCleanup != nil
            else { return false }
            cleanupWasSubmitted = true
            cleanupDeadline = HALTeardownDeadline(timeout: 2)
            return true
        }
        if shouldSubmit { submit(self) }
    }

    var audioUnitCount: Int { lock.withLock { captureCleanup == nil ? 0 : 1 } }

    var hasTeardownWork: Bool {
        lock.withLock { captureCleanup != nil || farEndCleanup != nil }
    }

    func tearDownAudioUnits(
        using gate: AudioUnitTeardownGate
    ) -> AudioUnitOwnerDisposalResult {
        guard let deadline = lock.withLock({ cleanupDeadline }) else {
            return .blockedByRetainedTransaction(retainedUnits: audioUnitCount)
        }

        var disposedUnits = 0
        if let cleanup = lock.withLock({ captureCleanup }) {
            let result = cleanup(gate, deadline)
            guard result.isComplete else { return result }
            if case .complete(let count) = result { disposedUnits += count }
            lock.withLock { captureCleanup = nil }
        }

        // A timeout can become visible immediately after the unit is disposed.
        // Starting a HAL IOProc/aggregate teardown then would run beside the late
        // Audio Unit call this transaction deliberately quarantined.
        guard gate.admitsAnotherStep else {
            return .timedOut(step: gate.stepInFlight, disposedUnits: disposedUnits)
        }
        if let cleanup = lock.withLock({ farEndCleanup }) {
            guard cleanup(deadline) else {
                return .ownerRetained(disposedUnits: disposedUnits)
            }
            lock.withLock { farEndCleanup = nil }
        }
        return .complete(disposedUnits: disposedUnits)
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
    private let realtimeHandles: UnsafeMutablePointer<RealtimeHandles>
    private let lifecycleLock = NSLock()
    private var teardownOwner: EchoCancellationBridgeTeardownOwner?
    private var isRunning = false
    public private(set) var lastTeardownResult: EchoCancellationBridgeTeardownResult?

    /// Whether the stored verdict is the last word on this bridge.
    ///
    /// False while a teardown is only deferred — enqueued behind a graph
    /// admission or another transaction, and promoted when that completes. The
    /// router needs the difference to know whether another Stop can clear the
    /// route or whether only a relaunch can.
    public var teardownVerdictIsTerminal: Bool {
        lifecycleLock.withLock { lastTeardownResult != nil }
    }

    /// Which branch stored that verdict, for the divergence hunt.
    ///
    /// Five sites can write `lastTeardownResult` and the enum cannot tell them
    /// apart — `step: nil` came from three of them. Naming the decider is what
    /// found the last one; reasoning about which it must be is what got the
    /// three preceding attempts wrong.
    public private(set) var teardownDecidedBy = "never"

    /// - Parameters:
    ///   - microphoneUID: The microphone to capture and cancel for.
    ///   - settings: Speaker and far-end reference.
    ///   - routerSampleRate: Rate at which the router will drain cancelled
    ///     frames. The bridge refuses any capture clock that differs.
    ///   - maximumFrames: Largest block the unit will be asked for.
    /// - Throws: `EchoCancellationSetupError`, which the route records so the
    ///   interface can name the refusal instead of the feature disappearing.
    public convenience init(
        microphoneUID: String,
        settings: EchoCancellationSettings,
        routerSampleRate: Double,
        maximumFrames: Int = 512
    ) throws(EchoCancellationSetupError) {
        try self.init(
            microphoneUID: microphoneUID, settings: settings,
            routerSampleRate: routerSampleRate, maximumFrames: maximumFrames,
            constructionContext: nil)
    }

    /// Construction-lane entry point. The public standalone path has no
    /// cancellation context, while a route timeout must prevent every later
    /// HAL or Audio Unit stage from beginning.
    init(
        microphoneUID: String,
        settings: EchoCancellationSettings,
        routerSampleRate: Double,
        maximumFrames: Int,
        constructionContext: AudioUnitConstructionContext?,
        graphAdmission: BoundedAudioUnitDisposer.GraphAdmission? = nil
    ) throws(EchoCancellationSetupError) {
        guard EchoCancellationCapacityPolicy.isValidSampleRate(routerSampleRate) else {
            throw .unsafeCapacity(
                field: "router sample rate",
                value: String(describing: routerSampleRate))
        }
        guard
            EchoCancellationCapacityPolicy.requestedSliceFrames(maximumFrames) != nil
        else {
            throw .unsafeCapacity(
                field: "maximum slice", value: String(describing: maximumFrames))
        }
        guard constructionContext?.mayBeginOperation ?? true else {
            throw .audioOwnershipQuarantined
        }

        let partialOwner = EchoCancellationBridgePartialConstructionOwner()
        let cleanupRegistration: AudioUnitConstructionCleanupRegistration?
        if let constructionContext {
            guard
                let registration = constructionContext.deferCleanupAfterCancellation({
                    [partialOwner] in
                    partialOwner.disposeAfterConstruction()
                })
            else { throw .audioOwnershipQuarantined }
            cleanupRegistration = registration
        } else {
            cleanupRegistration = nil
        }
        var constructionCompleted = false
        defer {
            if !constructionCompleted { partialOwner.disposeAfterConstruction() }
        }

        // Build the far end first so its actual rate is known before accepting
        // it as a reference. The router's rate decides the canceller clock; a
        // tap on another clock is left out rather than consumed at the wrong
        // speed.
        let candidateReference =
            settings.farEndProcessIDs.isEmpty
            ? nil
            : FarEndCapture(
                processIDs: settings.farEndProcessIDs,
                muteBehavior: settings.tapMuteBehavior,
                constructionContext: constructionContext)
        if let candidateReference { partialOwner.adopt(candidateReference) }
        guard constructionContext?.mayBeginOperation ?? true else {
            throw .audioOwnershipQuarantined
        }

        let capture = try EchoCancellingCapture(
            microphoneUID: microphoneUID, speakerUID: settings.speakerUID,
            requiredSampleRate: routerSampleRate,
            maximumFrames: maximumFrames,
            constructionContext: constructionContext,
            graphAdmission: graphAdmission)
        partialOwner.adopt(capture)
        guard constructionContext?.mayBeginOperation ?? true else {
            throw EchoCancellationSetupError.audioOwnershipQuarantined
        }

        let contract = EchoCancellationRateContract(
            farEndRate: candidateReference?.sampleRate,
            captureRate: capture.sampleRate,
            routerRate: routerSampleRate)
        guard contract.canCarryCancelledAudio else {
            throw .captureClockDiffersFromRouter(
                captureRate: capture.sampleRate, routerRate: routerSampleRate)
        }
        guard constructionContext?.mayBeginOperation ?? true else {
            throw .audioOwnershipQuarantined
        }
        guard
            let allocation = EchoCancellationCapacityPolicy.ringAllocation(
                sampleRate: capture.sampleRate,
                seconds: 0.25,
                requestedSliceFrames: maximumFrames)
        else {
            throw .unsafeCapacity(
                field: "cancelled ring",
                value: "\(capture.sampleRate) Hz × 0.25 s")
        }

        // A mismatched process tap is not a reference at this clock. Running
        // the canceller blind is less capable, but remains time-correct; feeding
        // the ring one for one would change speed and inevitably underflow or
        // overflow it.
        let selectedReference =
            contract.canCarryFarEndReference ? candidateReference : nil
        if selectedReference == nil {
            guard constructionContext?.mayBeginOperation ?? true else {
                throw .audioOwnershipQuarantined
            }
            partialOwner.relinquishFarEnd()
            candidateReference?.disposeAfterFence()
        }
        farEnd = selectedReference
        self.capture = capture
        sampleRate = capture.sampleRate

        // A quarter of a second, as on the far-end side. Both ends of this ring
        // are realtime threads on the same nominal clock, so the standing fill
        // is a buffer or two; the rest is there so a stall costs latency rather
        // than a gap.
        guard let ring = yun_rt_ring_create(allocation.ringFrames) else {
            throw .cancelledRingNotAllocated(frames: Int(allocation.ringFrames))
        }
        cancelledRing = ring

        farEndScratchCapacity = allocation.scratchFrames
        farEndScratch = .allocate(capacity: farEndScratchCapacity)
        farEndScratch.initialize(repeating: 0, count: farEndScratchCapacity)
        realtimeHandles = .allocate(capacity: 1)
        realtimeHandles.initialize(
            to: RealtimeHandles(
                cancelledRing: ring, farEndRing: farEnd?.realtimeRing))

        // Do not cancel the registration here. Publication is the construction
        // lane accepting this return, not the last line of this initializer. A
        // deadline can win between those boundaries; in that case the context
        // runs the registered cleanup before retaining the late result. A normal
        // completed transaction releases the registration without invoking it.
        constructionCompleted = true
        withExtendedLifetime(cleanupRegistration) {}
    }

    deinit {
        if lifecycleLock.withLock({ teardownOwner }) != nil { return }
        // A timed-out Start or retry command already owns the capture on the
        // sole worker. Submitting a replacement owner here would manufacture a
        // second cleanup attempt. Raw bridge storage intentionally leaks in
        // this terminal process state so a possible late callback stays valid.
        if let captureTerminal = capture.terminalLifecycleResult,
            !captureTerminal.isComplete
        {
            if let farEnd { _ = Unmanaged.passRetained(farEnd).toOpaque() }
            return
        }
        let detached = detachForTeardown(until: HALTeardownDeadline(timeout: 2))
        BoundedAudioUnitDisposer.shared.disposeAfterFence(detached)
    }

    /// - Returns: False when either unit refused to start, in which case
    ///   nothing is left running.
    public func start() -> Bool {
        guard !isRunning else { return true }
        lastTeardownResult = nil
        let lifecycleDeadline = HALTeardownDeadline(timeout: 2)

        if let farEnd,
            startFarEnd(farEnd, until: lifecycleDeadline) != true
        {
            // An ordinary start refusal is not fatal. Without a reference the
            // canceller still suppresses steady noise; saying so beats refusing
            // to route. A failed cleanup is different: carrying a retained
            // IOProc into a new route would compound the fault.
            farEndReferenceFailed = true
            if lastTeardownResult?.isComplete == false { return false }
        }

        // `AudioOutputUnitStart` can return success without ever driving a
        // callback. Observed in the full flow: the route advertised a live
        // canceller and its produced-frame count stayed at zero indefinitely.
        // Success is two callbacks, not the return code; retry the unchanged
        // unit once, as CoreAudio commonly recovers on the second start.
        for _ in 0..<2 where lifecycleDeadline.hasTimeRemaining {
            if let farEnd {
                _ = farEnd.discardBufferedFrames(
                    into: farEndScratch,
                    capacity: farEndScratchCapacity)
            }
            let writtenBefore = producedFrames
            let started = capture.startRaw(
                captureContext: UnsafeMutableRawPointer(realtimeHandles),
                captureHandler: Self.captureHandler,
                farEndContext: UnsafeMutableRawPointer(realtimeHandles),
                farEndProvider: farEnd == nil ? nil : Self.farEndProvider,
                until: lifecycleDeadline)
            if !started, capture.terminalLifecycleResult != nil { break }
            if started {
                let proofDeadline = DispatchTime.now() + .milliseconds(750)
                while DispatchTime.now() < proofDeadline,
                    lifecycleDeadline.hasTimeRemaining,
                    producedFrames == writtenBefore
                {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if producedFrames > writtenBefore {
                    isRunning = true
                    return true
                }
                guard capture.pauseForRetry(until: lifecycleDeadline) == noErr else {
                    break
                }
            }
        }
        _ = stop(until: lifecycleDeadline)
        return false
    }

    /// Runs the far-end IOProc's complete start/proof/failure cleanup on the
    /// same sole worker as VoiceProcessingIO. A hung `AudioDeviceStart` or its
    /// failed-start Stop can therefore consume one worker, but cannot block the
    /// route caller or be followed by a replacement cleanup thread.
    private func startFarEnd(
        _ farEnd: FarEndCapture,
        until deadline: HALTeardownDeadline
    ) -> Bool? {
        final class StartResult: @unchecked Sendable {
            var started = false
        }

        let startResult = StartResult()
        let command = BoundedAudioUnitLifecycleCommand(
            retaining: self, step: .start, quarantineOnError: true
        ) {
            startResult.started = farEnd.start()
            // An ordinary unavailable reference is not unsafe and AEC can run
            // blind. A failed cleanup means ownership is uncertain, so keep the
            // command and this whole bridge quarantined.
            return startResult.started || farEnd.lastTeardownResult?.isComplete != false
                ? noErr : kAudioHardwareUnspecifiedError
        }
        let commandResult = BoundedAudioUnitDisposer.shared.dispose(
            command, until: deadline)
        switch commandResult {
        case .complete:
            return startResult.started
        case .operationFailed:
            let result =
                farEnd.lastTeardownResult.map {
                    EchoCancellationBridgeTeardownResult.farEnd($0)
                } ?? .lifecycleTimedOut(step: .start)
            lifecycleLock.withLock {
                lastTeardownResult = result
                teardownDecidedBy = "startFarEnd.operationFailed"
            }
            return nil
        case .timedOut(let step, _):
            lifecycleLock.withLock {
                lastTeardownResult = .lifecycleTimedOut(step: step)
                teardownDecidedBy = "startFarEnd.timedOut"
            }
            return nil
        case .blockedByRetainedTransaction:
            // The disposer cancels a deferred command under its own lock before
            // it can be promoted, so `AudioDeviceStart` provably never ran and
            // the far-end unit was never touched. That is the ordinary start
            // refusal `start()` already tolerates — the canceller runs without a
            // reference — and not a failed cleanup.
            //
            // Recording it as a terminal teardown verdict is what turned an
            // instant of contention into a dead process: `stop()` returns
            // `lastTeardownResult` before tearing anything down, so the very
            // next Stop freed nothing, reported an incomplete teardown, and the
            // router quarantined a route whose graph was already gone. Every
            // subsequent Stop short-circuited on the same stale verdict, which
            // is why the only cure anybody found was relaunching.
            command.cancelBeforeStart()
            return false
        case .ownerRetained:
            // Distinct from the above on purpose. This one means a transaction
            // ran and retained its owner, so the start may have got far enough
            // to change callback ownership; nothing here can prove it did not.
            command.cancelBeforeStart()
            lifecycleLock.withLock {
                lastTeardownResult = .lifecycleTimedOut(step: nil)
                teardownDecidedBy = "startFarEnd.ownerRetained"
            }
            return nil
        }
    }

    /// Tears the callback consumer down before its far-end producer.
    ///
    /// The capture render callback reads the far-end ring through a raw pointer,
    /// so reversing this order would free that ring while a failed voice-unit
    /// stop could still call it.
    @discardableResult
    public func stop(timeout: TimeInterval = 2) -> EchoCancellationBridgeTeardownResult {
        stop(until: HALTeardownDeadline(timeout: timeout))
    }

    /// Uses one absolute budget for the callback consumer and producer.
    @discardableResult
    public func stop(
        until deadline: HALTeardownDeadline
    ) -> EchoCancellationBridgeTeardownResult {
        if let terminal = lifecycleLock.withLock({ lastTeardownResult }) {
            return terminal
        }
        if let captureTerminal = capture.terminalLifecycleResult,
            !captureTerminal.isComplete
        {
            let result = EchoCancellationBridgeTeardownResult.capture(captureTerminal)
            lifecycleLock.withLock {
                lastTeardownResult = result
                teardownDecidedBy = "stop.captureAlreadyTerminal"
            }
            return result
        }

        let detached = detachForTeardown(until: deadline)
        let disposal = BoundedAudioUnitDisposer.shared.dispose(detached, until: deadline)
        let result: EchoCancellationBridgeTeardownResult
        let disposalBranch: String
        // Whether this verdict is the last word, or whether the work is still
        // queued and another Stop can finish it.
        //
        // The distinction is the difference between a route somebody can
        // recover and one that needs the application relaunched, and it was
        // not being made: every non-complete result was stored, and `stop()`
        // returns the stored one before tearing anything down. A teardown
        // merely waiting behind another transaction therefore became permanent
        // at the instant it was deferred.
        let isTerminal: Bool
        switch disposal {
        case .complete:
            result = detached.teardownResult ?? .complete
            disposalBranch = "complete"
            isTerminal = true
        case .operationFailed(let step, let status, _):
            result =
                detached.teardownResult
                ?? .capture(.audioUnit(step: step, status: status))
            disposalBranch = "operationFailed"
            isTerminal = true
        case .timedOut(let step, _):
            // The worker is inside a call Core Audio gives no way to cancel.
            // Ownership is genuinely uncertain and stays that way.
            result = .lifecycleTimedOut(step: step)
            disposalBranch = "timedOut"
            isTerminal = true
        case .ownerRetained:
            // A verdict from the owner itself means its transaction ran and
            // reached a conclusion. Without one, nothing ran.
            result = detached.teardownResult ?? .lifecycleTimedOut(step: nil)
            disposalBranch = "ownerRetained"
            isTerminal = detached.teardownResult != nil
        case .blockedByRetainedTransaction:
            // The owner is enqueued behind a graph admission or another
            // transaction, and the disposer promotes it when that completes.
            // Nothing has failed: the teardown has not happened *yet*. Saying
            // so lets the next Stop pick up the finished result, which is
            // exactly what the interface tells somebody to do.
            result = detached.teardownResult ?? .lifecycleTimedOut(step: nil)
            disposalBranch = "blockedByRetainedTransaction"
            isTerminal = detached.teardownResult != nil
        }
        lifecycleLock.withLock {
            if lastTeardownResult == nil, isTerminal {
                lastTeardownResult = result
                teardownDecidedBy = "stop.\(disposalBranch)"
            }
        }
        let terminal = lifecycleLock.withLock { lastTeardownResult ?? result }
        if terminal.isComplete { isRunning = false }
        return terminal
    }

    /// Exactly-once transfer of both callback sides and all shared raw storage.
    private func detachForTeardown(
        until deadline: HALTeardownDeadline
    ) -> EchoCancellationBridgeTeardownOwner {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if let teardownOwner { return teardownOwner }

        let captureOwner = capture.detachForTeardown(until: deadline)
        let retainedFarEnd = farEnd
        let retainedHandles = realtimeHandles
        let retainedScratch = farEndScratch
        let retainedRing = cancelledRing
        let owner = EchoCancellationBridgeTeardownOwner(
            capture: captureOwner,
            deadline: deadline,
            stopFarEnd: { transactionDeadline in
                retainedFarEnd?.stop(until: transactionDeadline)
            },
            releaseStorage: {
                retainedHandles.deinitialize(count: 1)
                retainedHandles.deallocate()
                retainedScratch.deallocate()
                yun_rt_ring_free(retainedRing)
            })
        teardownOwner = owner
        return owner
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
    /// Callback entries refused because an earlier entry was still active.
    public var callbackOverlaps: UInt64 { capture.callbackOverlapCount }
    public var renderDiagnostics: EchoCancellationRenderDiagnostics? {
        capture.renderDiagnosticsSnapshot
    }
    public var renderFailures: UInt64 { capture.renderFailureCount }
    public var lastRenderStatus: OSStatus { capture.lastRenderStatus }

    /// Turns the cancellation off while leaving the same path in place, which
    /// is what makes its effect measurable rather than merely asserted.
    @discardableResult
    public func setBypassed(
        _ bypassed: Bool, timeout: TimeInterval = 0.5
    ) -> EchoCancellationControlResult {
        capture.setBypassed(bypassed, timeout: timeout)
    }

    /// Raw handlers used by the production route. Both reach only POD and C
    /// rings, so Release object code contains no ARC calls on either callback.
    static let captureHandler:
        @convention(c) (
            UnsafeMutableRawPointer, UnsafePointer<Float>, UInt32,
            UnsafePointer<AudioTimeStamp>
        ) -> Void = { rawHandles, samples, frames, _ in
            guard
                frames
                    <= UInt32(
                        EchoCancellationCapacityPolicy.maximumCaptureBufferFrames)
            else { return }
            let handles = rawHandles.assumingMemoryBound(to: RealtimeHandles.self)
            _ = yun_rt_ring_write(handles.pointee.cancelledRing, samples, frames)
        }

    static let farEndProvider:
        @convention(c) (
            UnsafeMutableRawPointer, UnsafeMutablePointer<Float>, UInt32
        ) -> Int64 = { rawHandles, destination, frames in
            guard AudioProcessingContract.supports(framesPerSlice: frames) else {
                return 0
            }
            let handles = rawHandles.assumingMemoryBound(to: RealtimeHandles.self)
            guard let ring = handles.pointee.farEndRing else { return 0 }
            let taken = yun_rt_ring_read(ring, destination, frames)
            for index in 0..<Int(taken) {
                destination[index] = sanitisedAudioSample(destination[index])
            }
            return Int64(taken)
        }

    /// Copies process audio into the stateful voice-processing unit.
    ///
    /// The route graph sanitises every sample it emits, but the far-end
    /// reference reaches `AUVoiceProcessingIO` before that graph. One NaN from
    /// a captured application can otherwise enter the canceller's adaptive
    /// history and keep its later output non-finite after the source recovers.
    @inline(__always)
    static func copySafeReference(
        from source: UnsafePointer<Float>,
        to destination: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        guard AudioProcessingContract.supports(framesPerSlice: count)
        else { return }
        for index in 0..<count {
            destination[index] = sanitisedAudioSample(source[index])
        }
    }
}

/// The pointers the realtime callbacks need, in one immutable allocation.
///
/// What keeps these valid is lifetime, not synchronisation. The bridge stops
/// the consumer before the far-end producer and frees this only after both
/// callback fences hold.
struct RealtimeHandles: @unchecked Sendable {
    let cancelledRing: OpaquePointer
    let farEndRing: OpaquePointer?
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
    /// Callback entries refused because an earlier entry was still active.
    /// This must remain zero: a non-zero value is evidence that Core Audio
    /// entered a nominally serial render path concurrently.
    public let callbackOverlaps: UInt64
    public let renderFailures: UInt64
    public let lastRenderStatus: OSStatus
}
