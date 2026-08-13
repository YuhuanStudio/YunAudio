import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

private final class SourceTapSingingLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

@MainActor
private func sourceTapEventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@Suite("Source-tap lifecycle worker", .serialized)
struct SourceTapLifecycleWorkerTests {
    private static func key(
        _ index: Int, destination: String = "output"
    ) -> RouteOccurrenceKey {
        RouteOccurrenceKey(
            source: ChannelRef(deviceUID: "source-\(index)", channel: 0),
            destination: ChannelRef(deviceUID: destination, channel: 0),
            occurrence: 0)
    }

    private static func request(_ generation: UInt64, count: Int) -> SourceTapLifecycleRequest {
        SourceTapLifecycleRequest(
            generation: generation, routes: Array(0..<count),
            sourceUIDs: (0..<count).map { "source-\($0)" },
            routeKeys: (0..<count).map { Self.key($0) })
    }

    @MainActor
    @Test("ten thousand topology changes retain only first and latest")
    func firstLatestTopology() async throws {
        let applications = SourceTapSingingLockedBox<[Int]>([])
        let entered = SourceTapSingingLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        var published: [SourceTapLifecycleSnapshot] = []
        let worker = SourceTapLifecycleWorker(
            operations: .init(
                start: { routes in
                    applications.update { $0.append(routes.count) }
                    if routes.count == 1 {
                        entered.update { $0 = true }
                        _ = release.wait(timeout: .now() + 2)
                    }
                    return routes.count
                },
                stop: { true }),
            publish: { published.append($0) })

        #expect(worker.submit(Self.request(0, count: 1)))
        let enteredInTime = await sourceTapEventually { entered.read() }
        #expect(enteredInTime)
        for generation in 1..<UInt64(10_000) {
            #expect(worker.submit(Self.request(generation, count: 4)))
        }
        #expect(worker.statistics.submissions == 10_000)
        #expect(worker.statistics.coalesced == 9_998)
        #expect(worker.statistics.maximumPending == 1)
        #expect(worker.statistics.applications == 1)

        release.signal()
        for _ in 0..<2_000 where published.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(applications.read() == [1, 4])
        #expect(published.map(\.generation) == [9_999])
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.publications == 1)
        #expect(worker.statistics.revokedResults == 1)
        #expect(worker.statistics.mainThreadApplications == 0)
    }

    @MainActor
    @Test("generation revocation suppresses a late topology")
    func lateGenerationIsRevoked() async throws {
        let entered = SourceTapSingingLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        var published: [SourceTapLifecycleSnapshot] = []
        let worker = SourceTapLifecycleWorker(
            operations: .init(
                start: { routes in
                    entered.update { $0 = true }
                    _ = release.wait(timeout: .now() + 2)
                    return routes.count
                }, stop: { true }),
            publish: { published.append($0) })

        #expect(worker.submit(Self.request(1, count: 1)))
        let enteredInTime = await sourceTapEventually { entered.read() }
        #expect(enteredInTime)
        worker.invalidate()
        release.signal()
        for _ in 0..<2_000 where worker.statistics.revokedResults == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(published.isEmpty)
        #expect(worker.statistics.revokedResults == 1)
        #expect(worker.statistics.mainThreadApplications == 0)
    }

    @MainActor
    @Test("a partial open is reused against the same requested prefix")
    func partialOpenIsReusable() async throws {
        let starts = SourceTapSingingLockedBox(0)
        var published: [SourceTapLifecycleSnapshot] = []
        let worker = SourceTapLifecycleWorker(
            operations: .init(
                start: { _ in
                    starts.update { $0 += 1 }
                    return 2
                }, stop: { true }),
            publish: { published.append($0) })

        #expect(worker.submit(Self.request(1, count: 4)))
        for _ in 0..<2_000 where published.count < 1 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(worker.submit(Self.request(1, count: 4)))
        for _ in 0..<2_000 where published.count < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(starts.read() == 1)
        #expect(published.map(\.openedCount) == [2, 2])
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.mainThreadApplications == 0)
    }

    @MainActor
    @Test("expanding one requested source to four restarts the topology")
    func expandedTopologyRestarts() async {
        let starts = SourceTapSingingLockedBox<[Int]>([])
        let stops = SourceTapSingingLockedBox(0)
        var published: [SourceTapLifecycleSnapshot] = []
        let worker = SourceTapLifecycleWorker(
            operations: .init(
                start: { routes in
                    starts.update { $0.append(routes.count) }
                    return routes.count
                },
                stop: {
                    stops.update { $0 += 1 }
                    return true
                }),
            publish: { published.append($0) })

        #expect(worker.submit(Self.request(1, count: 1)))
        let firstPublished = await sourceTapEventually { published.count == 1 }
        #expect(firstPublished)
        #expect(worker.submit(Self.request(2, count: 4)))
        let secondPublished = await sourceTapEventually { published.count == 2 }
        #expect(secondPublished)
        #expect(starts.read() == [1, 4])
        #expect(stops.read() == 1)
        #expect(published.map(\.openedCount) == [1, 4])
        #expect(worker.statistics.mainThreadApplications == 0)
    }

    @MainActor
    @Test("the same UID on a different route occurrence restarts")
    func routeIdentityRestarts() async {
        let starts = SourceTapSingingLockedBox(0)
        let stops = SourceTapSingingLockedBox(0)
        var published: [SourceTapLifecycleSnapshot] = []
        let worker = SourceTapLifecycleWorker(
            operations: .init(
                start: { routes in
                    starts.update { $0 += 1 }
                    return routes.count
                },
                stop: {
                    stops.update { $0 += 1 }
                    return true
                }),
            publish: { published.append($0) })
        let first = SourceTapLifecycleRequest(
            generation: 1, routes: [0], sourceUIDs: ["source-0"],
            routeKeys: [Self.key(0, destination: "first")])
        let second = SourceTapLifecycleRequest(
            generation: 2, routes: [0], sourceUIDs: ["source-0"],
            routeKeys: [Self.key(0, destination: "second")])

        #expect(worker.submit(first))
        let firstPublished = await sourceTapEventually { published.count == 1 }
        #expect(firstPublished)
        #expect(worker.submit(second))
        let secondPublished = await sourceTapEventually { published.count == 2 }
        #expect(secondPublished)
        #expect(starts.read() == 2)
        #expect(stops.read() == 1)
        #expect(published.last?.routeKeys == second.routeKeys)
    }

    @MainActor
    @Test("a failed stop retains ownership and never starts the replacement")
    func failedStopRetainsOwnership() async {
        let starts = SourceTapSingingLockedBox<[Int]>([])
        let stops = SourceTapSingingLockedBox(0)
        let stopSucceeds = SourceTapSingingLockedBox(false)
        var published: [SourceTapLifecycleSnapshot] = []
        let worker = SourceTapLifecycleWorker(
            operations: .init(
                start: { routes in
                    starts.update { $0.append(routes.count) }
                    return routes.count
                },
                stop: {
                    stops.update { $0 += 1 }
                    return stopSucceeds.read()
                }),
            publish: { published.append($0) })

        #expect(worker.submit(Self.request(1, count: 1)))
        let firstPublished = await sourceTapEventually { published.count == 1 }
        #expect(firstPublished)
        #expect(worker.submit(Self.request(2, count: 4)))
        let failedPublished = await sourceTapEventually { published.count == 2 }
        #expect(failedPublished)
        #expect(starts.read() == [1])
        #expect(published.last?.sourceUIDs == ["source-0"])
        #expect(published.last?.transitionSucceeded == false)
        #expect(worker.statistics.failedStops == 1)

        stopSucceeds.update { $0 = true }
        #expect(worker.submit(Self.request(3, count: 4)))
        let replacementPublished = await sourceTapEventually { published.count == 3 }
        #expect(replacementPublished)
        #expect(starts.read() == [1, 4])
        #expect(stops.read() == 2)
        #expect(published.last?.transitionSucceeded == true)
    }
}

