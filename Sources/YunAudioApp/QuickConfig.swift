import Foundation
import YunAudioEngine
import YunAudioHAL

/// The whole machine's audio arrangement, remembered under a name.
///
/// Distinct from a scene preset, and the difference is the point. A preset says
/// *how to process* — isolation, buffer size, channel mode — and deliberately
/// leaves devices alone, because those are what you route rather than how. This
/// says what everything is plugged into: which devices the system itself is
/// pointed at, which ones this router is using, what it is capturing, and
/// whether it is running at all.
///
/// The two are wanted at different moments. A preset changes when the room
/// changes; this changes when the *work* changes — a podcast, a game, a call —
/// and each of those is a different set of devices, not a different compressor
/// setting.
struct QuickConfig: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String

    /// What the Sound pane is pointed at. Stored because half of setting up for
    /// a call is telling macOS itself where to listen, and forgetting that step
    /// is why somebody's first minute is always spent on "you're on mute".
    var systemInputUID: String?
    var systemOutputUID: String?

    /// What this router is using.
    var sourceUID: String?
    var destinationUID: String?
    var monitorUID: String?

    var capturedAppBundleIDs: [String]
    /// Whether the route was up when the snapshot was taken.
    var isRouting: Bool

    /// What was missing when a configuration was applied.
    ///
    /// Applying is best-effort by design: restoring a podcast setup on a laptop
    /// with the interface at home should put back everything it can and say
    /// what it could not, rather than refusing because one device is absent.
    struct Outcome: Equatable, Sendable {
        var restored: Int
        var missing: [String]
        var isComplete: Bool { missing.isEmpty }
    }

    /// The answer to one asynchronous apply request.
    enum ApplyResult: Equatable, Sendable {
        case completed(Outcome)
        case superseded
    }

    /// The answer to one asynchronous snapshot request.
    enum SaveResult: Equatable, Sendable {
        case saved(QuickConfig)
        case failed
        case invalidName
        case superseded
    }
}

private enum QuickConfigLaneWork: Sendable {
    case read(id: UInt64)
    case write(id: UInt64, QuickConfigSystemControl.WriteRequest)

    var id: UInt64 {
        switch self {
        case .read(let id), .write(let id, _): id
        }
    }
}

private enum QuickConfigLaneResponse: Sendable {
    case read(id: UInt64, QuickConfigSystemControl.ReadOutcome)
    case write(id: UInt64, QuickConfigSystemControl.WriteOutcome)
    case timedOut(id: UInt64)
}

/// Main-actor ownership of the callbacks which a blocking HAL lane cannot hold.
///
/// Supersession is answered at admission rather than after the old system call
/// returns. That distinction is what lets Stop and a newer setup converge while
/// a Sound-service getter remains quarantined on its own worker.
@MainActor
private final class QuickConfigLaneDeliveryOwner {
    private enum Completion {
        case read(
            @MainActor @Sendable (
                QuickConfigSystemControl.Delivery<QuickConfigSystemControl.ReadOutcome>
            ) -> Void)
        case write(
            @MainActor @Sendable (
                QuickConfigSystemControl.Delivery<QuickConfigSystemControl.WriteOutcome>
            ) -> Void)
    }

    private var nextID: UInt64 = 0
    private var current: (id: UInt64, completion: Completion)?

    var pendingCount: Int { current == nil ? 0 : 1 }

    func replaceRead(
        with completion:
            @escaping @MainActor @Sendable (
                QuickConfigSystemControl.Delivery<QuickConfigSystemControl.ReadOutcome>
            ) -> Void
    ) -> UInt64 {
        replace(with: .read(completion))
    }

    func replaceWrite(
        with completion:
            @escaping @MainActor @Sendable (
                QuickConfigSystemControl.Delivery<QuickConfigSystemControl.WriteOutcome>
            ) -> Void
    ) -> UInt64 {
        replace(with: .write(completion))
    }

    private func replace(with completion: Completion) -> UInt64 {
        nextID &+= 1
        let id = nextID
        let displaced = current?.completion
        current = (id, completion)
        resolve(displaced, as: .superseded)
        return id
    }

