import Foundation
import YunAudioEngine

struct HeadphoneProfileSnapshot: Sendable, Equatable {
    let profiles: [ParametricEQ]
    let directoryEntries: Int
    let filesRead: Int
    let bytesRead: Int
    let reachedLimit: Bool
    let timedOut: Bool
}

/// Reads AutoEq text exports within explicit filesystem and parser budgets.
enum HeadphoneProfileLoader {
    static let defaultTimeout: Duration = .milliseconds(500)
    static let maximumDirectoryEntries = 2_048
    static let maximumDirectoryNameBytes = 1 * 1_024 * 1_024
    static let maximumProfileFiles = 256
    static let maximumProfileBytes = 1 * 1_024 * 1_024
    static let maximumTotalBytes = 8 * 1_024 * 1_024

    static func read(
        directory: URL?,
        timeout: Duration = defaultTimeout,
        fileSystem: BoundedFileSystem = .system
    ) -> HeadphoneProfileSnapshot {
        guard let directory else {
            return HeadphoneProfileSnapshot(
                profiles: [], directoryEntries: 0, filesRead: 0, bytesRead: 0,
                reachedLimit: false, timedOut: false)
        }
        let deadline = ExternalIODeadline(timeout: timeout)
        let listing = fileSystem.listDirectory(
            directory, maximumDirectoryEntries, maximumDirectoryNameBytes, deadline)
        guard listing.isAvailable else {
            return HeadphoneProfileSnapshot(
                profiles: [], directoryEntries: 0, filesRead: 0, bytesRead: 0,
                reachedLimit: listing.reachedLimit, timedOut: listing.timedOut)
        }

        let candidates = listing.names
            .filter { $0.lowercased().hasSuffix(".txt") }
            .sorted()
        var profiles: [ParametricEQ] = []
        profiles.reserveCapacity(min(candidates.count, maximumProfileFiles))
        var filesRead = 0
        var bytesRead = 0
        var reachedLimit = listing.reachedLimit || candidates.count > maximumProfileFiles
        var timedOut = listing.timedOut

        profileLoop: for file in candidates.prefix(maximumProfileFiles) {
            guard !deadline.hasExpired else {
                timedOut = true
                reachedLimit = true
                break
            }
            switch fileSystem.readFile(
                directory.appendingPathComponent(file), maximumProfileBytes, deadline)
            {
            case .data(let data):
                guard data.count <= maximumTotalBytes - min(bytesRead, maximumTotalBytes)
                else {
                    reachedLimit = true
                    break profileLoop
                }
                filesRead += 1
                bytesRead += data.count
                guard let text = String(data: data, encoding: .utf8) else { continue }
                if let profile = ParametricEQ.parse(
                    text, name: (file as NSString).deletingPathExtension)
                {
                    profiles.append(profile)
                }
            case .unavailable, .tooLarge:
                continue
            case .timedOut:
                timedOut = true
                reachedLimit = true
            }
            if timedOut || bytesRead >= maximumTotalBytes { break }
        }

        return HeadphoneProfileSnapshot(
            profiles: profiles, directoryEntries: listing.names.count,
            filesRead: filesRead, bytesRead: bytesRead,
            reachedLimit: reachedLimit, timedOut: timedOut)
    }
}

final class HeadphoneProfileWorker: @unchecked Sendable {
    struct Request: Sendable {
        let directory: URL?
        let timeout: Duration

        init(
            directory: URL?, timeout: Duration = HeadphoneProfileLoader.defaultTimeout
        ) {
            self.directory = directory
            self.timeout = timeout
        }
    }

    private let lane: LatestExternalWorkLane<Request, HeadphoneProfileSnapshot>

    init(
        fileSystem: BoundedFileSystem = .system,
        publish: @escaping @MainActor @Sendable (HeadphoneProfileSnapshot) -> Void
    ) {
        lane = LatestExternalWorkLane(
            queue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.headphone-profiles", qos: .utility),
            apply: {
                HeadphoneProfileLoader.read(
                    directory: $0.directory, timeout: $0.timeout,
                    fileSystem: fileSystem)
            },
            publish: publish)
    }

    var statistics: LatestExternalWorkLane<Request, HeadphoneProfileSnapshot>.Statistics {
        lane.statistics
    }

    @discardableResult
    func submit(_ request: Request) -> Bool { lane.submit(request) }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }
}
