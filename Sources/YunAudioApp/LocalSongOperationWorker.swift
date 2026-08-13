import Foundation
import YunAudioHAL

enum LocalSongControlRequest: Sendable {
    case play(Double?)
    case pause
    case stop
    case seek(Double)
    case pitch(Float)
    case cancelCentre(Bool)
    case metadata(LocalSongMetadataSnapshot)
    case sample
}

struct LocalSongOperationSnapshot: Sendable {
    enum Kind: Sendable {
        case open(URL)
        case control(LocalSongControlRequest)
    }

    let generation: UInt64
    let kind: Kind
    let state: LocalSongPlayer.Snapshot
    let operationSucceeded: Bool
}

/// Owns every normal AVAudioEngine and AVAudioFile call for local songs.
///
/// Open and transport have separate first/latest mailboxes on the same serial
/// queue. An open therefore cannot be replaced by the Play which logically
/// follows it, while ten thousand slider positions still retain only one
/// pending transport request. Termination closes both mailboxes and queues the
/// existing ownership handoff behind whichever framework call is already in
/// flight; its outer fence has its own numeric deadline.
final class LocalSongOperationWorker: @unchecked Sendable {
    private enum TerminationPhase {
        case queued
        case entered
        case settled(OwnedResourceTeardownResult)
    }

    struct OpenRequest: Sendable {
        let generation: UInt64
        let url: URL
    }

    struct ControlEnvelope: Sendable {
        let generation: UInt64
        let request: LocalSongControlRequest
    }

    /// The only holder of the normal player. Constructing AVAudioEngine is a
    /// framework operation too, so even the first construction happens on the
    /// operation queue rather than as a side effect of a MainActor property.
    private final class Backend: @unchecked Sendable {
        private let queue: DispatchQueue
        private var player: LocalSongPlayer?

        init(queue: DispatchQueue) { self.queue = queue }

        func open(_ request: OpenRequest) -> LocalSongOperationSnapshot {
            let player = player ?? makePlayer()
            let succeeded = player.open(request.url) != nil
            return LocalSongOperationSnapshot(
                generation: request.generation, kind: .open(request.url),
                state: player.snapshot(), operationSucceeded: succeeded)
        }

        func control(_ envelope: ControlEnvelope) -> LocalSongOperationSnapshot {
            guard let player else {
                return LocalSongOperationSnapshot(
                    generation: envelope.generation, kind: .control(envelope.request),
                    state: .empty, operationSucceeded: false)
            }
            let succeeded: Bool
            switch envelope.request {
            case .play(let seconds):
                succeeded = player.play(from: seconds)
            case .pause:
                player.pause()
                succeeded = true
            case .stop:
                player.stop()
                succeeded = true
            case .seek(let seconds):
                player.seek(to: seconds)
                succeeded = true
            case .pitch(let cents):
                player.pitchCents = cents
                succeeded = true
            case .cancelCentre(let enabled):
                succeeded = player.setCancellingCentre(enabled)
            case .metadata(let metadata):
                player.applyMetadata(metadata)
                succeeded = true
            case .sample:
                succeeded = true
            }
            return LocalSongOperationSnapshot(
                generation: envelope.generation, kind: .control(envelope.request),
                state: player.snapshot(), operationSucceeded: succeeded)
        }

        func requestTerminationStop() -> OwnedResourceTeardownFence {
            player?.requestTerminationStop()
                ?? OwnedResourceTeardownFence(completedWith: .complete)
        }

        private func makePlayer() -> LocalSongPlayer {
            let made = LocalSongPlayer()
            made.installNormalOperationQueue(queue)
            player = made
            return made
        }
    }

