import AppKit
import Foundation

/// Why a folder reveal has its own owner rather than living in a button closure.
///
/// Creating a directory can cross a slow or unavailable volume. AppKit still owns
/// the reveal itself, so only the filesystem half leaves the main actor. One serial
/// first/latest lane bounds a burst to the first operation and one newer intent;
/// the lane's second generation check occurs on the main actor immediately before
/// `reveal`, so an answer revoked after filesystem work cannot open a stale folder.
@MainActor
final class FolderRevealWorker {
    enum Failure: Equatable, Sendable {
        case directoryCreation(domain: String, code: Int)
        case revealRefused
    }

    enum Outcome: Equatable, Sendable {
        case revealed(URL)
        case failed(URL, Failure)
    }

    struct Statistics: Equatable, Sendable {
        let submissions: UInt64
        let coalesced: UInt64
        let applications: UInt64
        let publications: UInt64
        let revokedResults: UInt64
        let maximumPending: Int
        let maximumConcurrentApplications: Int
        let revealCalls: UInt64
        let failures: UInt64
    }

    typealias DirectoryCreator = @Sendable (URL) throws -> Void
    typealias Reveal = @MainActor @Sendable (URL) -> Bool
    typealias Publication = @MainActor @Sendable (Outcome) -> Void

    /// Static initialisation is lazy. Neither a synthetic model nor rendering a
    /// button constructs this process owner; the first click is the first access.
    static let shared = FolderRevealWorker()

    private enum Preparation: Sendable {
        case ready(URL)
        case failed(URL, Failure)
    }

    private let queue: DispatchQueue
    private let createDirectory: DirectoryCreator
    private let reveal: Reveal
    private let publication: Publication
    private var revealCalls: UInt64 = 0
    private var failures: UInt64 = 0
    private(set) var lastOutcome: Outcome?

    private lazy var lane = SoleLatestSystemServiceWorker<URL, Preparation>(
        queue: queue,
        apply: { [createDirectory] directory, _ in
            do {
                try createDirectory(directory)
                return .ready(directory)
            } catch {
                let error = error as NSError
                return .failed(
                    directory,
                    .directoryCreation(domain: error.domain, code: error.code))
            }
        },
        publish: { [weak self] preparation in
            self?.publish(preparation)
        })

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "studio.yuhuan.YunAudio.folder-reveal", qos: .utility),
        createDirectory: @escaping DirectoryCreator = { directory in
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        },
        reveal: @escaping Reveal = { NSWorkspace.shared.open($0) },
        publication: @escaping Publication = { _ in }
    ) {
        self.queue = queue
        self.createDirectory = createDirectory
        self.reveal = reveal
        self.publication = publication
    }

    var statistics: Statistics {
        let laneStatistics = lane.statistics
        return Statistics(
            submissions: laneStatistics.submissions,
            coalesced: laneStatistics.coalesced,
            applications: laneStatistics.applications,
            publications: laneStatistics.publications,
            revokedResults: laneStatistics.revokedResults,
            maximumPending: laneStatistics.maximumPending,
            maximumConcurrentApplications: laneStatistics.maximumConcurrentApplications,
            revealCalls: revealCalls,
            failures: failures)
    }

    @discardableResult
    func submit(_ directory: URL) -> Bool {
        lane.submit(directory)
    }

    /// Revokes queued and late reveals without waiting for a filesystem call.
    func shutdown() {
        lane.shutdown()
    }

    private func publish(_ preparation: Preparation) {
        let outcome: Outcome
        switch preparation {
        case .ready(let directory):
            revealCalls &+= 1
            outcome =
                reveal(directory)
                ? .revealed(directory)
                : .failed(directory, .revealRefused)
        case .failed(let directory, let failure):
            outcome = .failed(directory, failure)
        }
        if case .failed = outcome { failures &+= 1 }
        lastOutcome = outcome
        publication(outcome)
    }
}
