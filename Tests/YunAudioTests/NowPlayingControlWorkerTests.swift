import Foundation
import Testing

@testable import YunAudioApp

private final class NowPlayingControlLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }

    var snapshot: Value { lock.withLock { value } }
}

private final class NowPlayingControlHeldMainScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@MainActor @Sendable () -> Void] = []

    func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { operations.append(operation) }
    }

    var count: Int { lock.withLock { operations.count } }

    @MainActor
    func runFirst() {
        let operation = lock.withLock { operations.removeFirst() }
        operation()
    }
}

@MainActor
private func nowPlayingControlEventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@Suite("Bounded now-playing control", .serialized)
struct NowPlayingControlWorkerTests {
    private static func target(_ value: Int) -> NowPlayingControlTarget {
        NowPlayingControlTarget(
            application: "Player \(value)",
            bundleIdentifier: "com.example.player-\(value)",
            trackIdentity: "track-\(value)")
    }

    private static func seconds(
        in applications: [NowPlayingControlApplication]
    ) -> [Double] {
        applications.compactMap {
            guard case .seek(let seconds) = $0.command else { return nil }
            return seconds
        }
    }

    @MainActor
    @Test("ten thousand scrub values execute first and latest without blocking MainActor")
    func seekStormIsBounded() async {
        let releaseFirst = DispatchSemaphore(value: 0)
        let applications = NowPlayingControlLockedBox<[NowPlayingControlApplication]>([])
        var publications: [NowPlayingControlCompletion] = []
        let worker = NowPlayingControlWorker(
            apply: { application in
                let call = applications.update {
                    $0.append(application)
                    return $0.count
                }
                if call == 1 { _ = releaseFirst.wait(timeout: .now() + TestGate.deadlock) }
                return true
            },
            publish: { publications.append($0) })
        worker.replaceTarget(Self.target(1))
        var durations: [UInt64] = []
        let firstStarted = DispatchTime.now().uptimeNanoseconds
        let firstSubmission = worker.submitSeek(seconds: 0)
        durations.append(DispatchTime.now().uptimeNanoseconds - firstStarted)
        #expect(firstSubmission == .accepted)
        #expect(await nowPlayingControlEventually { worker.statistics.applications == 1 })

        for value in 1..<10_000 {
            let started = DispatchTime.now().uptimeNanoseconds
            #expect(worker.submitSeek(seconds: Double(value)).wasAccepted)
            durations.append(DispatchTime.now().uptimeNanoseconds - started)
        }
        let during = worker.statistics
        #expect(during.applications == 1)
        #expect(during.activeApplications == 1)
        #expect(during.pendingSeeks == 1)
        #expect(during.maximumPendingSeeks == 1)
        #expect(during.maximumConcurrentApplications == 1)
        #expect(during.maximumScheduledRuns == 1)

        releaseFirst.signal()
        #expect(
            await nowPlayingControlEventually {
                worker.statistics.applications == 2 && publications.count == 2
            })
        let ordered = durations.sorted()
        let percentile99 = ordered[min(ordered.count - 1, ordered.count * 99 / 100)]
        let final = worker.statistics

