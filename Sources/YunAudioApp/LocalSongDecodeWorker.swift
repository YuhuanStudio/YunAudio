import AVFoundation
import Foundation
import Synchronization

/// A serial first/latest lane for work which must never form an unbounded queue.
///
/// The first request is allowed to finish because a synchronous file read cannot
/// be cancelled safely. While it runs there is exactly one pending slot, and
/// every newer request replaces that slot. Shutting the lane does not wait for a
/// decoder which may be stuck in a filesystem or codec; it revokes publication
/// and leaves the in-flight closure owning only this detached capsule.
final class BoundedFirstLatestWorkLane<Request: Sendable, Response: Sendable>:
    @unchecked Sendable
{
    struct Statistics: Equatable, Sendable {
        fileprivate(set) var submissions: UInt64 = 0
        fileprivate(set) var coalesced: UInt64 = 0
        fileprivate(set) var applications: UInt64 = 0
        fileprivate(set) var publications: UInt64 = 0
        fileprivate(set) var maximumPending: Int = 0
    }

    private struct Work {
        var request: Request
        var lifetime: UInt64
    }

    private struct State {
        var pending: Work?
        var hasWorker = false
        var acceptsWork = true
        var lifetime: UInt64 = 0
        var statistics = Statistics()
    }

    private let lock = NSLock()
    private var state = State()
    private let queue: DispatchQueue
    private let apply: @Sendable (Request) -> Response
    private let publish: @MainActor @Sendable (Response) -> Void

    init(
        queue: DispatchQueue,
        apply: @escaping @Sendable (Request) -> Response,
        publish: @escaping @MainActor @Sendable (Response) -> Void
    ) {
        self.queue = queue
        self.apply = apply
        self.publish = publish
    }

    var statistics: Statistics { lock.withLock { state.statistics } }

    @discardableResult
    func submit(_ request: Request) -> Bool {
        let decision: (accepted: Bool, schedulesWorker: Bool) = lock.withLock {
            guard state.acceptsWork else { return (false, false) }
            state.statistics.submissions &+= 1
            if state.pending != nil { state.statistics.coalesced &+= 1 }
            state.pending = Work(request: request, lifetime: state.lifetime)
            state.statistics.maximumPending = max(state.statistics.maximumPending, 1)
            guard !state.hasWorker else { return (true, false) }
            state.hasWorker = true
            return (true, true)
        }
        if decision.schedulesWorker { scheduleWorker() }
        return decision.accepted
    }

    /// Drops the pending request and makes an in-flight answer obsolete.
    func invalidate() {
        lock.withLock {
            state.lifetime &+= 1
            state.pending = nil
        }
    }

    /// Permanently revokes the lane without waiting on an admitted file read.
    func shutdown() {
        lock.withLock {
            state.acceptsWork = false
            state.lifetime &+= 1
            state.pending = nil
        }
    }

    private func scheduleWorker() {
        queue.async { [self] in runOne() }
    }

    private func runOne() {
        let work: Work? = lock.withLock {
            guard state.acceptsWork, let work = state.pending else {
                state.hasWorker = false
                return nil
            }
            state.pending = nil
            state.statistics.applications &+= 1
            return work
        }
        guard let work else { return }

        let response = apply(work.request)
        // The next response must not overtake this one on MainActor. Audio
        // chunks are ordered data, not independent slider values; scheduling
        // two unstructured publication tasks would make their order a hope.
        Task { @MainActor [self] in finish(response, lifetime: work.lifetime) }
    }

    @MainActor
    private func finish(_ response: Response, lifetime: UInt64) {
        let shouldPublish = lock.withLock {
            guard state.acceptsWork, state.lifetime == lifetime else { return false }
            state.statistics.publications &+= 1
            return true
        }
        if shouldPublish { publish(response) }

        let schedulesAgain = lock.withLock {
            guard state.acceptsWork, state.pending != nil else {
                state.hasWorker = false
                return false
            }
            return true
        }
        if schedulesAgain { scheduleWorker() }
    }
}

struct LocalSongCentreDecodeRequest: Sendable {
    enum Kind: Sendable {
        case start(url: URL, frame: AVAudioFramePosition)
        case refill(throughOrdinal: UInt32)
    }

    var generation: UInt32
    var kind: Kind
}

struct LocalSongDecodedChunk: @unchecked Sendable {
    var ordinal: UInt32
    var buffer: AVAudioPCMBuffer
}

struct LocalSongCentreDecodeBatch: @unchecked Sendable {
    var generation: UInt32
    var chunks: [LocalSongDecodedChunk]
    var reachedEnd: Bool
    var failed: Bool
}

