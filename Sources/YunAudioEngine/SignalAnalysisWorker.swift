import Foundation

/// Owns every non-realtime signal analyser on one bounded background lane.
///
/// Polling is an invitation, not a queue entry. While a drain is pending or in
/// flight, later invitations are folded into it. The serial queue therefore
/// contains at most one work item, however long MainActor was stalled or how
/// quickly callers ask for another reading.
public final class SignalAnalysisWorker: @unchecked Sendable {
    /// Realtime ring evidence captured beside the corresponding reading.
    public struct RingStatistics: Sendable, Equatable {
        public let isEnabled: Bool
        public let written: UInt32
        public let available: UInt32
        /// Samples rejected before the worker could receive them.
        public let dropped: UInt64

        public static let unavailable = RingStatistics(
            isEnabled: false, written: 0, available: 0, dropped: 0)
    }

    /// An immutable cross-thread view of the analyser state.
    public struct Snapshot: Sendable, Equatable {
        public let reading: SignalAnalyser.Reading
        public let chroma: [Double]?
        public let hearsSpeech: Bool
        /// Changes whenever any published analysis state changes.
        public let generation: UInt64
        /// Changes only when present-time analysis or its configuration changes.
        public let latestGeneration: UInt64
        public let statistics: SignalAnalyser.Statistics
        public let ring: RingStatistics

        public static let silent = Snapshot(
            reading: .silent,
            chroma: nil,
            hearsSpeech: false,
            generation: 0,
            latestGeneration: 0,
            statistics: SignalAnalyser.Statistics(),
            ring: .unavailable)
    }

    /// Numbers which make the queue bound and its cost directly assertable.
    public struct Telemetry: Sendable, Equatable {
        public let drainRequests: UInt64
        public let drainSteps: UInt64
        public let completedDrains: UInt64
        public let coalescedDrainRequests: UInt64
        /// Zero or one by construction, including an in-flight drain.
        public let pendingDrains: Int
        public let maximumPendingDrains: Int
        /// Zero or one by construction, including the currently running turn.
        public let scheduledTurns: Int
        public let maximumScheduledTurns: Int
        public let oldestPendingMilliseconds: Double
        public let longestDrainMilliseconds: Double
        public let ringWrittenSamples: UInt32
        public let ringAvailableSamples: UInt32
        public let ringDroppedSamples: UInt64
        /// Highest observed drop counter, retained after a graph disappears.
        public let maximumRingDroppedSamples: UInt64
        /// Must remain zero: this is the executable MainActor isolation claim.
        public let mainThreadTurns: UInt64
    }

    private struct Configuration: Equatable {
        var revision: UInt64 = 0
        var lifetime: UInt64 = 0
        var sampleRate: Double?
        var needs: SignalAnalyser.Needs = []
        var resetSequence: UInt64 = 0
    }

    private let queue: DispatchQueue
    private let drain: @Sendable (UnsafeMutablePointer<Float>, Int) -> Int
    private let readRingStatistics: @Sendable () -> RingStatistics
    private let makeAnalyser: @Sendable (Double) -> SignalAnalyser
    private let lock = NSLock()

    // Every property down to the queue-owned section is protected by `lock`.
    private var configuration = Configuration()
    private var publishedSnapshot = Snapshot.silent
    private var publicationGeneration: UInt64 = 0
    private var latestPublicationGeneration: UInt64 = 0
    private var drainRequestSequence: UInt64 = 0
    private var drainIsOutstanding = false
    private var pendingSince: UInt64 = 0
    private var isScheduled = false
    private var drainRequests: UInt64 = 0
    private var drainSteps: UInt64 = 0
    private var completedDrains: UInt64 = 0
    private var coalescedDrainRequests: UInt64 = 0
    private var maximumPendingDrains = 0
    private var maximumScheduledTurns = 0
    private var longestDrainMilliseconds: Double = 0
    private var latestRingStatistics = RingStatistics.unavailable
    private var maximumRingDroppedSamples: UInt64 = 0
    private var mainThreadTurns: UInt64 = 0

    // Queue-owned. Keeping the non-Sendable analyser on this lane is the
    // boundary this type exists to enforce.
    private var analyser: SignalAnalyser?
    private var appliedConfiguration = Configuration()
    private var latestChroma: [Double]?

