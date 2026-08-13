import Foundation
import YunAudioEngine

/// One desired recording state and every value needed to construct it.
struct RecordingLifecycleRequest: Sendable {
    let wantsRecording: Bool
    let directory: URL
    let format: Recorder.Format
    let stemGroups: [[Int]]
    let stemNames: [String]
}

/// Value-only answers from the recording lifecycle lane.
enum RecordingLifecycleEvent: Sendable, Equatable {
    case started(mix: URL, stems: [URL])
    case stopped(
        mix: URL?, duration: TimeInterval,
        finalisation: RecorderFinalisationResult)
    case failed(String)
}

/// State sampled before a recording branch is detached.
struct RecordingStopWork: Sendable {
    let mix: URL?
    let duration: TimeInterval
    let fences: [RecorderFinalisationFence]
}

/// Serialises recording intent away from MainActor and route lifecycle.
///
/// At most the first request and one newest replacement execute. Repeating the
/// same desired state is idempotent: an even toggle storm which ends at Start
/// publishes the first file it already opened instead of trying to replace it.
final class RecordingLifecycleWorker: @unchecked Sendable {
    struct Operations: Sendable {
        let snapshot: @Sendable () -> RoutingEngine.RecordingSnapshot
        let start: @Sendable (RecordingLifecycleRequest) throws -> (URL, [URL])
        let stop: @Sendable () -> RecordingStopWork
    }

    static let defaultFinalisationTimeout: TimeInterval = 0.75

    private final class AppliedState: @unchecked Sendable {
        private let lock = NSLock()
        private var started: (mix: URL, stems: [URL])?

        func current() -> (mix: URL, stems: [URL])? {
            lock.withLock { started }
        }

        func remember(mix: URL, stems: [URL]) {
            lock.withLock { started = (mix, stems) }
        }

        func clear() { lock.withLock { started = nil } }
    }

    private let lane: LatestExternalWorkLane<RecordingLifecycleRequest, RecordingLifecycleEvent>

    init(
        operations: Operations,
        finalisationTimeout: TimeInterval = RecordingLifecycleWorker.defaultFinalisationTimeout,
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.recording-lifecycle", qos: .userInitiated),
        publish: @escaping @MainActor @Sendable (RecordingLifecycleEvent) -> Void
    ) {
        let state = AppliedState()
        let timeout = max(0, finalisationTimeout)
        lane = LatestExternalWorkLane(
            queue: queue,
            apply: { request in
                if request.wantsRecording {
                    let snapshot = operations.snapshot()
                    if snapshot.isRecording, let current = state.current() {
                        return .started(mix: current.mix, stems: current.stems)
                    }
                    do {
                        let result = try operations.start(request)
                        state.remember(mix: result.0, stems: result.1)
                        return .started(mix: result.0, stems: result.1)
                    } catch {
                        return .failed(String(describing: error))
                    }
                }

                let work = operations.stop()
                state.clear()
                let deadline = DispatchTime.now() + timeout
                var finalisation = RecorderFinalisationResult.complete
                for fence in work.fences {
                    let now = DispatchTime.now()
                    let remaining: TimeInterval
                    if now >= deadline {
                        remaining = 0
                    } else {
                        remaining =
                            Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds)
                            / 1_000_000_000
                    }
                    let result = fence.wait(timeout: remaining)
                    if result == .detachmentFailed {
                        finalisation = .detachmentFailed
                    } else if result == .writerTimedOut, finalisation == .complete {
                        finalisation = .writerTimedOut
                    }
                }
                return .stopped(
                    mix: work.mix, duration: work.duration,
                    finalisation: finalisation)
            },
            publish: publish)
    }

    @discardableResult
    func submit(_ request: RecordingLifecycleRequest) -> Bool {
        lane.submit(request)
    }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }

    var statistics:
        LatestExternalWorkLane<
            RecordingLifecycleRequest, RecordingLifecycleEvent
        >.Statistics
    {
        lane.statistics
    }
}

extension RecordingLifecycleWorker {
    static func live(
        engine: RoutingEngine,
        publish: @escaping @MainActor @Sendable (RecordingLifecycleEvent) -> Void
    ) -> RecordingLifecycleWorker {
        RecordingLifecycleWorker(
            operations: Operations(
                snapshot: { engine.recordingSnapshot },
                start: { request in
                    let session = try engine.startRecordingSession(
                        to: request.directory,
                        format: request.format,
                        stemGroups: request.stemGroups,
                        stemNames: request.stemNames)
                    return (session.mix, session.stems)
                },
                stop: {
                    let snapshot = engine.recordingSnapshot
                    engine.setRecordingPaused(false)
                    let stems = engine.stopStemRecording()
                    let mix = engine.stopRecording()
                    return RecordingStopWork(
                        mix: snapshot.url, duration: snapshot.duration,
                        fences: [stems, mix])
                }),
            publish: publish)
    }
}