    func receive(_ response: QuickConfigLaneResponse) {
        let id = response.id
        guard current?.id == id else { return }
        let completion = current?.completion
        current = nil
        switch response {
        case .read(_, let outcome):
            guard case .read(let callback) = completion else { return }
            callback(.completed(outcome))
        case .write(_, let outcome):
            guard case .write(let callback) = completion else { return }
            callback(.completed(outcome))
        case .timedOut:
            resolve(completion, as: .timedOut)
        }
    }

    func refuse(_ id: UInt64) {
        guard current?.id == id else { return }
        let completion = current?.completion
        current = nil
        resolve(completion, as: .timedOut)
    }

    func revoke() {
        let revoked = current?.completion
        current = nil
        resolve(revoked, as: .superseded)
    }

    private enum Terminal {
        case superseded
        case timedOut
    }

    private func resolve(_ completion: Completion?, as terminal: Terminal) {
        switch (completion, terminal) {
        case (.read(let callback), .superseded): callback(.superseded)
        case (.read(let callback), .timedOut): callback(.timedOut)
        case (.write(let callback), .superseded): callback(.superseded)
        case (.write(let callback), .timedOut): callback(.timedOut)
        case (nil, _): break
        }
    }
}

private extension QuickConfigLaneResponse {
    var id: UInt64 {
        switch self {
        case .read(let id, _), .write(let id, _), .timedOut(let id): id
        }
    }
}

/// Deadline-bound ownership of every system-default read and write made by setups.
///
/// Reads and writes deliberately share one process-wide sole owner. Starting a
/// second property call beside a Sound service which has already missed its
/// deadline can deepen a system-wide failure. The deadline reports the newest
/// visible request once, then rejects new work until the original call returns.
@MainActor
final class QuickConfigSystemControl {
    struct LaneStatistics: Equatable, Sendable {
        let applications: UInt64
        let deadlineExpirations: UInt64
        let activeOwners: Int
        let quarantinedOwners: Int
        let maximumConcurrentApplications: Int
        let pendingDeliveries: Int
    }

    struct Defaults: Equatable, Sendable {
        let inputUID: String?
        let outputUID: String?
    }

    struct WriteRequest: Equatable, Sendable {
        let inputUID: String?
        let outputUID: String?
    }

    struct WriteOutcome: Equatable, Sendable {
        let restored: Int
        let missing: [String]
        let timedOut: Bool

        init(restored: Int, missing: [String], timedOut: Bool = false) {
            self.restored = restored
            self.missing = missing
            self.timedOut = timedOut
        }
    }

    enum ReadOutcome: Equatable, Sendable {
        case values(Defaults)
        case failed
    }

    enum Delivery<Value: Sendable>: Sendable {
        case completed(Value)
        case superseded
        case timedOut
    }

    private let deliveries: QuickConfigLaneDeliveryOwner
    private let lane: BoundedSystemQueryLane<QuickConfigLaneWork, QuickConfigLaneResponse>

    convenience init() {
        self.init(
            readSystemDefaults: Self.readSystemDefaultsFromHAL,
            writeSystemDefaults: Self.writeSystemDefaultsToHAL)
    }

    /// Injectable operations keep the ownership and completion contract
    /// measurable without making a test touch the machine's Sound settings.
    init(
        readSystemDefaults: @escaping @Sendable () -> ReadOutcome,
        writeSystemDefaults: @escaping @Sendable (WriteRequest) -> WriteOutcome,
        queue: DispatchQueue? = nil,
        timeout: Duration = .milliseconds(2_250),
        deadlineScheduler: SystemQueryDeadlineScheduler = .continuous,
        scheduleOnMainActor:
            @escaping @Sendable (
                @escaping @MainActor @Sendable () -> Void
            ) -> Void = { MainRunLoopDelivery.perform($0) }
    ) {
        let deliveries = QuickConfigLaneDeliveryOwner()
        self.deliveries = deliveries
        lane = BoundedSystemQueryLane(
            subsystem: .hardwareWrite,
            queue: queue
                ?? DispatchQueue(
                    label: "com.yuhuanstudio.yunaudio.system-defaults",
                    qos: .userInitiated),
            timeout: timeout,
            deadlineScheduler: deadlineScheduler,
            scheduleOnMainActor: scheduleOnMainActor,
            apply: { work, _ in
                switch work {
                case .read(let id):
                    return .read(id: id, readSystemDefaults())
                case .write(let id, let request):
                    return .write(id: id, writeSystemDefaults(request))
                }
            },
            deadlineResponse: { .timedOut(id: $0.id) },
            publish: { response in
                deliveries.receive(response)
            })
    }