    public convenience init(engine: RoutingEngine) {
        self.init(
            drain: { destination, capacity in
                engine.drainAnalysis(into: destination, capacity: capacity)
            },
            ringStatistics: {
                let statistics = engine.analysisStatistics
                return RingStatistics(
                    isEnabled: statistics.isEnabled,
                    written: statistics.written,
                    available: statistics.available,
                    dropped: statistics.dropped)
            })
    }

    init(
        label: String = "com.yuhuanstudio.yunaudio.analysis",
        drain: @escaping @Sendable (UnsafeMutablePointer<Float>, Int) -> Int,
        ringStatistics: @escaping @Sendable () -> RingStatistics = { .unavailable },
        makeAnalyser: @escaping @Sendable (Double) -> SignalAnalyser = {
            SignalAnalyser(sampleRate: $0)
        }
    ) {
        // Analysis may catch up for seconds after a process stall. Utility QoS
        // lets the audio server and direct interaction win that CPU contest.
        queue = DispatchQueue(label: label, qos: .utility)
        self.drain = drain
        readRingStatistics = ringStatistics
        self.makeAnalyser = makeAnalyser
    }

    /// Starts a new analyser lifetime. Construction itself happens off MainActor.
    public func activate(sampleRate: Double) {
        let admittedRate =
            AudioProcessingContract.supports(sampleRate: sampleRate)
            ? sampleRate : SignalAnalyser.fallbackSampleRate
        lock.lock()
        configuration.revision &+= 1
        configuration.lifetime &+= 1
        configuration.sampleRate = admittedRate
        configuration.needs = []
        configuration.resetSequence &+= 1
        drainIsOutstanding = false
        pendingSince = 0
        publishSilentLocked()
        scheduleLocked()
        lock.unlock()
    }

    /// Ends the lifetime without waiting for an expensive analyser already in flight.
    public func deactivate() {
        lock.lock()
        configuration.revision &+= 1
        configuration.lifetime &+= 1
        configuration.sampleRate = nil
        configuration.needs = []
        configuration.resetSequence &+= 1
        drainIsOutstanding = false
        pendingSince = 0
        publishSilentLocked()
        scheduleLocked()
        lock.unlock()
    }

    /// Replaces the desired work; intermediate configurations have no meaning.
    public func require(_ needs: SignalAnalyser.Needs) {
        lock.lock()
        guard needs != configuration.needs else {
            lock.unlock()
            return
        }
        configuration.revision &+= 1
        configuration.needs = needs
        if needs.isEmpty {
            drainIsOutstanding = false
            pendingSince = 0
            publishSilentLocked()
        }
        scheduleLocked()
        lock.unlock()
    }

    /// Resets session state on the worker and invalidates an older in-flight answer.
    public func reset() {
        lock.lock()
        guard configuration.sampleRate != nil else {
            publishSilentLocked()
            lock.unlock()
            return
        }
        configuration.revision &+= 1
        configuration.resetSequence &+= 1
        publishSilentLocked()
        scheduleLocked()
        lock.unlock()
    }

    /// Requests a drain without ever putting another caller-owned block on the queue.
    public func requestDrain() {
        lock.lock()
        guard configuration.sampleRate != nil, !configuration.needs.isEmpty else {
            lock.unlock()
            return
        }
        drainRequests &+= 1
        drainRequestSequence &+= 1
        if drainIsOutstanding {
            coalescedDrainRequests &+= 1
        } else {
            drainIsOutstanding = true
            pendingSince = DispatchTime.now().uptimeNanoseconds
            maximumPendingDrains = max(maximumPendingDrains, 1)
        }
        scheduleLocked()
        lock.unlock()
    }

