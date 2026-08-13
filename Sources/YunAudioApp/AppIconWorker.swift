import AppKit
import Foundation
import Observation

/// One immutable row-sized image transferred from the sole raster worker.
struct AppIconLoadSnapshot: @unchecked Sendable {
    let path: String
    let image: NSImage?
}

/// Fetches application icons on one bounded, deduplicating utility owner.
final class AppIconLoadWorker: @unchecked Sendable {
    static let maximumOutstanding = 64

    struct Statistics: Equatable, Sendable {
        fileprivate(set) var submissions: UInt64 = 0
        fileprivate(set) var duplicates: UInt64 = 0
        fileprivate(set) var rejectedAtCapacity: UInt64 = 0
        fileprivate(set) var applications: UInt64 = 0
        fileprivate(set) var publications: UInt64 = 0
        fileprivate(set) var revokedResults: UInt64 = 0
        fileprivate(set) var maximumOutstanding: Int = 0
        fileprivate(set) var maximumConcurrentApplications: Int = 0
    }

    private struct Work {
        let path: String
        let generation: UInt64
    }

    private struct State {
        var active: Work?
        var pending: [Work] = []
        var pendingPaths: Set<String> = []
        var acceptsWork = true
        var generation: UInt64 = 0
        var concurrentApplications = 0
        var statistics = Statistics()
    }

    private let lock = NSLock()
    private var state = State()
    private let queue: DispatchQueue
    private let load: @Sendable (String) -> NSImage?
    private let rasterise: @Sendable (NSImage) -> NSImage?
    private let publish: @MainActor @Sendable (AppIconLoadSnapshot) -> Void

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.application-icons", qos: .utility),
        load: @escaping @Sendable (String) -> NSImage? = {
            NSWorkspace.shared.icon(forFile: $0)
        },
        rasterise: @escaping @Sendable (NSImage) -> NSImage? = AppIconRasteriser.thumbnail,
        publish: @escaping @MainActor @Sendable (AppIconLoadSnapshot) -> Void
    ) {
        self.queue = queue
        self.load = load
        self.rasterise = rasterise
        self.publish = publish
    }

    var statistics: Statistics { lock.withLock { state.statistics } }

    @discardableResult
    func submit(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let schedulesWorker: Bool? = lock.withLock {
            guard state.acceptsWork else { return nil }
            state.statistics.submissions &+= 1
            if state.active?.path == path && state.active?.generation == state.generation
                || state.pendingPaths.contains(path)
            {
                state.statistics.duplicates &+= 1
                return nil
            }
            let work = Work(path: path, generation: state.generation)
            guard state.active != nil else {
                state.active = work
                state.statistics.maximumOutstanding = max(
                    state.statistics.maximumOutstanding, 1)
                return true
            }
            guard state.pending.count + 1 < Self.maximumOutstanding else {
                state.statistics.rejectedAtCapacity &+= 1
                return nil
            }
            state.pending.append(work)
            state.pendingPaths.insert(path)
            state.statistics.maximumOutstanding = max(
                state.statistics.maximumOutstanding, state.pending.count + 1)
            return false
        }
        guard let schedulesWorker else { return false }
        if schedulesWorker { queue.async { [self] in drain() } }
        return true
    }

    func invalidate() {
        lock.withLock {
            state.generation &+= 1
            state.statistics.revokedResults &+= UInt64(state.pending.count)
            state.pending.removeAll(keepingCapacity: true)
            state.pendingPaths.removeAll(keepingCapacity: true)
        }
    }

    func shutdown() {
        lock.withLock {
            state.acceptsWork = false
            state.generation &+= 1
            state.statistics.revokedResults &+= UInt64(state.pending.count)
            state.pending.removeAll(keepingCapacity: false)
            state.pendingPaths.removeAll(keepingCapacity: false)
        }
    }

    private func drain() {
        while let work = beginApplication() {
            let image = autoreleasepool { load(work.path).flatMap(rasterise) }
            let shouldPublish = finishApplication(work)
            if shouldPublish {
                let snapshot = AppIconLoadSnapshot(path: work.path, image: image)
                MainRunLoopDelivery.perform { [self] in
                    deliver(snapshot, generation: work.generation)
                }
            }
        }
    }

    private func beginApplication() -> Work? {
        lock.withLock {
            guard let work = state.active else { return nil }
            state.statistics.applications &+= 1
            state.concurrentApplications += 1
            state.statistics.maximumConcurrentApplications = max(
                state.statistics.maximumConcurrentApplications,
                state.concurrentApplications)
            return work
        }
    }

    private func finishApplication(_ work: Work) -> Bool {
        lock.withLock {
            state.concurrentApplications -= 1
            let isCurrent = state.acceptsWork && work.generation == state.generation
            if !isCurrent { state.statistics.revokedResults &+= 1 }
            if state.pending.isEmpty {
                state.active = nil
            } else {
                state.active = state.pending.removeFirst()
                state.pendingPaths.remove(state.active!.path)
            }
            return isCurrent
        }
    }

    @MainActor
    private func deliver(_ snapshot: AppIconLoadSnapshot, generation: UInt64) {
        let accepted = lock.withLock {
            guard state.acceptsWork, state.generation == generation else {
                state.statistics.revokedResults &+= 1
                return false
            }
            state.statistics.publications &+= 1
            return true
        }
        if accepted { publish(snapshot) }
    }
}

/// Observable MainActor cache; its miss path only submits a string value.
@MainActor
@Observable
final class AppIconStore {
    static let shared = AppIconStore()

    @ObservationIgnored private let cache = AppIconCache()
    @ObservationIgnored private lazy var worker = AppIconLoadWorker { [weak self] snapshot in
        self?.receive(snapshot)
    }
    @ObservationIgnored private var failedPaths: Set<String> = []
    private var revision: UInt64 = 0

    func image(for url: URL?) -> NSImage? {
        _ = revision
        guard let url else { return nil }
        if let image = cache.cachedImage(for: url) { return image }
        guard !failedPaths.contains(url.path) else { return nil }
        _ = worker.submit(path: url.path)
        return nil
    }

    func invalidate() {
        worker.invalidate()
        // A refused Quit keeps these rows live. Force one fresh body pass so a
        // miss revoked above can re-enter the still-open worker immediately.
        revision &+= 1
    }

    func shutdown() { worker.shutdown() }

    private func receive(_ snapshot: AppIconLoadSnapshot) {
        guard let image = snapshot.image else {
            if failedPaths.count >= AppIconCache.maximumEntries,
                let oldest = failedPaths.first
            {
                failedPaths.remove(oldest)
            }
            failedPaths.insert(snapshot.path)
            revision &+= 1
            return
        }
        failedPaths.remove(snapshot.path)
        cache.insert(image, forPath: snapshot.path)
        revision &+= 1
    }
}
