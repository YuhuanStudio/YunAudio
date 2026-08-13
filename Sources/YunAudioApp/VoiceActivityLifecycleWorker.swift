import CoreAudio
import Foundation
import YunAudioEngine
import YunAudioHAL

/// Identity of one requested system voice-detector state.
///
/// Tokens cross the worker/MainActor boundary as values. The MainActor keeps
/// the newest one, so a result which was already in flight when Stop ran can
/// never put a detector or a warning back into the interface.
struct VoiceActivityLifecycleToken: Hashable, Sendable {
    fileprivate let value: UInt64
}

/// Value-only publications from the sole voice-detector HAL worker.
enum VoiceActivityLifecycleEvent: Equatable, Sendable {
    case availability(VoiceActivityLifecycleToken, Bool)
    case started(VoiceActivityLifecycleToken, available: Bool, observing: Bool)
    case speaking(VoiceActivityLifecycleToken, Bool)
    case timedOut(VoiceActivityLifecycleToken, ownerMayExist: Bool)
}

/// What a bounded caller can prove about detector cleanup.
enum VoiceActivityStopResult: Equatable, Sendable {
    case complete
    case operationFailed
    case timedOut

    var isComplete: Bool { self == .complete }
}

/// Complete application audio ownership, not merely the routing engine half.
enum ApplicationAudioTeardownResult: Equatable, Sendable {
    case complete
    case routing(RoutingTeardownResult)
    case voiceActivity(VoiceActivityStopResult)
    case transcription(OwnedResourceTeardownResult)
    case localSong(OwnedResourceTeardownResult)
    case lighting(OwnedResourceTeardownResult)

    var isComplete: Bool { self == .complete }

    /// Whether process death can provide the final containment boundary.
    ///
    /// The route and device-global voice detector have to be proven down before
    /// AppKit may exit: otherwise this process can leave shared Core Audio state
    /// behind. The song graph and HID ring are process-local. Their failed or
    /// timed-out answers remain an unclean diagnostic, but keeping the process
    /// alive cannot retry their one-shot fences and is worse containment than
    /// allowing the kernel to reclaim them.
    var allowsProcessExit: Bool {
        switch self {
        case .complete, .transcription, .localSong, .lighting:
            true
        case .routing, .voiceActivity:
            false
        }
    }
}

/// Every owner result from one application termination attempt.
///
/// `ApplicationAudioTeardownResult` remains the user-facing priority answer.
/// Recovery after AppKit refuses Quit needs the complete tuple: a route failure
/// must not hide that the local song or HID owner also timed out, because only
/// a proven-complete process-local owner may be replaced.
struct ApplicationAudioTeardownReport: Equatable, Sendable {
    let routing: RoutingTeardownResult
    let voiceActivity: VoiceActivityStopResult
    let transcription: OwnedResourceTeardownResult
    let localSong: OwnedResourceTeardownResult
    let lighting: OwnedResourceTeardownResult

    var result: ApplicationAudioTeardownResult {
        if !routing.isComplete { return .routing(routing) }
        if !voiceActivity.isComplete { return .voiceActivity(voiceActivity) }
        if !transcription.isComplete { return .transcription(transcription) }
        if !localSong.isComplete { return .localSong(localSong) }
        if !lighting.isComplete { return .lighting(lighting) }
        return .complete
    }
}

/// Joins independently scheduled route and detector teardown exactly once.
@MainActor
final class ApplicationAudioShutdownJoin {
    private var routing: RoutingTeardownResult?
    private var voiceActivity: VoiceActivityStopResult?
    private var transcription: OwnedResourceTeardownResult?
    private var localSong: OwnedResourceTeardownResult?
    private var lighting: OwnedResourceTeardownResult?
    private var didComplete = false
    private let completion: @MainActor (ApplicationAudioTeardownReport) -> Void

    init(completion: @escaping @MainActor (ApplicationAudioTeardownResult) -> Void) {
        self.completion = { completion($0.result) }
    }

    init(reporting completion: @escaping @MainActor (ApplicationAudioTeardownReport) -> Void) {
        self.completion = completion
    }

    func receive(routing result: RoutingTeardownResult) {
        guard routing == nil else { return }
        routing = result
        finishIfReady()
    }