    private let queue: DispatchQueue
    private let backend: Backend
    private let audioQuarantine: ProcessLifetimeAudioQuarantine
    private let openLane: LatestExternalWorkLane<OpenRequest, LocalSongOperationSnapshot>
    private let controlLane: LatestExternalWorkLane<ControlEnvelope, LocalSongOperationSnapshot>
    private let terminationLock = NSLock()
    private var terminationFence: OwnedResourceTeardownFence?
    private var terminationGeneration: UInt64 = 0
    private var terminationPhase: TerminationPhase?
    private var terminationQuarantineToken: ProcessLifetimeAudioQuarantine.Token?

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.local-song-control", qos: .userInitiated),
        audioQuarantine: ProcessLifetimeAudioQuarantine = .shared,
        publish: @escaping @MainActor @Sendable (LocalSongOperationSnapshot) -> Void
    ) {
        self.queue = queue
        self.audioQuarantine = audioQuarantine
        let backend = Backend(queue: queue)
        self.backend = backend
        openLane = LatestExternalWorkLane(
            queue: queue,
            apply: { backend.open($0) },
            publish: publish)
        controlLane = LatestExternalWorkLane(
            queue: queue,
            apply: { backend.control($0) },
            publish: publish)
    }

    @discardableResult
    func open(_ request: OpenRequest) -> Bool {
        controlLane.invalidate()
        return openLane.submit(request)
    }

    @discardableResult
    func submit(_ request: ControlEnvelope) -> Bool { controlLane.submit(request) }

    func invalidateOpen() { openLane.invalidate() }

    func requestTerminationStop(timeout: TimeInterval = 0.5) -> OwnedResourceTeardownFence {
        let outer = OwnedResourceTeardownFence()
        let admission: (fence: OwnedResourceTeardownFence, generation: UInt64, starts: Bool) =
            terminationLock.withLock {
                if let terminationFence {
                    guard case .settled(.timedOutBeforeEntry)? = terminationPhase else {
                        return (terminationFence, terminationGeneration, false)
                    }
                }
                terminationGeneration &+= 1
                terminationPhase = .queued
                if terminationQuarantineToken == nil {
                    terminationQuarantineToken = audioQuarantine.retain(
                        backend,
                        reason: "local song operation queue has not acknowledged teardown")
                }
                let generation = terminationGeneration
                terminationFence = outer
                return (outer, generation, true)
            }
        guard admission.starts else { return admission.fence }

        openLane.shutdown()
        controlLane.shutdown()
        let deadline = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.local-song-control.deadline",
            qos: .utility)
        deadline.asyncAfter(deadline: .now() + max(0, timeout)) { [self] in
            let mayTimeOut = terminationLock.withLock {
                guard terminationGeneration == admission.generation,
                    terminationFence === admission.fence,
                    case .queued? = terminationPhase
                else { return false }
                terminationPhase = .settled(.timedOutBeforeEntry)
                return true
            }
            if mayTimeOut { admission.fence.complete(.timedOutBeforeEntry) }
        }
        queue.async { [self] in
            let mayEnter = terminationLock.withLock {
                guard terminationGeneration == admission.generation,
                    terminationFence === admission.fence,
                    case .queued? = terminationPhase
                else { return false }
                terminationPhase = .entered
                return true
            }
            guard mayEnter else { return }
            let inner = backend.requestTerminationStop()
            let quarantineToRelease = terminationLock.withLock {
                guard terminationGeneration == admission.generation,
                    terminationFence === admission.fence,
                    case .entered? = terminationPhase
                else { return nil as ProcessLifetimeAudioQuarantine.Token? }
                defer { terminationQuarantineToken = nil }
                return terminationQuarantineToken
            }
            if let quarantineToRelease { audioQuarantine.release(quarantineToRelease) }
            inner.observe { [self] result in
                let mayComplete = terminationLock.withLock {
                    guard terminationGeneration == admission.generation,
                        terminationFence === admission.fence,
                        case .entered? = terminationPhase
                    else { return false }
                    terminationPhase = .settled(result)
                    return true
                }
                if mayComplete { admission.fence.complete(result) }
            }
        }
        return admission.fence
    }
}
