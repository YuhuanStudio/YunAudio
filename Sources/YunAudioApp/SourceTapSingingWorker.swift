import Foundation
import YunAudioEngine

/// One desired lifetime for the per-source rings.
struct SourceTapLifecycleRequest: Sendable, Equatable {
    let generation: UInt64
    let routes: [Int]
    let sourceUIDs: [String]
    let routeKeys: [RouteOccurrenceKey]

    static func closed(generation: UInt64) -> SourceTapLifecycleRequest {
        SourceTapLifecycleRequest(
            generation: generation, routes: [], sourceUIDs: [], routeKeys: [])
    }
}

/// The rings which survived one lifecycle application.
struct SourceTapLifecycleSnapshot: Sendable, Equatable {
    let generation: UInt64
    let sourceUIDs: [String]
    let routeKeys: [RouteOccurrenceKey]
    let openedCount: Int
    let transitionSucceeded: Bool

    var isOpen: Bool { openedCount > 0 }
}

/// Moves source-ring publication off MainActor through one first/latest lane.
///
/// Starting a tap publishes a structural realtime graph and may wait for its old
/// generation. None of that belongs on the interface executor. The lane is
/// serial because Stop and Start are an ownership order, and retains only one
/// newest desired state because intermediate source topologies have no value.
final class SourceTapLifecycleWorker: @unchecked Sendable {
    struct Statistics: Sendable, Equatable {
        let submissions: UInt64
        let coalesced: UInt64
        let applications: UInt64
        let publications: UInt64
        let revokedResults: UInt64
        let maximumPending: Int
        let mainThreadApplications: UInt64
        let failedStops: UInt64
    }

    struct Operations: Sendable {
        let start: @Sendable ([Int]) -> Int
        let stop: @Sendable () -> Bool
    }

    private final class AppliedState: @unchecked Sendable {
        private let telemetryLock = NSLock()
        var requestedSourceUIDs: [String] = []
        var requestedRouteKeys: [RouteOccurrenceKey] = []
        var sourceUIDs: [String] = []
        var routeKeys: [RouteOccurrenceKey] = []
        var openedCount = 0

        private var mainThreadApplications: UInt64 = 0
        private var failedStops: UInt64 = 0

        func recordApplicationThread() {
            guard Thread.isMainThread else { return }
            telemetryLock.withLock { mainThreadApplications &+= 1 }
        }

        var mainThreadApplicationCount: UInt64 {
            telemetryLock.withLock { mainThreadApplications }
        }

        func recordFailedStop() {
            telemetryLock.withLock { failedStops &+= 1 }
        }

        var failedStopCount: UInt64 { telemetryLock.withLock { failedStops } }

        func assumeClosed() {
            requestedSourceUIDs = []
            requestedRouteKeys = []
            sourceUIDs = []
            routeKeys = []
            openedCount = 0
        }
    }

    private let lane:
        LatestExternalWorkLane<SourceTapLifecycleRequest, SourceTapLifecycleSnapshot>
    private let applied: AppliedState
    private let queue: DispatchQueue

    init(
        operations: Operations,
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.source-tap-lifecycle",
            qos: .userInitiated),
        publish: @escaping @MainActor @Sendable (SourceTapLifecycleSnapshot) -> Void
    ) {
        let applied = AppliedState()
        self.applied = applied
        self.queue = queue
        lane = LatestExternalWorkLane(
            queue: queue,
            apply: { request in
                applied.recordApplicationThread()
                let requestsClose =
                    request.routes.isEmpty && request.sourceUIDs.isEmpty
                    && request.routeKeys.isEmpty
                if requestsClose {
                    if applied.openedCount > 0, !operations.stop() {
                        applied.recordFailedStop()
                        return SourceTapLifecycleSnapshot(
                            generation: request.generation,
                            sourceUIDs: applied.sourceUIDs,
                            routeKeys: applied.routeKeys,
                            openedCount: applied.openedCount,
                            transitionSucceeded: false)
                    }
                    applied.requestedSourceUIDs = []
                    applied.requestedRouteKeys = []
                    applied.sourceUIDs = []
                    applied.routeKeys = []
                    applied.openedCount = 0
                    return SourceTapLifecycleSnapshot(
                        generation: request.generation, sourceUIDs: [], routeKeys: [],
                        openedCount: 0, transitionSucceeded: true)
                }

                guard !request.routes.isEmpty,
                    request.routes.count == request.sourceUIDs.count,
                    request.routes.count == request.routeKeys.count
                else {
                    return SourceTapLifecycleSnapshot(
                        generation: request.generation,
                        sourceUIDs: applied.sourceUIDs,
                        routeKeys: applied.routeKeys,
                        openedCount: applied.openedCount,
                        transitionSucceeded: false)
                }

                let requestedCount = request.routes.count
                let requestedUIDs = Array(request.sourceUIDs.prefix(requestedCount))
                let requestedKeys = Array(request.routeKeys.prefix(requestedCount))
                if applied.openedCount > 0,
                    applied.requestedSourceUIDs == requestedUIDs,
                    applied.requestedRouteKeys == requestedKeys,
                    applied.openedCount <= requestedCount,
                    applied.sourceUIDs == Array(requestedUIDs.prefix(applied.openedCount)),
                    applied.routeKeys == Array(requestedKeys.prefix(applied.openedCount))
                {
                    return SourceTapLifecycleSnapshot(
                        generation: request.generation,
                        sourceUIDs: Array(requestedUIDs.prefix(applied.openedCount)),
                        routeKeys: Array(requestedKeys.prefix(applied.openedCount)),
                        openedCount: applied.openedCount, transitionSucceeded: true)
                }

                if applied.openedCount > 0, !operations.stop() {
                    applied.recordFailedStop()
                    return SourceTapLifecycleSnapshot(
                        generation: request.generation,
                        sourceUIDs: applied.sourceUIDs,
                        routeKeys: applied.routeKeys,
                        openedCount: applied.openedCount,
                        transitionSucceeded: false)
                }
                applied.requestedSourceUIDs = []
                applied.requestedRouteKeys = []
                applied.sourceUIDs = []
                applied.routeKeys = []
                applied.openedCount = 0

                let opened = max(
                    0,
                    min(
                        requestedCount,
                        operations.start(
                            Array(request.routes.prefix(requestedCount)))))
                applied.openedCount = opened
                applied.requestedSourceUIDs = opened > 0 ? requestedUIDs : []
                applied.requestedRouteKeys = opened > 0 ? requestedKeys : []
                applied.sourceUIDs = Array(requestedUIDs.prefix(opened))
                applied.routeKeys = Array(requestedKeys.prefix(opened))
                return SourceTapLifecycleSnapshot(
                    generation: request.generation, sourceUIDs: applied.sourceUIDs,
                    routeKeys: applied.routeKeys, openedCount: opened,
                    transitionSucceeded: true)
            },
            publish: publish)
    }

    @discardableResult
    func submit(_ request: SourceTapLifecycleRequest) -> Bool {
        lane.submit(request)
    }

    /// Revokes a late answer. Closing is a desired state and must be submitted
    /// explicitly, because invalidation cannot undo a framework call in flight.
    func invalidate() { lane.invalidate() }

    /// Forgets rings already destroyed by the route owner's complete Stop.
    /// The reset is ordered on the same queue as every later lifecycle request,
    /// and never calls the engine a second time after its graph is gone.
    func assumeClosedAfterRouteStop() {
        lane.invalidate()
        queue.async { [applied] in applied.assumeClosed() }
    }

    func shutdown() { lane.shutdown() }

    var statistics: Statistics {
        let lane = lane.statistics
        return Statistics(
            submissions: lane.submissions, coalesced: lane.coalesced,
            applications: lane.applications, publications: lane.publications,
            revokedResults: lane.revokedResults, maximumPending: lane.maximumPending,
            mainThreadApplications: applied.mainThreadApplicationCount,
            failedStops: applied.failedStopCount)
    }
}