@Suite("Source-tap union planner")
struct SourceTapUnionPlannerTests {
    private static func candidate(_ index: Int, prefix: String) -> SourceTapUnionCandidate {
        let uid = "\(prefix)-\(index)"
        return SourceTapUnionCandidate(
            route: index,
            routeKey: RouteOccurrenceKey(
                source: ChannelRef(deviceUID: uid, channel: 0),
                destination: ChannelRef(deviceUID: "output", channel: 0), occurrence: 0),
            uid: uid, name: uid)
    }

    @Test("four transcripts four voices and one backing have nine bounded slots")
    func disjointMaximum() {
        let transcripts = (0..<4).map { Self.candidate($0, prefix: "transcript") }
        let voices = (0..<4).map { Self.candidate($0 + 4, prefix: "voice") }
        let backing = Self.candidate(8, prefix: "backing")

        let plan = SourceTapUnionPlanner.plan(
            transcriptions: transcripts, voices: voices,
            backingReferences: [backing], recognitionReference: backing)

        #expect(plan.sources.count == 9)
        #expect(plan.maximumSlotCount == 9)
        #expect(plan.sources.prefix(4).allSatisfy { $0.consumers == .transcription })
        #expect(
            plan.sources[4..<8].allSatisfy { $0.consumers == .voicePitch })
        #expect(
            plan.sources[8].consumers
                == [.backingPitch, .musicRecognition])
        #expect(plan.refusedTranscriptions == 0)
        #expect(plan.refusedVoices == 0)
        #expect(plan.refusedBackingReferences == 0)
    }

    @Test("overlap owns one ring with both consumers")
    func overlapIsDeduplicated() {
        let shared = Self.candidate(0, prefix: "shared")
        let plan = SourceTapUnionPlanner.plan(
            transcriptions: [shared], voices: [shared], backingReferences: [])

        #expect(plan.sources.count == 1)
        #expect(plan.sources[0].consumers == [.transcription, .voicePitch])
        #expect(plan.lifecycleRequest(generation: 7).routes == [0])
        let analysis = plan.analysisSources(openedCount: 1)
        #expect(analysis.count == 1)
        #expect(analysis[0].needsPitch)
        #expect(analysis[0].forwardsPCM)
    }

    @Test("the sixty-four source boundary refuses beyond each independent budget")
    func sixtyFourSourcesAreBounded() {
        let requested = (0..<64).map { Self.candidate($0, prefix: "source") }
        let plan = SourceTapUnionPlanner.plan(
            transcriptions: requested, voices: requested,
            backingReferences: Array(requested.reversed()))

        #expect(plan.sources.count == 5)
        #expect(plan.refusedTranscriptions == 60)
        #expect(
            plan.transcriptionAdmission.refused.map(\.source.uid)
                == (4..<64).map { "source-\($0)" })
        #expect(
            plan.transcriptionAdmission.refused.allSatisfy {
                $0.reason == .sourceLimit(maximum: 4)
            })
        #expect(plan.refusedVoices == 60)
        #expect(plan.refusedBackingReferences == 63)
        #expect(plan.sources.count { $0.consumers.contains(.voicePitch) } == 4)
        #expect(plan.sources.count { $0.consumers.contains(.backingPitch) } == 1)
    }
}