        #expect(Self.seconds(in: applications.snapshot) == [0, 9_999])
        #expect(durations.count == 10_000)
        #expect(applications.snapshot.map(\.context.requestToken) == [1, 10_000])
        #expect(final.seekSubmissions == 10_000)
        #expect(final.coalescedSeeks == 9_998)
        #expect(final.applications == 2)
        #expect(final.pendingSeeks == 0)
        #expect(final.mainThreadApplications == 0)
        #expect(percentile99 < 2_000_000)
        #expect((ordered.last ?? .max) < 8_000_000)
    }

    @MainActor
    @Test("seek starts are limited to twenty per second and retain the latest value")
    func seekCadence() async {
        let releaseFirst = DispatchSemaphore(value: 0)
        let starts = NowPlayingControlLockedBox<[UInt64]>([])
        let applications = NowPlayingControlLockedBox<[NowPlayingControlApplication]>([])
        let worker = NowPlayingControlWorker(
            apply: { application in
                let call = starts.update {
                    $0.append(DispatchTime.now().uptimeNanoseconds)
                    return $0.count
                }
                applications.update { $0.append(application) }
                if call == 1 { _ = releaseFirst.wait(timeout: .now() + TestGate.deadlock) }
                return true
            },
            publish: { _ in })
        worker.replaceTarget(Self.target(1))
        #expect(worker.submitSeek(seconds: 1) == .accepted)
        #expect(await nowPlayingControlEventually { worker.statistics.activeApplications == 1 })
        for value in 2...64 {
            #expect(worker.submitSeek(seconds: Double(value)).wasAccepted)
        }
        releaseFirst.signal()
        #expect(await nowPlayingControlEventually { starts.snapshot.count == 2 })

        let times = starts.snapshot
        #expect(times.count == 2)
        #expect(times[1] - times[0] >= 49_000_000)
        #expect(Self.seconds(in: applications.snapshot) == [1, 64])
        #expect(NowPlayingControlWorker.minimumSeekIntervalNanoseconds == 50_000_000)
    }

    @MainActor
    @Test("thirty-two transport edges retain order and the thirty-third is explicit")
    func edgeFIFOIsBounded() async {
        let releaseSeek = DispatchSemaphore(value: 0)
        let applications = NowPlayingControlLockedBox<[NowPlayingControlApplication]>([])
        let worker = NowPlayingControlWorker(
            minimumSeekIntervalNanoseconds: 0,
            apply: { application in
                let call = applications.update {
                    $0.append(application)
                    return $0.count
                }
                if call == 1 { _ = releaseSeek.wait(timeout: .now() + TestGate.deadlock) }
                return true
            },
            publish: { _ in })
        worker.replaceTarget(Self.target(1))
        #expect(worker.submitSeek(seconds: 0) == .accepted)
        #expect(await nowPlayingControlEventually { worker.statistics.activeApplications == 1 })

        let expected: [NowPlayingControlEdge] = (0..<32).map { value in
            switch value % 3 {
            case 0: .playPause
            case 1: .next
            default: .previous
            }
        }
        for edge in expected { #expect(worker.submitEdge(edge) == .accepted) }
        #expect(worker.submitEdge(.next) == .refused(.edgeBacklogFull))
        #expect(worker.statistics.pendingEdges == 32)
        #expect(worker.statistics.maximumPendingEdges == 32)

        releaseSeek.signal()
        #expect(await nowPlayingControlEventually { applications.snapshot.count == 33 })
        let appliedEdges: [NowPlayingControlEdge] = applications.snapshot.compactMap {
            application in
            guard case .edge(let edge) = application.command else { return nil }
            return edge
        }
        #expect(appliedEdges == expected)
        #expect(NowPlayingControlWorker.maximumPendingEdges == 32)
        #expect(worker.statistics.edgeOverflows == 1)
        #expect(worker.statistics.refusedRequests == 1)
        #expect(worker.statistics.maximumConcurrentApplications == 1)
    }

    @MainActor
    @Test("ten thousand target epochs revoke pending work without another owner")
    func targetStormIsBounded() async {
        let releaseFirst = DispatchSemaphore(value: 0)
        let applications = NowPlayingControlLockedBox<[NowPlayingControlApplication]>([])
        var publications: [NowPlayingControlCompletion] = []
        let worker = NowPlayingControlWorker(
            minimumSeekIntervalNanoseconds: 0,
            apply: { application in
                let call = applications.update {
                    $0.append(application)
                    return $0.count
                }
                if call == 1 { _ = releaseFirst.wait(timeout: .now() + TestGate.deadlock) }
                return true
            },
            publish: { publications.append($0) })
        worker.replaceTarget(Self.target(0))
        #expect(worker.submitSeek(seconds: 1) == .accepted)
        #expect(await nowPlayingControlEventually { worker.statistics.activeApplications == 1 })
        #expect(worker.submitSeek(seconds: 2) == .accepted)
        #expect(worker.submitEdge(.playPause) == .accepted)

        for value in 1...10_000 { worker.replaceTarget(Self.target(value)) }
        #expect(worker.submitSeek(seconds: 7_777) == .accepted)
        let during = worker.statistics
        #expect(during.targetChanges == 10_001)
        #expect(during.applications == 1)
        #expect(during.activeApplications == 1)
        #expect(during.pendingSeeks == 1)
        #expect(during.pendingEdges == 0)
        #expect(during.revokedSeeks == 1)
        #expect(during.revokedEdges == 1)
        #expect(during.maximumConcurrentApplications == 1)
        #expect(during.maximumScheduledRuns == 1)

        releaseFirst.signal()
        #expect(
            await nowPlayingControlEventually {
                worker.statistics.applications == 2 && publications.count == 1
            })
        let applied = applications.snapshot
        #expect(Self.seconds(in: applied) == [1, 7_777])
        #expect(applied.last?.context.target == Self.target(10_000))
        #expect(applied.last?.context.targetEpoch == 10_001)
        #expect(worker.statistics.staleCompletions == 1)
        #expect(worker.statistics.publications == 1)
    }

    @MainActor
    @Test("actual MainActor delivery rechecks the target epoch")
    func deliveryGate() async {
        let held = NowPlayingControlHeldMainScheduler()
        var publications: [NowPlayingControlCompletion] = []
        let worker = NowPlayingControlWorker(
            minimumSeekIntervalNanoseconds: 0,
            apply: { _ in true },
            scheduleMain: held.schedule,
            publish: { publications.append($0) })
        worker.replaceTarget(Self.target(1))
        #expect(worker.submitEdge(.playPause) == .accepted)
        #expect(await nowPlayingControlEventually { held.count == 1 })

        worker.replaceTarget(Self.target(2))
        held.runFirst()
        #expect(publications.isEmpty)
        #expect(worker.statistics.stalePublications == 1)

        #expect(worker.submitEdge(.next) == .accepted)
        #expect(await nowPlayingControlEventually { held.count == 1 })
        held.runFirst()
        #expect(publications.map(\.application.context.target) == [Self.target(2)])
        #expect(worker.statistics.publications == 1)
    }

    @MainActor
    @Test("shutdown revokes pending controls without joining a blocked sender")
    func shutdownDoesNotJoin() async {
        let release = DispatchSemaphore(value: 0)
        var publications = 0
        let worker = NowPlayingControlWorker(
            apply: { _ in
                _ = release.wait(timeout: .now() + TestGate.deadlock)
                return true
            },
            publish: { _ in publications += 1 })
        worker.replaceTarget(Self.target(1))
        #expect(worker.submitSeek(seconds: 1) == .accepted)
        #expect(await nowPlayingControlEventually { worker.statistics.activeApplications == 1 })
        #expect(worker.submitSeek(seconds: 2) == .accepted)
        #expect(worker.submitEdge(.next) == .accepted)

        let started = DispatchTime.now().uptimeNanoseconds
        worker.shutdown()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        #expect(elapsed < 8_000_000)
        #expect(!worker.statistics.acceptsRequests)
        #expect(worker.statistics.pendingSeeks == 0)
        #expect(worker.statistics.pendingEdges == 0)
        #expect(worker.submitSeek(seconds: 3) == .refused(.shutDown))
        #expect(worker.submitEdge(.previous) == .refused(.shutDown))
        release.signal()
        #expect(await nowPlayingControlEventually { worker.statistics.staleCompletions == 1 })
        #expect(worker.statistics.applications == 1)
        #expect(worker.statistics.maximumConcurrentApplications == 1)
        #expect(publications == 0)
    }

    @Test("invalid or targetless controls are refused before scheduling")
    func invalidAdmission() {
        let applications = NowPlayingControlLockedBox(0)
        let worker = NowPlayingControlWorker(
            apply: { _ in
                applications.update { $0 += 1 }
                return true
            },
            publish: { _ in })

        #expect(worker.submitSeek(seconds: 1) == .refused(.noTarget))
        #expect(worker.submitEdge(.next) == .refused(.noTarget))
        worker.replaceTarget(Self.target(1))
        #expect(worker.submitSeek(seconds: .nan) == .refused(.invalidSeek))
        #expect(worker.submitSeek(seconds: -.infinity) == .refused(.invalidSeek))
        #expect(worker.statistics.applications == 0)
        #expect(worker.statistics.scheduledRuns == 0)
        #expect(applications.snapshot == 0)
    }
}
