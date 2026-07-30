import Foundation
import Testing
import YunAudioRT

@testable import YunAudioApp
@testable import YunAudioEngine
@testable import YunAudioHAL

@Suite("Background resource use")
struct BackgroundResourceTests {
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

    @Test("a hundred HAL notifications become one device refresh")
    func deviceChangeBurstIsCoalesced() throws {
        let queue = DispatchQueue(label: "yunaudio.test.device-change")
        let delivered = DispatchSemaphore(value: 0)
        let count = Count()
        let coalescer = DeviceChangeCoalescer(
            queue: queue, delay: .milliseconds(50)
        ) {
            count.increment()
            delivered.signal()
        }

        for _ in 0..<100 { coalescer.signal() }
        // Put every signal into the fixed window before its deadline. Without
        // the coalescer this barrier would leave 100 expensive refreshes queued.
        queue.sync {}
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        queue.sync {}
        #expect(count.current == 1)

        // Coalescing is per burst, not a once-only gate.
        coalescer.signal()
        queue.sync {}
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        queue.sync {}
        #expect(count.current == 2)
    }

    @MainActor
    @Test("a hundred control changes become one preferences write")
    func preferenceWritesAreCoalesced() async throws {
        var written: [Int] = []
        let writer = CoalescedPreferenceWriter<Int>(delay: .milliseconds(50)) {
            written.append($0)
        }

        for value in 0..<100 { writer.submit(value) }
        #expect(writer.pendingValue == 99)
        #expect(written.isEmpty)

        try await Task.sleep(for: .milliseconds(100))
        #expect(written == [99])
        #expect(writer.pendingValue == nil)

        // Quit does not wait for the window, so its flush has to write exactly
        // once and cancel the scheduled duplicate.
        writer.submit(100)
        writer.flush()
        try await Task.sleep(for: .milliseconds(100))
        #expect(written == [99, 100])
    }

    @MainActor
    @Test("a hundred control changes build one preferences snapshot")
    func preferenceSnapshotsAreCoalesced() async throws {
        let captured = Set(["com.example.music"])
        let excluded = Set(["com.example.private"])
        let effects: Set<EffectKind> = [.gate, .compressor]
        let roles = ["com.example.music": LevelCalibration.Role.background]
        let bindings = [
            MIDITarget.fader(.master):
                MIDIAddress(channel: 0, kind: .controlChange(7))
        ]
        var snapshotsBuilt = 0
        var written: [Int] = []
        let writer = CoalescedPreferenceWriter<PendingPreferencesSnapshot>(
            delay: .milliseconds(50)
        ) {
            snapshotsBuilt += 1
            written.append($0.materialised().monoChannel)
        }

        for value in 0..<100 {
            var preferences = Preferences.default
            preferences.monoChannel = value
            writer.submit(
                PendingPreferencesSnapshot(
                    preferences,
                    capturedAppBundleIDs: captured,
                    excludedAppBundleIDs: excluded,
                    enabledEffects: effects,
                    sourceRoles: roles,
                    midiBindings: bindings))
        }

        #expect(snapshotsBuilt == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(snapshotsBuilt == 1)
        #expect(written == [99])
    }

