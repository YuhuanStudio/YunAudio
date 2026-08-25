import Foundation
import Testing
import YunAudioControl

@testable import YunAudioApp

private final class ScriptRouterCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() { lock.withLock { storage += 1 } }
    var value: Int { lock.withLock { storage } }
}

private final class ScriptRouterGate<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case empty
        case waiting(CheckedContinuation<Value?, Never>)
        case completed(Value?)
    }

    private let lock = NSLock()
    private var state: State = .empty

    func resolve(_ value: Value) {
        let continuation: CheckedContinuation<Value?, Never>? = lock.withLock {
            switch state {
            case .empty:
                state = .completed(value)
                return nil
            case .waiting(let continuation):
                state = .completed(value)
                return continuation
            case .completed:
                return nil
            }
        }
        continuation?.resume(returning: value)
    }

    func wait(timeout: TimeInterval = TestGate.deadlockSeconds) async -> Value? {
        await withCheckedContinuation { continuation in
            let completed: Value?? = lock.withLock {
                switch state {
                case .empty:
                    state = .waiting(continuation)
                    return nil
                case .waiting:
                    Issue.record("one script router gate had two waiters")
                    return .some(nil)
                case .completed(let value):
                    return .some(value)
                }
            }
            if let completed { continuation.resume(returning: completed) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                self.timeOut()
            }
        }
    }

    private func timeOut() {
        let continuation: CheckedContinuation<Value?, Never>? = lock.withLock {
            guard case .waiting(let continuation) = state else { return nil }
            state = .completed(nil)
            return continuation
        }
        continuation?.resume(returning: nil)
    }
}

private final class HeldScriptCommandScheduler: @unchecked Sendable {
    typealias Operation = ScriptCommandAdmissionLane.Operation

    private let lock = NSLock()
    private var operations: [Operation] = []

    func schedule(_ operation: @escaping Operation) {
        lock.withLock { operations.append(operation) }
    }

    var count: Int { lock.withLock { operations.count } }

    @MainActor
    func releaseAll() {
        let held: [Operation] = lock.withLock {
            let held = operations
            operations = []
            return held
        }
        for operation in held { operation() }
    }
}

@Suite("Script and router integration", .serialized)
@MainActor
struct ScriptRouterIntegrationTests {
    @Test("every remote command admits below two millisecond p99 and eight millisecond max")
    func everyRemoteCommandHasBoundedAdmission() {
        let scheduler = HeldScriptCommandScheduler()
        let model = RouterModel(
            startupPolicy: AppStartup.ModelPolicy(kind: .syntheticEvidence))
        model.installScriptCommandSchedulerForDiagnostics { scheduler.schedule($0) }
        let commands: [RemoteCommand] = [
            .routing(false), .mute(false), .record(true), .transcribe(false),
            .stage(true), .score(false), .config("missing"),
            .script("yun.status()"), .preset("Voice chat"),
        ]
        var latencies: [UInt64] = []
        var completions = 0
        latencies.reserveCapacity(commands.count * 1_000)

        for _ in 0..<1_000 {
            for command in commands {
                let began = DispatchTime.now().uptimeNanoseconds
                model.submitRemoteCommand(command) { _ in completions += 1 }
                latencies.append(DispatchTime.now().uptimeNanoseconds - began)
            }
        }

        let ordered = latencies.sorted()
        let percentile99 = ordered[min(ordered.count - 1, ordered.count * 99 / 100)]
        #expect(completions == commands.count * 1_000)
        #expect(percentile99 < 2_000_000, "remote command p99 was \(percentile99) ns")
        #expect(
            (ordered.last ?? 0) < 8_000_000,
            "remote command max was \(ordered.last ?? 0) ns")
        #expect(model.scriptServiceOwnerCountForDiagnostics == 0)
        #expect(!model.isKTVWindowOpen)