enum SingingAnalysisSourceRole: Sendable, Equatable {
    case voice
    case backingReference
}

/// Independent consumers of one single-consumer source ring.
struct SourceTapConsumerFlags: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    static let transcription = SourceTapConsumerFlags(rawValue: 1 << 0)
    static let voicePitch = SourceTapConsumerFlags(rawValue: 1 << 1)
    static let backingPitch = SourceTapConsumerFlags(rawValue: 1 << 2)
    static let musicRecognition = SourceTapConsumerFlags(rawValue: 1 << 3)

    var needsPitch: Bool { contains(.voicePitch) || contains(.backingPitch) }
    var forwardsPCM: Bool { contains(.transcription) || contains(.musicRecognition) }
}

/// Synchronous admission edge between a route lifetime and source workers.
struct SourceTapRequestGate: Sendable, Equatable {
    private(set) var acceptsRequests = false

    mutating func activate() { acceptsRequests = true }
    mutating func revoke() { acceptsRequests = false }

    func accepts(generation: UInt64, currentGeneration: UInt64) -> Bool {
        acceptsRequests && generation == currentGeneration
    }
}

/// Stable user intent across temporary scoring admission failures.
struct ScoringWishState: Sendable, Equatable {
    private(set) var requested: Bool
    private(set) var active: Bool

    mutating func suspend() { active = false }

    @discardableResult
    mutating func setByUser(_ requested: Bool, routeIsRunning: Bool) -> Bool {
        let nextActive = requested && routeIsRunning
        guard self.requested != requested || active != nextActive else {
            return false
        }
        self.requested = requested
        active = nextActive
        return true
    }

    mutating func routeDidStart() { active = requested }
}

/// One logical source before it receives a physical ring slot.
struct SourceTapUnionCandidate: Sendable, Equatable {
    let route: Int
    let routeKey: RouteOccurrenceKey
    let uid: String
    let name: String
}

/// Builds one deterministic topology for transcription and singing.
///
/// Transcription owns at most four forwarders, singing owns four voices and one
/// backing reference, and overlap owns one ring carrying both flags. A
/// transcription-only source therefore never constructs a pitch tracker.
struct SourceTapUnionPlanner {
    static let maximumRequestedSources = 64

    struct Source: Sendable, Equatable {
        let candidate: SourceTapUnionCandidate
        fileprivate(set) var consumers: SourceTapConsumerFlags
    }

    struct Result: Sendable, Equatable {
        let sources: [Source]
        /// Carries every refused identity and reason to the interface.
        let transcriptionAdmission: TranscriptionAdmission.Plan
        let refusedTranscriptions: Int
        let refusedVoices: Int
        let refusedBackingReferences: Int
        let refusedRecognitionReferences: Int
        let refusedInvalidSources: Int

        var maximumSlotCount: Int {
            TranscriptionAdmission.maximumSources
                + SingingSourceAdmissionPolicy.maximumVoiceSources
                + SingingSourceAdmissionPolicy.maximumBackingReferences
        }

        func lifecycleRequest(generation: UInt64) -> SourceTapLifecycleRequest {
            SourceTapLifecycleRequest(
                generation: generation,
                routes: sources.map(\.candidate.route),
                sourceUIDs: sources.map(\.candidate.uid),
                routeKeys: sources.map(\.candidate.routeKey))
        }

        func analysisSources(openedCount: Int) -> [SingingAnalysisSource] {
            zip(sources.indices, sources).prefix(max(0, openedCount)).map { slot, source in
                SingingAnalysisSource(
                    slot: slot, uid: source.candidate.uid, name: source.candidate.name,
                    routeKey: source.candidate.routeKey, consumers: source.consumers)
            }
        }
    }

    fileprivate struct Identity: Hashable {
        let uid: String
        let routeKey: RouteOccurrenceKey
    }

