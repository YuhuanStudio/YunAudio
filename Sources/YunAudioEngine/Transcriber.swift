import AVFoundation
import Foundation
import Speech

/// Builds the caller-owned side of `AnalyzerInputConverter` with one format per
/// stable route rate.
///
/// The PCM buffer itself is deliberately not reused. `convert` returns
/// `AnalyzerInput` values which remain queued after the call, and Speech does
/// not document that it releases or copies the source buffer before returning.
/// Rewriting one shared buffer could therefore rewrite audio the analyser has
/// not consumed. The counters keep that remaining allocation visible until the
/// API provides an ownership boundary a safe pool can use.
final class TranscriptionPCMBufferBuilder {
    struct Statistics: Sendable, Equatable {
        let formatAllocations: Int
        let bufferAllocations: Int
        let copiedFrames: UInt64
        let retainsFormat: Bool
    }

    private var format: AVAudioFormat?
    private var sampleRate: Double = 0
    private var formatAllocations = 0
    private var bufferAllocations = 0
    private var copiedFrames: UInt64 = 0

    func make(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard sampleRate.isFinite, sampleRate > 0, !samples.isEmpty,
            samples.count <= Int(UInt32.max)
        else { return nil }

        if format == nil || self.sampleRate != sampleRate {
            guard
                let replacement = AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate, channels: 1)
            else { return nil }
            format = replacement
            self.sampleRate = sampleRate
            formatAllocations += 1
        }
        guard let format,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            channel[0].update(from: $0.baseAddress!, count: samples.count)
        }
        bufferAllocations += 1
        copiedFrames &+= UInt64(samples.count)
        return buffer
    }

    func beginSession() {
        format = nil
        sampleRate = 0
        formatAllocations = 0
        bufferAllocations = 0
        copiedFrames = 0
    }

    /// Releases session storage but leaves its measurements readable.
    func releaseStorage() {
        format = nil
        sampleRate = 0
    }

    var statistics: Statistics {
        Statistics(
            formatAllocations: formatAllocations,
            bufferAllocations: bufferAllocations,
            copiedFrames: copiedFrames,
            retainsFormat: format != nil)
    }
}

/// A bounded hand-off from a caller such as MainActor to one conversion lane.
///
/// The caller retains an already-owned Swift Array in a preallocated batch
/// ring. PCM allocation, copying and `AnalyzerInputConverter.convert` happen on
/// the serial utility queue. Each work item converts one batch before yielding,
/// so a session barrier waits behind at most the conversion already in flight.
final class TranscriptionInputWorker: @unchecked Sendable {
    static let maximumBacklogFrames = 192_000
    static let maximumBacklogSeconds = 2.0
    static let maximumBacklogBatches = 512
    static let maximumAnalyzerInputBacklog = 32

    struct ProcessingResult: Sendable {
        let converted: Bool
        let formatAllocations: Int
        let bufferAllocations: Int
        let copiedFrames: UInt64
        let retainsFormat: Bool

        static let dropped = ProcessingResult(
            converted: false,
            formatAllocations: 0,
            bufferAllocations: 0,
            copiedFrames: 0,
            retainsFormat: false)
    }

    struct Session: @unchecked Sendable {
        let converterCount: Int
        let process: @Sendable ([Float], Double) -> ProcessingResult
        let finish: @Sendable () -> Void

        init(
            converterCount: Int = 1,
            process: @escaping @Sendable ([Float], Double) -> ProcessingResult,
            finish: @escaping @Sendable () -> Void = {}
        ) {
            self.converterCount = converterCount
            self.process = process
            self.finish = finish
        }
    }

    struct Statistics: Sendable, Equatable {
        let converterInstallations: Int
        let activeConverters: Int
        let formatAllocations: Int
        let retainedFormats: Int
        let bufferAllocations: Int
        let copiedFrames: UInt64
        let submittedFrames: UInt64
        let convertedFrames: UInt64
        let droppedFrames: UInt64
        let backlogFrames: Int
        let maximumBacklogFrames: Int
        let backlogSeconds: Double
        let maximumBacklogSeconds: Double
        let scheduledDrainWorkItems: Int
        let maximumScheduledDrainWorkItems: Int
        let converterTurns: UInt64
        let mainThreadConverterTurns: UInt64
        let longestConverterMilliseconds: Double
    }

