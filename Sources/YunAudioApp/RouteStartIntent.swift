import Foundation

/// Linearises cancellation against the handover from discovery to route ownership.
///
/// Capture resolution owns no audio resource, so cancelling in that phase may
/// retire the UI immediately. Once the engine lane has been admitted, only its
/// ordered completion may clear Start state: doing so early would admit a second
/// route while the first is still opening or tearing down shared devices.
final class RouteStartIntent: @unchecked Sendable {
    enum Phase: Equatable, Sendable {
        case resolvingCapture
        case engineLifecycle
        case cancelled
    }

    enum EngineAdmission: Equatable, Sendable {
        case admitted
        case cancelled
        case alreadyAdmitted
    }

    enum CancellationDisposition: Equatable, Sendable {
        /// No route owner exists; the caller may finish on the next MainActor turn.
        case finishWithoutEngine
        /// The engine lane owns completion and must be allowed to tear down first.
        case awaitEngineOwner
        /// Another caller already arranged the required completion.
        case alreadyCancelled
    }

    private let lock = NSLock()
    private var phaseStorage: Phase = .resolvingCapture

    /// Atomically transfers this Start from discovery to the engine lane.
    ///
    /// Only `.admitted` authorises enqueueing engine work. A late discovery
    /// answer observes `.cancelled`; a duplicate answer observes
    /// `.alreadyAdmitted`, and neither may open an audio device.
    func admitEngineLifecycle() -> EngineAdmission {
        lock.withLock {
            switch phaseStorage {
            case .resolvingCapture:
                phaseStorage = .engineLifecycle
                return .admitted
            case .engineLifecycle:
                return .alreadyAdmitted
            case .cancelled:
                return .cancelled
            }
        }
    }

    /// Cancels Start and identifies which owner must finish it.
    func cancel() -> CancellationDisposition {
        lock.withLock {
            switch phaseStorage {
            case .resolvingCapture:
                phaseStorage = .cancelled
                return .finishWithoutEngine
            case .engineLifecycle:
                phaseStorage = .cancelled
                return .awaitEngineOwner
            case .cancelled:
                return .alreadyCancelled
            }
        }
    }

    var isCancelled: Bool {
        lock.withLock { phaseStorage == .cancelled }
    }

    var phase: Phase { lock.withLock { phaseStorage } }
}