/// Orders seek admission against completion admission outside the audio callback.
///
/// The atomic mailbox rejects the common stale callback without locking. This
/// second gate closes the check-to-submit race on the decoder queue: either an
/// old refill is submitted first and the new Start replaces it, or Start wins
/// the lock and every old refill is rejected afterwards.
final class LocalSongCentreRequestAdmission: @unchecked Sendable {
    typealias Lane = BoundedFirstLatestWorkLane<
        LocalSongCentreDecodeRequest, LocalSongCentreDecodeBatch
    >

    private let lock = NSLock()
    private var activeGeneration: UInt32 = 0
    private let lane: Lane

    init(lane: Lane) { self.lane = lane }

    func start(url: URL, frame: AVAudioFramePosition, generation: UInt32) {
        lock.withLock {
            activeGeneration = generation
            _ = lane.submit(
                LocalSongCentreDecodeRequest(
                    generation: generation, kind: .start(url: url, frame: frame)))
        }
    }

    func refill(generation: UInt32, through: UInt32) {
        lock.withLock {
            guard activeGeneration == generation else { return }
            _ = lane.submit(
                LocalSongCentreDecodeRequest(
                    generation: generation, kind: .refill(throughOrdinal: through)))
        }
    }

    func shutdown() {
        lock.withLock {
            activeGeneration = 0
            lane.shutdown()
        }
    }
}

/// Owns the only `AVAudioFile` whose frame cursor is moved by centre cancellation.
///
/// This object is used on one serial queue. Marking it Sendable records that
/// ownership rather than claiming `AVAudioFile` itself is safe to share.
final class LocalSongCentreDecodeBackend: @unchecked Sendable {
    static let chunksInFlight: UInt32 = 3
    static let maximumChunkFrames: AVAudioFrameCount = 384_000
    static let maximumChannels: AVAudioChannelCount = 8

    private var file: AVAudioFile?
    private var generation: UInt32 = 0
    private var nextOrdinal: UInt32 = 0

    func perform(_ request: LocalSongCentreDecodeRequest) -> LocalSongCentreDecodeBatch {
        autoreleasepool {
            switch request.kind {
            case .start(let url, let requestedFrame):
                guard let opened = try? AVAudioFile(forReading: url) else {
                    reset()
                    return failed(request.generation)
                }
                let format = opened.processingFormat
                let frameCount = format.sampleRate.rounded(.up)
                guard format.channelCount >= 2, format.channelCount <= Self.maximumChannels,
                    format.sampleRate.isFinite,
                    frameCount > 0, frameCount <= Double(Self.maximumChunkFrames),
                    opened.length > 0
                else {
                    reset()
                    return failed(request.generation)
                }
                generation = request.generation
                nextOrdinal = 0
                file = opened
                opened.framePosition = min(max(0, requestedFrame), opened.length)
                return read(through: Self.chunksInFlight - 1)

            case .refill(let requestedOrdinal):
                guard request.generation == generation, file != nil else {
                    return LocalSongCentreDecodeBatch(
                        generation: request.generation, chunks: [], reachedEnd: false,
                        failed: false)
                }
                // Even a corrupt completion value can ask for no more than the
                // three-buffer lead. That is the memory and decode-time bound.
                let furthest = nextOrdinal.addingReportingOverflow(Self.chunksInFlight - 1)
                let bound = furthest.overflow ? UInt32.max : furthest.partialValue
                return read(through: min(requestedOrdinal, bound))
            }
        }
    }

    private func read(through requestedOrdinal: UInt32) -> LocalSongCentreDecodeBatch {
        guard let file else { return failed(generation) }
        let batchGeneration = generation
        let format = file.processingFormat
        let frameCapacity = AVAudioFrameCount(format.sampleRate.rounded(.up))
        var chunks: [LocalSongDecodedChunk] = []
        chunks.reserveCapacity(Int(Self.chunksInFlight))

        while nextOrdinal <= requestedOrdinal, file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let framesToRead = AVAudioFrameCount(
                min(AVAudioFramePosition(frameCapacity), remaining))
            guard remaining > 0,
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: framesToRead)
            else {
                reset()
                return failed(batchGeneration)
            }
            do {
                try file.read(into: buffer, frameCount: framesToRead)
            } catch {
                reset()
                return failed(batchGeneration)
            }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                reset()
                return failed(batchGeneration)
            }
            CentreCancel.apply(
                left: channels[0], right: channels[1], frames: Int(buffer.frameLength),
                amount: CentreCancel.defaultAmount)
            chunks.append(LocalSongDecodedChunk(ordinal: nextOrdinal, buffer: buffer))
            guard nextOrdinal < UInt32.max else {
                reset()
                return failed(batchGeneration)
            }
            nextOrdinal &+= 1
        }

        return LocalSongCentreDecodeBatch(
            generation: batchGeneration, chunks: chunks,
            reachedEnd: file.framePosition >= file.length, failed: false)
    }

    private func failed(_ requestedGeneration: UInt32) -> LocalSongCentreDecodeBatch {
        LocalSongCentreDecodeBatch(
            generation: requestedGeneration, chunks: [], reachedEnd: false, failed: true)
    }

    private func reset() {
        file = nil
        generation = 0
        nextOrdinal = 0
    }
}