    static func plan(
        transcriptions: [SourceTapUnionCandidate],
        voices: [SourceTapUnionCandidate],
        backingReferences: [SourceTapUnionCandidate],
        recognitionReference: SourceTapUnionCandidate? = nil
    ) -> Result {
        var sources: [Source] = []
        sources.reserveCapacity(
            TranscriptionAdmission.maximumSources
                + SingingSourceAdmissionPolicy.maximumVoiceSources
                + SingingSourceAdmissionPolicy.maximumBackingReferences)
        var indices: [Identity: Int] = [:]
        let transcriptionAdmission = TranscriptionAdmission.plan(
            transcriptions.map {
                TranscriptionAdmission.Source(uid: $0.uid, name: $0.name)
            })
        let admittedTranscriptionUIDs = Set(
            transcriptionAdmission.admitted.map(\.uid))
        var mergedTranscriptionUIDs = Set<String>()
        var voiceIdentities = Set<Identity>()
        var backingIdentities = Set<Identity>()
        let refusedTranscriptions = transcriptionAdmission.refused.count
        var refusedVoices = 0
        var refusedBacking = 0
        var refusedRecognition = 0
        var refusedInvalid = 0

        func isValid(_ candidate: SourceTapUnionCandidate) -> Bool {
            candidate.route >= 0 && !candidate.uid.isEmpty
                && candidate.uid.utf8.count <= TranscriptionAdmission.maximumUIDBytes
                && !candidate.name.isEmpty
                && candidate.name.utf8.count <= TranscriptionAdmission.maximumNameBytes
        }

        func merge(
            _ candidate: SourceTapUnionCandidate, consumer: SourceTapConsumerFlags
        ) -> Bool {
            let identity = Identity(uid: candidate.uid, routeKey: candidate.routeKey)
            if let index = indices[identity] {
                guard sources[index].candidate.route == candidate.route else { return false }
                sources[index].consumers.insert(consumer)
            } else {
                indices[identity] = sources.count
                sources.append(Source(candidate: candidate, consumers: consumer))
            }
            return true
        }

        for candidate in transcriptions {
            guard admittedTranscriptionUIDs.contains(candidate.uid) else { continue }
            guard mergedTranscriptionUIDs.insert(candidate.uid).inserted else { continue }
            guard isValid(candidate) else {
                refusedInvalid += 1
                continue
            }
            guard merge(candidate, consumer: .transcription) else {
                refusedInvalid += 1
                continue
            }
        }

        for (index, candidate) in voices.enumerated() {
            guard index < maximumRequestedSources, isValid(candidate) else {
                refusedInvalid += 1
                continue
            }
            let identity = Identity(uid: candidate.uid, routeKey: candidate.routeKey)
            guard voiceIdentities.insert(identity).inserted else {
                refusedInvalid += 1
                continue
            }
            guard voiceIdentities.count <= SingingSourceAdmissionPolicy.maximumVoiceSources
            else {
                refusedVoices += 1
                continue
            }
            if let sourceIndex = indices[identity],
                sources[sourceIndex].consumers.contains(.backingPitch)
            {
                refusedVoices += 1
                continue
            }
            guard merge(candidate, consumer: .voicePitch) else {
                refusedInvalid += 1
                continue
            }
        }

        for (index, candidate) in backingReferences.enumerated() {
            guard index < maximumRequestedSources, isValid(candidate) else {
                refusedInvalid += 1
                continue
            }
            let identity = Identity(uid: candidate.uid, routeKey: candidate.routeKey)
            guard backingIdentities.insert(identity).inserted else {
                refusedInvalid += 1
                continue
            }
            guard
                backingIdentities.count
                    <= SingingSourceAdmissionPolicy.maximumBackingReferences
            else {
                refusedBacking += 1
                continue
            }
            if let sourceIndex = indices[identity],
                sources[sourceIndex].consumers.contains(.voicePitch)
            {
                refusedBacking += 1
                continue
            }
            guard merge(candidate, consumer: .backingPitch) else {
                refusedInvalid += 1
                continue
            }
        }

        if let recognitionReference {
            let identity = Identity(
                uid: recognitionReference.uid, routeKey: recognitionReference.routeKey)
            if isValid(recognitionReference), let index = indices[identity],
                sources[index].candidate.route == recognitionReference.route,
                sources[index].consumers.contains(.backingPitch)
            {
                sources[index].consumers.insert(.musicRecognition)
            } else {
                refusedRecognition += 1
            }
        }

        return Result(
            sources: sources, transcriptionAdmission: transcriptionAdmission,
            refusedTranscriptions: refusedTranscriptions,
            refusedVoices: refusedVoices,
            refusedBackingReferences: refusedBacking,
            refusedRecognitionReferences: refusedRecognition,
            refusedInvalidSources: refusedInvalid)
    }
}

/// One source whose tap can feed the singing analysis owner.
struct SingingAnalysisSource: Sendable, Equatable {
    let slot: Int
    let uid: String
    let name: String
    let routeKey: RouteOccurrenceKey
    let consumers: SourceTapConsumerFlags

    var role: SingingAnalysisSourceRole? {
        if consumers.contains(.voicePitch) { return .voice }
        if consumers.contains(.backingPitch) { return .backingReference }
        return nil
    }

    var needsPitch: Bool { consumers.needsPitch }
    var forwardsPCM: Bool { consumers.forwardsPCM }

    init(
        slot: Int, uid: String, name: String,
        routeKey: RouteOccurrenceKey, consumers: SourceTapConsumerFlags
    ) {
        self.slot = slot
        self.uid = uid
        self.name = name
        self.routeKey = routeKey
        self.consumers = consumers
    }

