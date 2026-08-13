import Foundation

/// A serial first/latest lane for external work which may block in another subsystem.
///
/// One request may be executing and one newer request may be retained. Every
/// intermediate request is replaced before it reaches the queue. Unlike an audio
/// decoder, an external discovery result is a snapshot rather than ordered data:
/// submitting a newer request therefore also revokes publication of the in-flight
/// answer. A slow network volume can finish late, but it cannot put an old song or
/// registry snapshot back on screen.
final class LatestExternalWorkLane<Request: Sendable, Response: Sendable>:
    @unchecked Sendable
{
    struct Statistics: Equatable, Sendable {
        fileprivate(set) var submissions: UInt64 = 0
        fileprivate(set) var coalesced: UInt64 = 0
        fileprivate(set) var applications: UInt64 = 0
        fileprivate(set) var publications: UInt64 = 0
        fileprivate(set) var revokedResults: UInt64 = 0
        fileprivate(set) var maximumPending: Int = 0
    }

    private struct Work {
        let request: Request
        let generation: UInt64
    }

    private struct State {
        var pending: Work?
        var hasWorker = false
        var acceptsWork = true
        var generation: UInt64 = 0
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
            state.generation &+= 1
            state.statistics.submissions &+= 1
            if state.pending != nil { state.statistics.coalesced &+= 1 }
            state.pending = Work(request: request, generation: state.generation)
            state.statistics.maximumPending = max(state.statistics.maximumPending, 1)
            guard !state.hasWorker else { return (true, false) }
            state.hasWorker = true
            return (true, true)
        }
        if decision.schedulesWorker { queue.async { [self] in drain() } }
        return decision.accepted
    }

    /// Drops work which has not started and revokes an answer already in flight.
    func invalidate() {
        lock.withLock {
            state.generation &+= 1
            state.pending = nil
        }
    }

    /// Permanently revokes publication without waiting for an external call.
    func shutdown() {
        lock.withLock {
            state.acceptsWork = false
            state.generation &+= 1
            state.pending = nil
        }
    }

    private func drain() {
        while let work = takePending() {
            let response = autoreleasepool { apply(work.request) }
            let schedulesPublication = lock.withLock {
                guard state.acceptsWork, state.generation == work.generation else {
                    state.statistics.revokedResults &+= 1
                    return false
                }
                return true
            }
            if schedulesPublication {
                MainRunLoopDelivery.perform { [self] in
                    deliver(response, generation: work.generation)
                }
            }
        }
    }

    private func takePending() -> Work? {
        lock.withLock {
            guard state.acceptsWork, let work = state.pending else {
                state.hasWorker = false
                return nil
            }
            state.pending = nil
            state.statistics.applications &+= 1
            return work
        }
    }

    @MainActor
    private func deliver(_ response: Response, generation: UInt64) {
        let accepted = lock.withLock {
            guard state.acceptsWork, state.generation == generation else {
                state.statistics.revokedResults &+= 1
                return false
            }
            state.statistics.publications &+= 1
            return true
        }
        if accepted { publish(response) }
    }
}

/// The async counterpart used by framework APIs whose supported accessors suspend.
///
/// Cancellation is requested when a newer value arrives, but the replacement is
/// not started until the first task has actually returned. That keeps a framework
/// which ignores cancellation from accumulating one blocked task per song.
@MainActor
final class LatestAsyncExternalWorkLane<Request: Sendable, Response: Sendable> {
    struct Statistics: Equatable, Sendable {
        fileprivate(set) var submissions: UInt64 = 0
        fileprivate(set) var coalesced: UInt64 = 0
        fileprivate(set) var applications: UInt64 = 0
        fileprivate(set) var publications: UInt64 = 0
        fileprivate(set) var revokedResults: UInt64 = 0
        fileprivate(set) var maximumPending: Int = 0
    }

    private struct Work: Sendable {
        let request: Request
        let generation: UInt64
    }

    private let apply: @Sendable (Request) async -> Response
    private let publish: @MainActor @Sendable (Response) -> Void
    private var pending: Work?
    private var active: Task<Void, Never>?
    private var acceptsWork = true
    private var generation: UInt64 = 0
    private(set) var statistics = Statistics()

    init(
        apply: @escaping @Sendable (Request) async -> Response,
        publish: @escaping @MainActor @Sendable (Response) -> Void
    ) {
        self.apply = apply
        self.publish = publish
    }

    @discardableResult
    func submit(_ request: Request) -> Bool {
        guard acceptsWork else { return false }
        generation &+= 1
        statistics.submissions &+= 1
        if pending != nil { statistics.coalesced &+= 1 }
        pending = Work(request: request, generation: generation)
        statistics.maximumPending = max(statistics.maximumPending, 1)
        guard active == nil else {
            active?.cancel()
            return true
        }
        startPending()
        return true
    }

    func invalidate() {
        generation &+= 1
        pending = nil
        active?.cancel()
    }

    func shutdown() {
        acceptsWork = false
        generation &+= 1
        pending = nil
        active?.cancel()
    }

