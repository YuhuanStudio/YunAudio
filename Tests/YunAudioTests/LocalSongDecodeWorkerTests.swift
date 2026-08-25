import AVFoundation
import Foundation
import Testing

@testable import YunAudioApp

private final class LocalSongLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

@Suite("Local song decode worker", .serialized)
struct LocalSongDecodeWorkerTests {
    @Test("ten thousand seeks execute exactly first and latest off the main thread")
    @MainActor
    func firstLatestBoundary() async throws {
        let beganFirst = LocalSongLockedBox(false)
        let releaseFirst = DispatchSemaphore(value: 0)
        let applications = LocalSongLockedBox<[(value: Int, wasMain: Bool)]>([])
        var publications: [Int] = []
        let lane = BoundedFirstLatestWorkLane<Int, Int>(
            queue: DispatchQueue(
                label: "studio.yuhuan.YunAudio.tests.local-song-first-latest"),
            apply: { value in
                applications.update { $0.append((value, Thread.isMainThread)) }
                if value == 0 {
                    beganFirst.update { $0 = true }
                    _ = releaseFirst.wait(timeout: .now() + TestGate.deadlock)
                }
                return value
            },
            publish: { publications.append($0) })

        #expect(lane.submit(0))
        for _ in 0..<2_000 where !beganFirst.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(beganFirst.read())

        // Thread CPU time, not wall clock.
        //
        // The claim is that submitting does no work — a version which queues a
        // decode per seek could not finish this loop at all while the first
        // decode is held at the semaphore. Wall clock also counts this thread
        // being descheduled, which with three hundred suites in parallel it
        // routinely is, and the ceiling then measures the machine's load and
        // blames the lane.
        let beganBurst = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var allAccepted = true
        for value in 1..<10_000 { allAccepted = lane.submit(value) && allAccepted }
        let burstMilliseconds =
            Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - beganBurst) / 1_000_000
        #expect(burstMilliseconds < 500, "burst cost \(burstMilliseconds) ms of CPU")
        #expect(allAccepted)

        let held = lane.statistics
        #expect(held.submissions == 10_000)
        #expect(held.coalesced == 9_998)
        #expect(held.applications == 1)
        #expect(held.maximumPending == 1)