    init(
        slot: Int, uid: String, name: String, routeKey: RouteOccurrenceKey,
        role: SingingAnalysisSourceRole, forwardsPCM: Bool = false
    ) {
        let pitch: SourceTapConsumerFlags =
            role == .voice ? .voicePitch : .backingPitch
        self.init(
            slot: slot, uid: uid, name: name, routeKey: routeKey,
            consumers: forwardsPCM ? pitch.union(.transcription) : pitch)
    }
}

/// A process-wide limit for KTV pitch work.
///
/// Four independent voices covers two duets and keeps the 0.24 ms learned head
/// below one millisecond per analysis frame. One accompaniment is enough by
/// definition: interleaving two recordings cannot produce a valid reference.
struct SingingSourceAdmissionPolicy {
    static let maximumVoiceSources = 4
    static let maximumBackingReferences = 1
    static let maximumRecognitionReferences = 1
    static let maximumInputSources = 64

    struct Result: Sendable, Equatable {
        let admitted: [SingingAnalysisSource]
        let refusedTranscriptions: Int
        let refusedVoices: Int
        let refusedBackingReferences: Int
        let refusedRecognitionReferences: Int
        let refusedInvalidSources: Int
    }

    static func admit(_ sources: [SingingAnalysisSource]) -> Result {
        var admitted: [SingingAnalysisSource] = []
        admitted.reserveCapacity(
            TranscriptionAdmission.maximumSources + maximumVoiceSources
                + maximumBackingReferences)
        var voiceCount = 0
        var backingCount = 0
        var transcriptionCount = 0
        var recognitionCount = 0
        var refusedTranscriptions = 0
        var refusedVoices = 0
        var refusedBacking = 0
        var refusedRecognition = 0
        var refusedInvalid = 0
        var slots = Set<Int>()
        var identifiers = Set<SourceTapUnionPlanner.Identity>()

        for (index, source) in sources.enumerated() {
            guard index < maximumInputSources,
                source.slot >= 0,
                !source.uid.isEmpty,
                !source.consumers.isEmpty,
                slots.insert(source.slot).inserted,
                identifiers.insert(
                    SourceTapUnionPlanner.Identity(
                        uid: source.uid, routeKey: source.routeKey)
                ).inserted
            else {
                refusedInvalid += 1
                continue
            }
            var consumers = source.consumers
            guard
                !(consumers.contains(.voicePitch)
                    && consumers.contains(.backingPitch))
            else {
                refusedInvalid += 1
                continue
            }
            if consumers.contains(.transcription) {
                if transcriptionCount < TranscriptionAdmission.maximumSources {
                    transcriptionCount += 1
                } else {
                    consumers.remove(.transcription)
                    refusedTranscriptions += 1
                }
            }
            if consumers.contains(.voicePitch) {
                if voiceCount < maximumVoiceSources {
                    voiceCount += 1
                } else {
                    consumers.remove(.voicePitch)
                    refusedVoices += 1
                }
            }
            if consumers.contains(.backingPitch) {
                if backingCount < maximumBackingReferences {
                    backingCount += 1
                } else {
                    consumers.remove(.backingPitch)
                    refusedBacking += 1
                }
            }
            if consumers.contains(.musicRecognition) {
                if recognitionCount < maximumRecognitionReferences,
                    consumers.contains(.backingPitch)
                {
                    recognitionCount += 1
                } else {
                    consumers.remove(.musicRecognition)
                    refusedRecognition += 1
                }
            }
            guard !consumers.isEmpty else {
                continue
            }
            admitted.append(
                SingingAnalysisSource(
                    slot: source.slot, uid: source.uid, name: source.name,
                    routeKey: source.routeKey, consumers: consumers))
        }
        return Result(
            admitted: admitted, refusedTranscriptions: refusedTranscriptions,
            refusedVoices: refusedVoices,
            refusedBackingReferences: refusedBacking,
            refusedRecognitionReferences: refusedRecognition,
            refusedInvalidSources: refusedInvalid)
    }
}

/// Immutable values needed to prepare the four-hertz score off MainActor.
struct SingingScoreRequest: Sendable, Equatable {
    let through: Double
    let lyrics: Lyrics?
    let melody: MidiMelody?
    /// The tune read out of the song file itself, when there is no `.mid`.
    ///
    /// Already sampled at `KaraokeScore.referenceInterval`, so it drops into
    /// the same slot the MIDI melody is sampled into and the scorer cannot tell
    /// them apart. Empty when the song is an instrumental, when extraction has
    /// not finished, or when the song is not ours to read.
    let songMelody: [PitchSample]
    /// Changes only when either immutable reference changes.
    let referenceVersion: UInt64
    let key: KeyDetector.Key?
    let refresh: Bool
}

/// One latest request to drain all admitted source rings.
struct SingingAnalysisRequest: Sendable, Equatable {
    let generation: UInt64
    let resetToken: UInt64
    let submittedAtNanoseconds: UInt64
    let sampleRate: Double
    let anchorSeconds: Double
    let advancesTimeline: Bool
    let usesLearnedHead: Bool
    let sources: [SingingAnalysisSource]
    let score: SingingScoreRequest?

    init(
        generation: UInt64, resetToken: UInt64,
        submittedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        sampleRate: Double, anchorSeconds: Double, advancesTimeline: Bool,
        usesLearnedHead: Bool, sources: [SingingAnalysisSource],
        score: SingingScoreRequest? = nil
    ) {
        self.generation = generation
        self.resetToken = resetToken
        self.submittedAtNanoseconds = submittedAtNanoseconds
        self.sampleRate = sampleRate
        self.anchorSeconds = anchorSeconds
        self.advancesTimeline = advancesTimeline
        self.usesLearnedHead = usesLearnedHead
        self.sources = sources
        self.score = score
    }
}

enum SingingScoringReferenceMode: Sendable, Equatable {
    case waiting
    case exact
    case capturedBacking
    /// The tune read out of the song file before it played.
    case extractedSong
    case key
}

