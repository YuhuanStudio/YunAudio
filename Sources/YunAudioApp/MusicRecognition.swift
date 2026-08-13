import AVFAudio
import Foundation
import ShazamKit

/// Public, source-independent now-playing metadata from captured audio.
///
/// QQ Music and NetEase Cloud Music publish no AppleScript dictionary on
/// macOS. Scraping their windows would require Accessibility access and would
/// break whenever either application rearranged a label; MediaRemote is a
/// private framework. ShazamKit instead identifies the exact recording already
/// flowing through YunAudio and returns its reference timecode, so the same
/// path also covers browsers and future players without pretending they expose
/// an integration they do not.
final class MusicRecognition: @unchecked Sendable {

    struct Match: Sendable, Equatable {
        let title: String
        let artist: String
        let album: String
        let identity: String
        let position: Double
        let duration: Double
        let confidence: Float
        let artworkURL: URL?
        let appleMusicURL: URL?
    }

    enum Failure: Error, Sendable, Equatable {
        case catalogueAccessNotEnabled
        case failed(String)
    }

    typealias Handler = @MainActor @Sendable (Result<Match, Failure>) -> Void

    /// Bounded evidence for the ingress and one non-cancellable catalogue owner.
    struct Statistics: Equatable, Sendable {
        fileprivate(set) var submittedBlocks: UInt64 = 0
        fileprivate(set) var submittedSamples: UInt64 = 0
        fileprivate(set) var acceptedSamples: UInt64 = 0
        fileprivate(set) var droppedWhileMatching: UInt64 = 0
        fileprivate(set) var droppedAtCapacity: UInt64 = 0
        fileprivate(set) var scheduledDrains: UInt64 = 0
        fileprivate(set) var activeScheduledDrains = 0
        fileprivate(set) var maximumScheduledDrains = 0
        fileprivate(set) var preparedMatches: UInt64 = 0
        fileprivate(set) var startedSystemAwaits: UInt64 = 0
        fileprivate(set) var activeSystemAwaits = 0
        fileprivate(set) var maximumConcurrentSystemAwaits = 0
        fileprivate(set) var resets: UInt64 = 0
        fileprivate(set) var shutdowns: UInt64 = 0
        fileprivate(set) var lateResults: UInt64 = 0
        fileprivate(set) var publications: UInt64 = 0
        fileprivate(set) var pendingSamples = 0
        fileprivate(set) var maximumPendingSamples = 0
    }

    /// A prepared signature contains no captured PCM. The testing token lets the
    /// lifetime contract be fault-injected without contacting Shazam's service.
    enum PreparedSignature: @unchecked Sendable {
        case shazam(SHSignature)
        case testing(UInt64)
    }

    enum CatalogueResult: Sendable {
        case match(Match)
        case noMatch
        case failure(Failure)
    }

    typealias PrepareSignature = @Sendable ([Float], Double) throws -> PreparedSignature
    typealias MatchSignature = @Sendable (PreparedSignature) async -> CatalogueResult

    private enum PreparationError: Error {
        case invalidBuffer
    }

    /// Owns the framework singleton independently of `MusicRecognition` itself.
    /// A catalogue await which ignores cancellation may retain this one capsule,
    /// but never the router, its PCM accumulator, or a replacement task.
    private final class LiveSession: @unchecked Sendable {
        let session = SHSession()

        func result(from prepared: PreparedSignature) async -> CatalogueResult {
            guard case .shazam(let signature) = prepared else { return .noMatch }
            switch await session.result(from: signature) {
            case let .match(match):
                guard let item = match.mediaItems.first,
                    let title = item.title?.nonEmpty,
                    let artist = item.artist?.nonEmpty
                else { return .noMatch }
                return .match(
                    Match(
                        title: title, artist: artist, album: item.subtitle ?? "",
                        identity: item.shazamID.map { "shazam:\($0)" }
                            ?? "shazam:\(artist):\(title)",
                        position: max(0, item.predictedCurrentMatchOffset),
                        // `timeRanges` describe the reference-signature ranges,
                        // not the recording's total duration.
                        duration: 0,
                        confidence: item.confidence, artworkURL: item.artworkURL,
                        appleMusicURL: item.appleMusicURL))
            case .noMatch:
                return .noMatch
            case let .error(error, _):
                return .failure(MusicRecognition.describe(error))
            }
        }
    }

