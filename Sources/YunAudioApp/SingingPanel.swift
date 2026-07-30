import AppKit
import SwiftUI
import YunAudioEngine
import YunAudioHAL
import YunDesign

/// The moving half of the singing inspector.
///
/// Lyrics and tuner readings change up to twenty times a second. Keeping
/// their Observation reads in this view prevents one moving mask from
/// invalidating the header, device pickers, patchbay and the other columns.
struct SingingPanel: View {
    @Bindable var model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("SingingPanel")
        singing
    }

    @ViewBuilder
    private var singing: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            if let track = model.nowPlaying {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(Yun.Text.title)
                        .foregroundStyle(Yun.Palette.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: Yun.Space.sm) {
                        Text(track.artist)
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.textTertiary)
                            .lineLimit(1)
                        Spacer()
                        // From the model's own clock rather than from the
                        // track: the player is asked once a second and this
                        // ticks between, which is what makes it a clock rather
                        // than a number that lurches.
                        Text(
                            Self.clock(Double(model.songSecond)) + " / "
                                + Self.clock(track.duration)
                        )
                        .font(Yun.Text.mono)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .monospacedDigit()
                        YunBadge(track.application)
                    }
                }
            } else if let problem = model.nowPlayingProblem {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    Text(problem)
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(loc("Open Automation settings")) {
                        guard
                            let url = URL(
                                string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                            )
                        else { return }
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
                }
            } else if let problem = model.musicRecognitionProblem {
                Text(problem)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(
                    NowPlaying.hasAPlayer
                        ? loc(
                            "Play something in Music or Spotify, capture another music application, or choose the words yourself."
                        )
                        : loc(
                            "Capture a music application such as QQ Music or NetEase, or choose the words yourself."
                        )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            handRun

            YunDivider()

            if let lyrics = model.lyrics {
                lyricsSource(synchronised: true)
                lyricView(lyrics)
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

            YunDivider()
            scoring

            Button(loc("Open the folder")) {
                guard let directory = RouterModel.lyricsDirectory else { return }
                try? FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(directory)
            }
            .buttonStyle(YunButtonStyle(.ghost, small: true))
        }
    }

    @ViewBuilder
    private func lyricsSource(synchronised: Bool) -> some View {
        HStack(spacing: Yun.Space.xs) {
            if let source = model.lyricsSourceName {
                Text(String(format: loc("Words from %@"), source))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
            }
            YunBadge(synchronised ? loc("timed") : loc("plain words"))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var lyricsLookupState: some View {
        switch model.lyricsLookupStatus {
        case .loading:
            HStack(spacing: Yun.Space.sm) {
                ProgressView()
                    .controlSize(.small)
                Text(loc("Searching Music, LRCLIB, QQ Music, NetEase and lyrics.ovh…"))
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
        case .notFound, .idle, .local, .native, .online:
            Text(
                loc(
                    "No words were found in Music, LRCLIB, QQ Music, NetEase or lyrics.ovh. A local .lrc still takes priority."
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
        HStack(spacing: Yun.Space.sm) {
            Button(model.isHandRun ? loc("Choose another") : loc("Choose the words…")) {
                chooseWords()
            }
            .buttonStyle(YunButtonStyle(.ghost, small: true))
            if model.isHandRun {
                Button(model.isRunningWords ? loc("Stop") : loc("Start")) {
                    if model.isRunningWords { model.stopWords() } else { model.runWords() }
                }
                .buttonStyle(YunButtonStyle(.secondary, small: true))
                Button(loc("Back to the player")) { model.closeWords() }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
            }
            Spacer(minLength: 0)
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
        ForEach(Array(model.singers.enumerated()), id: \.element.id) { index, singer in
            singerRow(singer, colour: Self.singerColour(index))
        }
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
    private func singerRow(_ singer: RouterModel.Singer, colour: Color) -> some View {
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
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Yun.Palette.elevated)
                    Capsule()
                        .fill(colour)
                        .frame(
                            width: geometry.size.width
                                * (singer.score.isMeaningful
                                    ? singer.score.percentage / 100 : 0))
                }
            }
            .frame(height: 4)
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

    /// Three lines: what was just sung, what is being sung, what comes next.
    ///
    /// Three rather than a scrolling sheet, because the one being sung has to
    /// be findable without reading — that is the difference between lyrics you
    /// can sing to and lyrics you have to search.
    private func lyricView(_ lyrics: Lyrics) -> some View {
        let current = model.lyricLine
        return VStack(alignment: .leading, spacing: Yun.Space.sm) {
            ForEach(-1...1, id: \.self) { offset in
                let index = (current ?? -1) + offset
                let text = lyrics.lines.indices.contains(index) ? lyrics.lines[index].text : ""
                if offset == 0 {
                    ZStack(alignment: .leading) {
                        Text(text.isEmpty ? " " : text)
                            .font(Yun.Text.title)
                            .foregroundStyle(Yun.Palette.textMuted)
                        // The sweep is the point: a line that lights up all at
                        // once tells you which line, and a line that fills
                        // tells you where in it.
                        Text(text.isEmpty ? " " : text)
                            .font(Yun.Text.title)
                            .foregroundStyle(Yun.Palette.accent)
                            .mask(alignment: .leading) {
                                GeometryReader { proxy in
                                    Rectangle()
                                        .frame(width: proxy.size.width * model.lyricProgress)
                                }
                            }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(text)
                        .font(Yun.Text.body)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.linear(duration: 0.1), value: model.lyricProgress)
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

}
