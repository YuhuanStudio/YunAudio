import AVFoundation
import Foundation
import Speech

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
    private var analyser: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
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

    /// Lines finished so far. Volatile partial results are deliberately not
    /// kept: a transcript that rewrites itself as somebody speaks is unreadable
    /// scrolling past, and the finalised text is what anybody wants afterwards.
    public private(set) var lines: [Line] = []

    public init(speaker: String, locale: Locale = Locale.current) {
        self.speaker = speaker
        self.locale = locale
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
        guard #available(macOS 27, *), SpeechTranscriber.isAvailable else {
            throw Unavailable.noModel
        }

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
                throw Unavailable.failed(error.localizedDescription)
            }
        }

        var converter: AnyObject?
        if #available(macOS 27, *) {
            do {
                converter = try await AnalyzerInputConverter.converter(
                    compatibleWith: [transcriber])
            } catch {
                throw Unavailable.failed(error.localizedDescription)
            }
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        feed.open(converter: converter, continuation: continuation)
        let analyser = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])
        self.analyser = analyser

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
    }

    private func append(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lines.append(
            Line(
                speaker: speaker,
                text: text,
                start: sessionOffset + result.range.start.seconds,
                duration: result.range.duration.seconds))
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
        guard #available(macOS 27, *), !samples.isEmpty else { return }
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            channel[0].update(from: $0.baseAddress!, count: samples.count)
        }
        feed.send(buffer)
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        feed.close()
        try? await analyser?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyser = nil
        transcriber = nil
    }

    /// The audio side of a transcriber, reachable without the actor.
    ///
    /// Small on purpose: a lock, a converter and a continuation. Everything
    /// that has to happen in the order the audio was drained lives here, and
    /// everything else stays on the actor where it belongs.
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var converter: AnyObject?
        private var continuation: AsyncStream<AnalyzerInput>.Continuation?
        private var firstAccepted: Double?

        /// When the converter swallowed its first sample, on the same wall
        /// clock the session start was taken on. Nil until it has.
        var openedAt: Double? {
            lock.lock()
            defer { lock.unlock() }
            return firstAccepted
        }

        func open(converter: AnyObject?, continuation: AsyncStream<AnalyzerInput>.Continuation)
        {
            lock.lock()
            defer { lock.unlock() }
            self.converter = converter
            self.continuation = continuation
            firstAccepted = nil
        }

        func send(_ buffer: AVAudioPCMBuffer) {
            guard #available(macOS 27, *) else { return }
            lock.lock()
            defer { lock.unlock() }
            guard let continuation,
                let converter = converter as? AnalyzerInputConverter,
                let inputs = try? converter.convert(buffer, at: nil)
            else { return }
            // Noted on the buffer the converter took rather than on the first
            // one it gave something back for: it chunks, so the first call can
            // yield nothing at all, and the analyser's zero is the first sample
            // it swallowed either way.
            if firstAccepted == nil { firstAccepted = Date().timeIntervalSince1970 }
            for input in inputs { continuation.yield(input) }
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            continuation?.finish()
            continuation = nil
            converter = nil
        }
    }

    /// Adds a line directly. Only for tests, which cannot make Apple's model
    /// say something specific on demand — what is being checked is the shape of
    /// the transcript, not the model.
    public func appendForTesting(_ line: Line) { lines.append(line) }

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