    /// Thread-safe admission for PCM and the sole catalogue await.
    private final class Core: @unchecked Sendable {
        private struct ActiveMatch {
            let identifier: UInt64
            let generation: UInt64
            let sampleRate: Double
            var isAwaiting = false
            var task: Task<Void, Never>?
        }

        private struct PreparedMatch {
            let signature: PreparedSignature
            let active: ActiveMatch
        }

        private struct State {
            var pending: [Float] = []
            var sampleRate: Double = 0
            var cooldownSamples = 0
            var drainIsScheduled = false
            var acceptsWork = true
            var isDisabled = false
            var generation: UInt64 = 0
            var nextMatchIdentifier: UInt64 = 0
            var activeMatch: ActiveMatch?
            var statistics = Statistics()
        }

        private let lock = NSLock()
        private var state = State()
        private let queue: DispatchQueue
        private let prepare: PrepareSignature
        private let match: MatchSignature
        private let handler: Handler

        init(
            queue: DispatchQueue,
            prepare: @escaping PrepareSignature,
            match: @escaping MatchSignature,
            handler: @escaping Handler
        ) {
            self.queue = queue
            self.prepare = prepare
            self.match = match
            self.handler = handler
        }

        var statistics: Statistics {
            lock.withLock {
                var snapshot = state.statistics
                snapshot.pendingSamples = state.pending.count
                snapshot.activeScheduledDrains = state.drainIsScheduled ? 1 : 0
                return snapshot
            }
        }

        func add(_ samples: [Float], sampleRate: Double) {
            let schedulesDrain: Bool = lock.withLock {
                state.statistics.submittedBlocks &+= 1
                state.statistics.submittedSamples &+= UInt64(samples.count)
                guard state.acceptsWork, !state.isDisabled else { return false }
                guard state.activeMatch == nil else {
                    state.statistics.droppedWhileMatching &+= UInt64(samples.count)
                    return false
                }

                if state.sampleRate != sampleRate {
                    state.pending = []
                    state.pending.reserveCapacity(Self.queryFrames(sampleRate: sampleRate))
                    state.sampleRate = sampleRate
                    state.cooldownSamples = 0
                }

                var start = 0
                if state.cooldownSamples > 0 {
                    let split = MusicRecognition.consumeCooldown(
                        sampleCount: samples.count,
                        cooldownSamples: state.cooldownSamples)
                    state.cooldownSamples = split.remaining
                    start = split.discarded
                }

                let available = max(0, samples.count - start)
                let capacity = max(
                    0, Self.queryFrames(sampleRate: sampleRate) - state.pending.count)
                let admitted = min(available, capacity)
                if admitted > 0 {
                    state.pending.append(contentsOf: samples[start..<(start + admitted)])
                    state.statistics.acceptedSamples &+= UInt64(admitted)
                    state.statistics.maximumPendingSamples = max(
                        state.statistics.maximumPendingSamples, state.pending.count)
                }
                if admitted < available {
                    state.statistics.droppedAtCapacity &+= UInt64(available - admitted)
                }

                guard admitted > 0,
                    state.pending.count >= Self.queryFrames(sampleRate: sampleRate)
                else { return false }
                guard !state.drainIsScheduled else { return false }
                state.drainIsScheduled = true
                state.statistics.scheduledDrains &+= 1
                state.statistics.maximumScheduledDrains = max(
                    state.statistics.maximumScheduledDrains, 1)
                return true
            }
            if schedulesDrain {
                queue.async { [weak self] in self?.drain() }
            }
        }

        func reset(releasingBuffers: Bool) {
            lock.withLock {
                state.generation &+= 1
                state.statistics.resets &+= 1
                if releasingBuffers {
                    state.pending = []
                } else {
                    state.pending.removeAll(keepingCapacity: true)
                }
                state.sampleRate = 0
                state.cooldownSamples = 0
                state.isDisabled = false
                // An entered `SHSession.result` remains the sole owner. Clearing
                // it here would admit another task beside a service which may be
                // precisely the thing that stopped returning.
            }
        }

        func shutdown() {
            let activeTask: Task<Void, Never>? = lock.withLock {
                guard state.acceptsWork else { return nil }
                state.acceptsWork = false
                state.generation &+= 1
                state.statistics.shutdowns &+= 1
                state.pending = []
                state.sampleRate = 0
                state.cooldownSamples = 0
                return state.activeMatch?.task
            }
            // Cancellation is a request, never a join. If Shazam ignores it the
            // one task and its session remain quarantined until their own return.
            activeTask?.cancel()
        }