    func writeDefaults(
        _ request: WriteRequest,
        completion: @escaping @MainActor @Sendable (Delivery<WriteOutcome>) -> Void
    ) {
        let id = deliveries.replaceWrite(with: completion)
        if !lane.submit(.write(id: id, request)) { deliveries.refuse(id) }
    }

    func readDefaults(
        completion: @escaping @MainActor @Sendable (Delivery<ReadOutcome>) -> Void
    ) {
        let id = deliveries.replaceRead(with: completion)
        if !lane.submit(.read(id: id)) { deliveries.refuse(id) }
    }

    /// Revokes visible setup work without joining an entered Sound-service call.
    func invalidate() {
        _ = lane.invalidate()
        deliveries.revoke()
    }

    /// Permanently closes setup work during accepted process termination.
    func shutdown() {
        _ = lane.shutdown()
        deliveries.revoke()
    }

    var laneStatistics: LaneStatistics {
        let statistics = lane.statistics
        return LaneStatistics(
            applications: statistics.applications,
            deadlineExpirations: statistics.deadlineExpirations,
            activeOwners: statistics.activeRequests,
            quarantinedOwners: statistics.quarantinedRequests,
            maximumConcurrentApplications: statistics.maximumConcurrentApplications,
            pendingDeliveries: deliveries.pendingCount
        )
    }

    nonisolated private static func readSystemDefaultsFromHAL() -> ReadOutcome {
        do {
            return .values(
                Defaults(
                    inputUID: try AudioDevices.defaultInputUID(),
                    outputUID: try AudioDevices.defaultOutputUID()))
        } catch {
            return .failed
        }
    }

    nonisolated private static func writeSystemDefaultsToHAL(
        _ request: WriteRequest
    ) -> WriteOutcome {
        writeSystemDefaultsAndWait(
            request,
            timeoutNanoseconds: 2_000_000_000,
            pollNanoseconds: 20_000_000,
            now: { DispatchTime.now().uptimeNanoseconds },
            setDefault: AudioDevices.setDefault,
            readDefaultUID: { isInput in
                if isInput { return try AudioDevices.defaultInputUID() }
                return try AudioDevices.defaultOutputUID()
            },
            pause: { nanoseconds in
                Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
            })
    }

    /// Writes and then reads each default back before calling it restored.
    ///
    /// Both devices spend one absolute deadline. A relative timeout per poll,
    /// or per device, makes a stuck service consume the whole allowance over
    /// and over. Every check occurs before its next HAL call, so nothing new is
    /// started once that shared deadline has passed.
    nonisolated static func writeSystemDefaultsAndWait(
        _ request: WriteRequest,
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64,
        now: () -> UInt64,
        setDefault: (String, Bool) throws -> Bool,
        readDefaultUID: (Bool) throws -> String?,
        pause: (UInt64) -> Void
    ) -> WriteOutcome {
        var restored = 0
        var missing: [String] = []
        let started = now()
        let (addedDeadline, overflowed) = started.addingReportingOverflow(timeoutNanoseconds)
        let deadline = overflowed ? UInt64.max : addedDeadline
        let poll = max(UInt64(1), pollNanoseconds)

        for (uid, isInput) in [
            (request.inputUID, true), (request.outputUID, false),
        ] {
            guard let uid else { continue }
            guard now() < deadline else {
                missing.append(uid)
                continue
            }
            do {
                guard try setDefault(uid, isInput) else {
                    missing.append(uid)
                    continue
                }
            } catch {
                missing.append(uid)
                continue
            }

            var wasReadBack = false
            while now() < deadline {
                do {
                    if try readDefaultUID(isInput) == uid {
                        wasReadBack = true
                        break
                    }
                } catch {
                    // A transient read failure has the same bounded retry as a
                    // value that has not arrived yet.
                }
                let afterRead = now()
                guard afterRead < deadline else { break }
                pause(min(poll, deadline - afterRead))
            }
            if wasReadBack {
                restored += 1
            } else {
                missing.append(uid)
            }
        }
        return WriteOutcome(restored: restored, missing: missing)
    }
}

extension RouterModel {

