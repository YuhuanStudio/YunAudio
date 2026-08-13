import Foundation

/// Fixed storage for a chronological tail whose oldest samples are replaceable.
///
/// This is deliberately not `Array.removeFirst`: when analysis falls behind,
/// every full ring read used to move almost half a second of samples merely to
/// discard its oldest quarter-second. The write index makes eviction constant
/// time and the two physical segments are borrowed without allocating.
struct SignalAnalysisTail {
    private var storage: [Float] = []
    private(set) var count = 0
    private var first = 0

    var capacity: Int { storage.count }
    var storageBytes: Int { storage.count * MemoryLayout<Float>.stride }

    mutating func allocate(capacity: Int) {
        guard storage.count != capacity else {
            clear()
            return
        }
        storage = capacity > 0 ? [Float](repeating: 0, count: capacity) : []
        count = 0
        first = 0
    }

    mutating func release() {
        storage = []
        count = 0
        first = 0
    }

    mutating func clear() {
        count = 0
        first = 0
    }

    /// Retains the newest `capacity` samples and returns how many were evicted.
    @discardableResult
    mutating func append(_ samples: UnsafePointer<Float>, count incoming: Int) -> Int {
        guard incoming > 0, !storage.isEmpty else { return max(0, incoming) }

        if incoming >= capacity {
            let fixedCapacity = capacity
            let discarded = count + incoming - fixedCapacity
            storage.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.update(
                    from: samples.advanced(by: incoming - fixedCapacity),
                    count: fixedCapacity)
            }
            count = fixedCapacity
            first = 0
            return discarded
        }

        let discarded = max(0, count + incoming - capacity)
        if discarded > 0 {
            first = (first + discarded) % capacity
            count -= discarded
        }

        let write = (first + count) % capacity
        let leading = min(incoming, capacity - write)
        storage.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.advanced(by: write).update(
                from: samples, count: leading)
            if leading < incoming {
                destination.baseAddress!.update(
                    from: samples.advanced(by: leading), count: incoming - leading)
            }
        }
        count += incoming
        return discarded
    }

    /// Borrows a chronological suffix as one or two physical segments.
    func forEachSuffix(
        count requested: Int,
        _ consume: (UnsafePointer<Float>, Int) -> Void
    ) {
        let retained = min(max(0, requested), count)
        guard retained > 0 else { return }
        let suffix = (first + count - retained) % capacity
        let leading = min(retained, capacity - suffix)
        storage.withUnsafeBufferPointer { source in
            consume(source.baseAddress!.advanced(by: suffix), leading)
            if leading < retained {
                consume(source.baseAddress!, retained - leading)
            }
        }
    }

    /// Copies the chronological tail into caller-owned fixed storage.
    func copyAll(into destination: UnsafeMutablePointer<Float>) {
        var offset = 0
        forEachSuffix(count: count) { samples, segmentCount in
            destination.advanced(by: offset).update(from: samples, count: segmentCount)
            offset += segmentCount
        }
    }
}

/// Everything measured off the routed signal that is too expensive to compute
/// on the IO thread.
///
/// Loudness and the spectrum both want the same samples, and both allocate —
/// the loudness meter grows an array of block energies for the whole session,
/// the FFT keeps a window. Neither belongs anywhere near a time-constrained
/// thread. So the IO thread does the one cheap thing it can do safely, folding
/// the output bus to mono into a ring, and a bounded worker does everything
/// else away from MainActor.
public final class SignalAnalyser {

    /// A non-failable analyser still needs a complete, numerically valid
    /// configuration when malformed metadata reaches this public boundary.
    static let fallbackSampleRate = 48_000.0

    /// Evidence that the lossless and latest-only paths are doing different
    /// jobs rather than merely running on a different queue.
    public struct Statistics: Sendable, Equatable {
        /// Every retained ring sample handed to integrated loudness.
        public fileprivate(set) var loudnessSamples = 0
        /// Samples discarded only from replaceable, present-time analysis.
        public fileprivate(set) var coalescedLatestSamples = 0
        /// Bounded batches handed to spectrum, pitch or classification.
        public fileprivate(set) var latestBatches = 0
        public fileprivate(set) var spectrumSamples = 0
        public fileprivate(set) var classifierSamples = 0
        public fileprivate(set) var pitchFrames = 0
    }