    private struct Batch: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let duration: Double
        let generation: UInt64
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var slots = [Batch?](repeating: nil, count: maximumBacklogBatches)
    private var head = 0
    private var tail = 0
    private var queuedBatches = 0
    private var outstandingBatches = 0
    private var outstandingFrames = 0
    private var outstandingSeconds: Double = 0
    private var acceptingGeneration: UInt64?
    private var nextGeneration: UInt64 = 0
    private var drainIsScheduled = false

    // Measurements below are protected by `lock` and reset for each session.
    private var converterInstallations = 0
    private var activeConverters = 0
    private var formatAllocations = 0
    private var retainedFormats = 0
    private var bufferAllocations = 0
    private var copiedFrames: UInt64 = 0
    private var submittedFrames: UInt64 = 0
    private var convertedFrames: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var maximumObservedBacklogFrames = 0
    private var maximumObservedBacklogSeconds: Double = 0
    private var maximumScheduledDrainWorkItems = 0
    private var converterTurns: UInt64 = 0
    private var mainThreadConverterTurns: UInt64 = 0
    private var longestConverterMilliseconds: Double = 0
    private var firstConvertedAt: Double?

    // Queue-owned. A generation is part of every batch so an obsolete session
    // can never feed the converter installed by its successor.
    private var workerGeneration: UInt64 = 0
    private var session: Session?

    init(label: String = "com.yuhuanstudio.yunaudio.transcription-input") {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    func open(session replacement: Session) async {
        await withCheckedContinuation { continuation in
            // Reserve the generation and enqueue its barrier under the same
            // lock. Two concurrent open/close callers must reach the worker in
            // the order in which admission changed; otherwise an older open
            // could be enqueued last and make the generation go backwards.
            lock.lock()
            nextGeneration &+= 1
            let generation = nextGeneration
            acceptingGeneration = nil
            dropQueuedBacklogLocked(countAsDropped: true)
            queue.async { [self] in
                session?.finish()
                session = replacement
                workerGeneration = generation

                lock.lock()
                clearBacklogLocked(countAsDropped: true)
                resetStatisticsLocked(converterCount: replacement.converterCount)
                acceptingGeneration = generation
                lock.unlock()
                continuation.resume()
            }
            lock.unlock()
        }
    }

    /// Retains a batch reference and returns; no PCM object or sample copy is
    /// made on the submitting thread.
    func submit(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0 else { return }
        let duration = Double(samples.count) / sampleRate
        guard duration.isFinite, duration > 0 else { return }

        lock.lock()
        submittedFrames &+= UInt64(samples.count)
        guard let generation = acceptingGeneration,
            samples.count <= Self.maximumBacklogFrames,
            outstandingBatches < Self.maximumBacklogBatches,
            outstandingFrames <= Self.maximumBacklogFrames - samples.count,
            outstandingSeconds + duration <= Self.maximumBacklogSeconds
        else {
            droppedFrames &+= UInt64(samples.count)
            lock.unlock()
            return
        }

        slots[tail] = Batch(
            samples: samples,
            sampleRate: sampleRate,
            duration: duration,
            generation: generation)
        tail = (tail + 1) % slots.count
        queuedBatches += 1
        outstandingBatches += 1
        outstandingFrames += samples.count
        outstandingSeconds += duration
        maximumObservedBacklogFrames = max(
            maximumObservedBacklogFrames, outstandingFrames)
        maximumObservedBacklogSeconds = max(
            maximumObservedBacklogSeconds, outstandingSeconds)
        scheduleDrainLocked()
        lock.unlock()
    }

    /// Stops admission immediately, then waits behind the sole drain item. On
    /// return every accepted frame was converted or counted as dropped, and no
    /// converter, PCM format or queued Array remains owned by the worker.
    func close() async {
        await withCheckedContinuation { continuation in
            // Keep the admission transition and barrier ordering indivisible
            // for the same reason as `open(session:)` above.
            lock.lock()
            acceptingGeneration = nil
            dropQueuedBacklogLocked(countAsDropped: true)
            queue.async { [self] in
                session?.finish()
                session = nil
                workerGeneration = 0

                lock.lock()
                clearBacklogLocked(countAsDropped: true)
                activeConverters = 0
                retainedFormats = 0
                drainIsScheduled = false
                lock.unlock()
                continuation.resume()
            }
            lock.unlock()
        }
    }

    var openedAt: Double? {
        lock.withLock { firstConvertedAt }
    }

    /// Exposes the admission edge independently of the utility-queue barrier.
    /// Tests use it to prove close and replacement stop accepting input before
    /// an in-flight converter is allowed to return.
    var isAcceptingInput: Bool {
        lock.withLock { acceptingGeneration != nil }
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(
                converterInstallations: converterInstallations,
                activeConverters: activeConverters,
                formatAllocations: formatAllocations,
                retainedFormats: retainedFormats,
                bufferAllocations: bufferAllocations,
                copiedFrames: copiedFrames,
                submittedFrames: submittedFrames,
                convertedFrames: convertedFrames,
                droppedFrames: droppedFrames,
                backlogFrames: outstandingFrames,
                maximumBacklogFrames: maximumObservedBacklogFrames,
                backlogSeconds: outstandingSeconds,
                maximumBacklogSeconds: maximumObservedBacklogSeconds,
                scheduledDrainWorkItems: drainIsScheduled ? 1 : 0,
                maximumScheduledDrainWorkItems: maximumScheduledDrainWorkItems,
                converterTurns: converterTurns,
                mainThreadConverterTurns: mainThreadConverterTurns,
                longestConverterMilliseconds: longestConverterMilliseconds)
        }
    }