        private func drain() {
            guard let preparedMatch = prepareNextMatch() else { return }
            let active = preparedMatch.active
            let prepared = preparedMatch.signature

            let mayCreateAwait = lock.withLock {
                guard state.acceptsWork,
                    state.generation == active.generation,
                    state.activeMatch?.identifier == active.identifier
                else {
                    if state.activeMatch?.identifier == active.identifier {
                        state.activeMatch = nil
                    }
                    return false
                }
                return true
            }
            guard mayCreateAwait else { return }

            let operation = match
            let task = Task.detached(priority: .utility) { [weak self] in
                guard self?.beginAwait(active) == true else { return }
                let result = await operation(prepared)
                self?.receive(result, active: active)
            }
            let shouldCancel = lock.withLock {
                guard state.activeMatch?.identifier == active.identifier else {
                    return false
                }
                state.activeMatch?.task = task
                return !state.acceptsWork
            }
            if shouldCancel { task.cancel() }
        }

        /// Returns only the signature and its scalar identity. Keeping PCM in a
        /// helper whose return value cannot carry it makes the lifetime boundary
        /// explicit even when the catalogue task outlives this object.
        private func prepareNextMatch() -> PreparedMatch? {
            let reserved: (samples: [Float], active: ActiveMatch)? = lock.withLock {
                state.drainIsScheduled = false
                guard state.acceptsWork, !state.isDisabled, state.activeMatch == nil,
                    state.sampleRate > 0
                else { return nil }
                let wanted = Self.queryFrames(sampleRate: state.sampleRate)
                guard state.pending.count >= wanted else { return nil }

                state.nextMatchIdentifier &+= 1
                let active = ActiveMatch(
                    identifier: state.nextMatchIdentifier,
                    generation: state.generation,
                    sampleRate: state.sampleRate,
                    task: nil)
                state.activeMatch = active
                // Move the sole bounded accumulator out for synchronous
                // signature construction. Nothing submitted during matching is
                // retained, and the array dies before the system await begins.
                let samples = state.pending
                state.pending = []
                return (samples, active)
            }
            guard let reserved else { return nil }
            let active = reserved.active

            do {
                return PreparedMatch(
                    signature: try prepare(reserved.samples, active.sampleRate),
                    active: active)
            } catch {
                failPreparation(error, active: active)
                return nil
            }
        }

        private func beginAwait(_ active: ActiveMatch) -> Bool {
            lock.withLock {
                guard state.acceptsWork, state.generation == active.generation,
                    var current = state.activeMatch,
                    current.identifier == active.identifier, !current.isAwaiting
                else {
                    if state.activeMatch?.identifier == active.identifier {
                        state.activeMatch = nil
                    }
                    return false
                }
                current.isAwaiting = true
                state.activeMatch = current
                state.statistics.preparedMatches &+= 1
                state.statistics.startedSystemAwaits &+= 1
                state.statistics.activeSystemAwaits += 1
                state.statistics.maximumConcurrentSystemAwaits = max(
                    state.statistics.maximumConcurrentSystemAwaits,
                    state.statistics.activeSystemAwaits)
                return true
            }
        }

        private func failPreparation(_ error: Error, active: ActiveMatch) {
            let shouldPublish = lock.withLock {
                guard state.activeMatch?.identifier == active.identifier else { return false }
                state.activeMatch = nil
                guard state.acceptsWork, state.generation == active.generation else {
                    state.statistics.lateResults &+= 1
                    return false
                }
                state.isDisabled = true
                return true
            }
            if shouldPublish {
                publish(
                    .failure(MusicRecognition.describe(error)),
                    generation: active.generation)
            }
        }

        private func receive(_ result: CatalogueResult, active: ActiveMatch) {
            let publication: Result<Match, Failure>? = lock.withLock {
                guard state.activeMatch?.identifier == active.identifier else {
                    state.statistics.lateResults &+= 1
                    return nil
                }
                state.activeMatch = nil
                state.statistics.activeSystemAwaits -= 1
                guard state.acceptsWork, state.generation == active.generation else {
                    state.statistics.lateResults &+= 1
                    return nil
                }
                state.cooldownSamples = Int(
                    MusicRecognition.retrySeconds * active.sampleRate)
                switch result {
                case .match(let match):
                    return .success(match)
                case .noMatch:
                    return nil
                case .failure(let failure):
                    state.isDisabled = true
                    return .failure(failure)
                }
            }
            if let publication { publish(publication, generation: active.generation) }
        }

