import AVFoundation
import Foundation
import YunAudioHAL
import YunAudioObjC

/// Where a song is, when the song is ours to play.
///
/// Everything else in this application asks somebody else where the music has
/// got to, and pays for the answer: an Apple event to Safari costs 73 ms, the
/// answer is a second old by the time the words use it, and the whole of
/// `TrackClock` exists to extrapolate between those answers. A file we opened
/// ourselves has none of that problem — the position is a count of samples the
/// output has actually consumed, so it is exact by construction.
///
/// Kept as a value apart from the player because the arithmetic is the part
/// that can be wrong and the part no audio device is needed to check: a seek
/// mid-song, a song whose length is not a whole number of render quanta, and a
/// clock asked about a moment past the end.
struct LocalSongClock: Equatable, Sendable {

    /// Where in the song the current run of playback began, in frames.
    ///
    /// A player node counts from the moment it was told to play, not from the
    /// start of the file, so a seek resets its count to zero and this is what
    /// remembers where zero now is.
    var startFrame: Int64 = 0
    var sampleRate: Double = 0
    var duration: Double = 0

    /// Seconds into the song, given frames the node reports having played.
    func position(playedFrames: Int64) -> Double {
        guard sampleRate > 0 else { return 0 }
        let frames = max(0, startFrame &+ max(0, playedFrames))
        let seconds = Double(frames) / sampleRate
        // A file is a finite thing and the node keeps counting past the end of
        // it while the tail drains, so without this the words would run off the
        // bottom of a song that had already finished.
        guard duration > 0 else { return seconds }
        return min(seconds, duration)
    }

    /// The frame a seek lands on, clamped inside the file.
    func frame(forSeconds seconds: Double) -> Int64 {
        guard sampleRate > 0, seconds.isFinite else { return 0 }
        let bounded = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        return Int64((bounded * sampleRate).rounded())
    }
}

/// The callback-facing graph whose lifetime must cross a termination timeout.
///
/// `AVAudioEngine` and its nodes are used only on MainActor until this owner is
/// detached. Afterwards the sole shutdown worker is the only code allowed to
/// touch them; `@unchecked` records that ownership handover rather than making
/// AVFoundation generally thread-safe.
private final class LocalSongOutputOwner: @unchecked Sendable {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let transpose = AVAudioUnitTimePitch()

    init() {
        engine.attach(node)
        engine.attach(transpose)
    }
}

/// Everything an already-scheduled node callback can reach after Quit.
private final class LocalSongTerminationOwner: @unchecked Sendable {
    private let output: LocalSongOutputOwner
    private let file: AVAudioFile?
    private let decoder: LocalSongCentreDecoder?

    init(
        output: LocalSongOutputOwner,
        file: AVAudioFile?,
        decoder: LocalSongCentreDecoder?
    ) {
        self.output = output
        self.file = file
        self.decoder = decoder
    }

    func stop(using gate: OwnedResourceShutdownGate) -> Bool {
        // Callback publication was revoked before this capsule crossed actors.
        // Repeating shutdown here orders the decoder's worker before graph
        // release without relying on the MainActor-side call for ownership.
        decoder?.shutdown()
        guard
            gate.perform({
                output.node.stop()
                return true
            }) == true
        else { return false }
        guard let isRunning = gate.perform({ output.engine.isRunning }) else {
            return false
        }
        if isRunning,
            gate.perform({
                output.engine.stop()
                return true
            }) != true
        {
            return false
        }
        return gate.perform({ !output.engine.isRunning }) ?? false
    }
}

/// A song this application plays itself.
///
/// **Not the routing engine's path, and deliberately not on it.**
/// `AVAudioEngine` is ruled out for the microphone chain because it would put
/// its own graph and its own thread between a real-time callback and a deadline
/// of 2.7 ms. This is the other thing entirely: a file being decoded and played to
/// whatever the system output is, with no real-time constraint of its own and
/// nothing of the router's in it. What it buys is the position — a count of
/// samples rather than a question asked of another process.
///
/// The audio goes wherever the system's default output goes. If that is the
/// YunAudio device, the song arrives back through the router as a source and is
/// mixed, monitored, scored and recorded exactly as a captured player would be;
/// if it is the speakers, it simply plays. Both are correct and neither needs a
/// setting, because both are what "play this file" already means on this Mac.
final class LocalSongPlayer: @unchecked Sendable {