    /// One bounded pull from the engine ring.
    public struct DrainProgress: Sendable, Equatable {
        public let samples: Int
        /// True after a short read. A full read may still have audio behind it.
        public let isDrained: Bool
        /// True when the latest-only analysers received the newest retained batch.
        public let processedLatest: Bool
    }

    /// One reading, as the interface consumes it.
    public struct Reading: Sendable, Equatable {
        /// Loudness over the last 400 ms.
        public var momentary: Double
        /// Loudness over the last 3 seconds. The one worth watching while
        /// speaking: momentary jumps around too much to aim with.
        public var shortTerm: Double
        /// Loudness over the whole session, gated. What a platform normalises.
        public var integrated: Double
        /// The spread between the quiet and loud parts, in LU.
        public var range: Double
        /// Sample peak in decibels, since the last reset.
        public var peak: Double
        /// Log-spaced band magnitudes, 0...1.
        public var bands: [Float]
        /// Seconds of audio measured, so the interface can say the integrated
        /// figure is not meaningful yet rather than showing a number that will
        /// move by five units in the next ten seconds.
        public var duration: Double
        /// What the on-device model hears in the signal.
        public var verdict: SoundClassifier.Verdict
        public var verdictConfidence: Double
        /// The model's own label, which is finer than the verdict.
        public var verdictLabel: String
        /// The fundamental of the voice in hertz, or zero when there is no
        /// pitch to find. Silence, breath and a fan all correctly report zero.
        public var pitchHertz: Float

        public init(
            momentary: Double, shortTerm: Double, integrated: Double, range: Double,
            peak: Double, bands: [Float], duration: Double,
            verdict: SoundClassifier.Verdict, verdictConfidence: Double,
            verdictLabel: String, pitchHertz: Float = 0
        ) {
            self.momentary = momentary
            self.shortTerm = shortTerm
            self.integrated = integrated
            self.range = range
            self.peak = peak
            self.bands = bands
            self.duration = duration
            self.verdict = verdict
            self.verdictConfidence = verdictConfidence
            self.verdictLabel = verdictLabel
            self.pitchHertz = pitchHertz
        }

        public static let silent = Reading(
            momentary: -.infinity, shortTerm: -.infinity, integrated: -.infinity,
            range: 0, peak: -.infinity,
            bands: SignalAnalyser.silentBands,
            duration: 0, verdict: .quiet, verdictConfidence: 0, verdictLabel: "",
            pitchHertz: 0)
    }

    /// One copy-on-write zero spectrum shared by readings which did not ask for
    /// an FFT. Auto-levelling reads at the poll rate; allocating 24 floats for
    /// every one of those readings was work whose visible result was always the
    /// same row of zeroes.
    static let silentBands = [Float](repeating: 0, count: SpectrumAnalyser.bandCount)

    private var loudness: LoudnessMeter?
    private var spectrum: SpectrumAnalyser?
    /// Apple's on-device sound model.
    ///
    /// Built on first use and torn down when nothing wants it. That is not
    /// tidiness: the classifier holds a CoreML model and an analysis queue, and
    /// the FFT below owns a transform setup and two window tables. Somebody who
    /// never opens the analysis panel and never switches on levelling should
    /// not be paying for either — a router that quietly loads a neural network
    /// to forward audio between two devices has misunderstood its own job.
    public private(set) var classifier: SoundClassifier?
    private let makeClassifier: (Double) -> SoundClassifier?
    private var tracker: PitchTracker?
    /// The newest tracker frame, never a queue of historical frames.
    private var pitchPending = SignalAnalysisTail()
    /// One contiguous view for the transform, allocated with the tracker.
    private var pitchFrame: [Float] = []
    private var lastPitch: Float = 0