        private func publish(
            _ result: Result<Match, Failure>, generation: UInt64
        ) {
            MainRunLoopDelivery.perform { [weak self] in
                guard let self else { return }
                let handler: Handler? = lock.withLock {
                    guard state.acceptsWork, state.generation == generation else {
                        state.statistics.lateResults &+= 1
                        return nil
                    }
                    state.statistics.publications &+= 1
                    return self.handler
                }
                handler?(result)
            }
        }

        private static func queryFrames(sampleRate: Double) -> Int {
            min(
                MusicRecognition.maximumPendingSamples,
                max(0, Int(MusicRecognition.querySeconds * sampleRate)))
        }
    }

    private let core: Core

    /// Six seconds was measured as enough for the specified Chinese release
    /// while keeping the first answer comfortably below one lyric line.
    static let querySeconds: Double = 6
    /// The largest supported six-second accumulator: 1,152,000 bytes of Float32.
    static let maximumPendingSamples = 288_000
    /// Twelve seconds between completed catalogue attempts. With the six-second
    /// signature this bounds an open panel to about three requests a minute.
    static let retrySeconds: Double = 12
    convenience init(handler: @escaping Handler) {
        let session = LiveSession()
        self.init(
            prepare: Self.prepareSignature,
            match: { prepared in await session.result(from: prepared) },
            handler: handler)
    }

    /// Injectable boundaries prove ownership without asking the live catalogue.
    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.music-recognition", qos: .utility),
        prepare: @escaping PrepareSignature,
        match: @escaping MatchSignature,
        handler: @escaping Handler
    ) {
        core = Core(queue: queue, prepare: prepare, match: match, handler: handler)
    }

    deinit { core.shutdown() }

    var statistics: Statistics { core.statistics }

    /// Adds mono samples copied from one captured application.
    func add(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, Self.supportedRates.contains(sampleRate) else { return }
        core.add(samples, sampleRate: sampleRate)
    }

    /// Invalidates the current request and clears accumulated audio.
    ///
    /// Closing KTV releases the six-second allocation rather than retaining
    /// 1,152,000 bytes for a panel that may never open again.
    func reset(releasingBuffers: Bool = false) {
        core.reset(releasingBuffers: releasingBuffers)
    }

    /// Permanently revokes this owner without waiting for an entered catalogue call.
    func shutdown() { core.shutdown() }

    private static func prepareSignature(
        samples: [Float], sampleRate: Double
    ) throws -> PreparedSignature {
        guard samples.count <= maximumPendingSamples,
            let buffer = buffer(samples: samples, sampleRate: sampleRate)
        else { throw PreparationError.invalidBuffer }
        let generator = SHSignatureGenerator()
        try generator.append(buffer, at: nil)
        return .shazam(generator.signature())
    }

    static func describe(_ error: Error) -> Failure {
        let cocoa = error as NSError
        if cocoa.domain == "com.apple.ShazamCore", cocoa.code == 102 {
            return .catalogueAccessNotEnabled
        }
        return .failed(cocoa.localizedDescription)
    }

    /// Divides one captured block at the end of a retry cooldown.
    ///
    /// Dropping the whole block delayed a new signature by whatever audio
    /// followed the boundary — up to the full drain size — even though only
    /// the prefix belonged to the cooldown.
    static func consumeCooldown(
        sampleCount: Int, cooldownSamples: Int
    ) -> (discarded: Int, remaining: Int) {
        let discarded = min(max(0, sampleCount), max(0, cooldownSamples))
        return (discarded, max(0, cooldownSamples - discarded))
    }

    /// A separate pure construction point so the frame count and sample
    /// values can be asserted without making a network match.
    static func buffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        samples.withUnsafeBufferPointer {
            buffer(samples: $0, sampleRate: sampleRate)
        }
    }

    /// The signature accumulator already owns six seconds in one contiguous
    /// array. Borrow it so constructing an AVAudio buffer does not first copy
    /// another 1.15 MB at 48 kHz.
    static func buffer(
        samples: UnsafeBufferPointer<Float>, sampleRate: Double
    ) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let source = samples.baseAddress else { return buffer }
        channel.update(from: source, count: samples.count)
        return buffer
    }

    private static let supportedRates: Set<Double> = [16_000, 32_000, 44_100, 48_000]
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