    /// MainActor only copies this value; it never runs an analyser.
    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return publishedSnapshot
    }

    public var telemetry: Telemetry {
        lock.lock()
        defer { lock.unlock() }
        let age: Double
        if drainIsOutstanding, pendingSince > 0 {
            age = Self.milliseconds(since: pendingSince)
        } else {
            age = 0
        }
        return Telemetry(
            drainRequests: drainRequests,
            drainSteps: drainSteps,
            completedDrains: completedDrains,
            coalescedDrainRequests: coalescedDrainRequests,
            pendingDrains: drainIsOutstanding ? 1 : 0,
            maximumPendingDrains: maximumPendingDrains,
            scheduledTurns: isScheduled ? 1 : 0,
            maximumScheduledTurns: maximumScheduledTurns,
            oldestPendingMilliseconds: age,
            longestDrainMilliseconds: longestDrainMilliseconds,
            ringWrittenSamples: latestRingStatistics.written,
            ringAvailableSamples: latestRingStatistics.available,
            ringDroppedSamples: latestRingStatistics.dropped,
            maximumRingDroppedSamples: maximumRingDroppedSamples,
            mainThreadTurns: mainThreadTurns)
    }

    private func scheduleLocked() {
        guard !isScheduled else { return }
        isScheduled = true
        maximumScheduledTurns = max(maximumScheduledTurns, 1)
        queue.async { [weak self] in self?.runTurn() }
    }

    /// Runs one fixed drain chunk, then yields the queue even when more remains.
    /// There is still only one continuation: `isScheduled` stays true until the
    /// worker has applied the newest configuration and reached a short read.
    private func runTurn() {
        let ranOnMainThread = Thread.isMainThread
        lock.lock()
        let wanted = configuration
        let configurationChanged = wanted != appliedConfiguration
        let shouldDrain =
            drainIsOutstanding && wanted.sampleRate != nil && !wanted.needs.isEmpty
        let requestSequence = drainRequestSequence
        if !configurationChanged, !shouldDrain {
            if ranOnMainThread { mainThreadTurns &+= 1 }
            isScheduled = false
            lock.unlock()
            return
        }
        lock.unlock()

        var latestChanged = false
        if configurationChanged {
            if wanted.lifetime != appliedConfiguration.lifetime {
                analyser = wanted.sampleRate.map(makeAnalyser)
                latestChroma = nil
            }
            analyser?.require(wanted.needs)
            if wanted.resetSequence != appliedConfiguration.resetSequence {
                analyser?.reset()
            }
            if !wanted.needs.contains(.spectrum) { latestChroma = nil }
            appliedConfiguration = wanted
            latestChanged = true
        }

        var progress: SignalAnalyser.DrainProgress?
        var drainMilliseconds: Double = 0
        if shouldDrain, let analyser, !analyser.isIdle {
            let started = DispatchTime.now().uptimeNanoseconds
            progress = analyser.drainStep(drain)
            drainMilliseconds = Self.milliseconds(since: started)
            if progress?.processedLatest == true {
                latestChroma = analyser.chroma()
                latestChanged = true
            }
        }

        let reading = analyser?.reading() ?? .silent
        let hearsSpeech = analyser?.classifier?.hearsSpeech ?? false
        let statistics = analyser?.statistics ?? SignalAnalyser.Statistics()
        let ringStatistics = readRingStatistics()

        lock.lock()
        if ranOnMainThread { mainThreadTurns &+= 1 }
        if progress != nil {
            drainSteps &+= 1
            longestDrainMilliseconds = max(longestDrainMilliseconds, drainMilliseconds)
        }
        latestRingStatistics = ringStatistics
        maximumRingDroppedSamples = max(
            maximumRingDroppedSamples, ringStatistics.dropped)

        // A control change during an expensive transform makes this result
        // belong to an obsolete configuration. The next turn publishes the
        // state after applying the replacement instead.
        if configuration.revision == wanted.revision {
            publicationGeneration &+= 1
            if latestChanged { latestPublicationGeneration &+= 1 }
            publishedSnapshot = Snapshot(
                reading: reading,
                chroma: latestChroma,
                hearsSpeech: hearsSpeech,
                generation: publicationGeneration,
                latestGeneration: latestPublicationGeneration,
                statistics: statistics,
                ring: ringStatistics)
        }

        if let progress, progress.isDrained,
            drainRequestSequence == requestSequence,
            configuration.revision == wanted.revision
        {
            drainIsOutstanding = false
            pendingSince = 0
            completedDrains &+= 1
        }

        let hasConfigurationWork = configuration != appliedConfiguration
        let hasDrainWork =
            drainIsOutstanding && configuration.sampleRate != nil
            && !configuration.needs.isEmpty
        if hasConfigurationWork || hasDrainWork {
            queue.async { [weak self] in self?.runTurn() }
        } else {
            isScheduled = false
        }
        lock.unlock()
    }

    private func publishSilentLocked() {
        publicationGeneration &+= 1
        latestPublicationGeneration &+= 1
        publishedSnapshot = Snapshot(
            reading: .silent,
            chroma: nil,
            hearsSpeech: false,
            generation: publicationGeneration,
            latestGeneration: latestPublicationGeneration,
            statistics: SignalAnalyser.Statistics(),
            ring: .unavailable)
    }

    private static func milliseconds(since started: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now >= started ? now - started : 0) / 1_000_000
    }
}