        releaseFirst.signal()
        for _ in 0..<2_000 where lane.statistics.publications != 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let final = lane.statistics
        #expect(final.applications == 2)
        #expect(final.publications == 2)
        #expect(publications == [0, 9_999])
        let applied = applications.read()
        #expect(applied.map(\.value) == [0, 9_999])
        #expect(applied.filter(\.wasMain).count == 0)
        lane.shutdown()
    }

    @Test("shutdown revokes a decoder answer already in flight")
    @MainActor
    func shutdownRevokesPublication() async {
        let began = LocalSongLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        let finished = LocalSongLockedBox(false)
        var publications: [Int] = []
        let lane = BoundedFirstLatestWorkLane<Int, Int>(
            queue: DispatchQueue(label: "studio.yuhuan.YunAudio.tests.local-song-stop"),
            apply: { value in
                began.update { $0 = true }
                _ = release.wait(timeout: .now() + TestGate.deadlock)
                finished.update { $0 = true }
                return value
            },
            publish: { publications.append($0) })

        #expect(lane.submit(7))
        for _ in 0..<2_000 where !began.read() {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(began.read())
        lane.shutdown()
        release.signal()
        for _ in 0..<2_000 where !finished.read() {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(finished.read())
        try? await Task.sleep(for: .milliseconds(20))
        #expect(lane.statistics.applications == 1)
        #expect(lane.statistics.publications == 0)
        #expect(publications.isEmpty)
        #expect(lane.submit(8) == false)
    }

    @Test("audio completions coalesce atomically without queueing tasks")
    func completionMailboxIsLatestWins() async {
        let queue = DispatchQueue(
            label: "studio.yuhuan.YunAudio.tests.local-song-completions")
        queue.suspend()
        let consumed = LocalSongLockedBox<[(UInt32, UInt32)]>([])
        let mailbox = LocalSongCompletionMailbox(queue: queue) { generation, through in
            consumed.update { $0.append((generation, through)) }
        }
        mailbox.activate(generation: 42)

        // CPU time, for the reason above: ten thousand completions into one
        // pending slot is a bounded amount of work, and how long the thread
        // waited to be run is not part of it.
        let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        // A completion from the schedule retired by a seek must not replace
        // the new generation's start request in the one pending slot.
        mailbox.completed(generation: 41, ordinal: 50_000)
        for ordinal in 0..<UInt32(10_000) {
            mailbox.completed(generation: 42, ordinal: ordinal)
        }
        let milliseconds =
            Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began) / 1_000_000
        #expect(milliseconds < 100, "cost \(milliseconds) ms of CPU")
        queue.resume()

        for _ in 0..<2_000 where consumed.read().isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(consumed.read().isEmpty == false)
        mailbox.shutdown()
        #expect(consumed.read().count == 1)
        #expect(consumed.read().first?.0 == 42)
        #expect(consumed.read().first?.1 == 10_002)
    }

    @Test("the decoder keeps three seconds and applies the measured centre arithmetic")
    func decodedAudioIsBoundedAndCorrect() async throws {
        let url = try makeStereoFile(seconds: 3.25)
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = LocalSongCentreDecodeBackend()

        let first = await Task.detached {
            backend.perform(
                LocalSongCentreDecodeRequest(
                    generation: 9, kind: .start(url: url, frame: 0)))
        }.value
        #expect(first.failed == false)
        #expect(first.reachedEnd == false)
        #expect(first.chunks.map(\.ordinal) == [0, 1, 2])
        #expect(first.chunks.map { $0.buffer.frameLength } == [48_000, 48_000, 48_000])
        let maximumBufferedBytes =
            Int(LocalSongCentreDecodeBackend.chunksInFlight)
            * Int(LocalSongCentreDecodeBackend.maximumChunkFrames)
            * Int(LocalSongCentreDecodeBackend.maximumChannels)
            * MemoryLayout<Float>.stride
        #expect(maximumBufferedBytes == 36_864_000)

        let firstBuffer = try #require(first.chunks.first?.buffer)
        let samples = try #require(firstBuffer.floatChannelData)
        // Input is left 0.5, right 0.3: mid 0.4, side 0.1. Keeping 15% of
        // the mid therefore produces 0.16 and -0.04, not merely a moving meter.
        // `floatChannelData` is borrowed storage; Release may otherwise end the
        // optional-chain owner's lifetime before the expectation dereferences it.
        withExtendedLifetime(firstBuffer) {
            #expect(abs(samples[0][100] - 0.16) < 1e-5)
            #expect(abs(samples[1][100] + 0.04) < 1e-5)
        }

        let last = await Task.detached {
            backend.perform(
                LocalSongCentreDecodeRequest(
                    generation: 9, kind: .refill(throughOrdinal: 3)))
        }.value
        #expect(last.failed == false)
        #expect(last.reachedEnd)
        #expect(last.chunks.map(\.ordinal) == [3])
        #expect(last.chunks.first?.buffer.frameLength == 12_000)
    }

    @Test("the audio completion closure contains only the atomic publication")
    func callbackSourceBoundary() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/YunAudioApp/LocalSongPlayer.swift"),
            encoding: .utf8)
        let schedule = try #require(
            source.range(of: "node.scheduleBuffer(\n                chunk.buffer"))
        let tail = source[schedule.lowerBound...]
        let callbackEnd = try #require(tail.range(of: "            }\n        }"))
        let callback = tail[..<callbackEnd.upperBound]
        #expect(callback.contains("mailbox.completed"))
        #expect(callback.contains("Task") == false)
        #expect(callback.contains("DispatchQueue") == false)
        #expect(callback.contains("NSLock") == false)
        #expect(callback.contains("file.read") == false)
        #expect(callback.contains("CentreCancel.apply") == false)
        #expect(source.contains("private func scheduleNextChunk") == false)
        #expect(source.contains("file.read") == false)
        #expect(source.contains("CentreCancel.apply") == false)
    }

    private func makeStereoFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-song-worker-\(UUID().uuidString).wav")
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            channels[0][frame] = 0.5
            channels[1][frame] = 0.3
        }
        try writer.write(from: buffer)
        return url
    }
}