struct SingingAnalysedSource: Sendable, Equatable {
    let uid: String
    let name: String
    let role: SingingAnalysisSourceRole
    let hertz: Float
    let comfortableMidi: Double?
    let elapsed: Double
    let score: KaraokeScore
}

/// Generation-fenced fan-out after the sole source-ring consumer.
///
/// The analysis owner is the only code allowed to advance a ring cursor. A
/// transcriber and music recognition therefore receive the same owned block
/// through callbacks installed for the current topology. Revoking the table is
/// synchronous: a late analysis turn can finish, but cannot feed PCM from an
/// old route lifetime into a newly opened speech or recognition session.
final class SourceTapPCMForwarder: @unchecked Sendable {
    static let maximumForwardingSources =
        TranscriptionAdmission.maximumSources
        + SingingSourceAdmissionPolicy.maximumRecognitionReferences
    static let maximumBurstBytes =
        maximumForwardingSources * TranscriptionAdmission.ringFramesPerSource
        * MemoryLayout<Float>.stride

    struct Statistics: Sendable, Equatable {
        let activeEndpoints: Int
        let refusedEndpoints: UInt64
        let forwardedBlocks: UInt64
        let forwardedSamples: UInt64
        let forwardedBytes: UInt64
    }

    static func bytesPerSecond(sampleRate: Double) -> Double {
        Double(maximumForwardingSources) * sampleRate
            * Double(MemoryLayout<Float>.stride)
    }

    struct Identity: Hashable, Sendable {
        let uid: String
        let routeKey: RouteOccurrenceKey
    }

    struct Endpoint: Sendable {
        let identity: Identity
        let consume: @Sendable ([Float], Double) -> Void
    }

    private let lock = NSLock()
    private var generation: UInt64?
    private var consumers: [Identity: @Sendable ([Float], Double) -> Void] = [:]
    private var refusedEndpoints: UInt64 = 0
    private var forwardedBlocks: UInt64 = 0
    private var forwardedSamples: UInt64 = 0

    func replace(generation: UInt64, endpoints: [Endpoint]) {
        var replacement: [Identity: @Sendable ([Float], Double) -> Void] = [:]
        replacement.reserveCapacity(min(endpoints.count, Self.maximumForwardingSources))
        for endpoint in endpoints.prefix(Self.maximumForwardingSources) {
            replacement[endpoint.identity] = endpoint.consume
        }
        lock.withLock {
            self.generation = generation
            consumers = replacement
            refusedEndpoints &+= UInt64(max(0, endpoints.count - replacement.count))
        }
    }

    func invalidate() {
        lock.withLock {
            generation = nil
            consumers = [:]
        }
    }

    func forward(
        generation: UInt64, source: SingingAnalysisSource,
        samples: [Float], sampleRate: Double
    ) {
        let identity = Identity(uid: source.uid, routeKey: source.routeKey)
        let consumer = lock.withLock { () -> (@Sendable ([Float], Double) -> Void)? in
            guard self.generation == generation, let consumer = consumers[identity]
            else { return nil }
            forwardedBlocks &+= 1
            forwardedSamples &+= UInt64(samples.count)
            return consumer
        }
        consumer?(samples, sampleRate)
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(
                activeEndpoints: consumers.count,
                refusedEndpoints: refusedEndpoints,
                forwardedBlocks: forwardedBlocks,
                forwardedSamples: forwardedSamples,
                forwardedBytes: forwardedSamples * UInt64(MemoryLayout<Float>.stride))
        }
    }
}

/// Value-only output which is cheap for MainActor to adopt.
struct SingingAnalysisSnapshot: Sendable, Equatable {
    let generation: UInt64
    let resetToken: UInt64
    let admittedVoiceCount: Int
    let admittedBackingReferenceCount: Int
    let refusedVoiceCount: Int
    let refusedBackingReferenceCount: Int
    let refusedInvalidSourceCount: Int
    let drainedSamples: UInt64
    let ringAvailableSamples: UInt64
    let ringDroppedSamplesTotal: UInt64
    let unavailableTapStatisticsCount: Int
    let scoringReferenceMode: SingingScoringReferenceMode
    let sources: [SingingAnalysedSource]
}

/// Observable proof that analysis work remains bounded.
struct SingingAnalysisWorkerStatistics: Sendable, Equatable {
    let submissions: UInt64
    let coalescedSnapshots: UInt64
    let applications: UInt64
    let publications: UInt64
    let revokedResults: UInt64
    let maximumPendingSnapshots: Int
    let activeApplications: Int
    let maximumActiveApplications: Int
    let maximumBacklogAgeNanoseconds: UInt64
    let mainThreadApplications: UInt64
    let refusedVoiceSources: UInt64
    let refusedBackingReferences: UInt64
    let refusedInvalidSources: UInt64
    let drainedSamples: UInt64
    let pitchTrackerConstructions: UInt64
    let activePitchTrackers: Int
    let maximumActivePitchTrackers: Int
    let latestRingAvailableSamples: UInt64
    let latestRingDroppedSamplesTotal: UInt64
    let unavailableTapStatistics: UInt64
}

/// Drains and analyses source audio on one bounded serial owner.
///
/// A timer submits only an immutable desire to inspect the latest rings. The
/// owner retains one active and one newest request; it initialises Core ML,
/// drains PCM, tracks pitch and prepares scores before publishing a value-only
/// snapshot. No poll creates a Task and MainActor never executes DSP.
final class SingingAnalysisWorker: @unchecked Sendable {
    static let scratchFrameCapacity = 96_000
    static let maximumHistorySamples = 4_096

    struct Operations: Sendable {
        let drain:
            @Sendable (_ slot: Int, _ destination: UnsafeMutablePointer<Float>, _ capacity: Int)
                -> Int
        let tapStatistics: @Sendable (_ slot: Int) -> RoutingEngine.TranscriptTapStatistics?
        let forwardPCM:
            @Sendable (
                _ generation: UInt64, _ source: SingingAnalysisSource,
                _ samples: [Float], _ sampleRate: Double
            )
                -> Void

