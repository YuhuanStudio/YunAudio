import AVFoundation
import AppKit
import Foundation

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

/// A song this application plays itself.
///
/// **Not the routing engine's path, and deliberately not on it.** `TODO.md`
/// rules out `AVAudioEngine` for the microphone chain because it would put its
/// own graph and its own thread between a real-time callback and a deadline of
/// 2.7 ms. This is the other thing entirely: a file being decoded and played to
/// whatever the system output is, with no real-time constraint of its own and
/// nothing of the router's in it. What it buys is the position — a count of
/// samples rather than a question asked of another process.
///
/// The audio goes wherever the system's default output goes. If that is the
/// YunAudio device, the song arrives back through the router as a source and is
/// mixed, monitored, scored and recorded exactly as a captured player would be;
/// if it is the speakers, it simply plays. Both are correct and neither needs a
/// setting, because both are what "play this file" already means on this Mac.
@MainActor
final class LocalSongPlayer {

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

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// The transpose, which only exists because the song is ours.
    ///
    /// `AVAudioUnitTimePitch` wraps `kAudioUnitSubType_NewTimePitch` — the same
    /// unit `EffectChain` uses for the voice changer, and the reason the
    /// accompaniment could not be transposed until now was never the unit. It
    /// was that the only chain in this application is the microphone's, one set
    /// of effects with one set of parameters, so raising the key would have
    /// raised the singer and left the backing track where it was. This chain has
    /// exactly one thing in it and the microphone is not in it.
    private let transpose = AVAudioUnitTimePitch()
    private var file: AVAudioFile?
    private var clock = LocalSongClock()
    /// Where the song was when it was paused. A node that is not running has no
    /// time at all, so this is the only thing that knows.
    private var restingPosition: Double = 0

    private(set) var song: Song?
    private(set) var isPlaying = false

    init() {
        engine.attach(node)
        engine.attach(transpose)
    }

    /// The transpose in cents, positive up. Takes effect on the next buffer.
    var pitchCents: Float {
        get { transpose.pitch }
        set { transpose.pitch = newValue }
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
        transpose.pitch == 0 ? 0 : transpose.latency
    }

