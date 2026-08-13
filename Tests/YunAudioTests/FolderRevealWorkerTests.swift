import Foundation
import Testing

@testable import YunAudioApp

private final class FolderRevealLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var snapshot: Value { lock.withLock { value } }

    @discardableResult
    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

@MainActor
private func folderRevealEventually(
    timeout: Duration = .seconds(2), _ predicate: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return predicate()
}

@Suite("Folder reveal worker", .serialized)
@MainActor
struct FolderRevealWorkerTests {
    @Test("both folder buttons cross the worker boundary instead of the filesystem")
    func userInterfaceWiring() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let mainWindow = try String(
            contentsOfFile: root + "Sources/YunAudioApp/MainWindow.swift", encoding: .utf8)
        let words = try String(
            contentsOfFile: root + "Sources/YunAudioApp/KTVWordsSourcing.swift",
            encoding: .utf8)

        #expect(
            mainWindow.ranges(of: "FolderRevealWorker.shared.submit(directory)").count == 1)
        #expect(words.ranges(of: "FolderRevealWorker.shared.submit(directory)").count == 1)
        #expect(!mainWindow.contains("FileManager.default.createDirectory"))
        #expect(!words.contains("FileManager.default.createDirectory"))
    }

    @Test("ten thousand clicks retain the first and latest with bounded admission")
    func saturationIsFirstLatestAndMainActorAdmissionIsBounded() async {
        let queue = DispatchQueue(label: "yunaudio.test.folder-reveal-saturation")
        queue.suspend()
        let applications = FolderRevealLockedBox<[URL]>([])
        var outcomes: [FolderRevealWorker.Outcome] = []
        var reveals: [URL] = []
        let worker = FolderRevealWorker(
            queue: queue,
            createDirectory: { directory in
                applications.update { $0.append(directory) }
            },
            reveal: {
                reveals.append($0)
                return true
            },
            publication: { outcomes.append($0) })
        var latencies: [UInt64] = []
        latencies.reserveCapacity(10_000)
        var accepted = 0

        for value in 0..<10_000 {
            let began = DispatchTime.now().uptimeNanoseconds
            if worker.submit(Self.directory(value)) { accepted += 1 }
            latencies.append(DispatchTime.now().uptimeNanoseconds - began)
        }

        let ordered = latencies.sorted()
        let percentile99 = ordered[9_899]
        let maximum = ordered[9_999]
        let queued = worker.statistics
        #expect(accepted == 10_000)
        #expect(queued.submissions == 10_000)
        #expect(queued.coalesced == 9_998)
        #expect(queued.applications == 0)
        #expect(queued.maximumPending == 1)
        #expect(percentile99 < 2_000_000, "folder submit p99 was \(percentile99) ns")
        #expect(maximum < 8_000_000, "folder submit max was \(maximum) ns")

        queue.resume()
        #expect(await folderRevealEventually { worker.statistics.publications == 1 })
        #expect(applications.snapshot == [Self.directory(0), Self.directory(9_999)])
        #expect(outcomes == [.revealed(Self.directory(9_999))])
        #expect(reveals == [Self.directory(9_999)])
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.maximumConcurrentApplications == 1)
    }

    @Test("a fifty millisecond directory call never occupies the main actor")
    func slowCreationStaysOnTheUtilityOwner() async {
        let elapsed = FolderRevealLockedBox<UInt64>(0)
        let creationRanOnMainThread = FolderRevealLockedBox(false)
        var reveals: [URL] = []
        var revealRanOnMainThread = false
        let worker = FolderRevealWorker(
            queue: DispatchQueue(label: "yunaudio.test.folder-reveal-slow"),
            createDirectory: { _ in
                let began = DispatchTime.now().uptimeNanoseconds
                creationRanOnMainThread.update { $0 = Thread.isMainThread }
                Thread.sleep(forTimeInterval: 0.05)
                elapsed.update { $0 = DispatchTime.now().uptimeNanoseconds - began }
            },
            reveal: {
                reveals.append($0)
                revealRanOnMainThread = Thread.isMainThread
                return true
            })
        let directory = Self.directory(50)

        let began = DispatchTime.now().uptimeNanoseconds
        #expect(worker.submit(directory))
        let admission = DispatchTime.now().uptimeNanoseconds - began

        #expect(admission < 8_000_000, "folder submit took \(admission) ns")
        #expect(await folderRevealEventually { worker.statistics.publications == 1 })
        #expect(elapsed.snapshot >= 50_000_000)
        #expect(!creationRanOnMainThread.snapshot)
        #expect(revealRanOnMainThread)
        #expect(reveals == [directory])
    }

    @Test("the main actor generation gate refuses an already queued old reveal")
    func mainActorGateRejectsStaleDelivery() async {
        let entered = FolderRevealLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        let applications = FolderRevealLockedBox<[URL]>([])
        var reveals: [URL] = []
        let queue = DispatchQueue(label: "yunaudio.test.folder-reveal-main-gate")
        let worker = FolderRevealWorker(
            queue: queue,
            createDirectory: { directory in
                let application = applications.update {
                    $0.append(directory)
                    return $0.count
                }
                if application == 1 {
                    entered.update { $0 = true }
                    _ = release.wait(timeout: .now() + 2)
                }
            },
            reveal: {
                reveals.append($0)
                return true
            })
        let old = Self.directory(1)
        let current = Self.directory(2)

        #expect(worker.submit(old))
        #expect(await folderRevealEventually { entered.snapshot })
        release.signal()
        // Keep the main actor occupied while the old answer reaches its queued
        // delivery. The newer generation then exists before AppKit is touched.
        queue.sync {}
        #expect(worker.statistics.applications == 1)
        #expect(worker.statistics.publications == 0)
        #expect(worker.submit(current))

        #expect(await folderRevealEventually { worker.statistics.publications == 1 })
        #expect(applications.snapshot == [old, current])
        #expect(reveals == [current])
        #expect(worker.statistics.revokedResults == 1)
    }

    @Test("filesystem and AppKit failures retain typed diagnostic outcomes")
    func failuresAreTypedAndPublished() async {
        let directory = Self.directory(41)
        var creationReveals = 0
        var creationOutcomes: [FolderRevealWorker.Outcome] = []
        let creationWorker = FolderRevealWorker(
            queue: DispatchQueue(label: "yunaudio.test.folder-reveal-create-failure"),
            createDirectory: { _ in throw NSError(domain: "FolderFixture", code: 41) },
            reveal: { _ in
                creationReveals += 1
                return true
            },
            publication: { creationOutcomes.append($0) })

        #expect(creationWorker.submit(directory))
        #expect(await folderRevealEventually { creationWorker.statistics.publications == 1 })
        let creationFailure = FolderRevealWorker.Outcome.failed(
            directory, .directoryCreation(domain: "FolderFixture", code: 41))
        #expect(creationOutcomes == [creationFailure])
        #expect(creationWorker.lastOutcome == creationFailure)
        #expect(creationReveals == 0)
        #expect(creationWorker.statistics.failures == 1)

        var revealOutcomes: [FolderRevealWorker.Outcome] = []
        let revealWorker = FolderRevealWorker(
            queue: DispatchQueue(label: "yunaudio.test.folder-reveal-refusal"),
            createDirectory: { _ in },
            reveal: { _ in false },
            publication: { revealOutcomes.append($0) })
        #expect(revealWorker.submit(directory))
        #expect(await folderRevealEventually { revealWorker.statistics.publications == 1 })
        let revealFailure = FolderRevealWorker.Outcome.failed(directory, .revealRefused)
        #expect(revealOutcomes == [revealFailure])
        #expect(revealWorker.lastOutcome == revealFailure)
        #expect(revealWorker.statistics.revealCalls == 1)
        #expect(revealWorker.statistics.failures == 1)
    }

    @Test("shutdown revokes an entered filesystem answer without a late reveal")
    func shutdownHasNoLatePublication() async {
        let entered = FolderRevealLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        var reveals = 0
        var outcomes: [FolderRevealWorker.Outcome] = []
        let worker = FolderRevealWorker(
            queue: DispatchQueue(label: "yunaudio.test.folder-reveal-shutdown"),
            createDirectory: { _ in
                entered.update { $0 = true }
                _ = release.wait(timeout: .now() + 2)
            },
            reveal: { _ in
                reveals += 1
                return true
            },
            publication: { outcomes.append($0) })

        #expect(worker.submit(Self.directory(1)))
        #expect(await folderRevealEventually { entered.snapshot })
        worker.shutdown()
        #expect(!worker.submit(Self.directory(2)))
        release.signal()

        #expect(await folderRevealEventually { worker.statistics.revokedResults == 1 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(worker.statistics.publications == 0)
        #expect(worker.statistics.revealCalls == 0)
        #expect(worker.lastOutcome == nil)
        #expect(reveals == 0)
        #expect(outcomes.isEmpty)
    }

    private static func directory(_ value: Int) -> URL {
        URL(fileURLWithPath: "/tmp/yunaudio-folder-reveal-\(value)", isDirectory: true)
    }
}