        init(
            drain:
                @escaping @Sendable (
                    _ slot: Int, _ destination: UnsafeMutablePointer<Float>, _ capacity: Int
                ) -> Int,
            tapStatistics:
                @escaping @Sendable (_ slot: Int) -> RoutingEngine.TranscriptTapStatistics? = {
                    _ in nil
                },
            forwardPCM:
                @escaping @Sendable (
                    _ generation: UInt64, _ source: SingingAnalysisSource,
                    _ samples: [Float], _ sampleRate: Double
                ) -> Void = { _, _, _, _ in }
        ) {
            self.drain = drain
            self.tapStatistics = tapStatistics
            self.forwardPCM = forwardPCM
        }
    }

    private final class Telemetry: @unchecked Sendable {
        struct Values {
            var activeApplications = 0
            var maximumActiveApplications = 0
            var maximumBacklogAgeNanoseconds: UInt64 = 0
            var mainThreadApplications: UInt64 = 0
            var refusedVoiceSources: UInt64 = 0
            var refusedBackingReferences: UInt64 = 0
            var refusedInvalidSources: UInt64 = 0
            var drainedSamples: UInt64 = 0
            var pitchTrackerConstructions: UInt64 = 0
            var activePitchTrackers = 0
            var maximumActivePitchTrackers = 0
            var latestRingAvailableSamples: UInt64 = 0
            var latestRingDroppedSamplesTotal: UInt64 = 0
            var unavailableTapStatistics: UInt64 = 0
        }

        private let lock = NSLock()
        private var values = Values()

        func begin(submittedAt: UInt64) {
            let now = DispatchTime.now().uptimeNanoseconds
            let isMainThread = Thread.isMainThread
            lock.withLock {
                values.activeApplications += 1
                if isMainThread { values.mainThreadApplications &+= 1 }
                values.maximumActiveApplications = max(
                    values.maximumActiveApplications, values.activeApplications)
                let age = now >= submittedAt ? now - submittedAt : 0
                values.maximumBacklogAgeNanoseconds = max(
                    values.maximumBacklogAgeNanoseconds, age)
            }
        }

        func finish(
            admission: SingingSourceAdmissionPolicy.Result,
            drainedSamples: UInt64, ringAvailableSamples: UInt64,
            ringDroppedSamplesTotal: UInt64, unavailableTapStatistics: Int
        ) {
            lock.withLock {
                values.activeApplications -= 1
                values.refusedVoiceSources &+= UInt64(admission.refusedVoices)
                values.refusedBackingReferences &+= UInt64(
                    admission.refusedBackingReferences)
                values.refusedInvalidSources &+= UInt64(admission.refusedInvalidSources)
                values.drainedSamples &+= drainedSamples
                values.latestRingAvailableSamples = ringAvailableSamples
                values.latestRingDroppedSamplesTotal = ringDroppedSamplesTotal
                values.unavailableTapStatistics &+= UInt64(unavailableTapStatistics)
            }
        }

        func replacePitchTrackers(count: Int) {
            lock.withLock {
                values.pitchTrackerConstructions &+= UInt64(count)
                values.activePitchTrackers = count
                values.maximumActivePitchTrackers = max(
                    values.maximumActivePitchTrackers, count)
            }
        }

        var snapshot: Values { lock.withLock { values } }
    }

    private final class Processor: @unchecked Sendable {
        private struct Identity: Equatable {
            let generation: UInt64
            let resetToken: UInt64
            let sampleRate: Double
            let usesLearnedHead: Bool
            let sources: [SingingAnalysisSource]
        }

        private struct ExactConfiguration: Equatable {
            let version: UInt64
            let lyrics: [Lyrics.Line]
        }

        private struct KeyConfiguration: Equatable {
            let key: KeyDetector.Key
            let lyrics: [Lyrics.Line]
        }

        private let operations: Operations
        private let telemetry: Telemetry
        private var identity: Identity?
        private var sources: [SingingAnalysisSource] = []
        private var tracks: [SingerPitch?] = []
        private var scores: [String: KaraokeScore] = [:]
        private var sampledReferenceVersion: UInt64?
        private var sampledReference: [PitchSample] = []
        /// Whether that reference is the declared `.mid` or the measured one.
        /// Both go through the same scorer; only the name shown differs.
        private var sampledReferenceIsExact = false
        private var exactConfigurations: [String: ExactConfiguration] = [:]
        private var exactScorers: [String: KaraokeScore.IncrementalExactScorer] = [:]
        private var keyConfigurations: [String: KeyConfiguration] = [:]
        private var keyScorers: [String: KaraokeScore.IncrementalKeyScorer] = [:]
        private var scratch = [Float](
            repeating: 0, count: SingingAnalysisWorker.scratchFrameCapacity)

        init(operations: Operations, telemetry: Telemetry) {
            self.operations = operations
            self.telemetry = telemetry
        }

