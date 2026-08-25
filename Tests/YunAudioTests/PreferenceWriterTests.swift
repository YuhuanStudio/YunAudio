import Foundation
import Testing

@testable import YunAudioApp

@Suite("Bounded preference writer", .serialized)
struct PreferenceWriterTests {
    private final class Values<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Element] = []

        func append(_ value: Element) {
            lock.withLock { values.append(value) }
        }

        var snapshot: [Element] {
            lock.withLock { values }
        }
    }

    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.withLock { value += 1 }
        }

        var current: Int {
            lock.withLock { value }
        }
    }

    @Test("ten thousand submissions retain only the active first and pending latest")
    func gateIsExactlyFirstLatest() throws {
        var gate = PreferenceWriteGate<Int>()
        gate.submit(0)
        let takenFirst = gate.takePending()
        let first = try #require(takenFirst)
        #expect(first.value == 0)

        var maximumRetained = gate.retainedRequestCount
        for value in 1..<10_000 {
            gate.submit(value)
            maximumRetained = max(maximumRetained, gate.retainedRequestCount)
        }

        #expect(maximumRetained == 2)
        #expect(gate.pending?.value == 9_999)
        #expect(gate.latest?.value == 9_999)
        let finishedFirst = gate.finish(first.generation)
        #expect(finishedFirst)
        let takenLatest = gate.takePending()
        let latest = try #require(takenLatest)
        #expect(latest.value == 9_999)
        let finishedLatest = gate.finish(latest.generation)
        #expect(finishedLatest)
        #expect(gate.retainedRequestCount == 0)
    }

    @Test("an expired deadline without pending work sleeps instead of spinning")
    func staleDeadlineCannotSpin() {
        #expect(
            PreferenceWorkerWaitPolicy.decide(
                hasPending: false, deadline: 10, now: 100) == .waitForSignal)
        #expect(
            PreferenceWorkerWaitPolicy.decide(
                hasPending: true, deadline: 10, now: 100) == .runNow)
        #expect(
            PreferenceWorkerWaitPolicy.decide(
                hasPending: true, deadline: 150, now: 100) == .waitNanoseconds(50))
    }

    @Test("accepted termination wires every bounded persistence writer")
    func terminationPersistenceWiringIsComplete() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/YunAudioApp.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "termination.onTerminate ="))
        let end = try #require(
            source.range(
                of: "termination.flowCheckModel = model",
                range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        #expect(body.contains("model.shutDown"))
        #expect(body.contains("ApplicationPersistenceFlushJoin"))
        #expect(body.contains("model.finaliseAcceptedTermination()"))
        #expect(body.ranges(of: "PreferencesStore.flush").count == 1)
        #expect(body.ranges(of: "QuickConfigStore.flush").count == 1)
        #expect(body.ranges(of: "UserPresets.flush").count == 1)
        #expect(body.contains("if !persistence.isAccepted"))
        #expect(body.contains("reply(false)"))
    }

    @MainActor
    @Test("persistence join waits for three writers and completes exactly once")
    func persistenceJoinIsExact() {
        var reports: [ApplicationPersistenceFlushReport] = []
        let join = ApplicationPersistenceFlushJoin { reports.append($0) }

        join.receiveQuickConfigurations(.synchronised)
        join.receiveQuickConfigurations(.failed)
        join.receivePreferences(.nothingToWrite)
        #expect(reports.isEmpty)

        join.receiveUserPresets(.timedOut)
        join.receiveUserPresets(.synchronised)
        join.receivePreferences(.failed)

        #expect(
            reports == [
                ApplicationPersistenceFlushReport(
                    preferences: .nothingToWrite,
                    quickConfigurations: .synchronised,
                    userPresets: .timedOut)
            ])
        #expect(reports.first?.isAccepted == false)
    }

    @MainActor
    @Test("one worker writes first and latest and flushes the exact latest snapshot")
    func burstIsBoundedAndFlushesLatest() async throws {
        let writes = Values<Int>()
        let firstStarted = Values<Bool>()
        let releaseFirst = DispatchSemaphore(value: 0)
        let synchronisations = Count()
        let writer = CoalescedPreferenceWriter<Int>(
            delay: .zero,
            durableWrite: { value in
                writes.append(value)
                if value == 0 {
                    firstStarted.append(true)
                    releaseFirst.wait()
                }
                return true
            },
            synchronise: {
                synchronisations.increment()
                return true
            })

        writer.submit(0)
        for _ in 0..<200 where firstStarted.snapshot.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(firstStarted.snapshot == [true])
        for value in 1..<10_000 { writer.submit(value) }
        #expect(writer.pendingValue == 9_999)
        #expect(writer.metrics.maximumRetainedSnapshots <= 3)

        releaseFirst.signal()
        let result = await flush(writer)
        #expect(result == .synchronised)
        #expect(writes.snapshot == [0, 9_999])
        #expect(synchronisations.current == 1)
        #expect(writer.metrics.workerStarts == 1)
        #expect(writer.metrics.maximumConcurrentWrites == 1)
        #expect(writer.metrics.maximumRetainedSnapshots == 3)
        #expect(!writer.hasUncommittedValue)
    }

    @MainActor
    @Test("encoding, sinking and durability run outside MainActor in order")
    func persistencePipelineIsBackgroundOnly() async {
        let events = Values<String>()
        let writer = CoalescedPreferenceWriter<Int>(
            delay: .seconds(3_600),
            encode: { value -> String? in
                events.append("encode \(value) main=\(Thread.isMainThread)")
                return String(value)
            },
            sink: { payload in
                events.append("sink \(payload) main=\(Thread.isMainThread)")
                return true
            },
            synchronise: {
                events.append("sync main=\(Thread.isMainThread)")
                return true
            })

        writer.submit(42)
        let result = await flush(writer)
        #expect(result == .synchronised)
        #expect(
            events.snapshot == [
                "encode 42 main=false", "sink 42 main=false", "sync main=false",
            ])
    }

    @MainActor
    @Test("a failed encoder reports failure without invoking the sink")
    func encoderFailureIsTruthful() async {
        let encodes = Count()
        let sinks = Count()
        let writer = CoalescedPreferenceWriter<Int>(
            delay: .seconds(3_600),
            encode: { _ -> String? in
                encodes.increment()
                return nil
            },
            sink: { _ in
                sinks.increment()
                return true
            },
            synchronise: { true })

        writer.submit(1)
        let result = await flush(writer)
        #expect(result == .failed)
        #expect(encodes.current == 1)
        #expect(sinks.current == 0)
        #expect(writer.hasUncommittedValue)

        let retry = await flush(writer)
        #expect(retry == .failed)
        #expect(encodes.current == 2)
        #expect(sinks.current == 0)
    }

    @MainActor
    @Test("a flush times out once and a late write cannot complete it twice")
    func timeoutRejectsLateCompletion() async throws {
        let started = Values<Bool>()
        let release = DispatchSemaphore(value: 0)
        let writes = Values<Int>()
        let completions = Values<PreferenceFlushResult>()
        let writer = CoalescedPreferenceWriter<Int>(
            delay: .zero,
            durableWrite: { value in
                started.append(true)
                release.wait()
                writes.append(value)
                return true
            },
            synchronise: { true })

        writer.submit(7)
        for _ in 0..<200 where started.snapshot.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(started.snapshot == [true])
        writer.flush(timeout: .milliseconds(20)) { result in
            completions.append(result)
        }
        for _ in 0..<100 where completions.snapshot.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(completions.snapshot == [.timedOut])

        release.signal()
        for _ in 0..<100 where writes.snapshot.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(writes.snapshot == [7])
        #expect(completions.snapshot == [.timedOut])
    }

    @MainActor
    @Test("ten thousand flushes retain sixteen waiters and answer every request once")
    func flushStormIsBoundedAndExactlyOnce() async throws {
        let started = Values<Bool>()
        let release = DispatchSemaphore(value: 0)
        let deliveries = Values<String>()
        let writer = CoalescedPreferenceWriter<Int>(
            delay: .zero,
            durableWrite: { _ in
                started.append(true)
                release.wait()
                return true
            },
            synchronise: { true })

        writer.submit(1)
        for _ in 0..<200 where started.snapshot.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(started.snapshot == [true])
        for request in 0..<10_000 {
            writer.flush(timeout: .seconds(1)) { result in
                deliveries.append("\(request):\(result)")
            }
        }
        #expect(writer.metrics.maximumFlushWaiters == 16)
        #expect(deliveries.snapshot.count == 9_984)

        release.signal()
        for _ in 0..<200 where deliveries.snapshot.count != 10_000 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let answers = deliveries.snapshot
        let requestIDs = answers.compactMap { Int($0.split(separator: ":")[0]) }
        #expect(answers.count == 10_000)
        #expect(Set(requestIDs).count == 10_000)
        #expect(answers.filter { $0.hasSuffix("superseded") }.count == 9_984)
        #expect(answers.filter { $0.hasSuffix("synchronised") }.count == 16)
    }

    @Test("a failed close synchronisation is attempted once rather than busy-looped")
    func failedCloseSynchronisationIsBounded() throws {
        let synchronised = DispatchSemaphore(value: 0)
        let attempts = Count()
        var writer: CoalescedPreferenceWriter<Int>? = CoalescedPreferenceWriter<Int>(
            delay: .seconds(3_600),
            durableWrite: { _ in true },
            synchronise: {
                attempts.increment()
                synchronised.signal()
                return false
            })

        writer?.submit(1)
        writer = nil
        #expect(synchronised.wait(timeout: .now() + TestGate.deadlock) == .success)
        Thread.sleep(forTimeInterval: 0.03)
        #expect(attempts.current == 1)
    }

    @Test("releasing the owner drains one accepted value without retaining the owner")
    func ownerReleaseStillDrains() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let writes = Values<Int>()
        var writer: CoalescedPreferenceWriter<Int>? = CoalescedPreferenceWriter<Int>(
            delay: .zero,
            durableWrite: { value in
                started.signal()
                release.wait()
                writes.append(value)
                finished.signal()
                return true
            },
            synchronise: { true })
        weak let weakWriter = writer

        writer?.submit(8)
        #expect(started.wait(timeout: .now() + TestGate.deadlock) == .success)
        writer = nil
        #expect(weakWriter == nil)
        release.signal()
        #expect(finished.wait(timeout: .now() + TestGate.deadlock) == .success)
        #expect(writes.snapshot == [8])
    }

    @MainActor
    private func flush<Value: Sendable>(
        _ writer: CoalescedPreferenceWriter<Value>
    ) async -> PreferenceFlushResult {
        await withCheckedContinuation { continuation in
            writer.flush(timeout: .seconds(1)) {
                continuation.resume(returning: $0)
            }
        }
    }
}