    /// Reads a file and makes it the song, without playing it.
    ///
    /// - Returns: The song, or nil when nothing on this system can decode it.
    @discardableResult
    func open(_ url: URL) -> Song? {
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
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(transpose)
        engine.connect(node, to: transpose, format: format)
        // The file's format on both edges. `nil` was tried here — the theory
        // being that the mixer, sitting downstream of an output device this
        // application switches while running, might not hold the file's rate.
        // The flow check answered: with `nil` the graph connects and then
        // renders nothing at all. Position stayed at 0.0 after 600 ms of
        // playing and the time-pitch unit reported no latency, which is what an
        // engine that never started looks like. The disconnect above is what
        // fixed the exception; this was a guess on top of it.
        engine.connect(transpose, to: engine.mainMixerNode, format: format)
        let tags = Self.metadata(of: url)
        let song = Song(
            url: url,
            title: tags.title ?? url.deletingPathExtension().lastPathComponent,
            artist: tags.artist ?? "",
            album: tags.album ?? "",
            duration: clock.duration,
            artwork: tags.artwork)
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
        guard let file else { return false }
        let target = seconds ?? restingPosition
        let startFrame = clock.frame(forSeconds: target)
        let remaining = file.length - startFrame
        guard remaining > 0 else {
            // Asked to play from the end. Treated as a finished song rather
            // than as a failure: scheduling zero frames succeeds and then
            // nothing ever happens, which looks like a fault.
            restingPosition = clock.duration
            isPlaying = false
            return false
        }
        node.stop()
        scheduleGeneration &+= 1
        clock.startFrame = startFrame
        if isCancellingCentre {
            // Read and processed a second at a time. The alternative is the
            // whole file in memory — eighty-five megabytes for a four-minute
            // stereo song — for a mode somebody switches on and off mid-verse.
            chunkCursor = startFrame
            for _ in 0..<Self.chunksInFlight { scheduleNextChunk() }
        } else {
            node.scheduleSegment(
                file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining),
                at: nil)
        }
        if !engine.isRunning {
            engine.prepare()
            guard (try? engine.start()) != nil else {
                isPlaying = false
                return false
            }
        }
        node.play()
        restingPosition = target
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
        guard isPlaying else { return }
        scheduleGeneration &+= 1
        restingPosition = position
        node.pause()
        engine.pause()
        isPlaying = false
    }

    func stop() {
        scheduleGeneration &+= 1
        node.stop()
        if engine.isRunning { engine.stop() }
        file = nil
        song = nil
        clock = LocalSongClock()
        restingPosition = 0
        isPlaying = false
    }

    /// Seconds into the song, from the samples the output has consumed.
    ///
    /// Less whatever the transpose is holding: the player node's count is what
    /// it has handed *to* the unit, and the unit is a window behind that. The
    /// words follow this number, so leaving the correction out would put them
    /// ahead of the music by the unit's latency the moment somebody changed
    /// key — and it would read as the lyric file being wrong.
    var position: Double {
        guard isPlaying,
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

    /// A second of audio per chunk, three in flight.
    ///
    /// One would leave the output waiting on the main thread between chunks —
    /// the completion handler arrives on an audio thread and the refill has to
    /// hop back — and any gap is a click. Three seconds of lead survives a busy
    /// main thread and is short enough that a seek throws little away.
    private static let chunkSeconds: Double = 1
    private static let chunksInFlight = 3
    private var chunkCursor: AVAudioFramePosition = 0
    /// Bumped wherever scheduling restarts, so a chunk that was already in
    /// flight cannot refill the queue after a seek, a pause or a new song.
    private var scheduleGeneration = 0

    private func scheduleNextChunk() {
        guard isCancellingCentre, let file else { return }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(Self.chunkSeconds * format.sampleRate)
        let remaining = file.length - chunkCursor
        guard remaining > 0, frames > 0, format.channelCount >= 2,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        file.framePosition = chunkCursor
        guard
            (try? file.read(
                into: buffer, frameCount: min(frames, AVAudioFrameCount(remaining)))) != nil,
            buffer.frameLength > 0, let channels = buffer.floatChannelData
        else { return }
        CentreCancel.apply(
            left: channels[0], right: channels[1], frames: Int(buffer.frameLength),
            amount: CentreCancel.defaultAmount)
        chunkCursor += AVAudioFramePosition(buffer.frameLength)
        let generation = scheduleGeneration
        node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            // The callback arrives on an audio thread; everything this touches
            // belongs to the main actor. The generation is what stops a chunk
            // scheduled before a seek from refilling after one.
            Task { @MainActor [weak self] in
                guard let self, self.scheduleGeneration == generation else { return }
                self.scheduleNextChunk()
            }
        }
    }

    private static func metadata(
        of url: URL
    ) -> (
        title: String?, artist: String?, album: String?, artwork: Data?
    ) {
        // The synchronous accessor, deliberately, and the deprecation warnings
        // it leaves in the build are the price of that. It is deprecated in
        // favour of an async load; what it buys by staying synchronous is that
        // `open(_:)` returns a song with its title already in it, so the words
        // and the lyric lookup have a name to work from at the moment the song
        // starts rather than a filename that changes under them a beat later.
        //
        // The cost is what makes that defensible, and it is now measured rather
        // than asserted: **0.300 ms** per song on this machine, warm — see
        // `SongMetadataCostTests`. The comment here used to say "tens of
        // microseconds", which was an order of magnitude out and nobody had
        // checked. Against a queue advancing between songs it is still nothing;
        // against a claim made up, it is the difference the test exists for.
        let asset = AVURLAsset(url: url)
        let items = asset.commonMetadata
        func string(_ key: AVMetadataKey) -> String? {
            let value = AVMetadataItem.metadataItems(
                from: items, withKey: key, keySpace: .common
            ).first?.stringValue
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        let artwork = AVMetadataItem.metadataItems(
            from: items, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common
        ).first?.dataValue
        return (
            string(.commonKeyTitle), string(.commonKeyArtist),
            string(.commonKeyAlbumName), artwork
        )
    }
}