@Suite("Singing source admission")
struct SingingSourceAdmissionTests {
    private static func key(_ index: Int) -> RouteOccurrenceKey {
        RouteOccurrenceKey(
            source: ChannelRef(deviceUID: "source-\(index)", channel: 0),
            destination: ChannelRef(deviceUID: "output", channel: 0), occurrence: 0)
    }

    private static func sources(_ count: Int, backing: Int = 0) -> [SingingAnalysisSource] {
        (0..<count).map { index in
            SingingAnalysisSource(
                slot: index, uid: "source-\(index)", name: "Source \(index)",
                routeKey: Self.key(index),
                role: index < backing ? .backingReference : .voice)
        }
    }

    @Test("one and four voices are admitted exactly")
    func ordinaryVoiceCounts() {
        let one = SingingSourceAdmissionPolicy.admit(Self.sources(1))
        let four = SingingSourceAdmissionPolicy.admit(Self.sources(4))
        #expect(one.admitted.count == 1)
        #expect(one.refusedVoices == 0)
        #expect(four.admitted.count == 4)
        #expect(four.refusedVoices == 0)
    }

    @Test("sixteen and sixty-four sources retain four voices and one backing")
    func largeTopologiesAreExplicitlyRefused() {
        for count in [16, 64] {
            let result = SingingSourceAdmissionPolicy.admit(Self.sources(count, backing: 2))
            #expect(result.admitted.count == 5)
            #expect(result.admitted.count { $0.role == .voice } == 4)
            #expect(result.admitted.count { $0.role == .backingReference } == 1)
            #expect(result.refusedBackingReferences == 1)
            #expect(result.refusedVoices == count - 6)
            #expect(result.refusedInvalidSources == 0)
        }
    }