    /// Takes the value-owned half of a snapshot without querying HAL.
    private func captureQuickConfig(named name: String) -> QuickConfig {
        QuickConfig(
            name: name,
            systemInputUID: nil,
            systemOutputUID: nil,
            sourceUID: selectedSourceUID,
            destinationUID: selectedDestinationUID,
            monitorUID: monitorDeviceUID,
            capturedAppBundleIDs: Array(capturedAppBundleIDs).sorted(),
            isRouting: isRunning)
    }

    /// Captures a setup without making its user action wait for CoreAudio.
    func requestSaveQuickConfig(
        named name: String,
        completion: (@MainActor @Sendable (QuickConfig.SaveResult) -> Void)? = nil
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(.invalidName)
            return
        }
        let captured = captureQuickConfig(named: trimmed)
        quickConfigSystemControl.readDefaults { [weak self] delivery in
            guard let self else {
                completion?(.superseded)
                return
            }
            switch delivery {
            case .superseded:
                completion?(.superseded)
            case .timedOut:
                completion?(.failed)
            case .completed(.failed):
                completion?(.failed)
            case .completed(.values(let defaults)):
                var completed = captured
                completed.systemInputUID = defaults.inputUID
                completed.systemOutputUID = defaults.outputUID
                var configurations = self.quickConfigs.filter { $0.name != trimmed }
                configurations.append(completed)
                configurations.sort { $0.name < $1.name }
                guard QuickConfigStore.refusal(for: configurations) == nil else {
                    completion?(.failed)
                    return
                }
                self.quickConfigs = configurations
                completion?(.saved(completed))
            }
        }
    }

    /// Awaitable form used by verification and other callers needing truth.
    func saveQuickConfig(named name: String) async -> QuickConfig.SaveResult {
        await withCheckedContinuation { continuation in
            requestSaveQuickConfig(named: name) { result in
                continuation.resume(returning: result)
            }
        }
    }

    func deleteQuickConfig(named name: String) {
        quickConfigs.removeAll { $0.name == name }
    }

    /// Queues a whole-machine change without waiting on MainActor.
    ///
    /// - Returns: What was restored and what was not, so the interface can say
    ///   "everything except the interface" instead of failing silently or
    ///   pretending it worked.
    func requestApplyQuickConfig(
        _ configuration: QuickConfig,
        completion: (@MainActor @Sendable (QuickConfig.ApplyResult) -> Void)? = nil
    ) {
        let request = QuickConfigSystemControl.WriteRequest(
            inputUID: configuration.systemInputUID,
            outputUID: configuration.systemOutputUID)
        quickConfigSystemControl.writeDefaults(request) { [weak self] delivery in
            guard let self else {
                completion?(.superseded)
                return
            }
            switch delivery {
            case .superseded:
                completion?(.superseded)
            case .timedOut:
                completion?(
                    .completed(
                        self.finishApplyingQuickConfig(
                            configuration,
                            systemOutcome: QuickConfigSystemControl.WriteOutcome(
                                restored: 0,
                                missing: [
                                    configuration.systemInputUID,
                                    configuration.systemOutputUID,
                                ].compactMap { $0 },
                                timedOut: true))))
            case .completed(let systemOutcome):
                completion?(
                    .completed(
                        self.finishApplyingQuickConfig(
                            configuration, systemOutcome: systemOutcome)))
            }
        }
    }

    /// Awaitable form used by the flow check to inspect the exact final result.
    func applyQuickConfig(_ configuration: QuickConfig) async -> QuickConfig.ApplyResult {
        await withCheckedContinuation { continuation in
            requestApplyQuickConfig(configuration) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func finishApplyingQuickConfig(
        _ configuration: QuickConfig,
        systemOutcome: QuickConfigSystemControl.WriteOutcome
    ) -> QuickConfig.Outcome {
        var restored = systemOutcome.restored
        var missing = systemOutcome.missing

        // Everything the router owns is set in one batch: each of these
        // restarts the route on its own, and applying a configuration used to
        // tear the audio down and build it back four times for one click.
        batched {
            for (uid, isInput) in [
                (configuration.sourceUID, true), (configuration.destinationUID, false),
            ] {
                guard let uid else { continue }
                let devices = isInput ? inputDevices : outputDevices
                guard let device = devices.first(where: { $0.uid == uid }) else {
                    missing.append(uid)
                    continue
                }
                _ = device
                if isInput {
                    selectedSourceUID = uid
                    if selectedSourceUID == uid { restored += 1 }
                } else {
                    selectedDestinationUID = uid
                    if selectedDestinationUID == uid { restored += 1 }
                }
            }

            // The monitor is allowed to be absent without complaint: it is the
            // one device somebody deliberately unplugs — headphones — and
            // reporting it missing every time would train them to ignore the
            // report.
            if let monitor = configuration.monitorUID {
                monitorDeviceUID = outputDevices.contains { $0.uid == monitor } ? monitor : nil
            } else {
                monitorDeviceUID = nil
            }

            // Anything on the never-capture list stays off it. A configuration
            // saved before something was excluded must not bring it back.
            let wanted = Set(configuration.capturedAppBundleIDs)
                .subtracting(excludedAppBundleIDs)
            capturedAppBundleIDs = wanted
        }

        // Last, and only after the system-control queue completed both default
        // writes. Starting sooner would build a route against half of the setup
        // while the Sound menu was still moving to the other half.
        if configuration.isRouting, !isRunning {
            start()
        } else if !configuration.isRouting, isRunning {
            stop()
        }

        return QuickConfig.Outcome(restored: restored, missing: missing)
    }

    /// Names devices that are not here, so the report reads as English rather
    /// than as a list of UIDs.
    func describeMissing(_ uids: [String]) -> String {
        uids.map { uid in
            (inputDevices + outputDevices).first { $0.uid == uid }?.name ?? uid
        }.joined(separator: ", ")
    }
}

private let quickConfigStoreKey = "com.yuhuanstudio.yunaudio.quickConfigs"

@MainActor
enum QuickConfigStore {
    private static let persistence = BoundedCollectionPersistence<[QuickConfig]>(
        encode: { try? JSONEncoder().encode($0) },
        sink: { data in
            UserDefaults.standard.set(data, forKey: quickConfigStoreKey)
            return UserDefaults.standard.data(forKey: quickConfigStoreKey) == data
        },
        synchronise: { UserDefaults.standard.synchronize() })

    static var statistics: CollectionPersistenceStatistics {
        persistence.statistics
    }

    static func refusal(
        for configurations: [QuickConfig]
    )
        -> CollectionPersistenceRefusal?
    {
        persistence.preflightRefusal(
            recordCount: configurations.count,
            estimatedEncodedBytes: encodedSizeUpperBoundForDiagnostics(configurations))
    }

    static func load() -> [QuickConfig] {
        switch persistence.load(
            UserDefaults.standard.data(forKey: quickConfigStoreKey),
            decode: { try? JSONDecoder().decode([QuickConfig].self, from: $0) },
            recordCount: \.count)
        {
        case .loaded(let saved):
            return saved
        case .absent, .refused:
            return []
        }
    }

    @discardableResult
    static func save(_ configurations: [QuickConfig]) -> CollectionPersistenceSubmission {
        persistence.submit(
            configurations,
            recordCount: configurations.count,
            estimatedEncodedBytes: encodedSizeUpperBoundForDiagnostics(configurations))
    }

    static func flush(
        timeout: Duration = .seconds(1),
        completion: @escaping @MainActor @Sendable (PreferenceFlushResult) -> Void
    ) {
        persistence.flush(timeout: timeout, completion: completion)
    }

    static func encodedSizeUpperBoundForDiagnostics(
        _ configurations: [QuickConfig]
    ) -> Int? {
        var budget = JSONEncodedSizeBudget(
            limit: CollectionPersistenceLimits.userCollection.maximumEncodedBytes)
        budget.addSyntax()
        for configuration in configurations {
            budget.addSyntax()
            budget.addField("name", string: configuration.name)
            budget.addField("systemInputUID", string: configuration.systemInputUID)
            budget.addField("systemOutputUID", string: configuration.systemOutputUID)
            budget.addField("sourceUID", string: configuration.sourceUID)
            budget.addField("destinationUID", string: configuration.destinationUID)
            budget.addField("monitorUID", string: configuration.monitorUID)
            budget.addStringArrayField(
                "capturedAppBundleIDs", values: configuration.capturedAppBundleIDs)
            budget.addBooleanField("isRouting")
            budget.addSyntax(2)
            if budget.hasExceededLimit { break }
        }
        budget.addSyntax()
        return budget.upperBound
    }
}