    func receive(voiceActivity result: VoiceActivityStopResult) {
        guard voiceActivity == nil else { return }
        voiceActivity = result
        finishIfReady()
    }

    func receive(transcription result: OwnedResourceTeardownResult) {
        guard transcription == nil else { return }
        transcription = result
        finishIfReady()
    }

    func receive(localSong result: OwnedResourceTeardownResult) {
        guard localSong == nil else { return }
        localSong = result
        finishIfReady()
    }

    func receive(lighting result: OwnedResourceTeardownResult) {
        guard lighting == nil else { return }
        lighting = result
        finishIfReady()
    }

    private func finishIfReady() {
        guard !didComplete, let routing, let voiceActivity, let transcription,
            let localSong, let lighting
        else { return }
        didComplete = true
        completion(
            ApplicationAudioTeardownReport(
                routing: routing, voiceActivity: voiceActivity,
                transcription: transcription,
                localSong: localSong, lighting: lighting))
    }
}

/// One cleanup epoch shared by every repeated Stop request.
///
/// Waiting is never performed on MainActor or the route owner. The group is a
/// result primitive rather than a work queue: a synchronous HAL call which
/// never returns consumes only the detector's one worker.
final class VoiceActivityStopFence: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var result: VoiceActivityStopResult?
    private var completionCountStorage = 0

    init(completedWith result: VoiceActivityStopResult? = nil) {
        completion.enter()
        if let result { complete(result) }
    }

    @discardableResult
    func complete(_ result: VoiceActivityStopResult) -> Bool {
        let didComplete = lock.withLock {
            guard self.result == nil else { return false }
            self.result = result
            completionCountStorage += 1
            return true
        }
        if didComplete { completion.leave() }
        return didComplete
    }

    func wait(timeout: TimeInterval) -> VoiceActivityStopResult {
        let timeout = max(0, timeout)
        guard completion.wait(timeout: .now() + timeout) == .success else {
            return .timedOut
        }
        return lock.withLock { result ?? .timedOut }
    }

    var completionCount: Int { lock.withLock { completionCountStorage } }
}

