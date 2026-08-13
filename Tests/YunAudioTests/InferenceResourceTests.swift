import Foundation
import Testing

@testable import YunAudioEngine

@Suite("Inference resource lifetime")
struct InferenceResourceTests {
    private final class BlockingConversion: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseFirst = DispatchSemaphore(value: 0)
        private var calls = 0
        private var finishes = 0

        var callCount: Int { lock.withLock { calls } }
        var finishCount: Int { lock.withLock { finishes } }

        func process(
            _ samples: [Float], sampleRate: Double
        ) -> TranscriptionInputWorker.ProcessingResult {
            let call = lock.withLock {
                calls += 1
                return calls
            }
            if call == 1 { releaseFirst.wait() }
            return TranscriptionInputWorker.ProcessingResult(
                converted: sampleRate > 0 && !samples.isEmpty,
                formatAllocations: 0,
                bufferAllocations: 0,
                copiedFrames: 0,
                retainsFormat: false)
        }

        func finish() {
            lock.withLock { finishes += 1 }
        }

        func release() { releaseFirst.signal() }
    }

    private final class CompletionProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        var isCompleted: Bool { lock.withLock { completed } }

        func complete() {
            lock.withLock { completed = true }
        }
    }

    @Test("one route rate builds one format while PCM ownership remains explicit")
    func transcriptionInputLifetime() throws {
        let builder = TranscriptionPCMBufferBuilder()
        let block = [Float](repeating: 0.25, count: 480)

        #expect(builder.make(samples: [], sampleRate: 48_000) == nil)
        #expect(
            builder.statistics
                == TranscriptionPCMBufferBuilder.Statistics(
                    formatAllocations: 0, bufferAllocations: 0, copiedFrames: 0,
                    retainsFormat: false))

        for _ in 0..<100 {
            let buffer = try #require(builder.make(samples: block, sampleRate: 48_000))
            #expect(buffer.frameLength == 480)
        }
        var statistics = builder.statistics
        #expect(statistics.formatAllocations == 1)
        #expect(statistics.bufferAllocations == 100)
        #expect(statistics.copiedFrames == 48_000)
        #expect(statistics.retainsFormat)

        _ = try #require(builder.make(samples: block, sampleRate: 44_100))
        statistics = builder.statistics
        #expect(statistics.formatAllocations == 2)
        #expect(statistics.bufferAllocations == 101)

        builder.releaseStorage()
        #expect(builder.statistics.formatAllocations == statistics.formatAllocations)
        #expect(builder.statistics.bufferAllocations == statistics.bufferAllocations)
        #expect(builder.statistics.copiedFrames == statistics.copiedFrames)
        #expect(!builder.statistics.retainsFormat)
        builder.beginSession()
        #expect(
            builder.statistics
                == TranscriptionPCMBufferBuilder.Statistics(
                    formatAllocations: 0, bufferAllocations: 0, copiedFrames: 0,
                    retainsFormat: false))
    }

    @Test("audio outside a transcription session allocates no converter input")
    func stoppedTranscriberIsAllocationIdle() {
        let transcriber = Transcriber(speaker: "Microphone")
        for _ in 0..<100 {
            transcriber.add([Float](repeating: 0.25, count: 480), sampleRate: 48_000)
        }

        let statistics = transcriber.resourceStatistics
        #expect(statistics.converterInstallations == 0)
        #expect(statistics.activeConverters == 0)
        #expect(statistics.retainedFormats == 0)
        #expect(statistics.bufferAllocations == 0)
        #expect(statistics.copiedFrames == 0)
        #expect(statistics.submittedFrames == 48_000)
        #expect(statistics.convertedFrames == 0)
        #expect(statistics.droppedFrames == 48_000)
        #expect(statistics.backlogFrames == 0)
        #expect(statistics.scheduledDrainWorkItems == 0)
        #expect(statistics.mainThreadConverterTurns == 0)
    }

    @Test("ten thousand submissions retain one bounded background drain")
    func transcriptionBacklogIsBounded() async throws {
        let conversion = BlockingConversion()
        let worker = TranscriptionInputWorker(label: "yunaudio.test.transcription-bound")
        await worker.open(
            session: TranscriptionInputWorker.Session(
                process: conversion.process,
                finish: conversion.finish))
        let block = [Float](repeating: 0.25, count: 480)
        worker.submit(block, sampleRate: 48_000)

        for _ in 0..<1_000 where conversion.callCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(conversion.callCount == 1)
        for _ in 1..<10_000 { worker.submit(block, sampleRate: 48_000) }

        let blocked = worker.statistics
        #expect(blocked.submittedFrames == 4_800_000)
        #expect(blocked.scheduledDrainWorkItems == 1)
        #expect(blocked.maximumScheduledDrainWorkItems == 1)
        #expect(blocked.backlogFrames <= TranscriptionInputWorker.maximumBacklogFrames)
        #expect(
            blocked.maximumBacklogFrames <= TranscriptionInputWorker.maximumBacklogFrames)
        #expect(blocked.backlogSeconds <= TranscriptionInputWorker.maximumBacklogSeconds)
        #expect(
            blocked.maximumBacklogSeconds
                <= TranscriptionInputWorker.maximumBacklogSeconds + 0.000_001)
        #expect(blocked.droppedFrames > 0)
        #expect(blocked.mainThreadConverterTurns == 0)

        conversion.release()
        await worker.close()
        let closed = worker.statistics
        #expect(conversion.finishCount == 1)
        #expect(closed.activeConverters == 0)
        #expect(closed.retainedFormats == 0)
        #expect(closed.backlogFrames == 0)
        #expect(closed.backlogSeconds == 0)
        #expect(closed.scheduledDrainWorkItems == 0)
        #expect(closed.maximumScheduledDrainWorkItems == 1)
        #expect(closed.mainThreadConverterTurns == 0)
        #expect(closed.convertedFrames + closed.droppedFrames == closed.submittedFrames)
    }

    @Test("one oversized batch is rejected without backlog arithmetic underflow")
    func oversizedTranscriptionBatchIsDropped() async {
        let worker = TranscriptionInputWorker(label: "yunaudio.test.transcription-oversized")
        await worker.open(
            session: TranscriptionInputWorker.Session { samples, sampleRate in
                TranscriptionInputWorker.ProcessingResult(
                    converted: sampleRate > 0 && !samples.isEmpty,
                    formatAllocations: 0,
                    bufferAllocations: 0,
                    copiedFrames: 0,
                    retainsFormat: false)
            })
        let frames = TranscriptionInputWorker.maximumBacklogFrames + 1

        worker.submit([Float](repeating: 0.25, count: frames), sampleRate: 48_000)

        let rejected = worker.statistics
        #expect(rejected.submittedFrames == UInt64(frames))
        #expect(rejected.convertedFrames == 0)
        #expect(rejected.droppedFrames == UInt64(frames))
        #expect(rejected.backlogFrames == 0)
        #expect(rejected.scheduledDrainWorkItems == 0)
        await worker.close()
    }

    @Test("close discards queued conversion work behind one in-flight batch")
    func transcriptionCloseHasOneBatchTail() async throws {
        let conversion = BlockingConversion()
        let completion = CompletionProbe()
        let worker = TranscriptionInputWorker(label: "yunaudio.test.transcription-close-tail")
        await worker.open(
            session: TranscriptionInputWorker.Session(
                process: conversion.process,
                finish: conversion.finish))
        let block = [Float](repeating: 0.25, count: 480)
        worker.submit(block, sampleRate: 48_000)
        for _ in 0..<1_000 where conversion.callCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(conversion.callCount == 1)
        for _ in 0..<100 { worker.submit(block, sampleRate: 48_000) }

        let close = Task {
            await worker.close()
            completion.complete()
        }
        for _ in 0..<1_000 where worker.isAcceptingInput {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(!worker.isAcceptingInput)
        #expect(!completion.isCompleted)
        #expect(worker.statistics.backlogFrames == 480)
        conversion.release()
        await close.value

        let closed = worker.statistics
        #expect(completion.isCompleted)
        #expect(conversion.callCount == 1)
        #expect(conversion.finishCount == 1)
        #expect(closed.backlogFrames == 0)
        #expect(closed.convertedFrames + closed.droppedFrames == closed.submittedFrames)
    }

    @Test("a session replacement drains its generation before installing the next")
    func transcriptionGenerationBarrier() async throws {
        let first = BlockingConversion()
        let second = BlockingConversion()
        second.release()
        let worker = TranscriptionInputWorker(label: "yunaudio.test.transcription-generation")
        await worker.open(
            session: TranscriptionInputWorker.Session(
                process: first.process,
                finish: first.finish))
        let oldBlock = [Float](repeating: 0.1, count: 480)
        worker.submit(oldBlock, sampleRate: 48_000)

        for _ in 0..<1_000 where first.callCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(first.callCount == 1)
        // This accepted old-generation block sits behind the blocked turn.
        // Replacement must not let it cross into the new converter.
        worker.submit(oldBlock, sampleRate: 48_000)
        let replacement = Task {
            await worker.open(
                session: TranscriptionInputWorker.Session(
                    process: second.process,
                    finish: second.finish))
        }

        for _ in 0..<1_000 where worker.isAcceptingInput {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!worker.isAcceptingInput)

        first.release()
        await replacement.value
        worker.submit([Float](repeating: 0.2, count: 960), sampleRate: 48_000)
        for _ in 0..<1_000 where second.callCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        await worker.close()

        #expect(first.callCount == 1)
        #expect(first.finishCount == 1)
        #expect(second.callCount == 1)
        #expect(second.finishCount == 1)
        let closed = worker.statistics
        #expect(closed.activeConverters == 0)
        #expect(closed.backlogFrames == 0)
        #expect(closed.scheduledDrainWorkItems == 0)
        #expect(closed.convertedFrames + closed.droppedFrames == closed.submittedFrames)
    }

    @Test("the learned package compiles once for every process")
    func learnedModelCompilationIsShared() throws {
        let heads = try (0..<4).map { _ in
            try #require(LearnedPitch(sampleRate: 48_000))
        }

        #expect(heads.count == 4)
        #expect(
            LearnedPitch.compilationStatistics
                == LearnedPitch.CompilationStatistics(attempts: 1, didCompile: true))
    }

    @Test("steady-state pitch predictions reuse one feature provider")
    func learnedPredictionInputIsReused() throws {
        let head = try #require(LearnedPitch(sampleRate: 48_000))
        var curve = [Float](repeating: 0, count: head.width)
        for index in curve.indices {
            curve[index] = Float(0.6 * cos(2 * Double.pi * Double(index) / 120))
        }

        #expect(
            head.predictionStatistics
                == LearnedPitch.PredictionStatistics(featureProviders: 1, predictions: 0))
        for _ in 0..<1_000 { _ = head.hertz(from: curve) }
        #expect(
            head.predictionStatistics
                == LearnedPitch.PredictionStatistics(
                    featureProviders: 1, predictions: 1_000))
    }
}
