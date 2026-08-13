import Foundation

struct KTVQueueRestoreRequest: Sendable {
    let paths: [String]
    let currentIndex: Int?
    let timeout: Duration

    init(
        paths: [String], currentIndex: Int?,
        timeout: Duration = KTVQueueRestoreLoader.defaultTimeout
    ) {
        self.paths = paths
        self.currentIndex = currentIndex
        self.timeout = timeout
    }
}

struct KTVQueueRestoreSnapshot: Sendable, Equatable {
    let songs: [URL]
    let currentIndex: Int?
    let inspectedPaths: Int
    let rejectedPaths: Int
    let reachedLimit: Bool
    let timedOut: Bool
}

/// Resolves a saved KTV queue without making MainActor stat arbitrary paths.
///
/// Saved songs can live on a disconnected NAS or removable disk. No stat call
/// has a useful hard cancellation API, so this runs on one worker and checks a
/// shared deadline around every path. Count and byte ceilings also prevent a
/// hand-edited preferences blob from turning launch into thousands of filesystem
/// round trips.
enum KTVQueueRestoreLoader {
    static let defaultTimeout: Duration = .milliseconds(500)
    static let maximumPaths = 2_048
    static let maximumPathBytes = 4_096
    static let maximumTotalPathBytes = 2 * 1_024 * 1_024

    static func restore(
        _ request: KTVQueueRestoreRequest,
        fileSystem: BoundedFileSystem = .system
    ) -> KTVQueueRestoreSnapshot {
        let deadline = ExternalIODeadline(timeout: request.timeout)
        var songs: [URL] = []
        songs.reserveCapacity(min(request.paths.count, maximumPaths))
        var restoredCurrent: Int?
        var inspected = 0
        var rejected = 0
        var pathBytes = 0
        var reachedLimit = request.paths.count > maximumPaths
        var timedOut = false

        for (originalIndex, path) in request.paths.prefix(maximumPaths).enumerated() {
            let bytes = path.utf8.count
            guard bytes > 0, bytes <= maximumPathBytes,
                bytes <= maximumTotalPathBytes - min(pathBytes, maximumTotalPathBytes)
            else {
                rejected += 1
                if bytes > maximumTotalPathBytes - min(pathBytes, maximumTotalPathBytes) {
                    reachedLimit = true
                    break
                }
                continue
            }
            pathBytes += bytes
            let url = URL(fileURLWithPath: path)
            inspected += 1
            switch fileSystem.itemExists(url, deadline) {
            case .exists(true):
                if originalIndex == request.currentIndex { restoredCurrent = songs.count }
                songs.append(url)
            case .exists(false):
                break
            case .timedOut:
                timedOut = true
                reachedLimit = true
                break
            }
            if timedOut { break }
        }

        return KTVQueueRestoreSnapshot(
            songs: songs, currentIndex: restoredCurrent,
            inspectedPaths: inspected, rejectedPaths: rejected,
            reachedLimit: reachedLimit, timedOut: timedOut)
    }
}

final class KTVQueueRestoreWorker: @unchecked Sendable {
    private let lane: LatestExternalWorkLane<KTVQueueRestoreRequest, KTVQueueRestoreSnapshot>

    init(
        fileSystem: BoundedFileSystem = .system,
        publish: @escaping @MainActor @Sendable (KTVQueueRestoreSnapshot) -> Void
    ) {
        lane = LatestExternalWorkLane(
            queue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.ktv-queue-restore", qos: .utility),
            apply: { KTVQueueRestoreLoader.restore($0, fileSystem: fileSystem) },
            publish: publish)
    }

    var statistics:
        LatestExternalWorkLane<KTVQueueRestoreRequest, KTVQueueRestoreSnapshot>.Statistics
    { lane.statistics }

    @discardableResult
    func submit(_ request: KTVQueueRestoreRequest) -> Bool { lane.submit(request) }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }
}