    private func startPending() {
        guard acceptsWork, let work = pending else {
            active = nil
            return
        }
        pending = nil
        statistics.applications &+= 1
        let apply = apply
        active = Task.detached(priority: .utility) { [weak self] in
            let response = await apply(work.request)
            await self?.finish(response, generation: work.generation)
        }
    }

    private func finish(_ response: Response, generation workGeneration: UInt64) {
        active = nil
        if acceptsWork, generation == workGeneration {
            statistics.publications &+= 1
            publish(response)
        } else {
            statistics.revokedResults &+= 1
        }
        startPending()
    }
}

/// A monotonic budget carried through one synchronous external-I/O transaction.
///
/// A filesystem or registry call which has already entered the kernel cannot be
/// interrupted safely. The deadline is therefore checked before and after every
/// call and every bounded chunk. Crossing it discards the answer; the sole worker
/// remains the owner until the call returns rather than spawning replacement
/// threads which can all become stuck on the same volume.
struct ExternalIODeadline: Sendable {
    private let expiresAt: UInt64

    init(timeout: Duration) {
        let interval = Self.nanoseconds(timeout)
        let now = DispatchTime.now().uptimeNanoseconds
        let addition = now.addingReportingOverflow(interval)
        expiresAt = addition.overflow ? UInt64.max : addition.partialValue
    }

    var hasExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= expiresAt
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let whole = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !whole.overflow else { return UInt64.max }
        let total = whole.partialValue.addingReportingOverflow(nanoseconds)
        return total.overflow ? UInt64.max : total.partialValue
    }
}

struct BoundedDirectorySnapshot: Sendable, Equatable {
    var names: [String]
    var isAvailable: Bool
    var reachedLimit: Bool
    var timedOut: Bool
}

enum BoundedFileSnapshot: Sendable, Equatable {
    case data(Data)
    case unavailable
    case tooLarge
    case timedOut
}

enum BoundedItemSnapshot: Sendable, Equatable {
    case exists(Bool)
    case timedOut
}

/// Injectable filesystem operations whose production implementation never reads
/// an unbounded file or materialises an unbounded directory listing.
struct BoundedFileSystem: Sendable {
    let itemExists: @Sendable (URL, ExternalIODeadline) -> BoundedItemSnapshot
    let listDirectory: @Sendable (URL, Int, Int, ExternalIODeadline) -> BoundedDirectorySnapshot
    let readFile: @Sendable (URL, Int, ExternalIODeadline) -> BoundedFileSnapshot

    static let system = BoundedFileSystem(
        itemExists: { url, deadline in
            guard !deadline.hasExpired else { return .timedOut }
            let exists = FileManager.default.fileExists(atPath: url.path)
            return deadline.hasExpired ? .timedOut : .exists(exists)
        },
        listDirectory: { directory, maximumEntries, maximumNameBytes, deadline in
            guard maximumEntries > 0, maximumNameBytes > 0, !deadline.hasExpired else {
                return BoundedDirectorySnapshot(
                    names: [], isAvailable: !deadline.hasExpired, reachedLimit: true,
                    timedOut: deadline.hasExpired)
            }
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            else {
                return BoundedDirectorySnapshot(
                    names: [], isAvailable: false, reachedLimit: false, timedOut: false)
            }

            var names: [String] = []
            names.reserveCapacity(min(maximumEntries, 256))
            var nameBytes = 0
            while let entry = enumerator.nextObject() as? URL {
                guard !deadline.hasExpired else {
                    return BoundedDirectorySnapshot(
                        names: names, isAvailable: true, reachedLimit: true, timedOut: true)
                }
                guard names.count < maximumEntries else {
                    return BoundedDirectorySnapshot(
                        names: names, isAvailable: true, reachedLimit: true, timedOut: false)
                }
                let name = entry.lastPathComponent
                let bytes = name.utf8.count
                guard bytes <= maximumNameBytes - min(nameBytes, maximumNameBytes) else {
                    return BoundedDirectorySnapshot(
                        names: names, isAvailable: true, reachedLimit: true, timedOut: false)
                }
                names.append(name)
                nameBytes += bytes
            }
            return BoundedDirectorySnapshot(
                names: names, isAvailable: true, reachedLimit: false,
                timedOut: deadline.hasExpired)
        },
        readFile: { url, maximumBytes, deadline in
            guard maximumBytes > 0 else { return .tooLarge }
            guard !deadline.hasExpired else { return .timedOut }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                if let size = values.fileSize, size > maximumBytes { return .tooLarge }
                guard !deadline.hasExpired else { return .timedOut }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var data = Data()
                if let size = values.fileSize { data.reserveCapacity(min(size, maximumBytes)) }
                while true {
                    guard !deadline.hasExpired else { return .timedOut }
                    let allowance = maximumBytes - data.count
                    let requested = min(64 * 1_024, allowance + 1)
                    guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty
                    else {
                        return deadline.hasExpired ? .timedOut : .data(data)
                    }
                    guard chunk.count <= allowance else { return .tooLarge }
                    data.append(chunk)
                }
            } catch {
                return deadline.hasExpired ? .timedOut : .unavailable
            }
        })
}
