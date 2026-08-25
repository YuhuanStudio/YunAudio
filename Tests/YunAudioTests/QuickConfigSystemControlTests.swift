import Foundation
import Testing

@testable import YunAudioApp

private final class QuickConfigVirtualDeadlineScheduler: @unchecked Sendable {
    private struct Entry {
        let operation: @Sendable () -> Void
        var isCancelled = false
    }

    private let lock = NSLock()
    private var nextID = 0
    private var entries: [Int: Entry] = [:]

    var scheduler: SystemQueryDeadlineScheduler {
        SystemQueryDeadlineScheduler { [self] _, operation in
            let id = lock.withLock {
                nextID += 1
                entries[nextID] = Entry(operation: operation)
                return nextID
            }
            return SystemQueryDeadlineHandle { [weak self] in
                self?.cancel(id)
            }
        }
    }

    var activeIDs: [Int] {
        lock.withLock {
            entries.compactMap { id, entry in entry.isCancelled ? nil : id }.sorted()
        }
    }

    func fire(_ id: Int) {
        let operation: (@Sendable () -> Void)? = lock.withLock {
            guard let entry = entries[id], !entry.isCancelled else { return nil }
            return entry.operation
        }
        operation?()
    }

    private func cancel(_ id: Int) {
        lock.withLock { entries[id]?.isCancelled = true }
    }
}

private final class QuickConfigHeldMainDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@MainActor @Sendable () -> Void] = []

    func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { operations.append(operation) }
    }

    var count: Int { lock.withLock { operations.count } }

    @MainActor
    func runAll() {
        while true {
            let operation: (@MainActor @Sendable () -> Void)? = lock.withLock {
                guard !operations.isEmpty else { return nil }
                return operations.removeFirst()
            }
            guard let operation else { return }
            operation()
        }
    }
}

@MainActor
private func waitForQuickConfig(_ condition: () -> Bool) async throws {
    for _ in 0..<2_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("the setup system-control condition did not arrive")
}

@Suite("Quick configuration system control")
struct QuickConfigSystemControlTests {
    private final class FakeTime {
        var now: UInt64 = 0
    }

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

