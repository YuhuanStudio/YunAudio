import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

private final class RecordingLifecycleLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

@Suite("Recording lifecycle worker", .serialized)
struct RecordingLifecycleWorkerTests {
    private static let directory = URL(fileURLWithPath: "/recordings", isDirectory: true)

    private static func request(_ wantsRecording: Bool) -> RecordingLifecycleRequest {
        RecordingLifecycleRequest(
            wantsRecording: wantsRecording,
            directory: directory,
            format: .wav,
            stemGroups: [],
            stemNames: [])
    }

    @MainActor
    @Test("ten thousand MainActor intents execute first and latest only")
    func firstLatestIntentIsBounded() async throws {
        let running = RecordingLifecycleLockedBox(false)
        let applied = RecordingLifecycleLockedBox<[Bool]>([])
        let began = RecordingLifecycleLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        var published: [RecordingLifecycleEvent] = []
        let mix = URL(fileURLWithPath: "/recordings/mix.wav")
        let worker = RecordingLifecycleWorker(
            operations: .init(
                snapshot: {
                    RoutingEngine.RecordingSnapshot(
                        isRecording: running.read(),
                        url: running.read() ? mix : nil,
                        duration: running.read() ? 12.5 : 0,
                        error: nil)
                },
                start: { _ in
                    applied.update { $0.append(true) }
                    began.update { $0 = true }
                    _ = release.wait(timeout: .now() + 2)
                    running.update { $0 = true }
                    return (mix, [])
                },
                stop: {
                    applied.update { $0.append(false) }
                    running.update { $0 = false }
                    return RecordingStopWork(
                        mix: mix, duration: 12.5,
                        fences: [RecorderFinalisationFence(completedWith: .complete)])
                }),
            publish: { published.append($0) })

        let submissionBegan = DispatchTime.now().uptimeNanoseconds
        #expect(worker.submit(Self.request(true)))
        let submissionElapsed = DispatchTime.now().uptimeNanoseconds - submissionBegan
        #expect(submissionElapsed < 2_000_000)
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(began.read())

        let stormBegan = DispatchTime.now().uptimeNanoseconds
        for _ in 1..<10_000 { #expect(worker.submit(Self.request(false))) }
        let stormElapsed = DispatchTime.now().uptimeNanoseconds - stormBegan
        #expect(stormElapsed < 250_000_000)
        #expect(worker.statistics.submissions == 10_000)
        #expect(worker.statistics.coalesced == 9_998)
        #expect(worker.statistics.maximumPending == 1)
        #expect(worker.statistics.applications == 1)

        release.signal()
        for _ in 0..<2_000 where published.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(applied.read() == [true, false])
        #expect(
            published
                == [.stopped(mix: mix, duration: 12.5, finalisation: .complete)])
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.publications == 1)
        #expect(worker.statistics.revokedResults == 1)
    }

    @MainActor
    @Test("an even toggle storm reuses the first file and publishes only latest Start")
    func latestStartIsIdempotent() async throws {
        let running = RecordingLifecycleLockedBox(false)
        let starts = RecordingLifecycleLockedBox(0)
        let stops = RecordingLifecycleLockedBox(0)
        let began = RecordingLifecycleLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        let mix = URL(fileURLWithPath: "/recordings/existing.wav")
        let stem = URL(fileURLWithPath: "/recordings/stem.wav")
        var published: [RecordingLifecycleEvent] = []
        let worker = RecordingLifecycleWorker(
            operations: .init(
                snapshot: {
                    RoutingEngine.RecordingSnapshot(
                        isRecording: running.read(),
                        url: running.read() ? mix : nil,
                        duration: 0,
                        error: nil)
                },
                start: { _ in
                    starts.update { $0 += 1 }
                    began.update { $0 = true }
                    _ = release.wait(timeout: .now() + 2)
                    running.update { $0 = true }
                    return (mix, [stem])
                },
                stop: {
                    stops.update { $0 += 1 }
                    return RecordingStopWork(mix: mix, duration: 0, fences: [])
                }),
            publish: { published.append($0) })

        #expect(worker.submit(Self.request(true)))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(began.read())
        #expect(worker.submit(Self.request(false)))
        #expect(worker.submit(Self.request(true)))
        release.signal()
        for _ in 0..<2_000 where published.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(starts.read() == 1)
        #expect(stops.read() == 0)
        #expect(published == [.started(mix: mix, stems: [stem])])
        #expect(worker.statistics.maximumPending == 1)
        #expect(worker.statistics.revokedResults == 1)
    }

    @MainActor
    @Test("invalidation prevents a late file result from changing the model")
    func invalidationRevokesLateResult() async throws {
        let began = RecordingLifecycleLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        var published: [RecordingLifecycleEvent] = []
        let worker = RecordingLifecycleWorker(
            operations: .init(
                snapshot: {
                    RoutingEngine.RecordingSnapshot(
                        isRecording: false, url: nil, duration: 0, error: nil)
                },
                start: { request in
                    began.update { $0 = true }
                    _ = release.wait(timeout: .now() + 2)
                    return (request.directory.appendingPathComponent("late.wav"), [])
                },
                stop: {
                    RecordingStopWork(mix: nil, duration: 0, fences: [])
                }),
            publish: { published.append($0) })

        #expect(worker.submit(Self.request(true)))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(began.read())
        worker.invalidate()
        release.signal()
        for _ in 0..<2_000 where worker.statistics.revokedResults == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(published.isEmpty)
        #expect(worker.statistics.revokedResults == 1)
    }
}