/// Runs every potentially blocking voice-detector call on one bounded lane.
///
/// Core Audio property calls cannot be cancelled. A timeout therefore closes
/// admission and, once an activation call may own global state, retains this
/// worker in the process-wide audio quarantine. It does not start a replacement
/// thread. A late result either proves its candidate was cleaned or stays
/// quarantined; it is never published after a newer request.
final class VoiceActivityLifecycleWorker<Owner: AnyObject & Sendable>:
    @unchecked Sendable
{
    struct Operations: Sendable {
        let isAvailable: @Sendable (AudioObjectID) -> Bool
        let start:
            @Sendable (
                AudioObjectID,
                VoiceActivityActivationPolicy,
                @escaping @Sendable (Bool) -> Void,
                @escaping @Sendable () -> Void
            ) -> Owner?
        let isObserving: @Sendable (Owner) -> Bool
        let stop: @Sendable (Owner) -> Bool
    }

    struct Telemetry: Equatable, Sendable {
        let submittedRequests: UInt64
        let startedOperations: UInt64
        let coalescedRequests: UInt64
        let timedOutOperations: UInt64
        let refusedRequests: UInt64
        let maximumPendingRequests: Int
        let maximumConcurrentOperations: Int
    }

    private enum Kind: Sendable {
        case availability(AudioObjectID)
        case start(AudioObjectID, VoiceActivityActivationPolicy)
        case stop

        var mayConstructOwner: Bool {
            if case .start = self { return true }
            return false
        }

        var isStop: Bool {
            if case .stop = self { return true }
            return false
        }
    }

    private struct Request: Sendable {
        let token: VoiceActivityLifecycleToken
        let kind: Kind
    }

    static var defaultOperationTimeout: TimeInterval { 0.5 }

    private let lock = NSLock()
    private let worker: DispatchQueue
    private let deadlineQueue: DispatchQueue
    private let deadlineTimer: DispatchSourceTimer
    private let operations: Operations
    private let publish: @Sendable (VoiceActivityLifecycleEvent) -> Void
    private let quarantine: ProcessLifetimeAudioQuarantine
    private let operationTimeout: TimeInterval

    private var generation: UInt64 = 0
    private var desired: Request?
    private var pending: Request?
    private var drainIsScheduled = false
    private var active: Request?
    private var activeDeadlineNanoseconds: UInt64 = 0
    private var activeMayOwn = false
    private var activeTimedOut = false
    private var activeOwnerRiskResolved = false
    private var constructionCleanupFailed = false
    private var pendingSpeaking: Bool?

    private var owner: Owner?
    private var ownerToken: VoiceActivityLifecycleToken?
    private var failedOwner: Owner?
    private var permanentFailure: VoiceActivityStopResult?
    private var stopFence: VoiceActivityStopFence?
    private var quarantineToken: ProcessLifetimeAudioQuarantine.Token?
    private var workerIsStalled = false

    private var submittedRequests: UInt64 = 0
    private var startedOperations: UInt64 = 0
    private var coalescedRequests: UInt64 = 0
    private var timedOutOperations: UInt64 = 0
    private var refusedRequests: UInt64 = 0
    private var maximumPendingRequests = 0
    private var concurrentOperations = 0
    private var maximumConcurrentOperations = 0

    init(
        operations: Operations,
        quarantine: ProcessLifetimeAudioQuarantine = .shared,
        operationTimeout: TimeInterval = VoiceActivityLifecycleWorker.defaultOperationTimeout,
        label: String = "com.yuhuanstudio.yunaudio.voice-activity-lifecycle",
        publish: @escaping @Sendable (VoiceActivityLifecycleEvent) -> Void
    ) {
        self.operations = operations
        self.quarantine = quarantine
        self.operationTimeout = max(0, operationTimeout)
        self.publish = publish
        worker = DispatchQueue(label: label, qos: .utility)
        deadlineQueue = DispatchQueue(label: label + ".deadline", qos: .utility)
        deadlineTimer = DispatchSource.makeTimerSource(queue: deadlineQueue)
        deadlineTimer.setEventHandler { [weak self] in self?.operationDeadlineReached() }
        deadlineTimer.schedule(deadline: .distantFuture)
        deadlineTimer.resume()
    }

    deinit { deadlineTimer.cancel() }

    /// Coalesces a capability storm to the first call already running and one
    /// newest value. A stalled read closes this detector lane, not route Stop.
    func requestAvailability(on device: AudioObjectID) -> VoiceActivityLifecycleToken? {
        submit(.availability(device))
    }

    /// Requests explicit detector ownership. Callers still have to pass the
    /// opt-in policy; there is no implicit enabling default in this boundary.
    func requestStart(
        on device: AudioObjectID,
        activation: VoiceActivityActivationPolicy
    ) -> VoiceActivityLifecycleToken? {
        submit(.start(device, activation))
    }

    /// Invalidates callbacks synchronously and returns the one cleanup fence.
    ///
    /// The fence is completed immediately when no activation call has entered
    /// and no watcher exists. Otherwise process-wide audio admission closes
    /// before this method returns, preventing a route restart from racing an
    /// unresolved device-global property owner.
    func requestStop() -> VoiceActivityStopFence {
        var shouldSchedule = false
        let fence: VoiceActivityStopFence = lock.withLock {
            generation &+= 1
            let request = Request(
                token: VoiceActivityLifecycleToken(value: generation), kind: .stop)
            desired = request
            pendingSpeaking = nil
            submittedRequests &+= 1

            if let permanentFailure {
                pending = request
                shouldSchedule = scheduleLocked(request)
                return VoiceActivityStopFence(completedWith: permanentFailure)
            }

            let ownerRisk = owner != nil || failedOwner != nil || activeMayOwn
            if ownerRisk {
                ensureQuarantineLocked(reason: "System voice detector cleanup")
                if let stopFence {
                    pending = request
                    _ = scheduleLocked(request)
                    return stopFence
                }
                let fence = VoiceActivityStopFence()
                stopFence = fence
                pending = request
                shouldSchedule = scheduleLocked(request)
                return fence
            }

            // An availability read may still be blocked, but it has neither a
            // listener nor a property baseline to restore. Cancelling its token
            // is sufficient evidence for application termination.
            pending = request
            shouldSchedule = scheduleLocked(request)
            return VoiceActivityStopFence(completedWith: .complete)
        }
        if shouldSchedule { scheduleDrain() }
        return fence
    }

    var telemetry: Telemetry {
        lock.withLock {
            Telemetry(
                submittedRequests: submittedRequests,
                startedOperations: startedOperations,
                coalescedRequests: coalescedRequests,
                timedOutOperations: timedOutOperations,
                refusedRequests: refusedRequests,
                maximumPendingRequests: maximumPendingRequests,
                maximumConcurrentOperations: maximumConcurrentOperations)
        }
    }

    private func submit(_ kind: Kind) -> VoiceActivityLifecycleToken? {
        var shouldSchedule = false
        let token: VoiceActivityLifecycleToken? = lock.withLock {
            guard permanentFailure == nil, stopFence == nil, !workerIsStalled else {
                refusedRequests &+= 1
                return nil
            }
            if kind.mayConstructOwner, quarantineToken == nil,
                quarantine.refusalForNewAudioOwnership() != nil
            {
                // A retained route, tap or Audio Unit is already an uncertain
                // Core Audio owner. A read-only capability answer is still
                // useful, but this device-global property owner must not be
                // created beside it.
                refusedRequests &+= 1
                return nil
            }
            generation &+= 1
            let token = VoiceActivityLifecycleToken(value: generation)
            let request = Request(token: token, kind: kind)
            desired = request
            submittedRequests &+= 1

            if kind.mayConstructOwner, owner != nil || activeMayOwn {
                ensureQuarantineLocked(reason: "System voice detector transition")
            }
            shouldSchedule = scheduleLocked(request)
            return token
        }
        if shouldSchedule { scheduleDrain() }
        return token
    }

    private func scheduleLocked(_ request: Request) -> Bool {
        if drainIsScheduled {
            if pending != nil { coalescedRequests &+= 1 }
            pending = request
            maximumPendingRequests = max(maximumPendingRequests, 1)
            return false
        }
        pending = request
        drainIsScheduled = true
        maximumPendingRequests = max(maximumPendingRequests, 1)
        return true
    }

    private func scheduleDrain() {
        worker.async { [self] in drain() }
    }

    private func drain() {
        while true {
            guard let request = beginNextRequest() else { return }
            run(request)
            finish(request)
        }
    }

    private func beginNextRequest() -> Request? {
        let request: Request? = lock.withLock {
            guard let pending else {
                drainIsScheduled = false
                return nil
            }
            self.pending = nil
            active = pending
            activeMayOwn = false
            activeTimedOut = false
            activeOwnerRiskResolved = false
            constructionCleanupFailed = false
            pendingSpeaking = nil
            workerIsStalled = false
            startedOperations &+= 1
            concurrentOperations += 1
            maximumConcurrentOperations = max(
                maximumConcurrentOperations, concurrentOperations)

            let now = DispatchTime.now().uptimeNanoseconds
            let interval = operationTimeout * 1_000_000_000
            let duration =
                interval.isFinite && interval < Double(UInt64.max)
                ? UInt64(interval) : UInt64.max
            activeDeadlineNanoseconds =
                duration > UInt64.max - now ? UInt64.max : now + duration
            return pending
        }
        if request != nil {
            deadlineTimer.schedule(deadline: .now() + operationTimeout)
        }
        return request
    }

    private func run(_ request: Request) {
        switch request.kind {
        case .availability(let device):
            let available = operations.isAvailable(device)
            if isAdmitted(request) {
                emitIfCurrent(.availability(request.token, available))
            }

        case .start(let device, let activation):
            guard cleanPublishedOwner(for: request), isAdmitted(request) else { return }

            let available = operations.isAvailable(device)
            guard isAdmitted(request) else { return }
            guard available else {
                emitIfCurrent(.started(request.token, available: false, observing: false))
                return
            }

            let entered = lock.withLock {
                guard active?.token == request.token, !activeTimedOut,
                    desired?.token == request.token, permanentFailure == nil
                else { return false }
                activeMayOwn = true
                return true
            }
            guard entered else { return }

            let candidate = operations.start(
                device,
                activation,
                { [weak self] speaking in
                    self?.receiveSpeaking(speaking, from: request.token)
                },
                { [weak self] in
                    self?.recordConstructionCleanupFailure(for: request.token)
                })

            let disposition: (publish: Bool, initial: Bool?) = lock.withLock {
                guard let candidate else { return (false, nil) }
                guard active?.token == request.token, !activeTimedOut,
                    desired?.token == request.token, permanentFailure == nil,
                    !constructionCleanupFailed
                else { return (false, nil) }
                owner = candidate
                ownerToken = request.token
                activeMayOwn = false
                let initial = pendingSpeaking
                pendingSpeaking = nil
                return (true, initial)
            }

            if disposition.publish, let candidate {
                releaseTransitionQuarantineIfSafe()
                emitIfCurrent(
                    .started(
                        request.token, available: true,
                        observing: operations.isObserving(candidate)))
                if let initial = disposition.initial {
                    emitIfCurrent(.speaking(request.token, initial))
                }
                return
            }

            guard let candidate else {
                let uncertain = lock.withLock {
                    active?.token == request.token
                        && (activeTimedOut || constructionCleanupFailed)
                }
                if uncertain { retainPermanentFailure(nil, result: .operationFailed) }
                return
            }
            let cleaned = operations.stop(candidate)
            lock.withLock { activeMayOwn = false }
            if !cleaned {
                retainPermanentFailure(candidate, result: .operationFailed)
            } else {
                lock.withLock { activeOwnerRiskResolved = true }
                releaseTransitionQuarantineIfSafe()
            }

        case .stop:
            _ = cleanPublishedOwner(for: request)
        }
    }

    private func cleanPublishedOwner(for request: Request) -> Bool {
        let existing: Owner? = lock.withLock {
            guard let owner else { return nil }
            self.owner = nil
            ownerToken = nil
            pendingSpeaking = nil
            activeMayOwn = true
            return owner
        }
        guard let existing else { return lock.withLock { permanentFailure == nil } }

        let cleaned = operations.stop(existing)
        lock.withLock { activeMayOwn = false }
        guard cleaned else {
            retainPermanentFailure(existing, result: .operationFailed)
            return false
        }
        lock.withLock { activeOwnerRiskResolved = true }
        return true
    }

    private func finish(_ request: Request) {
        deadlineTimer.schedule(deadline: .distantFuture)

        var fenceCompletion: (VoiceActivityStopFence, VoiceActivityStopResult)?
        var releaseToken: ProcessLifetimeAudioQuarantine.Token?
        lock.withLock {
            if active?.token == request.token {
                active = nil
                activeMayOwn = false
                activeDeadlineNanoseconds = 0
                concurrentOperations -= 1
            }

            if let failure = permanentFailure {
                if let stopFence {
                    fenceCompletion = (stopFence, failure)
                    self.stopFence = nil
                }
                return
            }

            workerIsStalled = false
            let hasUncertainOwner = activeMayOwn || failedOwner != nil
            if desired?.kind.isStop == true, owner == nil, !hasUncertainOwner {
                if let stopFence {
                    fenceCompletion = (stopFence, .complete)
                    self.stopFence = nil
                }
                releaseToken = quarantineToken
                quarantineToken = nil
            } else if (owner != nil || activeOwnerRiskResolved), stopFence == nil,
                !hasUncertainOwner
            {
                // This token guarded replacement of an older watcher. The new
                // watcher is the current, deliberate owner and is no residue.
                releaseToken = quarantineToken
                quarantineToken = nil
            }
        }
        if let releaseToken { quarantine.release(releaseToken) }
        // The fence is the ownership truth seen by route teardown. Publish it
        // only after process-wide admission no longer sees this transition as
        // quarantined; otherwise a waiter can observe `.complete` and still be
        // refused by the residue registry for one scheduling turn.
        if let fenceCompletion {
            _ = fenceCompletion.0.complete(fenceCompletion.1)
        }
    }

    private func isAdmitted(_ request: Request) -> Bool {
        lock.withLock {
            active?.token == request.token && desired?.token == request.token
                && !activeTimedOut && permanentFailure == nil
        }
    }

    private func receiveSpeaking(
        _ speaking: Bool,
        from token: VoiceActivityLifecycleToken
    ) {
        let shouldPublish = lock.withLock {
            guard desired?.token == token, permanentFailure == nil else { return false }
            if ownerToken == token { return true }
            guard active?.token == token, activeMayOwn else { return false }
            pendingSpeaking = speaking
            return false
        }
        if shouldPublish { emitIfCurrent(.speaking(token, speaking)) }
    }

    private func emitIfCurrent(_ event: VoiceActivityLifecycleEvent) {
        let token: VoiceActivityLifecycleToken
        let isTimeout: Bool
        switch event {
        case .availability(let value, _), .started(let value, _, _),
            .speaking(let value, _):
            token = value
            isTimeout = false
        case .timedOut(let value, _):
            token = value
            isTimeout = true
        }
        guard
            lock.withLock({
                guard desired?.token == token, permanentFailure == nil else { return false }
                if !isTimeout, active?.token == token, activeTimedOut { return false }
                return true
            })
        else { return }
        publish(event)
    }

    private func recordConstructionCleanupFailure(
        for token: VoiceActivityLifecycleToken
    ) {
        lock.withLock {
            guard active?.token == token else { return }
            constructionCleanupFailed = true
            ensureQuarantineLocked(reason: "System voice detector activation cleanup failed")
        }
    }

    private func retainPermanentFailure(
        _ failedOwner: Owner?,
        result: VoiceActivityStopResult
    ) {
        var fence: VoiceActivityStopFence?
        lock.withLock {
            if let failedOwner { self.failedOwner = failedOwner }
            permanentFailure = result
            workerIsStalled = true
            ensureQuarantineLocked(reason: "System voice detector owner retained")
            fence = stopFence
            stopFence = nil
        }
        if let fence { _ = fence.complete(result) }
    }

    private func releaseTransitionQuarantineIfSafe() {
        let token: ProcessLifetimeAudioQuarantine.Token? = lock.withLock {
            guard permanentFailure == nil, stopFence == nil, !activeTimedOut else {
                return nil
            }
            defer { quarantineToken = nil }
            return quarantineToken
        }
        if let token { quarantine.release(token) }
    }

    private func ensureQuarantineLocked(reason: String) {
        guard quarantineToken == nil else { return }
        quarantineToken = quarantine.retain(self, reason: reason)
    }

    private func operationDeadlineReached() {
        var event: VoiceActivityLifecycleEvent?
        lock.withLock {
            guard let active, !activeTimedOut else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= activeDeadlineNanoseconds else { return }

            activeTimedOut = true
            workerIsStalled = true
            timedOutOperations &+= 1
            if activeMayOwn {
                ensureQuarantineLocked(reason: "System voice detector HAL call timed out")
            }
            if desired?.token == active.token {
                event = .timedOut(active.token, ownerMayExist: activeMayOwn)
            }
        }
        if let event { emitIfCurrent(event) }
    }
}