    @Test("duplicates and a sixty-fifth source are named invalid input")
    func invalidSources() {
        var sources = Self.sources(64)
        sources.append(
            SingingAnalysisSource(
                slot: 64, uid: "source-64", name: "Too many",
                routeKey: Self.key(64), role: .voice))
        sources.append(sources[0])
        let result = SingingSourceAdmissionPolicy.admit(sources)
        #expect(result.admitted.count == 4)
        #expect(result.refusedVoices == 60)
        #expect(result.refusedInvalidSources == 2)
    }
}

@Suite("Singing analysis worker", .serialized)
struct SingingAnalysisWorkerTests {
    private static func key(_ index: Int) -> RouteOccurrenceKey {
        RouteOccurrenceKey(
            source: ChannelRef(deviceUID: "voice-\(index)", channel: 0),
            destination: ChannelRef(deviceUID: "output", channel: 0), occurrence: 0)
    }

    private static func sources(_ count: Int) -> [SingingAnalysisSource] {
        (0..<count).map { index in
            SingingAnalysisSource(
                slot: index, uid: "voice-\(index)", name: "Voice \(index)",
                routeKey: Self.key(index), role: .voice)
        }
    }

    private static func request(
        generation: UInt64, resetToken: UInt64 = 1, count: Int = 4,
        submittedAt: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> SingingAnalysisRequest {
        SingingAnalysisRequest(
            generation: generation, resetToken: resetToken,
            submittedAtNanoseconds: submittedAt, sampleRate: 48_000,
            anchorSeconds: 0, advancesTimeline: true, usesLearnedHead: false,
            sources: Self.sources(count))
    }

    @MainActor
    @Test("ten thousand PCM snapshots retain only first and latest")
    func firstLatestSnapshot() async throws {
        let applied = SourceTapSingingLockedBox<[UInt64]>([])
        let entered = SourceTapSingingLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        var published: [SingingAnalysisSnapshot] = []
        let worker = SingingAnalysisWorker(
            operations: .init(drain: { slot, _, _ in
                if slot == 0 {
                    applied.update { $0.append(UInt64($0.count)) }
                    if applied.read().count == 1 {
                        entered.update { $0 = true }
                        _ = release.wait(timeout: .now() + 2)
                    }
                }
                return 0
            }),
            publish: { published.append($0) })

        #expect(worker.submit(Self.request(generation: 0)))
        let enteredInTime = await sourceTapEventually { entered.read() }
        #expect(enteredInTime)
        for generation in 1..<UInt64(10_000) {
            #expect(worker.submit(Self.request(generation: generation)))
        }
        #expect(worker.statistics.submissions == 10_000)
        #expect(worker.statistics.coalescedSnapshots == 9_998)
        #expect(worker.statistics.maximumPendingSnapshots == 1)
        #expect(worker.statistics.applications == 1)
        #expect(worker.statistics.activeApplications == 1)
        #expect(worker.statistics.maximumActiveApplications == 1)
        #expect(worker.statistics.mainThreadApplications == 0)

        release.signal()
        for _ in 0..<2_000 where published.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(applied.read().count == 2)
        #expect(published.map(\.generation) == [9_999])
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.maximumPendingSnapshots == 1)
        #expect(worker.statistics.maximumActiveApplications == 1)
        #expect(worker.statistics.mainThreadApplications == 0)
    }