    private func source() throws -> String {
        try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/QuickConfig.swift",
            encoding: .utf8)
    }

    private func section(
        of source: String,
        from start: String,
        to end: String
    ) throws -> Substring {
        let lower = try #require(source.range(of: start))
        let upper = try #require(
            source.range(of: end, range: lower.upperBound..<source.endIndex))
        return source[lower.lowerBound..<upper.lowerBound]
    }

    @MainActor
    @Test("every request receives one answer while a burst executes only first and latest")
    func burstDeliveryIsExactlyOnce() async throws {
        let firstStarted = Values<Int>()
        let releaseFirst = DispatchSemaphore(value: 0)
        let executed = Values<Int>()
        var completed: [Int] = []
        var superseded: [Int] = []
        var timedOut: [Int] = []
        var callbackCounts: [Int: Int] = [:]
        // The timeout is chosen, not inherited.
        //
        // This test holds the first write open on purpose and queues ten
        // thousand behind it, and the production 2.25 s covers that whole
        // stretch — on a loaded machine some of them expired, and the
        // coalescing assertions below then described a queue that had timed out
        // rather than one that had coalesced. What is being tested is exactly
        // once and first-and-latest; the deadline has its own test.
        let control = QuickConfigSystemControl(
            readSystemDefaults: { .failed },
            writeSystemDefaults: { request in
                let value = Int(request.inputUID ?? "") ?? -1
                executed.append(value)
                if value == 0 {
                    firstStarted.append(value)
                    releaseFirst.wait()
                }
                return .init(restored: 1, missing: [])
            },
            timeout: .seconds(120))

        func submit(_ value: Int) {
            control.writeDefaults(.init(inputUID: String(value), outputUID: nil)) { delivery in
                callbackCounts[value, default: 0] += 1
                switch delivery {
                case .completed:
                    completed.append(value)
                case .superseded:
                    superseded.append(value)
                case .timedOut:
                    timedOut.append(value)
                }
            }
        }

        submit(0)
        for _ in 0..<TestGate.polls where firstStarted.snapshot.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(firstStarted.snapshot == [0])
        for value in 1..<10_000 { submit(value) }
        releaseFirst.signal()

        for _ in 0..<TestGate.polls where callbackCounts.count != 10_000 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(executed.snapshot == [0, 9_999])
        #expect(completed == [9_999])
        #expect(superseded.count == 9_999)
        #expect(timedOut.isEmpty)
        #expect(callbackCounts.count == 10_000)
        #expect(callbackCounts.values.allSatisfy { $0 == 1 })
    }

    @MainActor
    @Test("a blocked Sound read times out the latest setup without starting a second HAL call")
    func deadlineQuarantinesTheSoleSystemDefaultsOwner() async throws {
        let deadlines = QuickConfigVirtualDeadlineScheduler()
        let mainDelivery = QuickConfigHeldMainDelivery()
        let readBegan = Values<Bool>()
        let releaseRead = DispatchSemaphore(value: 0)
        defer { releaseRead.signal() }
        let writes = Values<String>()
        var readTerminals: [String] = []
        var writeTerminals: [String] = []
        let control = QuickConfigSystemControl(
            readSystemDefaults: {
                readBegan.append(true)
                releaseRead.wait()
                return .failed
            },
            writeSystemDefaults: { request in
                writes.append(request.inputUID ?? "")
                return .init(restored: 1, missing: [])
            },
            queue: DispatchQueue(label: "yunaudio.test.system-defaults.deadline"),
            timeout: .milliseconds(2_250),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: mainDelivery.schedule)

        control.readDefaults { delivery in
            switch delivery {
            case .completed: readTerminals.append("completed")
            case .superseded: readTerminals.append("superseded")
            case .timedOut: readTerminals.append("timed-out")
            }
        }
        try await waitForQuickConfig {
            !readBegan.snapshot.isEmpty && deadlines.activeIDs.count == 1
        }
        control.writeDefaults(.init(inputUID: "latest", outputUID: nil)) { delivery in
            switch delivery {
            case .completed: writeTerminals.append("completed")
            case .superseded: writeTerminals.append("superseded")
            case .timedOut: writeTerminals.append("timed-out")
            }
        }
        #expect(readTerminals == ["superseded"])
        #expect(writes.snapshot.isEmpty)

        let deadline = try #require(deadlines.activeIDs.first)
        deadlines.fire(deadline)
        deadlines.fire(deadline)
        #expect(mainDelivery.count == 1)
        mainDelivery.runAll()

        #expect(writeTerminals == ["timed-out"])
        #expect(writes.snapshot.isEmpty)
        #expect(control.laneStatistics.applications == 1)
        #expect(control.laneStatistics.deadlineExpirations == 1)
        #expect(control.laneStatistics.quarantinedOwners == 1)
        #expect(control.laneStatistics.maximumConcurrentApplications == 1)
        #expect(control.laneStatistics.pendingDeliveries == 0)

        var rejected = 0
        control.writeDefaults(.init(inputUID: "rejected", outputUID: nil)) { delivery in
            if case .timedOut = delivery { rejected += 1 }
        }
        #expect(rejected == 1)
        #expect(writes.snapshot.isEmpty)
        #expect(control.laneStatistics.applications == 1)

        releaseRead.signal()
        try await waitForQuickConfig { control.laneStatistics.quarantinedOwners == 0 }
        mainDelivery.runAll()
        #expect(readTerminals.count == 1)
        #expect(writeTerminals.count == 1)
    }

    @MainActor
    @Test("shutdown revokes setup callbacks without joining a blocked Sound call")
    func shutdownIsNonJoiningAndExactOnce() async throws {
        let deadlines = QuickConfigVirtualDeadlineScheduler()
        let mainDelivery = QuickConfigHeldMainDelivery()
        let began = Values<Bool>()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var callbackCounts = ["read": 0, "write": 0, "after": 0]
        let control = QuickConfigSystemControl(
            readSystemDefaults: {
                began.append(true)
                release.wait()
                return .failed
            },
            writeSystemDefaults: { _ in .init(restored: 0, missing: []) },
            queue: DispatchQueue(label: "yunaudio.test.system-defaults.shutdown"),
            deadlineScheduler: deadlines.scheduler,
            scheduleOnMainActor: mainDelivery.schedule)

        control.readDefaults { _ in callbackCounts["read", default: 0] += 1 }
        try await waitForQuickConfig { !began.snapshot.isEmpty }
        control.writeDefaults(.init(inputUID: "pending", outputUID: nil)) { _ in
            callbackCounts["write", default: 0] += 1
        }
        #expect(callbackCounts == ["read": 1, "write": 0, "after": 0])

        let before = ContinuousClock.now
        control.shutdown()
        let elapsed = before.duration(to: .now)
        #expect(elapsed < .milliseconds(2))
        #expect(callbackCounts == ["read": 1, "write": 1, "after": 0])

        control.readDefaults { delivery in
            if case .timedOut = delivery { callbackCounts["after", default: 0] += 1 }
        }
        #expect(callbackCounts == ["read": 1, "write": 1, "after": 1])
        #expect(control.laneStatistics.applications == 1)
        #expect(control.laneStatistics.maximumConcurrentApplications == 1)

        release.signal()
        try await waitForQuickConfig { control.laneStatistics.activeOwners == 0 }
        mainDelivery.runAll()
        #expect(callbackCounts == ["read": 1, "write": 1, "after": 1])
    }

    @MainActor
    @Test("Quit supersedes a blocked setup without applying or restarting")
    func quitSupersedesBlockedApplyExactlyOnce() async throws {
        let began = Values<Bool>()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var terminals: [String] = []
        var finishApplying = 0
        var routeStarts = 0
        let control = QuickConfigSystemControl(
            readSystemDefaults: { .failed },
            writeSystemDefaults: { _ in
                began.append(true)
                release.wait()
                return .init(restored: 2, missing: [])
            })

        control.writeDefaults(.init(inputUID: "input", outputUID: "output")) { delivery in
            switch delivery {
            case .superseded:
                terminals.append("superseded")
            case .timedOut:
                terminals.append("timed-out")
            case .completed:
                terminals.append("completed")
                finishApplying += 1
                routeStarts += 1
            }
        }
        try await waitForQuickConfig { !began.snapshot.isEmpty }

        control.invalidate()
        #expect(terminals == ["superseded"])
        #expect(finishApplying == 0)
        #expect(routeStarts == 0)

        release.signal()
        try await waitForQuickConfig { control.laneStatistics.activeOwners == 0 }
        #expect(terminals == ["superseded"])
        #expect(finishApplying == 0)
        #expect(routeStarts == 0)

        control.shutdown()
        control.writeDefaults(.init(inputUID: "late", outputUID: nil)) { delivery in
            if case .timedOut = delivery { terminals.append("refused") }
        }
        #expect(terminals == ["superseded", "refused"])
        #expect(control.laneStatistics.applications == 1)
    }

    @MainActor
    @Test("an in-flight failed read outlives its external owner and answers once")
    func failedReadCompletesAcrossOwnerRelease() async throws {
        let started = Values<Bool>()
        let release = DispatchSemaphore(value: 0)
        var deliveries:
            [QuickConfigSystemControl.Delivery<QuickConfigSystemControl.ReadOutcome>] = []
        // Chosen for the reason the burst test's is: the read is held open on
        // purpose while the owner is released, and that stretch has to outlast
        // the deadline or the answer below is a timeout rather than the one
        // this test is about.
        var control: QuickConfigSystemControl? = QuickConfigSystemControl(
            readSystemDefaults: {
                started.append(true)
                release.wait()
                return .failed
            },
            writeSystemDefaults: { _ in .init(restored: 0, missing: []) },
            timeout: .seconds(120))
        weak let retainedControl = control

        control?.readDefaults { deliveries.append($0) }
        for _ in 0..<TestGate.polls where started.snapshot.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        control = nil
        #expect(retainedControl == nil)
        release.signal()

        for _ in 0..<TestGate.polls where deliveries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(deliveries.count == 1)
        if case .completed(.failed)? = deliveries.first {
            // The exact failure is the number asserted by the count above.
        } else {
            Issue.record("the failed read did not report its real outcome")
        }
    }

    @Test("HAL work begins only inside one deadline-bearing system-default lane")
    func sourceBoundaryKeepsHALAwayFromMainActorAndEngineQueue() throws {
        let source = try source()
        let model = try section(
            of: source,
            from: "extension RouterModel {",
            to: "@MainActor\nenum QuickConfigStore")
        #expect(!model.contains("AudioDevices."))
        #expect(!model.contains("engineQueue"))
        #expect(model.contains("quickConfigSystemControl.readDefaults"))
        #expect(model.contains("quickConfigSystemControl.writeDefaults"))

        let control = try section(
            of: source,
            from: "final class QuickConfigSystemControl {",
            to: "nonisolated private static func readSystemDefaultsFromHAL")
        #expect(control.contains("BoundedSystemQueryLane"))
        #expect(control.contains("com.yuhuanstudio.yunaudio.system-defaults"))
        #expect(control.contains("timeout: Duration = .milliseconds(2_250)"))
        #expect(control.contains("case .read(let id):"))
        #expect(control.contains("case .write(let id, let request):"))
        #expect(!control.contains("quickConfigSystemControlQueue"))
        #expect(!control.contains("Task { @MainActor"))
        #expect(!control.contains("AudioDevices."))
    }

    @Test("system defaults finish before local mutation and route lifecycle")
    func applyOrderingIsExplicit() throws {
        let source = try source()
        let request = try section(
            of: source,
            from: "func requestApplyQuickConfig(",
            to: "/// Awaitable form used by the flow check")
        let write = try #require(request.range(of: "writeDefaults(request)"))
        let finish = try #require(request.range(of: "finishApplyingQuickConfig("))
        #expect(write.lowerBound < finish.lowerBound)

        let local = try section(
            of: source,
            from: "private func finishApplyingQuickConfig(",
            to: "/// Names devices that are not here")
        #expect(!local.contains("AudioDevices."))
        #expect(local.contains("if configuration.isRouting, !isRunning"))
        #expect(local.contains("start()"))
        #expect(local.contains("stop()"))
    }

    @Test("structural lint wires Stop and Quit to setup revocation and final closure")
    func routerLifecycleOwnsSetupAdmission() throws {
        // `quitSupersedesBlockedApplyExactlyOnce` and
        // `shutdownIsNonJoiningAndExactOnce` execute the revocation and closure
        // contracts with blocked Sound calls. This source lint checks only that
        // RouterModel invokes them at its three lifecycle boundaries.
        let root = PreferencesCompletenessTests.sourceRootForTests
        let router = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let stopStart = try #require(router.range(of: "func stop()"))
        let stopEnd = try #require(
            router.range(
                of: "func retainFailedTeardown",
                range: stopStart.upperBound..<router.endIndex))
        let stop = router[stopStart.lowerBound..<stopEnd.lowerBound]
        #expect(stop.contains("quickConfigSystemControl.invalidate()"))

        let quitStart = try #require(router.range(of: "func shutDown("))
        let finaliseStart = try #require(
            router.range(
                of: "func finaliseAcceptedTermination()",
                range: quitStart.upperBound..<router.endIndex))
        let quit = router[quitStart.lowerBound..<finaliseStart.lowerBound]
        let finalise = router[finaliseStart.lowerBound...]
        #expect(quit.contains("quickConfigSystemControl.invalidate()"))
        #expect(!quit.contains("quickConfigSystemControl.shutdown()"))
        #expect(finalise.contains("quickConfigSystemControl.shutdown()"))
    }

    @Test("default-device identity and writes do not construct full device snapshots")
    func defaultDeviceHALWorkIsMetadataOnly() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioHAL/AudioDevice.swift",
            encoding: .utf8)
        let output = try section(
            of: source,
            from: "public static func defaultOutputUID()",
            to: "/// Points the whole system at a device")
        #expect(output.contains("readDefaultDeviceUID("))
        #expect(!output.contains("AudioDevice(id:"))

        let setter = try section(
            of: source,
            from: "public static func setDefault(",
            to: "// MARK: - Clock relationship")
        #expect(setter.contains("objectID(forUID: uid)"))
        #expect(!setter.contains("device(uid: uid)"))
        #expect(!setter.contains("AudioDevice(id:"))
    }

    @Test("each accepted default is read back in exact set-then-observe order")
    func setAndReadbackOrderingIsExact() {
        let time = FakeTime()
        var events: [String] = []
        var inputReads = 0
        let outcome = QuickConfigSystemControl.writeSystemDefaultsAndWait(
            .init(inputUID: "input", outputUID: "output"),
            timeoutNanoseconds: 100,
            pollNanoseconds: 10,
            now: { time.now },
            setDefault: { uid, isInput in
                events.append("set \(isInput ? "input" : "output") \(uid)")
                return true
            },
            readDefaultUID: { isInput in
                events.append("read \(isInput ? "input" : "output")")
                if isInput {
                    inputReads += 1
                    return inputReads == 1 ? "not-yet" : "input"
                }
                return "output"
            },
            pause: { nanoseconds in
                events.append("pause \(nanoseconds)")
                time.now += nanoseconds
            })

        #expect(outcome == .init(restored: 2, missing: []))
        #expect(
            events == [
                "set input input", "read input", "pause 10", "read input",
                "set output output", "read output",
            ])
    }

    @Test("a refused default write is missing and performs no readback")
    func rejectedWriteStopsAtTheSet() {
        var reads = 0
        var pauses = 0
        let outcome = QuickConfigSystemControl.writeSystemDefaultsAndWait(
            .init(inputUID: "refused", outputUID: nil),
            timeoutNanoseconds: 100,
            pollNanoseconds: 10,
            now: { 0 },
            setDefault: { _, _ in false },
            readDefaultUID: { _ in
                reads += 1
                return "refused"
            },
            pause: { _ in pauses += 1 })

        #expect(outcome == .init(restored: 0, missing: ["refused"]))
        #expect(reads == 0)
        #expect(pauses == 0)
    }

    @Test("both defaults share one deadline and no HAL call begins at or after it")
    func absoluteDeadlineIsShared() {
        let time = FakeTime()
        var setCalls: [(String, UInt64)] = []
        var readTimes: [UInt64] = []
        var pauses: [UInt64] = []
        let outcome = QuickConfigSystemControl.writeSystemDefaultsAndWait(
            .init(inputUID: "input", outputUID: "output"),
            timeoutNanoseconds: 25,
            pollNanoseconds: 10,
            now: { time.now },
            setDefault: { uid, _ in
                setCalls.append((uid, time.now))
                return true
            },
            readDefaultUID: { _ in
                readTimes.append(time.now)
                return "still-old"
            },
            pause: { nanoseconds in
                pauses.append(nanoseconds)
                time.now += nanoseconds
            })

        #expect(outcome == .init(restored: 0, missing: ["input", "output"]))
        #expect(setCalls.count == 1)
        #expect(setCalls.first?.0 == "input")
        #expect(setCalls.first?.1 == 0)
        #expect(readTimes == [0, 10, 20])
        #expect(pauses == [10, 10, 5])
        #expect((setCalls.map { $0.1 } + readTimes).allSatisfy { $0 < 25 })
    }

    @Test("structural lint reports a remote setup as queued rather than applied")
    func remoteResultDoesNotClaimSynchronousSuccess() throws {
        // The executable cases above prove the asynchronous system-control lane's
        // ordering, deadline and exact-once delivery. This only keeps the remote
        // command's user-facing claim wired to that contract.
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let command = try section(
            of: source,
            from: "case .config(let name):",
            to: "case .script:")
        #expect(command.contains("requestApplyQuickConfig(configuration)"))
        #expect(command.contains("loc(\"%@ queued.\")"))
        #expect(!command.contains("outcome.isComplete"))
    }
}