    private func scheduleDrainLocked() {
        guard queuedBatches > 0, !drainIsScheduled else { return }
        drainIsScheduled = true
        maximumScheduledDrainWorkItems = max(maximumScheduledDrainWorkItems, 1)
        queue.async { [weak self] in self?.drainOneBatch() }
    }

    /// Converts one batch, then yields to the serial queue. An open or close
    /// barrier can therefore wait behind at most the conversion already in
    /// flight, never behind the complete two-second backlog.
    private func drainOneBatch() {
        lock.lock()
        guard queuedBatches > 0, let batch = slots[head] else {
            drainIsScheduled = false
            lock.unlock()
            return
        }
        slots[head] = nil
        head = (head + 1) % slots.count
        queuedBatches -= 1
        lock.unlock()

        let began = DispatchTime.now().uptimeNanoseconds
        let beganAt = Date().timeIntervalSince1970
        let ranOnMainThread = Thread.isMainThread
        let result: ProcessingResult
        let invokedProcessor: Bool
        if batch.generation == workerGeneration, let session {
            result = session.process(batch.samples, batch.sampleRate)
            invokedProcessor = true
        } else {
            result = .dropped
            invokedProcessor = false
        }
        let elapsed = Self.milliseconds(since: began)

        lock.lock()
        outstandingBatches -= 1
        outstandingFrames -= batch.samples.count
        outstandingSeconds -= batch.duration
        if outstandingBatches == 0 {
            outstandingFrames = 0
            outstandingSeconds = 0
        }
        if invokedProcessor {
            converterTurns &+= 1
            if ranOnMainThread { mainThreadConverterTurns &+= 1 }
            longestConverterMilliseconds = max(longestConverterMilliseconds, elapsed)
        }
        formatAllocations += result.formatAllocations
        retainedFormats = result.retainsFormat ? 1 : 0
        bufferAllocations += result.bufferAllocations
        copiedFrames &+= result.copiedFrames
        if result.converted {
            convertedFrames &+= UInt64(batch.samples.count)
            if firstConvertedAt == nil { firstConvertedAt = beganAt }
        } else {
            droppedFrames &+= UInt64(batch.samples.count)
        }
        // Mark this quantum complete before scheduling another. Admission or a
        // barrier which wins the lock here can clear the queue first; an
        // already-scheduled empty quantum costs no conversion.
        drainIsScheduled = false
        scheduleDrainLocked()
        lock.unlock()
    }