    @MainActor
    @Test("a reset revokes late DSP publication")
    func resetRevokesLatePublication() async throws {
        let entered = SourceTapSingingLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        var published: [SingingAnalysisSnapshot] = []
        let worker = SingingAnalysisWorker(
            operations: .init(drain: { _, _, _ in
                entered.update { $0 = true }
                _ = release.wait(timeout: .now() + 2)
                return 0
            }), publish: { published.append($0) })

        #expect(worker.submit(Self.request(generation: 1, count: 1)))
        let enteredInTime = await sourceTapEventually { entered.read() }
        #expect(enteredInTime)
        worker.invalidate()
        release.signal()
        for _ in 0..<2_000 where worker.statistics.revokedResults == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<2_000 where worker.statistics.activePitchTrackers != 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(published.isEmpty)
        #expect(worker.statistics.revokedResults == 1)
        #expect(worker.statistics.activePitchTrackers == 0)
        #expect(worker.statistics.mainThreadApplications == 0)
    }

    @MainActor
    @Test("ring totals and refused voices are observable")
    func telemetryNamesLoss() async throws {
        var publication: SingingAnalysisSnapshot?
        let worker = SingingAnalysisWorker(
            operations: .init(
                drain: { _, destination, _ in
                    destination[0] = 0
                    return 1
                },
                tapStatistics: { _ in
                    RoutingEngine.TranscriptTapStatistics(available: 17, dropped: 7)
                }),
            publish: { publication = $0 })

        #expect(worker.submit(Self.request(generation: 1, count: 64)))
        for _ in 0..<2_000 where publication == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        let snapshot = try #require(publication)
        #expect(snapshot.admittedVoiceCount == 4)
        #expect(snapshot.refusedVoiceCount == 60)
        #expect(snapshot.drainedSamples == 4)
        #expect(snapshot.ringAvailableSamples == 68)
        #expect(snapshot.ringDroppedSamplesTotal == 28)
        #expect(snapshot.unavailableTapStatisticsCount == 0)
        #expect(worker.statistics.refusedVoiceSources == 60)
        #expect(worker.statistics.drainedSamples == 4)
        #expect(worker.statistics.latestRingAvailableSamples == 68)
        #expect(worker.statistics.latestRingDroppedSamplesTotal == 28)
        #expect(worker.statistics.unavailableTapStatistics == 0)
        #expect(worker.statistics.mainThreadApplications == 0)
    }