    @Test("a deferred snapshot keeps the state from the user event")
    func preferenceSnapshotHasValueSemantics() {
        var preferences = Preferences.default
        preferences.inputDecibels = -3
        var captured = Set(["event"])
        var excluded = Set(["private"])
        var effects: Set<EffectKind> = [.gate]
        var roles = ["event": LevelCalibration.Role.voice]
        var bindings = [
            MIDITarget.fader(.master):
                MIDIAddress(channel: 0, kind: .controlChange(7))
        ]
        let snapshot = PendingPreferencesSnapshot(
            preferences,
            capturedAppBundleIDs: captured,
            excludedAppBundleIDs: excluded,
            enabledEffects: effects,
            sourceRoles: roles,
            midiBindings: bindings)

        // These stand in for a later automatic adjustment, restore or
        // verification mutation whose own `persist()` call is suppressed.
        preferences.inputDecibels = -30
        captured.insert("automatic")
        excluded.insert("automatic")
        effects.insert(.compressor)
        roles["event"] = .background
        bindings[.fader(.master)] = MIDIAddress(channel: 0, kind: .controlChange(8))

        let materialised = snapshot.materialised()
        #expect(materialised.inputDecibels == -3)
        #expect(Set(materialised.capturedAppBundleIDs) == ["event"])
        #expect(Set(materialised.excludedAppBundleIDs ?? []) == ["private"])
        #expect(Set(materialised.enabledEffects) == [EffectKind.gate.rawValue])
        #expect(materialised.sourceRoles == ["event": LevelCalibration.Role.voice.rawValue])
        #expect(materialised.midiBindings == ["fader:master": "0.cc.7"])
    }

    /// The regression was structural: `engine.start` was already queued, while
    /// the 27–118 ms application enumeration and every ProcessTap constructor
    /// still ran before the dispatch. Measuring a fake engine would pass while
    /// that exact placement was wrong, so assert the boundary itself and count
    /// the synchronous resources on each side of it.
    @Test("capture preflight belongs wholly to the engine queue")
    func capturePreflightIsNotOnTheMainActor() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "func start(selftest: Bool)"))
        let worker = try #require(
            source.range(
                of: "private func beginStartOnEngineQueue",
                range: start.upperBound..<source.endIndex))
        let mainActorBody = source[start.upperBound..<worker.lowerBound]
        #expect(mainActorBody.ranges(of: "AudioApplications.grouped").count == 0)
        #expect(mainActorBody.ranges(of: "ProcessTap(").count == 0)
        #expect(mainActorBody.ranges(of: "beginStartOnEngineQueue(").count == 1)

        let finish = try #require(
            source.range(
                of: "private func finishCancelledStart",
                range: worker.upperBound..<source.endIndex))
        let workerBody = source[worker.lowerBound..<finish.lowerBound]
        #expect(workerBody.ranges(of: "engineQueue.async").count == 1)
        #expect(workerBody.ranges(of: "Self.prepareCapture(").count == 1)
        #expect(workerBody.ranges(of: "try engine.start(").count == 1)
    }

    @Test("one workspace enumeration supplies both application maps")
    func workspaceIsReadOncePerGrouping() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioHAL/AudioApplication.swift",
            encoding: .utf8)
        let snapshot = try #require(source.range(of: "public static func workspaceSnapshot()"))
        let end = try #require(
            source.range(
                of: "private static func baseIdentifier",
                range: snapshot.upperBound..<source.endIndex))
        let body = source[snapshot.lowerBound..<end.lowerBound]
        #expect(body.ranges(of: "NSWorkspace.shared.runningApplications").count == 1)
        #expect(body.ranges(of: "foreground[bundle] = info").count == 1)
        #expect(body.ranges(of: "named[bundle] = info").count == 1)
    }

    @MainActor
    @Test("the AppKit half left on MainActor stays below one frame")
    func workspaceSnapshotFitsAFrame() {
        let iterations = 20
        let started = DispatchTime.now().uptimeNanoseconds
        var entries = 0
        for _ in 0..<iterations {
            entries &+= AudioApplications.workspaceSnapshot().named.count
        }
        let average = (DispatchTime.now().uptimeNanoseconds - started) / UInt64(iterations)
        print("workspace snapshot: \(average) ns average, \(entries / iterations) apps")
        #expect(entries >= iterations)
        #expect(average < 16_000_000)
    }

    @Test("echo reference never falls back through an application exclusion")
    func excludedEchoReferencesStayExcluded() {
        let playing = AudioApplication(
            bundleID: "com.example.playing",
            name: "Playing",
            bundleURL: nil,
            isPlaying: true,
            isRecording: false,
            processIDs: [11, 12],
            isBackground: false)
        let quiet = AudioApplication(
            bundleID: "com.example.quiet",
            name: "Quiet",
            bundleURL: nil,
            isPlaying: false,
            isRecording: false,
            processIDs: [13],
            isBackground: false)

        #expect(
            RouterModel.echoReferenceProcessIDs(
                in: [playing, quiet],
                excluding: ["com.example.playing"]
            ).isEmpty)
        #expect(
            RouterModel.echoReferenceProcessIDs(in: [playing, quiet], excluding: [])
                == [11, 12])
    }
}