    /// How many silent frames a reading survives before it goes.
    ///
    /// Three, which at this frame size is about 60 ms — long enough to cross a
    /// plosive and short enough that a note nobody is singing any more is not
    /// still on screen when they look.
    private static let pitchHoldFrames = 3
    private var pitchHold = 0
    private let sampleRate: Double
    private var buffer: [Float]
    /// Tail retained while loudness catches up with every sample in the ring.
    ///
    /// Present-time analysers consume this only after the ring is dry. If ten
    /// seconds accumulated while the application was busy, integrated
    /// loudness sees ten seconds and the display sees the newest half-second,
    /// instead of burning through ten seconds of obsolete FFTs on the way.
    private var latestPending = SignalAnalysisTail()
    private let latestCapacity: Int
    /// SoundAnalysis receives one buffer per retained batch. Its batching is
    /// observable model input, so a wrapped tail is linearised once rather than
    /// being split into two independently classified buffers.
    private var classificationFrame: [Float] = []
    /// The retained tail no longer joins continuously onto analyser state from
    /// the previous batch, so their own partial windows must be discarded too.
    private var latestWasCoalesced = false
    public private(set) var statistics = Statistics()
    /// Frames which actually reached loudness, not frames consumed by some
    /// other analyser before loudness was requested.
    private var loudnessMeasuredFrames: Int = 0
    /// A quarter of a second at 96 kHz. The drain runs far more often than
    /// that; the headroom is for the case where the main thread was busy and
    /// several polls' worth piled up.
    static let workingBufferFrames = 24_576

    /// Storage retained solely to drain the analysis ring.
    ///
    /// Internal so the idle-memory contract can assert bytes rather than infer
    /// them from a source declaration.
    var workingBufferBytes: Int {
        buffer.count * MemoryLayout<Float>.stride
    }

    /// Fixed Array elements retained by the loudness meter, excluding Array and
    /// allocator metadata.
    var loudnessStorageBytes: Int {
        loudness == nil ? 0 : LoudnessMeter.retainedArrayBytes(sampleRate: sampleRate)
    }

    /// Maximum history retained for replaceable present-time analysis.
    var latestBufferLimitFrames: Int { latestCapacity }

    /// Storage which must return to zero when no present-time analyser needs it.
    var latestOnlyStorageBytes: Int {
        latestPending.storageBytes + pitchPending.storageBytes
            + (pitchFrame.count + classificationFrame.count) * MemoryLayout<Float>.stride
    }

