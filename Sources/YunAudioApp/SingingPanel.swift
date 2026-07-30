import AppKit
import SwiftUI
import YunAudioEngine
import YunAudioHAL
import YunAudioMedia
import YunDesign

/// The moving half of the singing inspector.
///
/// Lyrics and tuner readings change up to twenty times a second. Keeping
/// their Observation reads in this view prevents one moving mask from
/// invalidating the header, device pickers, patchbay and the other columns.
struct SingingPanel: View {
    @Bindable var model: RouterModel
    @State private var isTitleLookupExpanded = false
    @State private var handTitle = ""
    @State private var handArtist = ""

    var body: some View {
        let _ = BodyCount.tick("SingingPanel")
        singing
            .padding(Yun.Space.md)
            .background {
                cardBackground
                    .clipShape(.rect(cornerRadius: Yun.Radius.card))
            }
    }

    @ViewBuilder
    private var singing: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            if let track = model.nowPlaying {
                trackHeader(track)
            } else if let problem = model.musicRecognitionProblem {
                Text(problem)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let problem = model.nowPlayingProblem {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    Text(problem)
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(loc("Review permissions")) {
                        SettingsWindow.open(model: model, initialSection: .permissions)
                    }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
                }
            } else {
                Text(
                    NowPlaying.hasAPlayer
                        ? loc(
                            "Play something in Music or Spotify. A verified Shazam build can identify captured players; otherwise choose the words yourself."
                        )
                        : loc(
                            "A verified Shazam build can identify captured players such as QQ Music or NetEase; otherwise choose the words yourself."
                        )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            YunDivider()

            if let lyrics = model.lyrics {
                lyricsSource(synchronised: true)
                SingingLyrics(model: model, lyrics: lyrics)
                lyricNudge
            } else if let plain = model.plainLyrics {
                lyricsSource(synchronised: false)
                Text(plain)
                    .font(Yun.Text.body)
                    .foregroundStyle(Yun.Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.nowPlaying != nil {
                lyricsLookupState
            }

            // The key of what is playing, and how far it would have to move.
            // Every karaoke machine has a transpose button because a song is
            // written in the key its original singer could reach; the pitch
            // stage to fix that is already here, and this is the number it
            // needed.
            if let key = model.songKey {
                YunDivider()
                HStack(spacing: Yun.Space.sm) {
                    Text(loc("The song is in"))
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                    Text(key.name)
                        .font(Yun.Text.title)
                        .foregroundStyle(
                            key.confidence > 0.3
                                ? Yun.Palette.textPrimary : Yun.Palette.textMuted)
                    // Said out loud when it is a guess. Relative major and
                    // minor share every note, so a weak match is common and
                    // printing a letter with a straight face would be a lie.
                    if key.confidence <= 0.3 {
                        YunBadge(loc("a guess"))
                    }
                    Spacer()
                    if let shift = model.suggestedShift, shift != 0 {
                        Button(
                            String(format: loc("Move it %+d"), shift)
                        ) {
                            model.applySuggestedShift()
                        }
                        .buttonStyle(YunButtonStyle(.secondary, small: true))
                    }
                }
                if model.comfortableMidi == nil {
                    Text(loc("Sing for a moment and it will work out how far to move it."))
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Whether you are on the note. The tracker was already here; what
            // it lacked was a reason to be looked at.
            SingingNote(model: model)

            YunDivider()
            scoring

            YunDivider()
            handRun
        }
    }

    private var cardBackground: some View {
        LinearGradient(
            colors: [
                Yun.Palette.accent.opacity(model.nowPlaying == nil ? 0.035 : 0.11),
                Yun.Palette.elevated.opacity(0.32),
                Yun.Palette.accent.opacity(0.025),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    private func trackHeader(_ track: NowPlaying.Track) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack(alignment: .top, spacing: Yun.Space.sm) {
                SongArtwork(url: track.artworkURL, title: track.title)
                    .frame(width: 72, height: 72)
                    .background(Yun.Palette.elevated)
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Yun.Palette.borderHairline, lineWidth: 1)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Yun.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(track.artist)
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !track.album.isEmpty {
                        Text(track.album)
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            trackProgress(track)

            SongClock(model: model, track: track)

            if let appleMusicURL = track.appleMusicURL {
                Button(loc("Open in Apple Music")) {
                    NSWorkspace.shared.open(appleMusicURL)
                }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
            }
        }
    }

    private func trackProgress(_ track: NowPlaying.Track) -> some View {
        SongProgress(model: model, duration: track.duration)
    }

    @ViewBuilder
    private func lyricsSource(synchronised: Bool) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.xs) {
            HStack(spacing: Yun.Space.xs) {
                if let source = model.lyricsSourceName {
                    Text(String(format: loc("Words from %@"), source))
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                }
                YunBadge(synchronised ? loc("timed") : loc("plain words"))
                if let region = model.lyricsRegion {
                    YunBadge(String(format: loc("Catalogue region %@"), region))
                }
                Spacer(minLength: 0)
            }
            if let copyright = model.lyricsCopyright {
                Text(copyright)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var lyricsLookupState: some View {
        let hasMusixmatch = model.isMusixmatchSessionConfigured
        switch model.lyricsLookupStatus {
        case .loading:
            HStack(spacing: Yun.Space.sm) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    hasMusixmatch
                        ? loc(
                            "Searching LRCLIB, QQ Music, NetEase, lyrics.ovh and Musixmatch…"
                        )
                        : loc("Searching LRCLIB, QQ Music, NetEase and lyrics.ovh…")
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            }
        case .failed, .rateLimited:
            VStack(alignment: .leading, spacing: Yun.Space.xs) {
                Text(
                    model.lyricsLookupStatus == .rateLimited
                        ? loc("The lyric services asked YunAudio to wait.")
                        : loc("The lyric services could not be reached.")
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.warning)
                Button(loc("Try the lyric sources again")) { model.retryLyricsLookup() }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
            }
        case .notFound:
            VStack(alignment: .leading, spacing: Yun.Space.xs) {
                Text(
                    hasMusixmatch
                        ? loc(
                            "No words were found in LRCLIB, QQ Music, NetEase, lyrics.ovh or Musixmatch. A local .lrc still takes priority."
                        )
                        : loc(
                            "No words were found in LRCLIB, QQ Music, NetEase or lyrics.ovh. A local .lrc still takes priority."
                        )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                Button(loc("Try the lyric sources again")) { model.retryLyricsLookup() }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
            }
        case .idle, .local, .native, .online:
            Text(
                hasMusixmatch
                    ? loc(
                        "No words were found in LRCLIB, QQ Music, NetEase, lyrics.ovh or Musixmatch. A local .lrc still takes priority."
                    )
                    : loc(
                        "No words were found in LRCLIB, QQ Music, NetEase or lyrics.ovh. A local .lrc still takes priority."
                    )
            )
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Words with no player to ask.
    ///
    /// Music and Spotify have scripting dictionaries; a browser, a hardware
    /// player, a file on the desktop and a karaoke machine on the line input
    /// have none — and to every one of those the panel used to say "play
    /// something in Music or Spotify" and stop there, which is most of the ways
    /// anybody actually plays a backing track. Choosing the words and starting
    /// them when the music starts is what a karaoke machine has always done.
    @ViewBuilder
    private var handRun: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            YunWrap(
                spacing: Yun.Space.sm, lineSpacing: 6,
                balanced: true
            ) {
                Button(model.isHandRun ? loc("Choose another") : loc("Choose the words…")) {
                    chooseWords()
                }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isTitleLookupExpanded.toggle()
                    }
                } label: {
                    Label(
                        loc("Find words by title"),
                        systemImage: isTitleLookupExpanded ? "chevron.up" : "magnifyingglass"
                    )
                }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
            }

            if model.isHandRun || model.nowPlaying != nil {
                YunWrap(
                    spacing: Yun.Space.sm, lineSpacing: 6,
                    balanced: true
                ) {
                    if model.isHandRun {
                        if model.lyrics != nil {
                            Button(model.isRunningWords ? loc("Stop") : loc("Start")) {
                                if model.isRunningWords {
                                    model.stopWords()
                                } else {
                                    model.runWords()
                                }
                            }
                            .buttonStyle(YunButtonStyle(.secondary, small: true))
                        }
                        Button(loc("Back to the player")) { model.closeWords() }
                            .buttonStyle(YunButtonStyle(.ghost, small: true))
                    }
                    if let track = model.nowPlaying {
                        Button(loc("Find accompaniment")) {
                            guard
                                let url = AccompanimentSearch.youtubeSearchURL(
                                    title: track.title, artist: track.artist)
                            else { return }
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(YunButtonStyle(.ghost, small: true))
                        .help(
                            loc(
                                "Searches official YouTube results for accompaniment candidates; nothing is downloaded or played automatically."
                            )
                        )
                    }
                    Button(loc("Open the folder")) {
                        guard let directory = RouterModel.lyricsDirectory else { return }
                        try? FileManager.default.createDirectory(
                            at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(directory)
                    }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
                }
            } else {
                Button(loc("Open the folder")) {
                    guard let directory = RouterModel.lyricsDirectory else { return }
                    try? FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(directory)
                }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
            }

            if isTitleLookupExpanded {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    HStack(spacing: Yun.Space.sm) {
                        TextField(loc("Song title"), text: $handTitle)
                            .onChange(of: handTitle) { _, value in
                                let bounded = String(
                                    value.prefix(RouterModel.maximumHandLyricsFieldLength))
                                if bounded != value { handTitle = bounded }
                            }
                            .onSubmit { searchWordsByTitle() }
                        TextField(loc("Artist (optional)"), text: $handArtist)
                            .onChange(of: handArtist) { _, value in
                                let bounded = String(
                                    value.prefix(RouterModel.maximumHandLyricsFieldLength))
                                if bounded != value { handArtist = bounded }
                            }
                            .onSubmit { searchWordsByTitle() }
                    }
                    HStack(alignment: .center, spacing: Yun.Space.sm) {
                        Text(
                            loc(
                                "Local and cached words are checked first, then every configured public lyric source. No extra permission is requested."
                            )
                        )
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Yun.Space.sm)
                        Button(loc("Search lyric sources")) { searchWordsByTitle() }
                            .buttonStyle(YunButtonStyle(.primary, small: true))
                            .disabled(
                                handTitle.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty)
                    }
                }
                .padding(Yun.Space.md)
                .background(
                    LinearGradient(
                        colors: [
                            Yun.Palette.accent.opacity(0.09),
                            Yun.Palette.elevated.opacity(0.7),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: Yun.Radius.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Yun.Radius.card)
                        .stroke(Yun.Palette.borderHairline, lineWidth: 1)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func searchWordsByTitle() {
        guard model.findWordsByTitle(handTitle, artist: handArtist) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isTitleLookupExpanded = false
        }
    }

    private func chooseWords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "lrc") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.directoryURL = RouterModel.lyricsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openWords(at: url)
    }

    /// Moving the words against the recording.
    ///
    /// The one control everybody who has ever sung to a downloaded `.lrc` has
    /// wanted. The format carries an `[offset:]` and it is wrong as often as it
    /// is right — the file was written against a different master, or a stream
    /// with a different silent lead-in — and without this the only remedy was
    /// editing the file between verses.
    @ViewBuilder
    private var lyricNudge: some View {
        HStack(spacing: Yun.Space.sm) {
            Text(loc("Words"))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            Button(loc("Earlier")) { model.nudgeLyrics(by: 0.1) }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
            Button(loc("Later")) { model.nudgeLyrics(by: -0.1) }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
            Spacer()
            Text(
                model.lyricNudge == 0
                    ? loc("as written") : String(format: "%+.1f s", model.lyricNudge)
            )
            .font(Yun.Text.mono)
            .foregroundStyle(
                model.lyricNudge == 0 ? Yun.Palette.textMuted : Yun.Palette.textSecondary
            )
            .monospacedDigit()
        }
    }

    /// How much of the tune each person actually sang.
    ///
    /// Two microphones is two scores rather than one, and it costs nothing to
    /// do it that way: the sources were never mixed, so each already had its
    /// own ring. Every other product that does this has to work out from the
    /// sound which of the two is singing, and is sometimes wrong.
    @ViewBuilder
    private var scoring: some View {
        HStack(spacing: Yun.Space.sm) {
            YunSwitch(isOn: $model.isScoringSinging)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc("Score the singing"))
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.textPrimary)
                Text(
                    loc(
                        "Listens to each microphone on its own. A matching .mid gives an exact tune score; otherwise YunAudio uses captured original vocals or the detected key."
                    )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            // The other button every karaoke machine has. Without it the only
            // way to start the attempt again was the switch, which also throws
            // away the tune, the taps and the words.
            if model.isScoringSinging {
                Button(loc("Start again")) { model.restartScore() }
                    .buttonStyle(YunButtonStyle(.secondary, small: true))
            }
        }
        if let problem = model.singingError {
            Text(problem)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.isScoringSinging {
            Text(scoringReferenceDescription)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Driven by whether there are any rather than by the switch, which is
        // the same thing in the running application — the list is filled when
        // scoring starts and emptied when it stops — and is what lets the
        // offscreen capture show the rows without opening a tap.
        SingerScores(model: model)
    }

    private var scoringReferenceDescription: String {
        switch model.scoringReferenceMode {
        case .waiting:
            loc("Finding the strongest scoring reference…")
        case .midi:
            loc("Exact melody score from the matching MIDI file.")
        case .capturedPlayer:
            loc(
                "Automatic score from the captured original vocal; a matching MIDI remains more exact."
            )
        case .key:
            loc("Key and timing score — accompaniment alone does not contain the vocal melody.")
        }
    }

    /// Score lines are stored in lyric order. Looking up the current one must
    /// not walk a whole song for every singer on every lyric tick.
    nonisolated static func scoreLine(
        at wanted: Int,
        in lines: [KaraokeScore.Line]
    ) -> KaraokeScore.Line? {
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lines[middle].index < wanted {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < lines.count, lines[lower].index == wanted else { return nil }
        return lines[lower]
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

}

/// The same fill for progress tracks, retaining both rounded ends.
private struct HorizontalCapsuleFill: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width * max(0, min(1, fraction))
        return Capsule().path(
            in: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
    }
}

/// Loads one cover per song and keeps the decoded image out of the moving lyric
/// body. `AsyncImage` does not load file URLs, which made local artwork look
/// complete in the model and remain a placeholder on screen.
struct SongArtwork: View {
    let url: URL?
    let title: String
    var contentMode: ContentMode = .fit

    @State private var image: NSImage?

    /// What the most recent artwork fetch did, for the capture gate to report.
    nonisolated(unsafe) static var lastTaskOutcome = "never started"

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    // Player artwork remains complete and uncropped.
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Yun.Palette.accent.opacity(0.42),
                            Yun.Palette.info.opacity(0.16),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(title.first.map(String.init) ?? "♪")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(Yun.Palette.textPrimary.opacity(0.82))
                }
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            SongArtwork.lastTaskOutcome = "started"
            guard
                let decoded = await SongArtworkResources.shared.value(for: url),
                !Task.isCancelled
            else {
                // Which of the two it is. A capture that photographs the
                // placeholder cannot say whether the decode returned nothing —
                // a defect a user meets — or whether this task simply had not
                // run yet, which is only the gate being impatient.
                SongArtwork.lastTaskOutcome =
                    Task.isCancelled ? "cancelled" : "no decoded value"
                return
            }
            let loaded = NSImage(
                cgImage: decoded.image,
                size: NSSize(width: decoded.image.width, height: decoded.image.height))
            guard !Task.isCancelled else { return }
            SongArtwork.lastTaskOutcome = "loaded"
            image = loaded
        }
    }
}

// MARK: - The parts that move

/// The observation leaves of the singing panel.
///
/// `SingingPanel` is eight hundred lines, and every one of its sub-views is a
/// computed property of the same struct — so a value read anywhere inside it is
/// a dependency of the whole body. Measured before this split: 54 body
/// evaluations in four idle seconds, 13.5 a second, re-deriving the track
/// header, the permission prose, the lyric source row and every button for a
/// note readout that had changed by a semitone.
///
/// The same shape as `LiveSpectrum`, and for the same reason: put the
/// invalidation where the moving picture is.
private struct SingingLyrics: View {
    let model: RouterModel
    let lyrics: Lyrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = BodyCount.tick("SingingLyrics")
        let current = model.lyricLine ?? 0
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            ForEach(-1...1, id: \.self) { offset in
                let index = current + offset
                let line =
                    lyrics.lines.indices.contains(index) ? lyrics.lines[index] : nil
                // A rest is drawn here exactly as it is on the stage: a timed
                // line with no words is an intro, an interlude or an outro, and
                // an empty row says none of that. The same mark, so the two
                // presentations of the same song do not disagree.
                let text = line.map { $0.isInterlude ? KTVStage.interludeMark : $0.text } ?? ""
                if offset == 0 {
                    // The sweep is the point: a line that lights up all at
                    // once tells you which line, and a line that fills tells
                    // you where in it. Core Animation now advances that sweep
                    // without making this Observation leaf a display link.
                    CompositedLyricSurface(
                        model: model,
                        text: text.isEmpty ? " " : text,
                        style: .inspector
                    )
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Yun.Space.lg)
                    .padding(.vertical, Yun.Space.lg)
                    .background(
                        LinearGradient(
                            colors: [
                                Yun.Palette.accent.opacity(0.14),
                                Yun.Palette.accent.opacity(0.045),
                            ],
                            startPoint: .leading, endPoint: .trailing),
                        in: .rect(cornerRadius: Yun.Radius.card)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(text)
                        .font(.system(size: offset < 0 ? 15 : 18, weight: .medium))
                        .foregroundStyle(
                            offset < 0
                                ? Yun.Palette.textMuted : Yun.Palette.textTertiary
                        )
                        .contentTransition(.opacity)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(offset < 0 ? 0.65 : 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: model.lyricLine)
    }
}

/// Per-microphone readings, which move at the scoring cadence.
///
/// Keeping the switch and its explanation in the parent means enabling scoring
/// still updates the whole inspector once. Keeping the readings here means the
/// next eighty score frames do not.
private struct SingerScores: View {
    let model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("SingerScores")
        let singers = model.singers
        let currentLyricLine = model.lyricLine
        let targetMidi = model.scoringTargetMidi
        ForEach(singers.indices, id: \.self) { index in
            singerRow(
                singers[index],
                currentLyricLine: currentLyricLine,
                targetMidi: targetMidi,
                colour: Self.singerColour(index))
        }
    }

    /// One colour a singer, so two of them can be told apart at a glance.
    ///
    /// The first stays on the accent, so one person singing looks like the rest
    /// of the application rather than like a special mode. The rest come from
    /// the status palette, which is the only place in this design system where
    /// hue is allowed at all — and amber against any of the accents on offer is
    /// the pair that survives both appearances.
    private static func singerColour(_ index: Int) -> Color {
        switch index % 4 {
        case 0: Yun.Palette.accent
        case 1: Yun.Palette.warning
        case 2: Yun.Palette.success
        default: Yun.Palette.info
        }
    }

    @ViewBuilder
    private func singerRow(
        _ singer: RouterModel.Singer,
        currentLyricLine: Int?,
        targetMidi: Double?,
        colour: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.xs) {
            HStack(spacing: Yun.Space.sm) {
                Circle()
                    .fill(colour)
                    .frame(width: 8, height: 8)
                Text(singer.name)
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Yun.Space.sm)
                Text(singer.note ?? "—")
                    .font(Yun.Text.mono)
                    .foregroundStyle(
                        singer.note == nil ? Yun.Palette.textMuted : Yun.Palette.textSecondary)
                Text(
                    singer.score.isMeaningful
                        ? String(format: "%.0f%%", singer.score.percentage) : "—"
                )
                .font(Yun.Text.title)
                .foregroundStyle(singer.score.isMeaningful ? colour : Yun.Palette.textMuted)
                .monospacedDigit()
            }
            // Drawn here rather than with YunProgressBar because that one is
            // always the accent, and the whole point of this row is that the
            // second singer is not.
            ZStack(alignment: .leading) {
                Capsule().fill(Yun.Palette.elevated)
                HorizontalCapsuleFill(
                    fraction: singer.score.isMeaningful
                        ? singer.score.percentage / 100 : 0
                )
                .fill(colour)
            }
            .frame(height: 4)
            if singer.score.isMeaningful {
                HStack(spacing: Yun.Space.lg) {
                    scoreMetric(
                        loc("Pitch accuracy"), percentage: singer.score.pitchPercentage,
                        colour: colour)
                    scoreMetric(
                        loc("Coverage"), percentage: singer.score.coveragePercentage,
                        colour: colour)
                    Spacer(minLength: 0)
                    if let line = currentLineScore(
                        in: singer.score,
                        at: currentLyricLine),
                        line.referenceSeconds > 0
                    {
                        Text(String(format: loc("This line %.0f%%"), line.percentage))
                            .font(Yun.Text.caption)
                            .foregroundStyle(colour)
                            .monospacedDigit()
                    }
                }
            }
            if let target = targetMidi {
                pitchGuide(currentHertz: singer.hertz, targetMidi: target, colour: colour)
            }
            // The one number a singer can act on: consistently under the note
            // is flat, which is a different problem from being wrong.
            if singer.score.isMeaningful, let error = singer.score.meanErrorSemitones,
                abs(error) > 0.2
            {
                Text(
                    String(
                        format: error < 0
                            ? loc("A little flat — about %.0f cents under.")
                            : loc("A little sharp — about %.0f cents over."),
                        abs(error) * 100)
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            }
        }
    }

    private func scoreMetric(
        _ title: String, percentage: Double, colour: Color
    ) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .foregroundStyle(Yun.Palette.textTertiary)
            Text(String(format: "%.0f%%", percentage))
                .foregroundStyle(colour)
                .monospacedDigit()
        }
        .font(Yun.Text.caption)
    }

    private func currentLineScore(
        in score: KaraokeScore,
        at index: Int?
    ) -> KaraokeScore.Line? {
        guard let index else { return nil }
        return SingingPanel.scoreLine(at: index, in: score.lines)
    }

    /// A compact pitch lane modelled on the useful part of karaoke games: the
    /// written note is the centre mark and the singer moves above or below it.
    /// Only exact MIDI references reach here.
    private func pitchGuide(
        currentHertz: Float, targetMidi: Double, colour: Color
    ) -> some View {
        let currentMidi =
            currentHertz > 0 ? PitchSample.midi(fromHertz: Double(currentHertz)) : nil
        let error = currentMidi.map { max(-3, min(3, $0 - targetMidi)) }
        let targetName =
            PitchTracker.noteName(Float(440 * pow(2, (targetMidi - 69) / 12))) ?? "—"
        let currentName = PitchTracker.noteName(currentHertz) ?? "—"
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(String(format: loc("Target %@"), targetName))
                Spacer()
                Text(String(format: loc("Current %@"), currentName))
            }
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            GeometryReader { geometry in
                ZStack {
                    Capsule().fill(Yun.Palette.elevated)
                    Rectangle()
                        .fill(Yun.Palette.textMuted)
                        .frame(width: 1, height: 10)
                    if let error {
                        Circle()
                            .fill(colour)
                            .frame(width: 9, height: 9)
                            .offset(x: geometry.size.width * CGFloat(error / 6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 10)
        }
    }
}

private struct SingingNote: View {
    let model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("SingingNote")
        HStack(spacing: Yun.Space.sm) {
            Text(loc("You are singing"))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            Spacer()
            Text(model.heardNote ?? "—")
                .font(Yun.Text.title)
                .foregroundStyle(
                    model.heardNote == nil ? Yun.Palette.textMuted : Yun.Palette.accent
                )
                .monospacedDigit()
        }
    }
}

/// Elapsed and total, which is the only thing on that row that moves.
///
/// The track's own name and application arrive as values: they change when the
/// song does, which is not twenty times a second.
private struct SongClock: View {
    let model: RouterModel
    let track: NowPlaying.Track

    var body: some View {
        let _ = BodyCount.tick("SongClock")
        HStack(spacing: Yun.Space.sm) {
            Text(SingingPanel.clock(Double(model.songSecond)))
            Spacer(minLength: Yun.Space.sm)
            YunBadge(track.application)
            Text(track.duration > 0 ? SingingPanel.clock(track.duration) : "--:--")
        }
        .font(Yun.Text.mono)
        .foregroundStyle(Yun.Palette.textTertiary)
        .monospacedDigit()
    }
}

/// The bar under the title. The duration is a value; only the position moves.
private struct SongProgress: View {
    let model: RouterModel
    let duration: Double

    var body: some View {
        let _ = BodyCount.tick("SongProgress")
        let fraction =
            duration > 0 ? max(0, min(1, Double(model.songSecond) / duration)) : 0
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Yun.Palette.border)
                Capsule()
                    .fill(Yun.Palette.accent)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