/// The write coalescer is only useful if it also avoids the allocations needed
/// to turn the model's sets and typed dictionaries into their Codable shape.
@Suite("Preference snapshot performance", .serialized)
struct PreferenceSnapshotPerformanceTests {
    #if DEBUG
        @Test(
            "coalescing avoids intermediate collection allocations",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("coalescing avoids intermediate collection allocations")
    #endif
    func deferredCollections() throws {
        let captured = Set((0..<64).map { "com.example.captured.\($0)" })
        let excluded = Set((0..<64).map { "com.example.excluded.\($0)" })
        let effects = Set(EffectKind.allCases)
        let roles: [String: LevelCalibration.Role] = Dictionary(
            uniqueKeysWithValues: (0..<64).map {
                ("source-\($0)", $0.isMultiple(of: 2) ? .voice : .background)
            })
        let bindings = Dictionary(
            uniqueKeysWithValues: (0..<64).map {
                (
                    MIDITarget.sourceFader(uid: "source-\($0)"),
                    MIDIAddress(
                        channel: UInt8($0 / 16),
                        kind: .controlChange(UInt8($0 % 16)))
                )
            })
        let snapshots = (0..<100).map { value in
            var preferences = Preferences.default
            preferences.monoChannel = value
            return PendingPreferencesSnapshot(
                preferences,
                capturedAppBundleIDs: captured,
                excludedAppBundleIDs: excluded,
                enabledEffects: effects,
                sourceRoles: roles,
                midiBindings: bindings)
        }

        _ = Self.consume(try #require(snapshots.last).materialised())
        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }

        let eager = Self.measure(snapshots)
        let coalesced = Self.measure([try #require(snapshots.last)])

        print(
            "preferences collections: eager \(eager.nanoseconds) ns / "
                + "\(eager.allocations) allocations; coalesced "
                + "\(coalesced.nanoseconds) ns / \(coalesced.allocations) allocations")
        #expect(eager.checksum > coalesced.checksum)
        #expect(eager.allocations >= coalesced.allocations * 50)
        #expect(eager.nanoseconds > coalesced.nanoseconds * 10)
    }

    private static func measure(
        _ snapshots: [PendingPreferencesSnapshot]
    ) -> (allocations: UInt64, nanoseconds: UInt64, checksum: Int) {
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        var checksum = 0
        for snapshot in snapshots {
            checksum &+= consume(snapshot.materialised())
        }
        yun_rt_tripwire_mark_realtime(false)
        return (
            RoutingEngine.allocationViolations - before,
            DispatchTime.now().uptimeNanoseconds - started,
            checksum
        )
    }

    @inline(never)
    private static func consume(_ preferences: Preferences) -> Int {
        preferences.monoChannel
            + preferences.capturedAppBundleIDs.reduce(0) { $0 &+ $1.utf8.count }
            + (preferences.excludedAppBundleIDs ?? []).reduce(0) {
                $0 &+ $1.utf8.count
            }
            + preferences.enabledEffects.reduce(0) { $0 &+ $1.utf8.count }
            + (preferences.sourceRoles ?? [:]).reduce(0) {
                $0 &+ $1.key.utf8.count &+ $1.value.utf8.count
            }
            + (preferences.midiBindings ?? [:]).reduce(0) {
                $0 &+ $1.key.utf8.count &+ $1.value.utf8.count
            }
    }
}
