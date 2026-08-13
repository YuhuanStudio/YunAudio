import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

private final class TranscriberLifecycleLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private actor TranscriberLifecycleAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for continuation in waiting { continuation.resume() }
    }
}

private final class TranscriberLifecycleHeldScheduler: @unchecked Sendable {
    typealias Operation = @MainActor @Sendable () -> Void

    private let lock = NSLock()
    private var operations: [Operation] = []

    func schedule(_ operation: @escaping Operation) {
        lock.withLock { operations.append(operation) }
    }

    var count: Int { lock.withLock { operations.count } }

    @MainActor
    func releaseFirst() {
        let operation = lock.withLock { operations.removeFirst() }
        operation()
    }
}

private final class TranscriberLifecycleWeakSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: TranscriberLifecycleWorker.Session?

    func replace(_ session: TranscriberLifecycleWorker.Session) {
        lock.withLock { value = session }
    }

    var session: TranscriberLifecycleWorker.Session? { lock.withLock { value } }
}

private final class TranscriberLifecycleWeakWorkerBox: @unchecked Sendable {
    private weak var value: TranscriberLifecycleWorker?

    init(_ value: TranscriberLifecycleWorker?) { self.value = value }

    var worker: TranscriberLifecycleWorker? { value }
}

private final class TranscriberLifecycleFenceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OwnedResourceTeardownResult, Never>?
    private var value: OwnedResourceTeardownResult?

    func wait() async -> OwnedResourceTeardownResult {
        await withCheckedContinuation { continuation in
            let immediate: OwnedResourceTeardownResult? = lock.withLock {
                guard let value else {
                    self.continuation = continuation
                    return nil
                }
                return value
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func resolve(_ result: OwnedResourceTeardownResult) {
        let continuation: CheckedContinuation<OwnedResourceTeardownResult, Never>? =
            lock.withLock {
                guard value == nil else { return nil }
                value = result
                defer { self.continuation = nil }
                return self.continuation
            }
        continuation?.resume(returning: result)
    }
}

private final class TranscriberFinalLineOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var finalisedStorage = 0

    func finish() { lock.withLock { finalisedStorage += 1 } }
    var finalised: Int { lock.withLock { finalisedStorage } }
}

@MainActor
private func transcriberLifecycleEventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@Suite("Transcriber lifecycle worker", .serialized)
struct TranscriberLifecycleWorkerTests {
    private struct Publication: Equatable {
        let generation: UInt64
        let finalised: Bool
    }

    private static func source(_ index: Int) -> TranscriberLifecycleSource {
        let uid = "source-\(index)"
        return TranscriberLifecycleSource(
            identity: SourceTapPCMForwarder.Identity(
                uid: uid,
                routeKey: RouteOccurrenceKey(
                    source: ChannelRef(deviceUID: uid, channel: 0),
                    destination: ChannelRef(deviceUID: "output", channel: 0),
                    occurrence: 0)),
            name: "Source \(index)")
    }

    private static func request(
        topology: UInt64, transcript: UInt64 = 1, count: Int
    ) -> TranscriberLifecycleRequest {
        TranscriberLifecycleRequest(
            topologyGeneration: topology, transcriptGeneration: transcript,
            sources: (0..<count).map(Self.source))
    }

    private static func immediateSession(
        _ source: TranscriberLifecycleSource
    ) -> TranscriberLifecycleWorker.Session {
        TranscriberLifecycleWorker.Session(
            identity: source.identity, consume: { _, _ in }, start: { _ in }, stop: {})
    }

    @MainActor
    @Test("a queued old publication is revoked on the MainActor adoption edge")
    func lateMainActorDeliveryIsRevoked() async {
        let scheduler = TranscriberLifecycleHeldScheduler()
        var published: [UInt64] = []
        let worker = TranscriberLifecycleWorker(
            factory: { source, _ in Self.immediateSession(source) },
            schedule: scheduler.schedule,
            publish: { published.append($0.topologyGeneration) })

        #expect(worker.submit(Self.request(topology: 1, count: 1)))
        #expect(await transcriberLifecycleEventually { scheduler.count == 1 })
        #expect(worker.submit(Self.request(topology: 2, count: 1)))
        #expect(await transcriberLifecycleEventually { scheduler.count == 2 })

        scheduler.releaseFirst()
        #expect(published.isEmpty)
        #expect(worker.statistics.publications == 0)
        #expect(worker.statistics.stalePublications == 1)

        scheduler.releaseFirst()
        #expect(published == [2])
        #expect(worker.statistics.publications == 1)
    }

    @MainActor
    @Test("a queued closed snapshot cannot cover a newer speech session")
    func lateClosedDeliveryIsRevoked() async {
        let scheduler = TranscriberLifecycleHeldScheduler()
        var published: [Publication] = []
        let worker = TranscriberLifecycleWorker(
            factory: { source, _ in Self.immediateSession(source) },
            schedule: scheduler.schedule,
            publish: {
                published.append(
                    Publication(
                        generation: $0.topologyGeneration,
                        finalised: $0.finalisedStop))
            })

        #expect(worker.submit(Self.request(topology: 1, transcript: 1, count: 1)))
        #expect(await transcriberLifecycleEventually { scheduler.count == 1 })
        scheduler.releaseFirst()
        #expect(published == [Publication(generation: 1, finalised: false)])

        #expect(worker.submit(Self.request(topology: 2, transcript: 1, count: 0)))
        #expect(await transcriberLifecycleEventually { scheduler.count == 1 })
        #expect(worker.submit(Self.request(topology: 3, transcript: 2, count: 1)))
        #expect(await transcriberLifecycleEventually { scheduler.count == 2 })
        scheduler.releaseFirst()
        #expect(published == [Publication(generation: 1, finalised: false)])
        scheduler.releaseFirst()
        #expect(
            published
                == [
                    Publication(generation: 1, finalised: false),
                    Publication(generation: 3, finalised: false),
                ])
        #expect(worker.statistics.stalePublications == 1)
    }

    @MainActor
    @Test("one two four eight and sixty-four requests start at most two of four models")
    func concurrentStartsAreBounded() async {
        for requested in [1, 2, 4, 8, 64] {
            let admitted = min(requested, 4)
            let gate = TranscriberLifecycleAsyncGate()
            let worker = TranscriberLifecycleWorker(
                factory: { source, _ in
                    TranscriberLifecycleWorker.Session(
                        identity: source.identity, consume: { _, _ in },
                        start: { _ in await gate.wait() }, stop: {})
                }, publish: { _ in })

            #expect(
                worker.submit(
                    Self.request(
                        topology: UInt64(requested), count: admitted)))
            let expectedConcurrent = min(admitted, 2)
            #expect(
                await transcriberLifecycleEventually {
                    worker.statistics.activeStarts == expectedConcurrent
                })
            #expect(worker.statistics.maximumActiveStarts == expectedConcurrent)
            #expect(worker.statistics.mainThreadStarts == 0)
            await gate.open()
            #expect(
                await transcriberLifecycleEventually {
                    worker.statistics.activeSessions == admitted
                        && worker.statistics.publications == 1
                })
            #expect(worker.statistics.maximumActiveStarts == expectedConcurrent)
        }
    }

    @MainActor
    @Test("a finaliser timeout retains the worker and model with one result")
    func timeoutRetainsOwnerExactlyOnce() async {
        let stopGate = TranscriberLifecycleAsyncGate()
        let stopEntered = TranscriberLifecycleLockedBox(false)
        let weakSession = TranscriberLifecycleWeakSessionBox()
        let quarantine = ProcessLifetimeResourceQuarantine()
        var worker: TranscriberLifecycleWorker? = TranscriberLifecycleWorker(
            factory: { source, _ in
                let session = TranscriberLifecycleWorker.Session(
                    identity: source.identity, consume: { _, _ in }, start: { _ in },
                    stop: {
                        stopEntered.update { $0 = true }
                        await stopGate.wait()
                    })
                weakSession.replace(session)
                return session
            }, resourceQuarantine: quarantine, publish: { _ in })
        let retainedWorker = TranscriberLifecycleWeakWorkerBox(worker)

        #expect(worker?.submit(Self.request(topology: 1, count: 1)) == true)
        #expect(
            await transcriberLifecycleEventually {
                worker?.statistics.activeSessions == 1
            })
        let fence = worker!.shutdown(
            topologyGeneration: 2, transcriptGeneration: 1, timeout: 0.02)
        #expect(await transcriberLifecycleEventually { stopEntered.read() })
        let result = TranscriberLifecycleFenceResult()
        fence.observe { result.resolve($0) }
        worker = nil

        #expect(await result.wait() == .timedOut)
        #expect(fence.completionCount == 1)
        #expect(retainedWorker.worker != nil)
        #expect(weakSession.session != nil)
        #expect(quarantine.count == 1)
        #expect(retainedWorker.worker?.statistics.shutdownTimeouts == 1)
        #expect(retainedWorker.worker?.statistics.activeSessions == 1)

        await stopGate.open()
        #expect(
            await transcriberLifecycleEventually {
                retainedWorker.worker?.statistics.activeSessions == 0
            })
        #expect(fence.completionCount == 1)
    }

    @MainActor
    @Test("a completed finaliser never leaves the timeout quarantine behind")
    func completionBeatsTimeoutWithoutQuarantine() async {
        let quarantine = ProcessLifetimeResourceQuarantine()
        let worker = TranscriberLifecycleWorker(
            factory: { source, _ in
                TranscriberLifecycleWorker.Session(
                    identity: source.identity, consume: { _, _ in }, start: { _ in },
                    stop: {})
            }, resourceQuarantine: quarantine, publish: { _ in })
        let fence = worker.shutdown(
            topologyGeneration: 1, transcriptGeneration: 1, timeout: 0.02)
        let result = TranscriberLifecycleFenceResult()
        fence.observe { result.resolve($0) }

        #expect(await result.wait() == .complete)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fence.completionCount == 1)
        #expect(quarantine.count == 0)
        #expect(worker.statistics.shutdownTimeouts == 0)
    }

    @MainActor
    @Test("the last callback precedes the finalised stop publication exactly once")
    func finalLinePrecedesStop() async {
        let owner = TranscriberFinalLineOwner()
        let submissions = TranscriberLifecycleLockedBox<[Bool]>([])
        let line = Transcriber.Line(
            speaker: "Source 0", text: "last line", start: 1, duration: 0.5)
        let lane = DispatchQueue(label: "yunaudio.transcriber-final-line.test")
        let storeWorker = TranscriptStoreWorker(
            scheduleWork: { work in lane.async(execute: work) },
            publish: { _ in })
        let mailbox = TranscriptLineMailbox(
            schedule: { work in lane.async(execute: work) },
            deliver: { generation, lines in
                storeWorker.receive(lines, generation: generation)
            },
            overflow: { _, _ in Issue.record("the final line overflowed") })
        storeWorker.activate(generation: 1)
        mailbox.activate(generation: 1)
        let worker = TranscriberLifecycleWorker(
            factory: { source, _ in
                TranscriberLifecycleWorker.Session(
                    identity: source.identity, consume: { _, _ in }, start: { _ in },
                    stop: {
                        let first = mailbox.submit(line, generation: 1)
                        let duplicate = mailbox.submit(line, generation: 1)
                        submissions.update { $0.append(contentsOf: [first, duplicate]) }
                    })
            },
            publish: { snapshot in
                if snapshot.finalisedStop {
                    mailbox.flush(generation: snapshot.transcriptGeneration) {
                        owner.finish()
                    }
                }
            })
        #expect(worker.submit(Self.request(topology: 1, count: 1)))
        #expect(
            await transcriberLifecycleEventually {
                worker.statistics.activeSessions == 1
            })
        #expect(worker.submit(Self.request(topology: 2, count: 0)))
        #expect(await transcriberLifecycleEventually { owner.finalised == 1 })
        #expect(storeWorker.snapshot.statistics.lines == 1)
        #expect(submissions.read() == [true, true])
        #expect(storeWorker.snapshot.statistics.duplicateLines == 1)
        #expect(storeWorker.snapshot.visibleLines == [line])
        #expect(storeWorker.statistics.mainThreadApplications == 0)
        #expect(owner.finalised == 1)
    }
}