    /// Drops only queued batches. The batch already executing remains in the
    /// outstanding totals until its one conversion finishes on the worker.
    private func dropQueuedBacklogLocked(countAsDropped: Bool) {
        var removedBatches = 0
        var removedFrames = 0
        var removedSeconds: Double = 0
        while removedBatches < queuedBatches {
            let index = (head + removedBatches) % slots.count
            if let batch = slots[index] {
                removedFrames += batch.samples.count
                removedSeconds += batch.duration
                slots[index] = nil
            }
            removedBatches += 1
        }
        if countAsDropped { droppedFrames &+= UInt64(removedFrames) }
        outstandingBatches -= removedBatches
        outstandingFrames -= removedFrames
        outstandingSeconds -= removedSeconds
        queuedBatches = 0
        head = 0
        tail = 0
        if outstandingBatches == 0 {
            outstandingFrames = 0
            outstandingSeconds = 0
        }
    }

    private func clearBacklogLocked(countAsDropped: Bool) {
        if countAsDropped { droppedFrames &+= UInt64(max(0, outstandingFrames)) }
        for index in slots.indices { slots[index] = nil }
        head = 0
        tail = 0
        queuedBatches = 0
        outstandingBatches = 0
        outstandingFrames = 0
        outstandingSeconds = 0
    }

    private func resetStatisticsLocked(converterCount: Int) {
        converterInstallations = converterCount
        activeConverters = converterCount
        formatAllocations = 0
        retainedFormats = 0
        bufferAllocations = 0
        copiedFrames = 0
        submittedFrames = 0
        convertedFrames = 0
        droppedFrames = 0
        maximumObservedBacklogFrames = 0
        maximumObservedBacklogSeconds = 0
        maximumScheduledDrainWorkItems = 0
        converterTurns = 0
        mainThreadConverterTurns = 0
        longestConverterMilliseconds = 0
        firstConvertedAt = nil
    }

    private static func milliseconds(since started: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        return Double(now >= started ? now - started : 0) / 1_000_000
    }
}