        func process(_ request: SingingAnalysisRequest) -> SingingAnalysisSnapshot {
            telemetry.begin(submittedAt: request.submittedAtNanoseconds)
            let admission = SingingSourceAdmissionPolicy.admit(request.sources)
            var drained: UInt64 = 0
            var ringAvailable: UInt64 = 0
            var ringDroppedTotal: UInt64 = 0
            var unavailableTapStatistics = 0
            defer {
                telemetry.finish(
                    admission: admission, drainedSamples: drained,
                    ringAvailableSamples: ringAvailable,
                    ringDroppedSamplesTotal: ringDroppedTotal,
                    unavailableTapStatistics: unavailableTapStatistics)
            }

            let nextIdentity = Identity(
                generation: request.generation, resetToken: request.resetToken,
                sampleRate: request.sampleRate, usesLearnedHead: request.usesLearnedHead,
                sources: admission.admitted)
            if identity != nextIdentity {
                rebuild(for: nextIdentity, anchor: request.anchorSeconds)
            }

            let keepsHistory = request.score != nil
            for case let track? in tracks {
                track.keepsHistory = keepsHistory
                track.historyCapacity = keepsHistory ? Self.historyCapacity : nil
            }

            for index in sources.indices {
                let source = sources[index]
                if let statistics = operations.tapStatistics(source.slot) {
                    ringAvailable &+= UInt64(statistics.available)
                    ringDroppedTotal &+= statistics.dropped
                } else {
                    unavailableTapStatistics += 1
                }
                let taken = scratch.withUnsafeMutableBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return 0 }
                    return max(
                        0,
                        min(
                            buffer.count,
                            operations.drain(
                                source.slot, base, buffer.count)))
                }
                guard taken > 0 else { continue }
                drained &+= UInt64(taken)
                scratch.withUnsafeBufferPointer { buffer in
                    if let track = tracks[index] {
                        track.add(
                            UnsafeBufferPointer(start: buffer.baseAddress, count: taken),
                            advancesTimeline: request.advancesTimeline)
                    }
                    if source.forwardsPCM {
                        operations.forwardPCM(
                            request.generation, source, Array(buffer.prefix(taken)),
                            request.sampleRate)
                    }
                }
            }