        let statistics = model.scriptCommandAdmissionStatisticsForDiagnostics
        #expect(statistics.submissions == 2_000)
        #expect(statistics.applications == 0)
        #expect(statistics.coalesced == 1_998)
        #expect(statistics.pending == 2)
        #expect(statistics.maximumPending == 2)
        #expect(statistics.scheduledDeliveries == 1)
        #expect(scheduler.count == 1)
    }

    @Test("a hostile preset application is coalesced behind bounded admission")
    func hostileMutationNeverRunsInsideAdmission() {
        let scheduler = HeldScriptCommandScheduler()
        let lane = ScriptCommandAdmissionLane { scheduler.schedule($0) }
        var latencies: [UInt64] = []
        latencies.reserveCapacity(10_000)

        for _ in 0..<10_000 {
            let began = DispatchTime.now().uptimeNanoseconds
            let submission = lane.submit(.preset) {
                Thread.sleep(forTimeInterval: 0.012)
            }
            #expect(submission == .accepted || submission == .coalesced)
            latencies.append(DispatchTime.now().uptimeNanoseconds - began)
        }

        let ordered = latencies.sorted()
        let percentile99 = ordered[min(ordered.count - 1, ordered.count * 99 / 100)]
        #expect(percentile99 < 2_000_000, "hostile admission p99 was \(percentile99) ns")
        #expect(
            (ordered.last ?? 0) < 8_000_000,
            "hostile admission max was \(ordered.last ?? 0) ns")
        #expect(lane.statistics.applications == 0)
        #expect(lane.statistics.pending == 1)
        #expect(lane.statistics.maximumPending == 1)
        #expect(lane.statistics.coalesced == 9_999)
        #expect(lane.statistics.scheduledDeliveries == 1)
        #expect(scheduler.count == 1)

        scheduler.releaseAll()
        #expect(lane.statistics.applications == 1)
        #expect(lane.statistics.pending == 0)
        #expect(lane.statistics.overBudgetApplications == 1)
        #expect(
            lane.statistics.maximumApplicationNanoseconds
                >= ScriptCommandAdmissionLane.maximumApplicationNanoseconds)
    }

    @Test("a refused quit creates a fresh script service and reloads one generation")
    func refusedQuitRestoresFreshGeneration() async throws {
        let model = RouterModel(
            startupPolicy: AppStartup.ModelPolicy(kind: .syntheticEvidence))
        var services: [ScriptService] = []
        let serviceConstructions = ScriptRouterCounter()
        model.installScriptServiceFactoryForDiagnostics {
            serviceConstructions.increment()
            let service = ScriptService { _, _ in
                .performed(message: "done", commandFailed: false)
            }
            services.append(service)
            return service
        }
        defer { for service in services { service.stop() } }

        model.residentScript =
            "var token = '\(UUID())'; yun.on('muted', function () { yun.log(token); });"
        try await waitUntil { !model.isResidentScriptLoading }
        #expect(serviceConstructions.value == 1)
        #expect(model.scriptServiceOwnerCountForDiagnostics == 1)
        let old = try #require(services.first)
        #expect(old.listens(for: .muted))

        model.shutDown { _ in }
        #expect(model.scriptServiceOwnerCountForDiagnostics == 0)
        model.recoverScriptServiceAfterRefusedTerminationForDiagnostics()
        try await waitUntil { !model.isResidentScriptLoading }

        #expect(serviceConstructions.value == 2)
        #expect(services.count == 2)
        #expect(model.scriptServiceOwnerCountForDiagnostics == 1)
        #expect(!old.listens(for: .muted))
        let fresh = try #require(services.last)
        #expect(fresh !== old)
        #expect(fresh.listens(for: .muted))
        #expect(fresh.statistics.reloadApplications == 1)
        #expect(fresh.statistics.residentOwners == 1)
    }

    @Test("script log history stays below 200 lines and 64 KiB after ten thousand results")
    func boundedScriptLogHistory() {
        let model = RouterModel(
            startupPolicy: AppStartup.ModelPolicy(kind: .syntheticEvidence))
        let line = String(repeating: "界", count: 30_000)
        let bounded = String(line.prefix(1_000))
        model.appendScriptLog(line)
        for _ in 1..<10_000 { model.appendScriptLog(bounded) }

        #expect(model.scriptLog.count <= ScriptService.maximumOutputLines)
        #expect(model.scriptLogUTF8BytesForDiagnostics <= ScriptService.maximumOutputBytes)
        #expect(model.scriptLog.count == 21)
        #expect(model.scriptLogApplicationsForDiagnostics == 10_000)
    }

    private func waitUntil(
        timeout: TimeInterval = 2, condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}