/// Live transcription of one source, on the device.
///
/// Every product in this space that transcribes a conversation has the same
/// hard problem, and every one of them hedges publicly about it: knowing who
/// said what. Acoustic diarization guesses from the sound, and it is wrong
/// often enough that the guessing is the feature people complain about.
///
/// This application does not have that problem, and not because it solved it —
/// because of how it is built. The microphone is one source and every captured
/// application is its own tap, already separated before anything reaches a
/// model. Attribution is not inferred, it is the wiring. One transcriber per
/// source and the speaker label is free and exact.
///
/// `SpeechTranscriber` is macOS 26's own model, designed for sustained
/// multi-hour transcription rather than short queries, and it runs on the
/// device: no per-minute billing, no upload, no key. What it costs is a model
/// download the first time a language is used, which the system manages.
public actor Transcriber {

    struct ResourceStatistics: Sendable, Equatable {
        let converterInstallations: Int
        let activeConverters: Int
        let formatAllocations: Int
        let retainedFormats: Int
        let bufferAllocations: Int
        let copiedFrames: UInt64
        let submittedFrames: UInt64
        let convertedFrames: UInt64
        let droppedFrames: UInt64
        let backlogFrames: Int
        let maximumBacklogFrames: Int
        let backlogSeconds: Double
        let maximumBacklogSeconds: Double
        let scheduledDrainWorkItems: Int
        let maximumScheduledDrainWorkItems: Int
        let converterTurns: UInt64
        let mainThreadConverterTurns: UInt64
        let longestConverterMilliseconds: Double
    }

    /// A finished piece of transcript, attributed.
    public struct Line: Sendable, Identifiable, Equatable {
        public let id: UUID
        /// Which source said it, by the name the mixer shows.
        public let speaker: String
        public let text: String
        /// Seconds from the start of the session — the instant handed to
        /// `start(now:)`, which every source is given the same value of. That
        /// is what makes merging several sources into one conversation
        /// meaningful; see `sessionOffset` for what it took to make it true.
        public let start: Double
        public let duration: Double

        public init(
            id: UUID = UUID(), speaker: String, text: String, start: Double,
            duration: Double
        ) {
            self.id = id
            self.speaker = speaker
            self.text = text
            self.start = start
            self.duration = duration
        }
    }

    /// Why transcription is not available, when it is not.
    ///
    /// A case rather than a sentence, because the sentence belongs to the
    /// interface: half of this application's users read Chinese, and an
    /// English string handed up from the engine would arrive in a window where
    /// everything around it had been translated.
    public enum Unavailable: Error, Sendable, Equatable {
        /// The system is older than the transcription path needs.
        case needsNewerSystem
        /// The model is not on this system and could not be fetched.
        case noModel
        /// No transcriber supports this language.
        case unsupportedLanguage(String)
        case failed(String)
    }

    /// Nonisolated because it never changes and the interface labels lines
    /// with it constantly; making every label read cross an actor boundary
    /// would be a hop for a string that was fixed at construction.
    public nonisolated let speaker: String
    private let locale: Locale
    /// Held as `AnyObject` for the reason the converter below is, one release
    /// further down: `SpeechAnalyzer` and `SpeechTranscriber` are macOS 26, and
    /// a stored property of a 26-only type would force the whole actor to 26 —
    /// and with it every property holding one, until the router could not name
    /// a transcriber on macOS 14 even to say the feature is not there.
    ///
    /// The casts back happen inside the availability guards, where the concrete
    /// types are legal and the compiler still checks every use of them.
    private var analyser: AnyObject?
    private var transcriber: AnyObject?
    /// The framework's own converter into whatever format the model wants.
    ///
    /// It knows what the model was trained at, which is not the rate the router
    /// runs at — handing the model 48 kHz directly produces nonsense. Doing the
    /// conversion by hand with an `AVAudioConverter` works and was the first
    /// version of this file; this is the one the framework offers, and it
    /// cannot disagree with the model about chunking the way a hand-rolled one
    /// silently can.
    ///
    /// `AnalyzerInputConverter` arrived in macOS 27, which is why transcription
    /// needs 27 while the rest of the application needs 26. Held as `AnyObject`
    /// rather than its own type for exactly one reason: a stored property of a
    /// 27-only type would force the whole actor to 27, and then so would every
    /// property holding one — the router could not so much as name a
    /// transcriber on macOS 26, let alone say the feature is unavailable there.
    /// The cast back happens inside the availability guards.
    private let feed = Feed()
    private var resultsTask: Task<Void, Never>?
    /// When the session began, on the caller's clock. Every source of one
    /// session is given the same value, which is what makes `Line.start`
    /// comparable across them.
    private var startedAt: Double = 0
    private var isRunning = false
    /// Whether final lines are also retained by this actor.
    ///
    /// The application consumes `onLine` into its bounded paged store. Keeping
    /// the same meeting here would give it a second, unbounded lifetime. The
    /// default preserves the standalone API and existing clients.
    private let retainsLines: Bool
    /// Delivers only the line that was just finalised.
    ///
    /// The interface used to poll every transcriber twenty times a second,
    /// copy every line said so far and sort the whole conversation even when
    /// nobody had spoken. A transcript is an event stream, not a meter. The
    /// callback lets its owner do work once per finished sentence instead.
    private let onLine: (@Sendable (Line) -> Void)?

    /// Lines finished so far. Volatile partial results are deliberately not
    /// kept: a transcript that rewrites itself as somebody speaks is unreadable
    /// scrolling past, and the finalised text is what anybody wants afterwards.
    public private(set) var lines: [Line] = []

    public init(
        speaker: String, locale: Locale = Locale.current,
        retainsLines: Bool = true,
        onLine: (@Sendable (Line) -> Void)? = nil
    ) {
        self.speaker = speaker
        self.locale = locale
        self.retainsLines = retainsLines
        self.onLine = onLine
    }

    /// True when this system can transcribe at all.
    ///
    /// Two separate conditions and both matter. The model has to be available,
    /// and the system has to be new enough for the converter that feeds it —
    /// so on macOS 26 the feature is reported unavailable rather than half
    /// working, which is the honest answer and the one the interface can act
    /// on.
    public nonisolated static var isSupported: Bool {
        guard #available(macOS 27, *) else { return false }
        return SpeechTranscriber.isAvailable
    }

    /// Why it is unavailable, when it is, so the interface can say something
    /// better than "unavailable".
    public nonisolated static var unsupportedReason: Unavailable? {
        guard #available(macOS 27, *) else { return .needsNewerSystem }
        return SpeechTranscriber.isAvailable ? nil : .noModel
    }

    /// The languages that can be transcribed without a download, and those that
    /// can with one.
    public static func languages() async -> (installed: [Locale], supported: [Locale]) {
        guard #available(macOS 26, *) else { return ([], []) }
        async let installed = SpeechTranscriber.installedLocales
        async let supported = SpeechTranscriber.supportedLocales
        return (await installed, await supported)
    }

    /// Starts transcribing. The caller then feeds it audio.
    ///
    /// - Parameter now: When the session began, as a
    ///   `Date().timeIntervalSince1970`. Every line's `start` is measured from
    ///   it, so give every source of one session the same value or their
    ///   transcripts cannot be merged.
    /// - Throws: `Unavailable` describing which of the three ways it can fail
    ///   happened, because "transcription is unavailable" is not something
    ///   anybody can act on.
    public func start(now: Double) async throws {
        guard !isRunning else { return }
        guard #available(macOS 27, *) else { throw Unavailable.needsNewerSystem }
        guard SpeechTranscriber.isAvailable else { throw Unavailable.noModel }

        // The language actually offered may not be the one asked for: a system
        // set to en_GB is served by whatever variant the model ships.
        guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else {
            throw Unavailable.unsupportedLanguage(locale.identifier)
        }

        let transcriber = SpeechTranscriber(locale: matched, preset: .transcription)
        self.transcriber = transcriber

        // The model is fetched on demand the first time a language is used.
        // Reported rather than waited on silently — it is tens of megabytes and
        // somebody pressing a button deserves to know why nothing happened yet.
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber])
                {
                    try await request.downloadAndInstall()
                }
            } catch {
                self.transcriber = nil
                throw Unavailable.failed(error.localizedDescription)
            }
        }

        // Compiled out under `YUNAUDIO_NO_SPEECH_ANALYZER`, which exists for
        // exactly one purpose: `AnalyzerInputConverter` is macOS 27 API, so
        // naming it made the whole project refuse to build under the previous
        // Xcode — and that made it impossible to run the one comparison that
        // could tell whether a crash came from the toolchain or from us. A flag
        // nobody ships is cheaper than an unanswerable question.
        #if YUNAUDIO_NO_SPEECH_ANALYZER
            self.transcriber = nil
            throw Unavailable.failed("built without the speech analyser")
        #else
            let converter: AnyObject?
            do {
                converter = try await AnalyzerInputConverter.converter(
                    compatibleWith: [transcriber])
            } catch {
                self.transcriber = nil
                throw Unavailable.failed(error.localizedDescription)
            }

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
                bufferingPolicy: .bufferingOldest(
                    TranscriptionInputWorker.maximumAnalyzerInputBacklog))
            let analyser = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])
            self.analyser = analyser
            await feed.open(converter: converter, continuation: continuation)

            startedAt = now
            isRunning = true

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        await self?.append(result)
                    }
                } catch {
                    // The stream ending is how it stops; nothing to report.
                }
            }
        #endif
    }

    @available(macOS 26, *)
    private func append(_ result: SpeechTranscriber.Result) {
        guard result.isFinal else { return }
        let text = String(result.text.characters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        record(
            Line(
                speaker: speaker,
                text: text,
                start: sessionOffset + result.range.start.seconds,
                duration: result.range.duration.seconds))
    }

    private func record(_ line: Line) {
        if retainsLines { lines.append(line) }
        onLine?(line)
    }

    /// Seconds between the session beginning and this source's first audio.
    ///
    /// The analyser's timeline and the session's are two different clocks and
    /// were silently taken for one. Measured here, against real speech:
    ///
    /// - Three seconds of digital silence in front of a sentence read back as
    ///   `range.start` 2.7, so the analyser's zero is the first buffer it
    ///   accepted rather than anything to do with the session.
    /// - Three transcribers started one after another — the shape
    ///   `startTranscribing` has — opened 69, 73 and 78 ms into the session,
    ///   because audio fed before a transcriber's model is open is dropped.
    ///   All three then reported their line at `start` 0.0. Warm that is 9 ms
    ///   of skew between sources; on a first use of a language the model is
    ///   fetched inside `start`, and the sources behind it in the loop open
    ///   however long that download took.
    ///
    /// So the offset is added rather than assumed to be nothing, which is what
    /// `startedAt` was recorded for and never used for. What the analyser
    /// counts *after* that origin is still audio delivered rather than wall
    /// time — a ring that yields nothing holds the clock still — so this makes
    /// the origin right, not the whole timeline immune to a dropout.
    private var sessionOffset: Double {
        guard let opened = feed.openedAt else { return 0 }
        return max(0, opened - startedAt)
    }

    /// Feeds audio: mono float at whatever rate the router is running.
    ///
    /// Samples rather than an `AVAudioPCMBuffer`, because the buffer is a class
    /// and not `Sendable` — handing one to an actor is a data race the compiler
    /// is right to refuse. The caller has a float array off the ring anyway.
    ///
    /// Deliberately not actor-isolated. The caller is a poll on the interface's
    /// timer handing over consecutive blocks of audio, and `Task { await ... }`
    /// per block does not preserve their order — two blocks can reach an actor
    /// the wrong way round, which in a transcript means two halves of a
    /// sentence swapped. The state this touches lives behind its own lock
    /// instead, so the audio arrives in the order it was drained.
    public nonisolated func add(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        feed.send(samples: samples, sampleRate: sampleRate)
    }

    nonisolated var resourceStatistics: ResourceStatistics { feed.statistics }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        await feed.close()
        if #available(macOS 26, *), let analyser = analyser as? SpeechAnalyzer {
            try? await analyser.finalizeAndFinishThroughEndOfInput()
        }
        // Finalisation ends the results sequence. Await that natural end so the
        // last final sentence reaches `onLine`; cancellation here used to cut
        // off precisely the tail Stop was meant to preserve.
        await finishResults()
        analyser = nil
        transcriber = nil
    }

    /// The audio side of a transcriber, reachable without the actor.
    ///
    /// Submission is a short bounded-ring mutation. Conversion lives on the
    /// worker, and `close` is its barrier before the analyser is finalised.
    private final class Feed: @unchecked Sendable {
        @available(macOS 26, *)
        private final class ConversionSession: @unchecked Sendable {
            let converter: AnyObject?
            let continuation: AsyncStream<AnalyzerInput>.Continuation
            let buffers = TranscriptionPCMBufferBuilder()

            init(
                converter: AnyObject?,
                continuation: AsyncStream<AnalyzerInput>.Continuation
            ) {
                self.converter = converter
                self.continuation = continuation
            }

            func process(
                samples: [Float], sampleRate: Double
            ) -> TranscriptionInputWorker.ProcessingResult {
                let before = buffers.statistics
                let converted: Bool
                #if YUNAUDIO_NO_SPEECH_ANALYZER
                    _ = samples
                    _ = sampleRate
                    converted = false
                #else
                    if #available(macOS 27, *),
                        let converter = converter as? AnalyzerInputConverter,
                        let buffer = buffers.make(samples: samples, sampleRate: sampleRate),
                        let inputs = try? converter.convert(buffer, at: nil)
                    {
                        var everyInputWasAccepted = true
                        for input in inputs {
                            switch continuation.yield(input) {
                            case .enqueued:
                                break
                            case .dropped, .terminated:
                                everyInputWasAccepted = false
                            @unknown default:
                                everyInputWasAccepted = false
                            }
                        }
                        converted = everyInputWasAccepted
                    } else {
                        converted = false
                    }
                #endif
                let after = buffers.statistics
                return TranscriptionInputWorker.ProcessingResult(
                    converted: converted,
                    formatAllocations: after.formatAllocations - before.formatAllocations,
                    bufferAllocations: after.bufferAllocations - before.bufferAllocations,
                    copiedFrames: after.copiedFrames - before.copiedFrames,
                    retainsFormat: after.retainsFormat)
            }

            func finish() {
                continuation.finish()
                buffers.releaseStorage()
            }
        }

        private let worker = TranscriptionInputWorker()

        /// When the converter swallowed its first sample, on the same wall
        /// clock the session start was taken on. Nil until it has.
        var openedAt: Double? { worker.openedAt }

        @available(macOS 26, *)
        func open(
            converter: AnyObject?, continuation: AsyncStream<AnalyzerInput>.Continuation
        ) async {
            let conversion = ConversionSession(
                converter: converter, continuation: continuation)
            await worker.open(
                session: TranscriptionInputWorker.Session(
                    converterCount: converter == nil ? 0 : 1,
                    process: conversion.process,
                    finish: conversion.finish))
        }

        func send(samples: [Float], sampleRate: Double) {
            worker.submit(samples, sampleRate: sampleRate)
        }

        func close() async { await worker.close() }

        var statistics: ResourceStatistics {
            let statistics = worker.statistics
            return ResourceStatistics(
                converterInstallations: statistics.converterInstallations,
                activeConverters: statistics.activeConverters,
                formatAllocations: statistics.formatAllocations,
                retainedFormats: statistics.retainedFormats,
                bufferAllocations: statistics.bufferAllocations,
                copiedFrames: statistics.copiedFrames,
                submittedFrames: statistics.submittedFrames,
                convertedFrames: statistics.convertedFrames,
                droppedFrames: statistics.droppedFrames,
                backlogFrames: statistics.backlogFrames,
                maximumBacklogFrames: statistics.maximumBacklogFrames,
                backlogSeconds: statistics.backlogSeconds,
                maximumBacklogSeconds: statistics.maximumBacklogSeconds,
                scheduledDrainWorkItems: statistics.scheduledDrainWorkItems,
                maximumScheduledDrainWorkItems: statistics.maximumScheduledDrainWorkItems,
                converterTurns: statistics.converterTurns,
                mainThreadConverterTurns: statistics.mainThreadConverterTurns,
                longestConverterMilliseconds: statistics.longestConverterMilliseconds)
        }
    }

    /// Adds a line directly. Only for tests, which cannot make Apple's model
    /// say something specific on demand — what is being checked is the shape of
    /// the transcript, not the model.
    public func appendForTesting(_ line: Line) { record(line) }

    /// Installs a deterministic stand-in for the framework results sequence.
    func installResultsTaskForTesting(_ task: Task<Void, Never>) {
        precondition(resultsTask == nil)
        resultsTask = task
    }

    /// Exercises the same result-completion barrier as Stop without audio hardware.
    func finishResultsForTesting(
        beganWaiting: @Sendable () -> Void = {}
    ) async {
        await finishResults(beganWaiting: beganWaiting)
    }

    private func finishResults(
        beganWaiting: @Sendable () -> Void = {}
    ) async {
        let task = resultsTask
        beganWaiting()
        await task?.value
        resultsTask = nil
    }

    /// Everything said so far, as a transcript somebody can read.
    ///
    /// Attributed by construction rather than by guessing, which is the whole
    /// point — so the speaker's name goes on every line rather than being left
    /// for a human to work out afterwards.
    public func transcript() -> String {
        lines.map { line in
            let minutes = Int(line.start) / 60
            let seconds = Int(line.start) % 60
            return String(
                format: "[%02d:%02d] %@: %@", minutes, seconds, line.speaker, line.text)
        }.joined(separator: "\n")
    }
}