/// The only object touched by an `AVAudioPlayerNode` completion callback.
///
/// A callback writes one packed integer. Allocation, locking, Objective-C and
/// task creation all happen later on the decoder queue when the timer drains it.
final class LocalSongCompletionMailbox: @unchecked Sendable {
    private let latest = Atomic<UInt64>(0)
    private let activeGeneration = Atomic<UInt32>(0)
    private let stopped = Atomic<Bool>(false)
    private let timer: DispatchSourceTimer
    private let consume: @Sendable (UInt32, UInt32) -> Void

    init(
        queue: DispatchQueue,
        consume: @escaping @Sendable (UInt32, UInt32) -> Void
    ) {
        self.consume = consume
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(100), repeating: .milliseconds(100),
            leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
    }

    /// Makes callbacks from every earlier player-node schedule ineligible.
    func activate(generation: UInt32) {
        activeGeneration.store(generation, ordering: .releasing)
        _ = latest.exchange(0, ordering: .acquiringAndReleasing)
    }

    /// Called from the audio completion context. Keep this body atomic-only.
    func completed(generation: UInt32, ordinal: UInt32) {
        guard !stopped.load(ordering: .relaxed),
            activeGeneration.load(ordering: .acquiring) == generation
        else { return }
        let addition = ordinal.addingReportingOverflow(
            LocalSongCentreDecodeBackend.chunksInFlight)
        let through =
            addition.overflow ? UInt32.max - 1 : min(addition.partialValue, UInt32.max - 1)
        let encoded = UInt64(generation) << 32 | UInt64(through &+ 1)
        var observed = latest.load(ordering: .relaxed)
        while encoded > observed {
            let result = latest.compareExchange(
                expected: observed, desired: encoded,
                ordering: .releasing)
            if result.exchanged { return }
            observed = result.original
        }
    }

    func shutdown() {
        guard !stopped.exchange(true, ordering: .acquiringAndReleasing) else { return }
        activeGeneration.store(0, ordering: .releasing)
        _ = latest.exchange(0, ordering: .acquiringAndReleasing)
        timer.cancel()
    }

    private func drain() {
        guard !stopped.load(ordering: .acquiring) else { return }
        let encoded = latest.exchange(0, ordering: .acquiringAndReleasing)
        guard encoded != 0 else { return }
        let generation = UInt32(truncatingIfNeeded: encoded >> 32)
        guard activeGeneration.load(ordering: .acquiring) == generation else { return }
        let through = UInt32(truncatingIfNeeded: encoded) &- 1
        consume(generation, through)
    }
}

/// Decodes and processes centre-cancelled chunks without owning the player.
final class LocalSongCentreDecoder: @unchecked Sendable {
    private let lane:
        BoundedFirstLatestWorkLane<
            LocalSongCentreDecodeRequest, LocalSongCentreDecodeBatch
        >
    private let admission: LocalSongCentreRequestAdmission
    let completionMailbox: LocalSongCompletionMailbox

    init(publish: @escaping @MainActor @Sendable (LocalSongCentreDecodeBatch) -> Void) {
        let queue = DispatchQueue(
            label: "studio.yuhuan.YunAudio.local-song-decode", qos: .userInitiated)
        let backend = LocalSongCentreDecodeBackend()
        let lane = BoundedFirstLatestWorkLane(
            queue: queue,
            apply: { backend.perform($0) },
            publish: publish)
        let admission = LocalSongCentreRequestAdmission(lane: lane)
        self.lane = lane
        self.admission = admission
        completionMailbox = LocalSongCompletionMailbox(queue: queue) {
            [weak admission] generation, through in
            admission?.refill(generation: generation, through: through)
        }
    }

    var statistics:
        BoundedFirstLatestWorkLane<
            LocalSongCentreDecodeRequest, LocalSongCentreDecodeBatch
        >.Statistics
    { lane.statistics }

    func start(url: URL, frame: AVAudioFramePosition, generation: UInt32) {
        completionMailbox.activate(generation: generation)
        admission.start(url: url, frame: frame, generation: generation)
    }

    func shutdown() {
        completionMailbox.shutdown()
        admission.shutdown()
    }
}