    @MainActor
    @Test("a forward-only transcript drains once and constructs no pitch tracker")
    func forwardOnlySkipsPitch() async throws {
        let forwarded = SourceTapSingingLockedBox<[Float]>([])
        var publication: SingingAnalysisSnapshot?
        let source = SingingAnalysisSource(
            slot: 0, uid: "transcript", name: "Transcript",
            routeKey: Self.key(0), consumers: .transcription)
        let worker = SingingAnalysisWorker(
            operations: .init(
                drain: { _, destination, _ in
                    destination[0] = 0.25
                    destination[1] = -0.5
                    return 2
                },
                tapStatistics: { _ in
                    RoutingEngine.TranscriptTapStatistics(available: 2, dropped: 0)
                },
                forwardPCM: { _, _, samples, _ in forwarded.update { $0 = samples } }),
            publish: { publication = $0 })
        let request = SingingAnalysisRequest(
            generation: 1, resetToken: 1, sampleRate: 48_000,
            anchorSeconds: 0, advancesTimeline: true, usesLearnedHead: false,
            sources: [source])

        #expect(worker.submit(request))
        let published = await sourceTapEventually { publication != nil }
        #expect(published)
        let snapshot = try #require(publication)
        #expect(snapshot.sources.isEmpty)
        #expect(snapshot.drainedSamples == 2)
        #expect(forwarded.read() == [0.25, -0.5])
        #expect(worker.statistics.pitchTrackerConstructions == 0)
        #expect(worker.statistics.activePitchTrackers == 0)
        #expect(worker.statistics.maximumActivePitchTrackers == 0)
    }

    @MainActor
    @Test("tap-statistics contention is explicit and never becomes zero loss")
    func unavailableTapStatisticsAreNamed() async throws {
        var publication: SingingAnalysisSnapshot?
        let worker = SingingAnalysisWorker(
            operations: .init(drain: { _, _, _ in 0 }, tapStatistics: { _ in nil }),
            publish: { publication = $0 })

        #expect(worker.submit(Self.request(generation: 1, count: 4)))
        let published = await sourceTapEventually { publication != nil }
        #expect(published)
        let snapshot = try #require(publication)
        #expect(snapshot.ringAvailableSamples == 0)
        #expect(snapshot.ringDroppedSamplesTotal == 0)
        #expect(snapshot.unavailableTapStatisticsCount == 4)
        #expect(worker.statistics.unavailableTapStatistics == 4)
    }

    @MainActor
    @Test("MIDI sampling and an exact backing-reference score stay off MainActor")
    func exactBackingScoreIsPreparedOnWorker() async throws {
        let count = 96_000
        let samples = (0..<count).map { frame in
            Float(0.5 * sin(2 * .pi * 440 * Double(frame) / 48_000))
        }
        var publication: SingingAnalysisSnapshot?
        let source = SingingAnalysisSource(
            slot: 0, uid: "backing", name: "Backing",
            routeKey: Self.key(0), role: .backingReference)
        let melody = MidiMelody(
            notes: [.init(start: 0, end: 2, midi: 69, track: 0)])
        let lyrics = Lyrics(lines: [.init(time: 0, text: "line")])
        let worker = SingingAnalysisWorker(
            operations: .init(drain: { _, destination, capacity in
                let copied = min(capacity, samples.count)
                for index in 0..<copied { destination[index] = samples[index] }
                return copied
            }),
            publish: { publication = $0 })
        let request = SingingAnalysisRequest(
            generation: 1, resetToken: 1, sampleRate: 48_000,
            anchorSeconds: 0, advancesTimeline: true, usesLearnedHead: false,
            sources: [source],
            score: SingingScoreRequest(
                through: 2, lyrics: lyrics, melody: melody,
                referenceVersion: 1, key: nil, refresh: true))

        #expect(worker.submit(request))
        let published = await sourceTapEventually { publication != nil }
        #expect(published)
        let snapshot = try #require(publication)
        let backing = try #require(snapshot.sources.first)
        #expect(snapshot.scoringReferenceMode == .exact)
        #expect(backing.role == .backingReference)
        #expect(backing.score.referenceSeconds >= 1.9)
        #expect(worker.statistics.mainThreadApplications == 0)
        #expect(worker.statistics.activePitchTrackers == 1)
    }

