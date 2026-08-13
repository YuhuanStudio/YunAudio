import Foundation
import Testing

@testable import YunAudioApp

private final class CollectionPersistenceLocked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    @discardableResult
    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

private final class CollectionPersistenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Int
    private var latencies: [UInt64] = []

    init(expected: Int) {
        self.expected = expected
        latencies.reserveCapacity(expected)
    }

    func record(sentAt: UInt64) {
        lock.withLock {
            latencies.append(DispatchTime.now().uptimeNanoseconds - sentAt)
        }
    }

    var isComplete: Bool { lock.withLock { latencies.count == expected } }
    var snapshot: [UInt64] { lock.withLock { latencies } }
}

@Suite("Bounded JSON collection persistence", .serialized)
struct CollectionPersistenceTests {
    @Test("256 records and one MiB are exact admission boundaries")
    func exactAdmissionBoundaries() {
        let limits = CollectionPersistenceLimits.userCollection
        let admission = CollectionPersistenceAdmission(limits: limits)

        #expect(
            admission.refusal(
                recordCount: 256,
                estimatedEncodedBytes: 1_048_576) == nil)
        #expect(
            admission.refusal(
                recordCount: 257,
                estimatedEncodedBytes: 1)
                == .recordLimit(requested: 257, maximum: 256))
        #expect(
            admission.refusal(
                recordCount: 1,
                estimatedEncodedBytes: 1_048_577)
                == .estimatedEncodedSize(requested: 1_048_577, maximum: 1_048_576))
        #expect(
            admission.refusal(recordCount: 1, estimatedEncodedBytes: nil)
                == .invalidEstimate)
    }

    @Test("an oversized persisted value is rejected before decode")
    func oversizedLoadNeverDecodes() {
        let decodes = CollectionPersistenceLocked(0)
        let persistence = BoundedCollectionPersistence<[Int]>(
            encode: { try? JSONEncoder().encode($0) },
            sink: { _ in true },
            synchronise: { true })

        let result = persistence.load(
            Data(count: 1_048_577),
            decode: { data in
                decodes.update { $0 += 1 }
                return try? JSONDecoder().decode([Int].self, from: data)
            },
            recordCount: \.count)

        guard case .refused(let refusal) = result else {
            Issue.record("an oversized persisted value was not refused")
            return
        }
        #expect(
            refusal
                == .persistedEncodedSize(requested: 1_048_577, maximum: 1_048_576))
        #expect(decodes.read() == 0)
        #expect(persistence.statistics.refusedLoads == 1)
    }

    @Test("a 257th encoded record is refused before decode")
    func encodedRecordCountIsCappedBeforeDecode() throws {
        let decodes = CollectionPersistenceLocked(0)
        let persistence = BoundedCollectionPersistence<[Int]>(
            encode: { try? JSONEncoder().encode($0) },
            sink: { _ in true },
            synchronise: { true })
        let data = try JSONEncoder().encode(Array(0...256))
        let result = persistence.load(
            data,
            decode: {
                decodes.update { $0 += 1 }
                return try? JSONDecoder().decode([Int].self, from: $0)
            },
            recordCount: \.count)

        guard case .refused(let refusal) = result else {
            Issue.record("a decoded oversized collection was not refused")
            return
        }
        #expect(refusal == .recordLimit(requested: 257, maximum: 256))
        #expect(decodes.read() == 0)
    }

    @Test("the record census ignores strings and nested collection commas")
    func recordCensusTracksOnlyTopLevelElements() {
        let data = Data(#"[{"text":"one,two","nested":[1,2,3]},{"text":"three"}]"#.utf8)
        #expect(
            JSONArrayCapacityInspector.inspect(data, maximumRecords: 2)
                == .withinLimit(2))
        #expect(
            JSONArrayCapacityInspector.inspect(data, maximumRecords: 1)
                == .exceedsLimit(2))
        #expect(
            JSONArrayCapacityInspector.inspect(Data("[]".utf8), maximumRecords: 0)
                == .withinLimit(0))
    }

    @Test("a refused submission is counted and schedules no worker value")
    func refusalTelemetryIsExplicit() {
        let persistence = BoundedCollectionPersistence<Int>(
            encode: { Data(String($0).utf8) },
            sink: { _ in true },
            synchronise: { true })

        let preflight = persistence.preflightRefusal(
            recordCount: 257,
            estimatedEncodedBytes: 3)
        let result = persistence.submit(
            257,
            recordCount: 257,
            estimatedEncodedBytes: 3)

        #expect(preflight == .recordLimit(requested: 257, maximum: 256))
        #expect(result == .refused(.recordLimit(requested: 257, maximum: 256)))
        #expect(persistence.latestValue == nil)
        #expect(persistence.statistics.refusedSubmissions == 2)
        #expect(persistence.statistics.admittedSubmissions == 0)
        #expect(
            persistence.statistics.lastRefusal
                == .recordLimit(requested: 257, maximum: 256))
    }

    @MainActor
    @Test("ten thousand submissions encode first and exact latest off MainActor")
    func stormIsFirstLatestAndMainActorResponsive() async throws {
        let firstStarted = CollectionPersistenceLocked(false)
        let releaseFirst = DispatchSemaphore(value: 0)
        let operations = CollectionPersistenceLocked<[String]>([])
        let concurrent = CollectionPersistenceLocked((active: 0, maximum: 0))
        let configuration = QuickConfig(
            name: "Podcast",
            systemInputUID: "input",
            systemOutputUID: "output",
            sourceUID: "source",
            destinationUID: "destination",
            monitorUID: "monitor",
            capturedAppBundleIDs: ["app.one", "app.two"],
            isRouting: true)
        let productionSizedCollection = Array(repeating: configuration, count: 256)
        let persistence = BoundedCollectionPersistence<Int>(
            encode: { value in
                concurrent.update {
                    $0.active += 1
                    $0.maximum = max($0.maximum, $0.active)
                }
                operations.update { $0.append("encode:\(value):\(Thread.isMainThread)") }
                if value == 0 {
                    firstStarted.update { $0 = true }
                    releaseFirst.wait()
                }
                Thread.sleep(forTimeInterval: 0.05)
                concurrent.update { $0.active -= 1 }
                return Data(String(value).utf8)
            },
            sink: { data in
                operations.update {
                    $0.append(
                        "sink:\(String(decoding: data, as: UTF8.self)):\(Thread.isMainThread)")
                }
                Thread.sleep(forTimeInterval: 0.05)
                return true
            },
            synchronise: { true })

        #expect(
            persistence.submit(0, recordCount: 1, estimatedEncodedBytes: 1)
                == .accepted)
        for _ in 0..<200 where !firstStarted.read() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(firstStarted.read())

        var submissionLatencies: [UInt64] = []
        submissionLatencies.reserveCapacity(9_999)
        for value in 1..<10_000 {
            let started = DispatchTime.now().uptimeNanoseconds
            let estimate = QuickConfigStore.encodedSizeUpperBoundForDiagnostics(
                productionSizedCollection)
            #expect(
                persistence.submit(
                    value,
                    recordCount: productionSizedCollection.count,
                    estimatedEncodedBytes: estimate)
                    == .accepted)
            submissionLatencies.append(DispatchTime.now().uptimeNanoseconds - started)
        }
        let probe = Self.startMainActorProbe(samples: 200)
        releaseFirst.signal()

        let flushResult = await Self.flush(persistence)
        for _ in 0..<200 where !probe.isComplete {
            try await Task.sleep(for: .milliseconds(5))
        }
        let probeLatencies = probe.snapshot
        try #require(probeLatencies.count == 200)
        let orderedSubmissions = submissionLatencies.sorted()
        let submissionP99 = orderedSubmissions[
            min(orderedSubmissions.count - 1, orderedSubmissions.count * 99 / 100)]
        let orderedProbes = probeLatencies.sorted()
        let probeP99 = orderedProbes[
            min(orderedProbes.count - 1, orderedProbes.count * 99 / 100)]

        print(
            "collection admission p99 \(submissionP99) ns, max "
                + "\(orderedSubmissions.last ?? .max) ns; MainActor probe p99 "
                + "\(probeP99) ns, max \(orderedProbes.last ?? .max) ns")

        #expect(flushResult == .synchronised)
        #expect(
            operations.read() == [
                "encode:0:false", "sink:0:false",
                "encode:9999:false", "sink:9999:false",
            ])
        #expect(persistence.latestValue == 9_999)
        #expect(concurrent.read().maximum == 1)
        #expect(persistence.statistics.admittedSubmissions == 10_000)
        #expect(persistence.statistics.successfulWrites == 2)
        #expect(persistence.statistics.workerStarts == 1)
        #expect(persistence.statistics.maximumConcurrentWrites == 1)
        #expect(persistence.statistics.maximumRetainedSnapshots <= 3)
        #expect(submissionP99 < 2_000_000, "submission p99 was \(submissionP99) ns")
        #expect(
            (orderedSubmissions.last ?? .max) < 8_000_000,
            "submission max was \(orderedSubmissions.last ?? .max) ns")
        #expect(probeP99 < 2_000_000, "MainActor probe p99 was \(probeP99) ns")
        #expect(
            (orderedProbes.last ?? .max) < 8_000_000,
            "MainActor probe max was \(orderedProbes.last ?? .max) ns")
    }

    @MainActor
    @Test("an encoder that exceeds its estimate never reaches the sink")
    func realEncodedSizeIsRechecked() async throws {
        let entered = CollectionPersistenceLocked(false)
        let release = DispatchSemaphore(value: 0)
        let sinks = CollectionPersistenceLocked(0)
        let flushResult = CollectionPersistenceLocked<PreferenceFlushResult?>(nil)
        let persistence = BoundedCollectionPersistence<Int>(
            limits: .init(maximumRecords: 1, maximumEncodedBytes: 4),
            encode: { _ in
                entered.update { $0 = true }
                release.wait()
                return Data(count: 5)
            },
            sink: { _ in
                sinks.update { $0 += 1 }
                return true
            },
            synchronise: { true })

        #expect(
            persistence.submit(1, recordCount: 1, estimatedEncodedBytes: 4)
                == .accepted)
        for _ in 0..<200 where !entered.read() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(entered.read())
        persistence.flush { result in flushResult.update { $0 = result } }
        release.signal()
        for _ in 0..<200 where flushResult.read() == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(flushResult.read() == .failed)
        #expect(sinks.read() == 0)
        #expect(persistence.statistics.failedWrites == 1)
        #expect(
            persistence.statistics.lastRefusal
                == .encodedSize(requested: 5, maximum: 4))
    }

    @Test("quick configurations and presets have conservative JSON byte bounds")
    @MainActor
    func modelSpecificBoundsCoverEncodedBytes() throws {
        let configuration = QuickConfig(
            name: "Podcast \u{0001} 🎤",
            systemInputUID: "input",
            systemOutputUID: "output",
            sourceUID: "source",
            destinationUID: "destination",
            monitorUID: "monitor",
            capturedAppBundleIDs: ["app.one", "應用程式.two"],
            isRouting: true)
        var preset = RoutePreset(
            name: "Room 🎙️",
            sampleRate: 48_000,
            bufferFrames: 256,
            voiceIsolationEnabled: true,
            voiceIsolationMix: 72,
            channelMode: "mono",
            cancelsEcho: true,
            recordingFormat: "wav",
            note: "A note with \u{0002} escaped content.",
            isUserDefined: true)
        preset.effects = ["gate", "compressor"]
        preset.effectValues = ["gate.threshold": -42, "compressor.headroom": 6]
        preset.voicePreset = "none"
        preset.inputDecibels = -7
        preset.outputDecibels = 2
        preset.monitorDeviceUID = "monitor"
        preset.sourceDeviceUID = "source"
        preset.destinationDeviceUID = "destination"
        preset.capturedAppBundleIDs = ["app.one", "應用程式.two"]
        preset.isDucking = true
        preset.duckDecibels = -18
        preset.isAutoLevelling = true
        preset.loudnessTarget = "discord"

        let configurations = Array(repeating: configuration, count: 256)
        let presets = Array(repeating: preset, count: 256)
        let quickBound = try #require(
            QuickConfigStore.encodedSizeUpperBoundForDiagnostics(configurations))
        let presetBound = try #require(
            UserPresets.encodedSizeUpperBoundForDiagnostics(presets))

        #expect(try JSONEncoder().encode(configurations).count <= quickBound)
        #expect(try JSONEncoder().encode(presets).count <= presetBound)
        #expect(QuickConfigStore.refusal(for: configurations) == nil)
        #expect(UserPresets.refusal(for: presets) == nil)
    }

    private static func startMainActorProbe(samples: Int) -> CollectionPersistenceProbe {
        let probe = CollectionPersistenceProbe(expected: samples)
        DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.collection-persistence-probe",
            qos: .userInitiated
        ).async {
            for _ in 0..<samples {
                let delivered = DispatchSemaphore(value: 0)
                let sentAt = DispatchTime.now().uptimeNanoseconds
                MainRunLoopDelivery.perform {
                    probe.record(sentAt: sentAt)
                    delivered.signal()
                }
                guard delivered.wait(timeout: .now() + 1) == .success else { return }
            }
        }
        return probe
    }

    @MainActor
    private static func flush<Value: Sendable>(
        _ persistence: BoundedCollectionPersistence<Value>
    ) async -> PreferenceFlushResult {
        await withCheckedContinuation { continuation in
            persistence.flush { continuation.resume(returning: $0) }
        }
    }
}