@Suite("Recorder finalisation", .serialized)
struct RecorderFinalisationWorkerTests {
    @Test("a blocked writer cannot stand in front of route teardown")
    func blockedWriterIsOnAnIndependentLane() {
        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let routeReached = DispatchSemaphore(value: 0)
        let owner = RecorderRetirementOwner(
            finaliseForTesting: { deadline in
                writerEntered.signal()
                return releaseWriter.wait(timeout: deadline) == .success
            })
        owner.makeSafe()
        let worker = RecorderFinalisationWorker(
            writerTimeout: 1,
            label: "yunaudio.test.recorder-finalisation-independence")
        let fence = worker.submit(owner)
        #expect(writerEntered.wait(timeout: .now() + 1) == .success)

        let began = DispatchTime.now().uptimeNanoseconds
        DispatchQueue(label: "yunaudio.test.route-teardown-independent").async {
            routeReached.signal()
        }
        #expect(routeReached.wait(timeout: .now() + 0.1) == .success)
        let elapsed = DispatchTime.now().uptimeNanoseconds - began
        #expect(elapsed < 100_000_000)

        releaseWriter.signal()
        #expect(fence.wait(timeout: 1) == .complete)
        #expect(fence.completionCount == 1)
        #expect(worker.telemetry.completedOwners == 1)
        #expect(worker.telemetry.retainedOwners == 0)
    }

    @Test("a writer timeout retains exactly one owner and closes admission")
    func timeoutRetainsOwner() {
        let owner = RecorderRetirementOwner(finaliseForTesting: { _ in false })
        owner.makeSafe()
        let quarantine = ProcessLifetimeRecorderQuarantine()
        let worker = RecorderFinalisationWorker(
            writerTimeout: 0.01,
            label: "yunaudio.test.recorder-finalisation-timeout",
            processQuarantine: quarantine)
        let fence = worker.submit(owner)

        #expect(!worker.acceptsConstruction)
        #expect(fence.wait(timeout: 0.25) == .writerTimedOut)
        #expect(fence.completionCount == 1)
        #expect(!worker.acceptsConstruction)
        #expect(worker.telemetry.submittedOwners == 1)
        #expect(worker.telemetry.timedOutOwners == 1)
        #expect(worker.telemetry.retainedOwners == 1)
        #expect(worker.telemetry.maximumOutstandingOwners == 1)
        #expect(quarantine.count == 1)
    }
}