    @MainActor
    @Test("MainActor submission meets the distribution gate at 1, 4, 16 and 64 sources")
    func submissionLatencyDistribution() async {
        let release = DispatchSemaphore(value: 0)
        let entered = SourceTapSingingLockedBox(false)
        let worker = SingingAnalysisWorker(
            operations: .init(drain: { _, _, _ in
                entered.update { $0 = true }
                _ = release.wait(timeout: .now() + 2)
                return 0
            }), publish: { _ in })
        #expect(worker.submit(Self.request(generation: 0, count: 1)))
        let enteredInTime = await sourceTapEventually { entered.read() }
        #expect(enteredInTime)

        for count in [1, 4, 16, 64] {
            var durations: [UInt64] = []
            durations.reserveCapacity(1_000)
            for generation in 1...UInt64(1_000) {
                let started = DispatchTime.now().uptimeNanoseconds
                #expect(
                    worker.submit(
                        Self.request(generation: generation, count: count)))
                durations.append(DispatchTime.now().uptimeNanoseconds - started)
            }
            durations.sort()
            let p99 = durations[989]
            let maximum = durations.last ?? .max
            #expect(p99 < 2_000_000)
            #expect(maximum < 8_000_000)
        }
        #expect(worker.statistics.activeApplications == 1)
        #expect(worker.statistics.maximumActiveApplications == 1)
        #expect(worker.statistics.maximumPendingSnapshots == 1)
        #expect(worker.statistics.mainThreadApplications == 0)
        release.signal()
    }

    @MainActor
    @Test("topology replacement cannot overlap an old-generation drain")
    func lifecycleAndAnalysisShareOneExecutor() async throws {
        let order = SourceTapSingingLockedBox<[String]>([])
        let drainEntered = SourceTapSingingLockedBox(false)
        let releaseDrain = DispatchSemaphore(value: 0)
        var lifecyclePublication: SourceTapLifecycleSnapshot?
        var analysisPublication: SingingAnalysisSnapshot?
        let pair = SourceTapSingingWorkerPair(
            lifecycleOperations: .init(
                start: { routes in
                    order.update { $0.append("start-\(routes.count)") }
                    return routes.count
                },
                stop: {
                    order.update { $0.append("stop") }
                    return true
                }),
            analysisOperations: .init(drain: { _, _, _ in
                order.update { $0.append("drain-enter") }
                drainEntered.update { $0 = true }
                _ = releaseDrain.wait(timeout: .now() + 2)
                order.update { $0.append("drain-exit") }
                return 0
            }),
            queue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.tests.source-tap-owner"),
            publishLifecycle: { lifecyclePublication = $0 },
            publishAnalysis: { analysisPublication = $0 })

        #expect(pair.lifecycle.submit(Self.lifecycleRequest(generation: 1, count: 1)))
        for _ in 0..<2_000 where lifecyclePublication == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(pair.analysis.submit(Self.request(generation: 1, count: 1)))
        let drainEnteredInTime = await sourceTapEventually { drainEntered.read() }
        #expect(drainEnteredInTime)
        lifecyclePublication = nil
        #expect(pair.lifecycle.submit(Self.lifecycleRequest(generation: 2, count: 2)))
        try await Task.sleep(for: .milliseconds(20))
        #expect(order.read() == ["start-1", "drain-enter"])

        releaseDrain.signal()
        for _ in 0..<2_000 where lifecyclePublication == nil || analysisPublication == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(order.read() == ["start-1", "drain-enter", "drain-exit", "stop", "start-2"])
        #expect(pair.lifecycle.statistics.mainThreadApplications == 0)
        #expect(pair.analysis.statistics.mainThreadApplications == 0)
    }

    private static func lifecycleRequest(
        generation: UInt64, count: Int
    ) -> SourceTapLifecycleRequest {
        SourceTapLifecycleRequest(
            generation: generation, routes: Array(0..<count),
            sourceUIDs: (0..<count).map { "voice-\($0)" },
            routeKeys: (0..<count).map(Self.key))
    }
}