extension VoiceActivityLifecycleWorker where Owner == VoiceActivityWatcher {
    static func live(
        publish: @escaping @Sendable (VoiceActivityLifecycleEvent) -> Void
    ) -> VoiceActivityLifecycleWorker<VoiceActivityWatcher> {
        VoiceActivityLifecycleWorker<VoiceActivityWatcher>(
            operations: Operations(
                isAvailable: { VoiceActivityWatcher.isAvailable(on: $0) },
                start: { device, activation, onChange, cleanupFailed in
                    VoiceActivityWatcher(
                        device: device, activation: activation,
                        onCleanupFailure: cleanupFailed, onChange: onChange)
                },
                isObserving: { $0.isObserving },
                stop: { $0.stop() }),
            publish: publish)
    }
}

/// Waits for the detector fence on one bounded, non-HAL lane.
enum VoiceActivityShutdownDispatcher {
    private static let queue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.voice-activity-shutdown", qos: .utility)

    static func submit(
        _ fence: VoiceActivityStopFence,
        timeout: TimeInterval,
        completion: @escaping @MainActor @Sendable (VoiceActivityStopResult) -> Void
    ) {
        queue.async {
            let result = fence.wait(timeout: timeout)
            MainRunLoopDelivery.perform { completion(result) }
        }
    }
}