            let mode = prepareScores(request.score)
            let analysed: [SingingAnalysedSource] = zip(sources, tracks).compactMap {
                source, track -> SingingAnalysedSource? in
                guard let role = source.role, let track else { return nil }
                return SingingAnalysedSource(
                    uid: source.uid, name: source.name, role: role,
                    hertz: track.hertz, comfortableMidi: track.comfortableMidi,
                    elapsed: track.elapsed,
                    score: scores[source.uid] ?? .none)
            }
            return SingingAnalysisSnapshot(
                generation: request.generation, resetToken: request.resetToken,
                admittedVoiceCount: analysed.count { $0.role == .voice },
                admittedBackingReferenceCount: analysed.count {
                    $0.role == .backingReference
                },
                refusedVoiceCount: admission.refusedVoices,
                refusedBackingReferenceCount: admission.refusedBackingReferences,
                refusedInvalidSourceCount: admission.refusedInvalidSources,
                drainedSamples: drained, ringAvailableSamples: ringAvailable,
                ringDroppedSamplesTotal: ringDroppedTotal,
                unavailableTapStatisticsCount: unavailableTapStatistics,
                scoringReferenceMode: mode, sources: analysed)
        }

        private static var historyCapacity: Int {
            SingingAnalysisWorker.maximumHistorySamples
        }

        private func rebuild(for next: Identity, anchor: Double) {
            identity = next
            sources = next.sources
            tracks = sources.map { source in
                guard source.needsPitch else { return nil }
                return SingerPitch(
                    sampleRate: next.sampleRate,
                    usesLearnedHead: next.usesLearnedHead)
            }
            let trackerCount = tracks.reduce(into: 0) { count, track in
                if track != nil { count += 1 }
            }
            telemetry.replacePitchTrackers(count: trackerCount)
            for case let track? in tracks { track.reset(at: anchor) }
            scores = [:]
            sampledReferenceVersion = nil
            sampledReference = []
            sampledReferenceIsExact = false
            exactConfigurations = [:]
            exactScorers = [:]
            keyConfigurations = [:]
            keyScorers = [:]
        }

        private func prepareScores(
            _ request: SingingScoreRequest?
        ) -> SingingScoringReferenceMode {
            guard let request else {
                scores = [:]
                return .waiting
            }
            let lyrics = shiftedLyrics(request.lyrics)
            if sampledReferenceVersion != request.referenceVersion {
                sampledReferenceVersion = request.referenceVersion
                // The `.mid` first, because it is exact. The song's own
                // melody second, because it is measured rather than declared —
                // but measured from the recording somebody is singing to, which
                // beats the detected key by everything.
                sampledReference =
                    request.melody?.samples(every: KaraokeScore.referenceInterval) ?? []
                sampledReferenceIsExact = !sampledReference.isEmpty
                if sampledReference.isEmpty { sampledReference = request.songMelody }
            }
            guard request.refresh else {
                if !sampledReference.isEmpty {
                    return sampledReferenceIsExact ? .exact : .extractedSong
                }
                if sources.contains(where: { $0.role == .backingReference }) {
                    return .capturedBacking
                }
                return request.key == nil ? .waiting : .key
            }

            let voices = sources.indices.filter { sources[$0].role == .voice }
            let pitchSources = sources.indices.filter { sources[$0].role != nil }
            guard !sampledReference.isEmpty else {
                exactConfigurations = [:]
                exactScorers = [:]
                if let backing = sources.indices.first(where: {
                    sources[$0].role == .backingReference
                }), let backingTrack = tracks[backing], !lyrics.isEmpty {
                    let reference = KaraokeScore.capturedReference(
                        backingTrack.samples, lyrics: lyrics,
                        through: request.through)
                    let referenceStep = backingTrack.sampleInterval
                    if Double(reference.count) * referenceStep >= KaraokeScore.leastSeconds {
                        keyConfigurations = [:]
                        keyScorers = [:]
                        for index in voices {
                            guard let track = tracks[index] else { continue }
                            scores[sources[index].uid] = KaraokeScore.scoreChronological(
                                sung: track.samples,
                                sungStep: track.sampleInterval,
                                reference: reference, referenceStep: referenceStep,
                                lyrics: lyrics, through: request.through)
                        }
                        return .capturedBacking
                    }
                }
                guard let key = request.key else {
                    scores = [:]
                    keyConfigurations = [:]
                    keyScorers = [:]
                    return .waiting
                }
                for index in voices {
                    guard let track = tracks[index] else { continue }
                    let uid = sources[index].uid
                    let configuration = KeyConfiguration(key: key, lyrics: lyrics)
                    if keyConfigurations[uid] != configuration {
                        keyConfigurations[uid] = configuration
                        keyScorers[uid] = KaraokeScore.IncrementalKeyScorer(
                            sungStep: track.sampleInterval,
                            key: key, lyrics: lyrics)
                    }
                    guard var scorer = keyScorers[uid] else { continue }
                    scores[uid] = scorer.update(
                        sung: track.samples,
                        historyStartIndex: track.historyStartIndex,
                        historyGeneration: track.historyGeneration,
                        through: request.through)
                    keyScorers[uid] = scorer
                }
                return .key
            }

            keyConfigurations = [:]
            keyScorers = [:]
            let configuration = ExactConfiguration(
                version: request.referenceVersion, lyrics: lyrics)
            for index in pitchSources {
                guard let track = tracks[index] else { continue }
                let uid = sources[index].uid
                if exactConfigurations[uid] != configuration {
                    exactConfigurations[uid] = configuration
                    exactScorers[uid] = KaraokeScore.IncrementalExactScorer(
                        sungStep: track.sampleInterval,
                        reference: sampledReference,
                        referenceStep: KaraokeScore.referenceInterval,
                        lyrics: lyrics)
                }
                guard var scorer = exactScorers[uid] else { continue }
                scores[uid] = scorer.update(
                    sung: track.samples,
                    historyStartIndex: track.historyStartIndex,
                    historyGeneration: track.historyGeneration,
                    through: request.through)
                exactScorers[uid] = scorer
            }
            return .exact
        }

        private func shiftedLyrics(_ lyrics: Lyrics?) -> [Lyrics.Line] {
            guard let lyrics else { return [] }
            return lyrics.lines.map { line in
                Lyrics.Line(
                    time: line.time - lyrics.offset, text: line.text,
                    singer: line.singer, syllables: line.syllables,
                    translation: line.translation)
            }
        }

        func release(releasingScratch: Bool) {
            identity = nil
            sources = []
            tracks = []
            scores = [:]
            sampledReferenceVersion = nil
            sampledReference = []
            sampledReferenceIsExact = false
            exactConfigurations = [:]
            exactScorers = [:]
            keyConfigurations = [:]
            keyScorers = [:]
            if releasingScratch { scratch = [] }
            telemetry.replacePitchTrackers(count: 0)
        }
    }

    private let telemetry = Telemetry()
    private let lane: LatestExternalWorkLane<SingingAnalysisRequest, SingingAnalysisSnapshot>
    private let processor: Processor
    private let queue: DispatchQueue

    init(
        operations: Operations,
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.singing-analysis", qos: .userInitiated),
        publish: @escaping @MainActor @Sendable (SingingAnalysisSnapshot) -> Void
    ) {
        let telemetry = self.telemetry
        let processor = Processor(operations: operations, telemetry: telemetry)
        self.processor = processor
        self.queue = queue
        lane = LatestExternalWorkLane(
            queue: queue, apply: { processor.process($0) }, publish: publish)
    }

    @discardableResult
    func submit(_ request: SingingAnalysisRequest) -> Bool {
        lane.submit(request)
    }

    func invalidate() {
        lane.invalidate()
        queue.async { [processor] in processor.release(releasingScratch: false) }
    }

    func shutdown() {
        lane.shutdown()
        queue.async { [processor] in processor.release(releasingScratch: true) }
    }

    var statistics: SingingAnalysisWorkerStatistics {
        let lane = lane.statistics
        let values = telemetry.snapshot
        return SingingAnalysisWorkerStatistics(
            submissions: lane.submissions, coalescedSnapshots: lane.coalesced,
            applications: lane.applications, publications: lane.publications,
            revokedResults: lane.revokedResults,
            maximumPendingSnapshots: lane.maximumPending,
            activeApplications: values.activeApplications,
            maximumActiveApplications: values.maximumActiveApplications,
            maximumBacklogAgeNanoseconds: values.maximumBacklogAgeNanoseconds,
            mainThreadApplications: values.mainThreadApplications,
            refusedVoiceSources: values.refusedVoiceSources,
            refusedBackingReferences: values.refusedBackingReferences,
            refusedInvalidSources: values.refusedInvalidSources,
            drainedSamples: values.drainedSamples,
            pitchTrackerConstructions: values.pitchTrackerConstructions,
            activePitchTrackers: values.activePitchTrackers,
            maximumActivePitchTrackers: values.maximumActivePitchTrackers,
            latestRingAvailableSamples: values.latestRingAvailableSamples,
            latestRingDroppedSamplesTotal: values.latestRingDroppedSamplesTotal,
            unavailableTapStatistics: values.unavailableTapStatistics)
    }
}

/// Owns the sole serial executor shared by ring topology and its consumer.
///
/// A Start which replaces rings must never run beside an old-generation drain:
/// the slot number is reusable, so such an overlap can silently label new PCM
/// with the old source UID. Production wiring constructs both workers here and
/// receives the engine's existing executor rather than inventing another owner.
struct SourceTapSingingWorkerPair: Sendable {
    let lifecycle: SourceTapLifecycleWorker
    let analysis: SingingAnalysisWorker

    init(
        lifecycleOperations: SourceTapLifecycleWorker.Operations,
        analysisOperations: SingingAnalysisWorker.Operations,
        queue: DispatchQueue,
        publishLifecycle:
            @escaping @MainActor @Sendable (SourceTapLifecycleSnapshot) -> Void,
        publishAnalysis:
            @escaping @MainActor @Sendable (SingingAnalysisSnapshot) -> Void
    ) {
        lifecycle = SourceTapLifecycleWorker(
            operations: lifecycleOperations, queue: queue,
            publish: publishLifecycle)
        analysis = SingingAnalysisWorker(
            operations: analysisOperations, queue: queue,
            publish: publishAnalysis)
    }

    func shutdown() {
        lifecycle.shutdown()
        analysis.shutdown()
    }
}