    struct Song: Equatable, Sendable {
        var url: URL
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var artwork: Data?
    }

    /// Extensions worth offering, which is not the same as the extensions that
    /// will open: `AVAudioFile` reads whatever the system has a decoder for,
    /// and the list is only for the open panel.
    static let openableTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]

    private var output: LocalSongOutputOwner? = LocalSongOutputOwner()
    /// The transpose, which only exists because the song is ours.
    ///
    /// `AVAudioUnitTimePitch` wraps `kAudioUnitSubType_NewTimePitch` — the same
    /// unit `EffectChain` uses for the voice changer, and the reason the
    /// accompaniment could not be transposed until now was never the unit. It
    /// was that the only chain in this application is the microphone's, one set
    /// of effects with one set of parameters, so raising the key would have
    /// raised the singer and left the backing track where it was. This chain has
    /// exactly one thing in it and the microphone is not in it.
    private var file: AVAudioFile?
    private var clock = LocalSongClock()
    /// Where the song was when it was paused. A node that is not running has no
    /// time at all, so this is the only thing that knows.
    private var restingPosition: Double = 0

    /// The file decoder is built only for the processed accompaniment path.
    /// It owns no player or node, so a read which outlives Stop is a detached
    /// capsule rather than a late writer into released audio state.
    private var centreDecoder: LocalSongCentreDecoder?
    private var isPreparingCentrePlayback = false
    private var normalOperationQueue: DispatchQueue?

    private(set) var song: Song?
    private(set) var isPlaying = false

    private let terminationWorker = BoundedOwnerShutdownWorker<LocalSongTerminationOwner>(
        label: "com.yuhuanstudio.yunaudio.local-song-shutdown",
        audioQuarantine: .shared,
        quarantineReason: "local song output teardown is unresolved",
        operation: { $0.stop(using: $1) })
    private var terminationFence: OwnedResourceTeardownFence?

    init() {}

    deinit { centreDecoder?.shutdown() }

    /// Routes decoder publications back to the sole normal-operation owner.
    func installNormalOperationQueue(_ queue: DispatchQueue) {
        precondition(normalOperationQueue == nil)
        normalOperationQueue = queue
    }

    /// Adopts tags loaded through AVFoundation's asynchronous property API.
    func applyMetadata(_ metadata: LocalSongMetadataSnapshot) {
        guard var song, song.url == metadata.url else { return }
        song.title = metadata.title ?? song.title
        song.artist = metadata.artist ?? ""
        song.album = metadata.album ?? ""
        song.artwork = metadata.artwork
        self.song = song
    }

    /// The transpose in cents, positive up. Takes effect on the next buffer.
    var pitchCents: Float {
        get { output?.transpose.pitch ?? 0 }
        set { output?.transpose.pitch = newValue }
    }

    /// Whether the lead vocal is being taken out of the mix.
    ///
    /// Off by default, and it re-schedules from where the song is rather than
    /// taking effect at the next line: a KTV machine's 原唱／伴奏 button is
    /// pressed mid-song, usually mid-phrase, and a button that waits is a
    /// button somebody presses twice.
    private(set) var isCancellingCentre = false

    /// True when this file has two channels to work with. A mono recording has
    /// no side channel, so cancelling its centre cancels all of it.
    var canCancelCentre: Bool {
        guard let file else { return false }
        return CentreCancel.isPossible(channels: file.processingFormat.channelCount)
    }

    @discardableResult
    func setCancellingCentre(_ on: Bool) -> Bool {
        guard on != isCancellingCentre else { return true }
        guard !on || canCancelCentre else { return false }
        let resumeAt = position
        isCancellingCentre = on
        if isPlaying {
            play(from: resumeAt)
        } else {
            restingPosition = resumeAt
        }
        return true
    }

    /// What the transpose costs in seconds, from the unit rather than assumed.
    ///
    /// It is not zero and it is not free to ignore: a time-pitch unit holds a
    /// window of audio to work on, so what reaches the speakers is behind the
    /// count of samples the player node has handed over. Left uncorrected, the
    /// words would run ahead of the music by exactly this, which is the same
    /// defect a wrong `.lrc` offset causes and would be blamed on the file.
    var transposeLatency: Double {
        // Only while it is doing something. The unit reports its window
        // whether or not the pitch is being moved, and a stage set to the
        // original key must not be corrected for work nobody asked for.
        guard let transpose = output?.transpose else { return 0 }
        return transpose.pitch == 0 ? 0 : transpose.latency
    }

    /// Why the last song would not open, when the reason was the engine rather
    /// than the file.
    ///
    /// Held rather than thrown: the caller's question is "is there a song", and
    /// a person's question is "why not". Nil when the last open succeeded.
    private(set) var openingError: String?

    /// How many times the graph had to fall back to the mixer's own format.
    ///
    /// A counter rather than a log line, so the flow check can assert that the
    /// fallback is exercised on this machine rather than merely compiled.
    private(set) var reconnectionsAtTheMixersFormat: UInt64 = 0

    /// Connects at whatever the mixer will actually take, when the file's own
    /// format was refused.
    ///
    /// The mixer's input format is the one format the engine has already agreed
    /// to, so the sample-rate conversion happens inside the player node instead
    /// of at the graph edge. It costs a conversion the bit-exact path does not
    /// have — and this path was never bit-exact: it is a song being played to a
    /// room, not a microphone being routed.
    ///
    /// - Returns: nil when it worked, or the reason when even this raised.
    private static func connectAtTheMixersOwnFormat(
        engine: AVAudioEngine, node: AVAudioPlayerNode, transpose: AVAudioUnitTimePitch,
        format: AVAudioFormat
    ) -> String? {
        let mixer = engine.mainMixerNode
        let mixerFormat = mixer.outputFormat(forBus: 0)
        // A mixer with no rate is an engine with no device behind it, and
        // connecting to it would raise for a third time.
        guard mixerFormat.sampleRate > 0 else {
            return "the output device has no format"
        }
        // **The player's own edge keeps the file's format. Only the edge above
        // it falls back.**
        //
        // `scheduleSegment` requires the node's output format to be the file's
        // processing format. The first version of this reconnected *both* edges
        // at the mixer's — so a 44.1 kHz mono file was scheduled onto a node
        // whose output was 48 kHz stereo, and the player produced silence while
        // reporting that it was playing. The song clock then sat at zero, and
        // everything riding on it — the words above all — sat there with it.
        //
        // Measured rather than reasoned. In a clean virtual machine, where the
        // one audio device does not offer the fixture's rate so this fallback is
        // always taken, the flow check read `position 0.00014 s after 600 ms of
        // playing`. That is this function, not the engine refusing a format.
        //
        // `AVAudioEngine` converts across a connection whose two formats differ,
        // so the rate change belongs on the edge into the mixer, where nothing
        // is scheduled and nothing depends on it.
        if let raised = catchingObjCException({
            engine.connect(node, to: transpose, format: format)
            engine.connect(transpose, to: mixer, format: mixerFormat)
        }) {
            _ = raised
            // **Then the transpose is what cannot take this file, so the song
            // plays without it.**
            //
            // `-10868` is `kAudioUnitErr_FormatNotSupported`, and it comes from
            // the time-pitch unit rather than from the mixer: the two attempts
            // above differ only in the edge *above* the unit, and both raise.
            // Retrying the same edge with the same format was the mistake — the
            // format was never the variable.
            //
            // Moving the key is a feature. Playing the song is the function.
            // Refusing to open a file because it cannot also be transposed is
            // the wrong trade, and it is the one that was being made: the flow
            // check read `the song would not open — error -10868` and every
            // check downstream of a playing song went with it.
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(transpose)
            if let last = catchingObjCException({
                engine.connect(node, to: mixer, format: format)
            }) {
                return last
            }
            return nil
        }
        return nil
    }

    /// Reads a file and makes it the song, without playing it.
    ///
    /// - Returns: The song, or nil when nothing on this system can decode it.
    @discardableResult
    func open(_ url: URL) -> Song? {
        guard let output else { return nil }
        stop()
        guard let opened = try? AVAudioFile(forReading: url) else { return nil }
        let format = opened.processingFormat
        guard format.sampleRate > 0, opened.length > 0 else { return nil }
        file = opened
        clock = LocalSongClock(
            startFrame: 0,
            sampleRate: format.sampleRate,
            duration: Double(opened.length) / format.sampleRate)
        // Connected per file rather than once: two files rarely share a
        // processing format, and a graph connected at the last file's rate
        // resamples the next one for no reason.
        //
        // **Torn down before it is rebuilt, and the second song is why.** The
        // first version reconnected on top of the existing edges, and opening a
        // stereo file after a mono one threw out of
        // `AVAudioEngineGraph::UpdateGraphAfterReconfig` — an Objective-C
        // exception, which Swift cannot catch, so it took the process with it.
        // A KTV evening is one song after another; this is the second one.
        output.engine.disconnectNodeOutput(output.node)
        output.engine.disconnectNodeOutput(output.transpose)
        // Behind the barrier, because `connect` reports failure by *raising*.
        //
        // The disconnect above was the fix for one instance of this — a stereo
        // file opened after a mono one — and it was a fix for that instance
        // rather than for the class. `AVAudioEngineGraph::UpdateGraphAfterReconfig`
        // raises whenever the graph cannot be reconfigured for a format, and
        // what it can be reconfigured for depends on the output device: a thing
        // this application switches while running and a person can unplug. The
        // flow check found it again with an ordinary 44.1 kHz mono file, and an
        // `NSException` through Swift frames is not a failed song, it is a dead
        // process.
        //
        // The file's format on both edges. `nil` was tried here — the theory
        // being that the mixer, sitting downstream of an output device this
        // application switches while running, might not hold the file's rate.
        // The flow check answered: with `nil` the graph connects and then
        // renders nothing at all. Position stayed at 0.0 after 600 ms of
        // playing and the time-pitch unit reported no latency, which is what an
        // engine that never started looks like.
        if let raised = catchingObjCException({
            output.engine.connect(output.node, to: output.transpose, format: format)
            output.engine.connect(
                output.transpose, to: output.engine.mainMixerNode, format: format)
        }) {
            // The graph is now half-built, so it is taken down before the
            // second attempt rather than connected on top of itself — which is
            // the mistake that produced the first exception.
            output.engine.disconnectNodeOutput(output.node)
            output.engine.disconnectNodeOutput(output.transpose)
            if let again = Self.connectAtTheMixersOwnFormat(
                engine: output.engine, node: output.node, transpose: output.transpose,
                format: format)
            {
                openingError = again
                self.file = nil
                return nil
            }
            openingError = nil
            reconnectionsAtTheMixersFormat &+= 1
            _ = raised
        } else {
            openingError = nil
        }
        let song = Song(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            artist: "",
            album: "",
            duration: clock.duration,
            artwork: nil)
        self.song = song
        restingPosition = 0
        return song
    }

    /// Starts, or restarts from a moment.
    ///
    /// - Returns: False when the engine would not start, which is a real
    ///   outcome on a Mac whose default output has just been unplugged and is
    ///   worth saying rather than silently doing nothing.
    @discardableResult
    func play(from seconds: Double? = nil) -> Bool {
        guard let output, let file else { return false }
        let target = seconds ?? restingPosition
        let startFrame = clock.frame(forSeconds: target)
        let remaining = file.length - startFrame
        guard remaining > 0 else {
            // Asked to play from the end. Treated as a finished song rather
            // than as a failure: scheduling zero frames succeeds and then
            // nothing ever happens, which looks like a fault.
            restingPosition = clock.duration
            scheduleGeneration &+= 1
            output.node.stop()
            if output.engine.isRunning { output.engine.pause() }
            isPreparingCentrePlayback = false
            retireCentreDecoder()
            isPlaying = false
            return false
        }

        // The first seek stops the old run. Another ten thousand seeks while
        // its replacement is decoding only replace the worker's one pending
        // slot; none of them reconnects a node or queues another file read.
        if !isPreparingCentrePlayback { output.node.stop() }
        scheduleGeneration &+= 1
        clock.startFrame = startFrame
        if isCancellingCentre {
            guard let url = song?.url else {
                isPreparingCentrePlayback = false
                isPlaying = false
                return false
            }
            isPreparingCentrePlayback = true
            decoderForCentreCancellation().start(
                url: url, frame: startFrame, generation: scheduleGeneration)
        } else {
            isPreparingCentrePlayback = false
            retireCentreDecoder()
            output.node.scheduleSegment(
                file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining),
                at: nil)
        }
        if !output.engine.isRunning {
            output.engine.prepare()
            guard (try? output.engine.start()) != nil else {
                scheduleGeneration &+= 1
                isPreparingCentrePlayback = false
                retireCentreDecoder()
                isPlaying = false
                return false
            }
        }
        if !isCancellingCentre { output.node.play() }
        restingPosition = Double(startFrame) / max(1, clock.sampleRate)
        isPlaying = true
        return true
    }

    /// Moves the playhead, whether or not the song is running.
    ///
    /// A paused song moves without being started: scheduling and immediately
    /// pausing would put a fragment of the new position through the output,
    /// which is a click somebody hears every time they drag the bar.
    func seek(to seconds: Double) {
        guard file != nil else { return }
        if isPlaying {
            play(from: seconds)
        } else {
            restingPosition =
                Double(clock.frame(forSeconds: seconds)) / max(1, clock.sampleRate)
        }
    }

    func pause() {
        guard isPlaying, let output else { return }
        scheduleGeneration &+= 1
        restingPosition = position
        if isCancellingCentre {
            // The old buffers cannot be resumed: their completion ordinals
            // belong to the decoder lifetime which Pause is retiring.
            output.node.stop()
            isPreparingCentrePlayback = false
            retireCentreDecoder()
        } else {
            output.node.pause()
        }
        output.engine.pause()
        isPlaying = false
    }

    func stop() {
        scheduleGeneration &+= 1
        if let output {
            output.node.stop()
            if output.engine.isRunning { output.engine.stop() }
        }
        isPreparingCentrePlayback = false
        retireCentreDecoder()
        file = nil
        song = nil
        clock = LocalSongClock()
        restingPosition = 0
        isPlaying = false
    }

    /// Revokes UI and callback publication, then transfers the output graph.
    ///
    /// This method performs no AVFoundation stop call. The decoder shutdown is
    /// lock/atomic-only and makes every already-scheduled node callback inert;
    /// the graph, file and decoder then move together to the one bounded lane.
    func requestTerminationStop() -> OwnedResourceTeardownFence {
        if let terminationFence {
            guard terminationFence.result?.permitsSameOwnerRetry == true,
                let retry = terminationWorker.retryAfterTimeoutBeforeEntry()
            else { return terminationFence }
            self.terminationFence = retry
            return retry
        }
        scheduleGeneration &+= 1
        isPreparingCentrePlayback = false
        isPlaying = false
        restingPosition = 0
        clock = LocalSongClock()
        song = nil

        let decoder = centreDecoder
        centreDecoder = nil
        decoder?.shutdown()

        let retainedFile = file
        file = nil
        guard let output else {
            let fence = OwnedResourceTeardownFence(completedWith: .complete)
            terminationFence = fence
            return fence
        }
        self.output = nil
        let fence = terminationWorker.submit(
            LocalSongTerminationOwner(
                output: output, file: retainedFile, decoder: decoder))
        terminationFence = fence
        return fence
    }

    /// Seconds into the song, from the samples the output has consumed.
    ///
    /// Less whatever the transpose is holding: the player node's count is what
    /// it has handed *to* the unit, and the unit is a window behind that. The
    /// words follow this number, so leaving the correction out would put them
    /// ahead of the music by the unit's latency the moment somebody changed
    /// key — and it would read as the lyric file being wrong.
    var position: Double {
        guard let node = output?.node, isPlaying, !isPreparingCentrePlayback,
            let nodeTime = node.lastRenderTime,
            let played = node.playerTime(forNodeTime: nodeTime)
        else { return restingPosition }
        let counted = clock.position(playedFrames: played.sampleTime)
        return max(0, counted - transposeLatency)
    }

    /// Whether the song has reached its end, so the caller can stop the words.
    var hasFinished: Bool {
        guard song != nil, clock.duration > 0 else { return false }
        return position >= clock.duration - 0.05
    }

    /// Bumped wherever scheduling restarts, so a chunk that was already in
    /// flight cannot refill the queue after a seek, a pause or a new song.
    private var scheduleGeneration: UInt32 = 0

    struct Snapshot: Sendable {
        let song: Song?
        let isPlaying: Bool
        let position: Double
        let hasFinished: Bool
        let canCancelCentre: Bool
        let isCancellingCentre: Bool
        let pitchCents: Float
        let transposeLatency: Double
        let openingError: String?
        let reconnectionsAtTheMixersFormat: UInt64

        static let empty = Snapshot(
            song: nil, isPlaying: false, position: 0, hasFinished: false,
            canCancelCentre: false, isCancellingCentre: false, pitchCents: 0,
            transposeLatency: 0, openingError: nil,
            reconnectionsAtTheMixersFormat: 0)
    }

    /// Value-only state sampled on the player's sole normal-operation lane.
    func snapshot() -> Snapshot {
        Snapshot(
            song: song, isPlaying: isPlaying, position: position,
            hasFinished: hasFinished, canCancelCentre: canCancelCentre,
            isCancellingCentre: isCancellingCentre, pitchCents: pitchCents,
            transposeLatency: transposeLatency, openingError: openingError,
            reconnectionsAtTheMixersFormat: reconnectionsAtTheMixersFormat)
    }

    private func decoderForCentreCancellation() -> LocalSongCentreDecoder {
        if let centreDecoder { return centreDecoder }
        // Capture the owner once. Reading `normalOperationQueue` from the main
        // actor while transport mutates the player on that queue would itself
        // be a race, even though the only action here is handing the value on.
        let operationQueue = normalOperationQueue
        let decoder = LocalSongCentreDecoder { @MainActor [weak self, operationQueue] batch in
            guard let owner = self else { return }
            if let operationQueue {
                operationQueue.async { owner.adoptCentreDecoded(batch) }
            } else {
                owner.adoptCentreDecoded(batch)
            }
        }
        centreDecoder = decoder
        return decoder
    }

    private func retireCentreDecoder() {
        centreDecoder?.shutdown()
        centreDecoder = nil
    }

    private func adoptCentreDecoded(_ batch: LocalSongCentreDecodeBatch) {
        guard let output, batch.generation == scheduleGeneration, isPlaying,
            isCancellingCentre,
            let decoder = centreDecoder
        else { return }
        guard !batch.failed, !batch.chunks.isEmpty else {
            if isPreparingCentrePlayback {
                isPreparingCentrePlayback = false
                isPlaying = false
                if output.engine.isRunning { output.engine.pause() }
                retireCentreDecoder()
            }
            return
        }

        let mailbox = decoder.completionMailbox
        for chunk in batch.chunks {
            let generation = batch.generation
            let ordinal = chunk.ordinal
            // The closure is allocated here. Its audio-context invocation is
            // one atomic publication into a preallocated mailbox and nothing
            // else — no Task, lock, Objective-C call or buffer allocation.
            output.node.scheduleBuffer(
                chunk.buffer, completionCallbackType: .dataConsumed
            ) { _ in
                mailbox.completed(generation: generation, ordinal: ordinal)
            }
        }
        if isPreparingCentrePlayback {
            isPreparingCentrePlayback = false
            output.node.play()
        }
    }

}