    /// What the caller currently wants computed. Everything not asked for is
    /// not merely skipped but not allocated.
    public struct Needs: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Loudness only. Cheap, and the levelling and the readout both need it.
        public static let loudness = Needs(rawValue: 1 << 0)
        /// The FFT and its window tables.
        public static let spectrum = Needs(rawValue: 1 << 1)
        /// Apple's sound model.
        public static let classification = Needs(rawValue: 1 << 2)
        /// The fundamental frequency, which is a transform per frame.
        public static let pitch = Needs(rawValue: 1 << 3)
    }

    private var needs: Needs = []

    /// Declares what is wanted. Building and releasing happen here rather than
    /// on every drain.
    public func require(_ wanted: Needs) {
        guard wanted != needs else { return }
        needs = wanted

        if wanted.isEmpty {
            // An idle analyser is kept around so integrated loudness can resume
            // within the same route, but its drain storage has no state worth
            // preserving. Releasing it saves 98,304 bytes whenever every
            // analysis consumer is closed.
            buffer = []
        } else if buffer.isEmpty {
            buffer = [Float](repeating: 0, count: Self.workingBufferFrames)
        }

        // Integrated loudness is session state, so once requested it survives a
        // window closing. It is nevertheless absent from a menu-bar-only route
        // and from ducking, whose classifier never reads it: 3,033,856 bytes at
        // 48 kHz should not be a prerequisite for recognising speech.
        if wanted.contains(.loudness), loudness == nil {
            loudness = LoudnessMeter(sampleRate: sampleRate)
        }

        if wanted.contains(.spectrum) {
            if spectrum == nil { spectrum = SpectrumAnalyser(sampleRate: sampleRate) }
        } else {
            spectrum = nil
        }

        if wanted.contains(.classification) {
            if classifier == nil { classifier = makeClassifier(sampleRate) }
            if classifier != nil, classificationFrame.count != latestCapacity {
                classificationFrame = [Float](repeating: 0, count: latestCapacity)
            } else if classifier == nil {
                classificationFrame = []
            }
        } else {
            classifier = nil
            classificationFrame = []
        }

        if wanted.contains(.pitch) {
            if tracker == nil { tracker = PitchTracker(sampleRate: sampleRate) }
            if pitchPending.capacity != PitchTracker.frameSize {
                pitchPending.allocate(capacity: PitchTracker.frameSize)
            }
            if pitchFrame.count != PitchTracker.frameSize {
                pitchFrame = [Float](repeating: 0, count: PitchTracker.frameSize)
            }
        } else {
            tracker = nil
            pitchPending.release()
            pitchFrame = []
            lastPitch = 0
            pitchHold = 0
        }

        if wanted.intersection([.spectrum, .classification, .pitch]).isEmpty {
            latestPending.release()
            latestWasCoalesced = false
        } else if latestPending.capacity != latestCapacity {
            latestPending.allocate(capacity: latestCapacity)
        }
    }

    public convenience init(sampleRate: Double) {
        self.init(sampleRate: sampleRate, makeClassifier: SoundClassifier.init(sampleRate:))
    }

    init(
        sampleRate: Double,
        makeClassifier: @escaping (Double) -> SoundClassifier?
    ) {
        let admittedRate =
            AudioProcessingContract.supports(sampleRate: sampleRate)
            ? sampleRate : Self.fallbackSampleRate
        self.sampleRate = admittedRate
        self.makeClassifier = makeClassifier
        latestCapacity = max(
            SpectrumAnalyser.windowSize,
            PitchTracker.frameSize,
            Int(admittedRate * 0.5))
        loudness = nil
        buffer = []
    }

    /// Pulls until the ring is dry for direct and legacy callers.
    ///
    /// The background worker uses `drainStep` so each control request gets a
    /// chance between chunks. Both paths preserve every sample they receive;
    /// ring overflow is reported separately by `SignalAnalysisWorker`.
    public func drain(from engine: RoutingEngine) {
        while true {
            let progress = drainStep(from: engine)
            if progress.isDrained { return }
        }
    }

    /// Takes at most one fixed buffer from the engine.
    ///
    /// A full read deliberately does not run FFT, pitch or classification: it
    /// says there may be a newer block waiting. Loudness consumes it now, the
    /// replaceable analysers retain only its bounded tail, and a later short
    /// read tells them that tail really is the newest one.
    @discardableResult
    public func drainStep(from engine: RoutingEngine) -> DrainProgress {
        drainStep { destination, capacity in
            engine.drainAnalysis(into: destination, capacity: capacity)
        }
    }

    @discardableResult
    func drainStep(
        _ take: (UnsafeMutablePointer<Float>, Int) -> Int
    ) -> DrainProgress {
        // `drainStep` can be called independently of the worker's idle gate.
        // An empty Array has no base address to force-unwrap, and an idle
        // analyser has deliberately released this buffer.
        guard !buffer.isEmpty else {
            return DrainProgress(samples: 0, isDrained: true, processedLatest: false)
        }
        let taken = buffer.withUnsafeMutableBufferPointer { pointer in
            take(pointer.baseAddress!, pointer.count)
        }
        guard taken >= 0, taken <= buffer.count else {
            return DrainProgress(samples: 0, isDrained: true, processedLatest: false)
        }

        if taken > 0 {
            buffer.withUnsafeBufferPointer { pointer in
                addLossless(pointer.baseAddress!, count: taken)
                retainLatest(pointer.baseAddress!, count: taken)
            }
        }
        let isDrained = taken < buffer.count
        let processedLatest = isDrained ? processLatest() : false
        return DrainProgress(
            samples: taken, isDrained: isDrained, processedLatest: processedLatest)
    }

    private func addLossless(_ samples: UnsafePointer<Float>, count: Int) {
        if loudness != nil {
            loudness?.add(samples, count: count)
            loudnessMeasuredFrames += count
            statistics.loudnessSamples += count
        }
    }

    private func retainLatest(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0,
            !needs.intersection([.spectrum, .classification, .pitch]).isEmpty
        else { return }

        let discarded = latestPending.append(samples, count: count)
        if discarded > 0 {
            statistics.coalescedLatestSamples += discarded
            latestWasCoalesced = true
        }
    }

    @discardableResult
    private func processLatest() -> Bool {
        guard latestPending.count > 0 else { return false }
        statistics.latestBatches += 1
        if latestWasCoalesced {
            // Joining a fresh tail onto half a stale FFT or classifier window
            // would still spend work on history and could report a hybrid that
            // never existed. Keep the last complete answer only until the new
            // tail replaces it.
            spectrum?.reset()
            classifier?.reset()
            pitchPending.clear()
        }
        let latestCount = latestPending.count
        if let spectrum {
            let count = min(latestCount, SpectrumAnalyser.windowSize)
            latestPending.forEachSuffix(count: count) { samples, segmentCount in
                spectrum.add(samples, count: segmentCount)
            }
            statistics.spectrumSamples += count
        }
        if let classifier {
            classificationFrame.withUnsafeMutableBufferPointer { frame in
                latestPending.copyAll(into: frame.baseAddress!)
                classifier.add(frame.baseAddress!, count: latestCount)
            }
            statistics.classifierSamples += latestCount
        }
        if tracker != nil {
            latestPending.forEachSuffix(count: latestCount) { samples, segmentCount in
                pitchPending.append(samples, count: segmentCount)
            }
            finishLatestPitch()
        }
        latestPending.clear()
        latestWasCoalesced = false
        return true
    }

    private func finishLatestPitch() {
        guard pitchPending.count == PitchTracker.frameSize, let tracker else { return }

        let found = pitchFrame.withUnsafeMutableBufferPointer { frame in
            pitchPending.copyAll(into: frame.baseAddress!)
            return tracker.track(
                frame: UnsafeBufferPointer(start: frame.baseAddress!, count: frame.count))
        }
        statistics.pitchFrames += 1
        // Held through a frame or two of consonant rather than dropping to
        // nothing. Held, not faded: halving a frequency invents lower notes.
        if found > 0 {
            lastPitch = found
            pitchHold = Self.pitchHoldFrames
        } else if pitchHold > 0 {
            pitchHold -= 1
        } else {
            lastPitch = 0
        }
    }

    /// Deterministic control-thread feed for lifecycle tests.
    ///
    /// The production path differs only in where the same contiguous samples
    /// came from; constructing a CoreAudio graph to verify a frame counter
    /// would make a memory test depend on hardware.
    func addForTesting(_ samples: [Float]) {
        samples.withUnsafeBufferPointer {
            guard let base = $0.baseAddress else { return }
            addLossless(base, count: $0.count)
            retainLatest(base, count: $0.count)
        }
        _ = processLatest()
    }

    /// True when nothing at all is wanted, so the drain can skip the ring
    /// entirely rather than copying audio nobody will look at.
    public var isIdle: Bool { needs.isEmpty }

    /// The current chroma, when the spectrum is being computed at all.
    ///
    /// Not part of `Reading`: a chroma is twelve doubles and the reading is
    /// rebuilt on every poll, twenty times a second, for an interface that
    /// wants this once a second at most.
    public func chroma() -> [Double]? { spectrum?.chroma(sampleRate: sampleRate) }

    public func reading() -> Reading {
        Reading(
            momentary: loudness?.momentary ?? -.infinity,
            shortTerm: loudness?.shortTerm ?? -.infinity,
            integrated: loudness?.integrated ?? -.infinity,
            range: loudness?.range ?? 0,
            peak: loudness?.peak ?? -.infinity,
            bands: spectrum?.bands ?? Self.silentBands,
            duration: Double(loudnessMeasuredFrames) / sampleRate,
            verdict: classifier?.verdict ?? .quiet,
            verdictConfidence: classifier?.confidence ?? 0,
            verdictLabel: classifier?.label ?? "",
            pitchHertz: lastPitch)
    }

    /// Starts the integrated measurement over. Bound to a button, because an
    /// integrated figure that has been running since the application launched
    /// answers a question nobody asked — the useful one is "how loud was I in
    /// the take I just did".
    public func reset() {
        loudness?.reset()
        spectrum?.reset()
        classifier?.reset()
        latestPending.clear()
        latestWasCoalesced = false
        pitchPending.clear()
        lastPitch = 0
        pitchHold = 0
        loudnessMeasuredFrames = 0
        statistics = Statistics()
    }
}