@Suite("Source-tap integration gates")
struct SourceTapIntegrationGateTests {
    private static func key(_ index: Int) -> RouteOccurrenceKey {
        RouteOccurrenceKey(
            source: ChannelRef(deviceUID: "source-\(index)", channel: 0),
            destination: ChannelRef(deviceUID: "output", channel: 0), occurrence: 0)
    }

    @Test("Stop revokes every later poll and old-generation snapshot")
    func stopAdmissionIsSynchronous() {
        var gate = SourceTapRequestGate()
        gate.activate()
        #expect(gate.accepts(generation: 7, currentGeneration: 7))

        gate.revoke()
        var admittedPolls = 0
        for _ in 0..<10_000 where gate.acceptsRequests { admittedPolls += 1 }
        #expect(admittedPolls == 0)
        #expect(!gate.accepts(generation: 7, currentGeneration: 8))
        #expect(!gate.accepts(generation: 8, currentGeneration: 8))
    }

    @Test("a suspended scoring wish can be switched off once and stays off")
    func stickyWishCanBeCleared() {
        var state = ScoringWishState(requested: true, active: true)
        state.suspend()
        #expect(state.requested)
        #expect(!state.active)

        let shouldPersist = state.setByUser(false, routeIsRunning: true)
        #expect(shouldPersist)
        #expect(!state.requested)
        #expect(!state.active)
        state.routeDidStart()
        #expect(!state.active)
    }

    @Test("PCM forwarding has five slots and exact bandwidth ceilings")
    func forwardingBudgetAndTelemetry() {
        let forwarder = SourceTapPCMForwarder()
        let endpoints = (0..<64).map { index in
            SourceTapPCMForwarder.Endpoint(
                identity: SourceTapPCMForwarder.Identity(
                    uid: "source-\(index)", routeKey: Self.key(index)),
                consume: { _, _ in })
        }
        forwarder.replace(generation: 7, endpoints: endpoints)
        #expect(forwarder.statistics.activeEndpoints == 5)
        #expect(forwarder.statistics.refusedEndpoints == 59)

        let source = SingingAnalysisSource(
            slot: 0, uid: "source-0", name: "Source 0", routeKey: Self.key(0),
            consumers: .transcription)
        forwarder.forward(
            generation: 7, source: source, samples: [0.25, -0.5], sampleRate: 48_000)
        #expect(forwarder.statistics.forwardedBlocks == 1)
        #expect(forwarder.statistics.forwardedSamples == 2)
        #expect(forwarder.statistics.forwardedBytes == 8)

        #expect(SourceTapPCMForwarder.maximumForwardingSources == 5)
        #expect(SourceTapPCMForwarder.maximumBurstBytes == 1_310_720)
        let ordinaryMiB =
            SourceTapPCMForwarder.bytesPerSecond(sampleRate: 48_000)
            / Double(1_024 * 1_024)
        let highRateMiB =
            SourceTapPCMForwarder.bytesPerSecond(sampleRate: 384_000)
            / Double(1_024 * 1_024)
        #expect(abs(ordinaryMiB - 0.915_527_343_75) < 0.000_000_001)
        #expect(abs(highRateMiB - 7.324_218_75) < 0.000_000_001)
    }
}

@Suite("Singer-pitch configuration")
struct SingerPitchConfigurationTests {
    @Test("each tracker keeps an immutable learned-head selection")
    func immutableLearnedHeadSelection() throws {
        let previous = SingerPitch.usesLearnedHead
        defer { SingerPitch.usesLearnedHead = previous }
        SingerPitch.usesLearnedHead = true
        let selected = try #require(
            SingerPitch(sampleRate: 48_000, usesLearnedHead: true))
        SingerPitch.usesLearnedHead = false
        let unselected = try #require(
            SingerPitch(sampleRate: 48_000, usesLearnedHead: false))

        #expect(selected.sampleInterval == unselected.sampleInterval)
        #expect(!SingerPitch.usesLearnedHead)
    }
}
