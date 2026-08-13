import Foundation
import Testing

@testable import YunAudioApp

private actor RecognitionMatchGate {
    struct Snapshot: Sendable {
        let calls: Int
        let active: Int
        let maximumConcurrent: Int
    }

    private var continuations: [CheckedContinuation<MusicRecognition.CatalogueResult, Never>] =
        []
    private var calls = 0
    private var active = 0
    private var maximumConcurrent = 0

    func wait() async -> MusicRecognition.CatalogueResult {
        calls += 1
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        let result = await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        active -= 1
        return result
    }

    func releaseAll(with result: MusicRecognition.CatalogueResult) {
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume(returning: result) }
    }

    var snapshot: Snapshot {
        Snapshot(calls: calls, active: active, maximumConcurrent: maximumConcurrent)
    }
}

private func waitForRecognition(
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    for _ in 0..<2_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("the music-recognition condition did not arrive")
}

private func waitForRecognitionGate(_ gate: RecognitionMatchGate) async throws {
    for _ in 0..<2_000 {
        if await gate.snapshot.calls == 1 { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("the catalogue fault did not enter its await")
}

private func recognitionMatch() -> MusicRecognition.Match {
    MusicRecognition.Match(
        title: "年少心動雨季", artist: "黃霄雲", album: "天賜的聲音",
        identity: "shazam:test", position: 18.96, duration: 0, confidence: 0.95,
        artworkURL: nil, appleMusicURL: nil)
}

@Suite("Bounded music recognition", .serialized)
struct MusicRecognitionWorkerTests {
    @MainActor
    @Test("twenty-four hours of queued PCM retains one six-second payload and one drain")
    func dayLongIngressIsBoundedBeforeDrain() {
        let queue = DispatchQueue(label: "yunaudio.test.recognition-suspended")
        queue.suspend()
        var queueIsSuspended = true
        defer {
            if queueIsSuspended { queue.resume() }
        }
        let recognition = MusicRecognition(
            queue: queue,
            prepare: { _, _ in .testing(1) },
            match: { _ in .noMatch },
            handler: { _ in })
        let oneSecond = [Float](repeating: 0.25, count: 48_000)
        let secondsInOneDay = 24 * 60 * 60

        for _ in 0..<5 {
            recognition.add(oneSecond, sampleRate: 48_000)
        }
        #expect(recognition.statistics.scheduledDrains == 0)
        for _ in 5..<secondsInOneDay {
            recognition.add(oneSecond, sampleRate: 48_000)
        }

        let statistics = recognition.statistics
        let submitted = UInt64(secondsInOneDay * oneSecond.count)
        #expect(statistics.submittedBlocks == UInt64(secondsInOneDay))
        #expect(statistics.submittedSamples == submitted)
        #expect(statistics.acceptedSamples == UInt64(MusicRecognition.maximumPendingSamples))
        #expect(
            statistics.droppedAtCapacity
                == submitted - UInt64(MusicRecognition.maximumPendingSamples))
        #expect(statistics.pendingSamples == MusicRecognition.maximumPendingSamples)
        #expect(
            statistics.pendingSamples * MemoryLayout<Float>.stride
                == 1_152_000)
        #expect(statistics.maximumPendingSamples == MusicRecognition.maximumPendingSamples)
        #expect(statistics.activeScheduledDrains == 1)
        #expect(statistics.maximumScheduledDrains == 1)
        #expect(statistics.scheduledDrains == 1)
        #expect(statistics.startedSystemAwaits == 0)

        recognition.shutdown()
        queue.resume()
        queueIsSuspended = false
    }

    @MainActor
    @Test("matching retains no PCM and ten thousand resets cannot start a peer await")
    func resetRevokesWithoutReplacingNeverReturningAwait() async throws {
        let gate = RecognitionMatchGate()
        var publications: [Result<MusicRecognition.Match, MusicRecognition.Failure>] = []
        let recognition = MusicRecognition(
            prepare: { samples, _ in
                #expect(samples.count == MusicRecognition.maximumPendingSamples)
                return .testing(1)
            },
            match: { _ in await gate.wait() },
            handler: { publications.append($0) })
        recognition.add(
            [Float](repeating: 0.25, count: MusicRecognition.maximumPendingSamples),
            sampleRate: 48_000)

        try await waitForRecognitionGate(gate)
        #expect(recognition.statistics.pendingSamples == 0)

        let block = [Float](repeating: 0.125, count: 480)
        for index in 0..<10_000 {
            recognition.reset(releasingBuffers: index.isMultiple(of: 2))
            recognition.add(block, sampleRate: 48_000)
        }

        let held = recognition.statistics
        let gateWhileHeld = await gate.snapshot
        #expect(held.resets == 10_000)
        #expect(held.pendingSamples == 0)
        #expect(held.activeSystemAwaits == 1)
        #expect(held.startedSystemAwaits == 1)
        #expect(held.maximumConcurrentSystemAwaits == 1)
        #expect(held.maximumScheduledDrains == 1)
        #expect(held.scheduledDrains == 1)
        #expect(held.droppedWhileMatching == UInt64(10_000 * block.count))
        #expect(gateWhileHeld.calls == 1)
        #expect(gateWhileHeld.active == 1)
        #expect(gateWhileHeld.maximumConcurrent == 1)

        await gate.releaseAll(with: .match(recognitionMatch()))
        try await waitForRecognition { recognition.statistics.activeSystemAwaits == 0 }
        #expect(recognition.statistics.lateResults == 1)
        #expect(recognition.statistics.publications == 0)
        #expect(publications.isEmpty)
        recognition.shutdown()
    }

    @MainActor
    @Test("shutdown never joins a stuck catalogue and rejects its late publication")
    func shutdownIsNonJoiningAndGenerationSafe() async throws {
        let gate = RecognitionMatchGate()
        var publications: [Result<MusicRecognition.Match, MusicRecognition.Failure>] = []
        let recognition = MusicRecognition(
            prepare: { _, _ in .testing(1) },
            match: { _ in await gate.wait() },
            handler: { publications.append($0) })
        recognition.add(
            [Float](repeating: 0.25, count: MusicRecognition.maximumPendingSamples),
            sampleRate: 48_000)
        try await waitForRecognitionGate(gate)

        let before = ContinuousClock.now
        recognition.shutdown()
        let elapsed = before.duration(to: .now)
        #expect(elapsed < .milliseconds(8))
        recognition.add([0.5], sampleRate: 48_000)
        #expect(recognition.statistics.startedSystemAwaits == 1)
        #expect(recognition.statistics.maximumConcurrentSystemAwaits == 1)
        #expect(recognition.statistics.shutdowns == 1)

        await gate.releaseAll(with: .match(recognitionMatch()))
        try await waitForRecognition { recognition.statistics.activeSystemAwaits == 0 }
        #expect(recognition.statistics.lateResults == 1)
        #expect(recognition.statistics.publications == 0)
        #expect(publications.isEmpty)
    }

    @Test("the detached catalogue closure cannot capture the PCM reservation")
    func catalogueAwaitOwnershipBoundary() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/YunAudioApp/MusicRecognition.swift")
        let source = try String(
            contentsOf: sourceURL, encoding: .utf8)
        let start = try #require(source.range(of: "let task = Task.detached"))
        let end = try #require(
            source.range(
                of: "let shouldCancel", range: start.upperBound..<source.endIndex))
        let task = source[start.lowerBound..<end.lowerBound]

        #expect(task.contains("operation(prepared)"))
        #expect(!task.contains("samples"))
        #expect(!task.contains("reserved"))
    }
}
