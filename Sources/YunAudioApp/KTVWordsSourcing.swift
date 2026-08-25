import AppKit
import SwiftUI
import YunAudioMedia
import YunDesign

/// Where the words come from when nothing found them automatically.
///
/// Everything in here existed and could be reached from the inspector column
/// only: searching the lyric sources by title, driving a set of words by hand
/// against a song another application is playing, going back to that player,
/// and opening the folder the words live in. The stage could open a file and
/// nothing else — so the case this is *for*, which is a song whose words did not
/// resolve, was unfixable from the surface where somebody discovers it.
///
/// 「慢冷」 is the standing example: the automatic match returns words for a
/// different edition, and the repair is to search by title and take a different
/// source. Somebody standing at the stage with the wrong words on screen had to
/// close the window to do it.
///
/// Two sizes, one construction, like the transport and the words controls. The
/// stage puts it under the queue where there is width; the inspector keeps it in
/// the column.
struct KTVWordsSourcing: View {

    enum Scale {
        /// On the darkened photograph.
        case stage
        /// The stage's queue popover, which is a light card like the inspector
        /// but belongs to the window: inspector colours, stage identifiers.
        /// Two axes would be more general and less honest — there are three
        /// places this appears, not four.
        case popover
        case inspector

        var isDark: Bool { self == .stage }
        /// Which presentation an identifier belongs to, so a flow check that
        /// finds `PanelFindWordsByTitle` knows the inspector answered it.
        var isWindow: Bool { self != .inspector }

        var caption: Font {
            isDark ? .system(size: 11, weight: .regular) : Yun.Text.caption
        }
        var quiet: Color {
            isDark ? Yun.Palette.OnStage.tertiary : Yun.Palette.textTertiary
        }
    }

    @Bindable var model: RouterModel
    var scale: Scale = .stage

    /// The search fields, which belong to the presentation rather than the
    /// model: two people with the window and the panel both open are two people
    /// typing, and a shared draft would have them overwriting each other.
    @State private var isExpanded = false
    @State private var title = ""
    @State private var artist = ""

    var body: some View {
        let _ = BodyCount.tick(scale.isWindow ? "KTVSourcingStage" : "KTVSourcingPanel")
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            YunWrap(spacing: Yun.Space.sm, lineSpacing: 6, balanced: true) {
                Button(loc("Open a song…")) { KTVFilePickers.chooseSongs(into: model) }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
                    .help(
                        loc(
                            "Plays an audio file here, so the words follow the samples instead of asking another application where it is."
                        ))
                Button(model.isHandRun ? loc("Choose another") : loc("Choose the words…")) {
                    KTVFilePickers.chooseWords(for: model)
                }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
                .accessibilityIdentifier(identifier("ChooseWordsFile"))
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    Label(
                        loc("Find words by title"),
                        systemImage: isExpanded ? "chevron.up" : "magnifyingglass")
                }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
                .accessibilityIdentifier(identifier("FindWordsByTitle"))
            }

            YunWrap(spacing: Yun.Space.sm, lineSpacing: 6, balanced: true) {
                if model.isHandRun {
                    // Only with words to run. A start button that starts nothing
                    // is the kind of control that teaches people the
                    // application is broken.
                    if model.lyrics != nil {
                        Button(model.isRunningWords ? loc("Stop") : loc("Start")) {
                            if model.isRunningWords {
                                model.stopWords()
                            } else {
                                model.runWords()
                            }
                        }
                        .buttonStyle(YunButtonStyle(.secondary, small: true))
                        .accessibilityIdentifier(identifier("RunWords"))
                    }
                    Button(loc("Back to the player")) { model.closeWords() }
                        .buttonStyle(YunButtonStyle(.ghost, small: true))
                        .accessibilityIdentifier(identifier("CloseWords"))
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
                        ))
                }
                Button(loc("Open the folder")) {
                    guard let directory = RouterModel.lyricsDirectory else { return }
                    FolderRevealWorker.shared.submit(directory)
                }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
            }

            // Which of the three ways the words are wrong, when they are.
            //
            // The nudge control has always been reachable, and it is the wrong
            // answer to two of the three: a drifting file cannot be fixed by
            // one number, and words for another recording cannot be fixed at
            // all. Saying which saves somebody nudging a file that was never
            // going to line up.
            if let message = model.lyricTimingMessage {
                HStack(alignment: .firstTextBaseline, spacing: Yun.Space.sm) {
                    Text(message)
                        .font(scale.caption)
                        .foregroundStyle(scale.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.lyricTimingIsCorrectable {
                        Button(loc("Line them up")) { model.applyMeasuredLyricOffset() }
                            .buttonStyle(YunButtonStyle(.primary, small: true))
                            .accessibilityIdentifier(identifier("ApplyMeasuredOffset"))
                    }
                }
                .accessibilityIdentifier(identifier("LyricTiming"))
            }

            if isExpanded { search }
            if model.isLoadingLocalWords {
                HStack(spacing: Yun.Space.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loc("Reading local words…"))
                        .font(scale.caption)
                        .foregroundStyle(scale.quiet)
                }
            }
            if let problem = model.localWordsError {
                Text(problem)
                    .font(scale.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var search: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack(spacing: Yun.Space.sm) {
                field(loc("Song title"), text: $title)
                field(loc("Artist (optional)"), text: $artist)
            }
            HStack(alignment: .center, spacing: Yun.Space.sm) {
                Text(
                    loc(
                        "Local and cached words are checked first, then every configured public lyric source. No extra permission is requested."
                    )
                )
                .font(scale.caption)
                .foregroundStyle(scale.quiet)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Yun.Space.sm)
                Button(loc("Search lyric sources")) { run() }
                    .buttonStyle(YunButtonStyle(.primary, small: true))
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier(identifier("SearchLyricSources"))
            }
        }
        .padding(Yun.Space.md)
        .background {
            background.clipShape(.rect(cornerRadius: Yun.Radius.card))
        }
        .overlay(
            RoundedRectangle(cornerRadius: Yun.Radius.card)
                .stroke(
                    scale.isDark ? Yun.Palette.OnStage.hairline : Yun.Palette.borderHairline,
                    lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var background: some View {
        if scale.isDark {
            // On a darkened photograph the inspector's near-white card is a
            // hole in the picture; a wash of the accent over the image is not.
            Yun.Palette.OnStage.well
        } else {
            LinearGradient(
                colors: [
                    Yun.Palette.accent.opacity(0.09),
                    Yun.Palette.elevated.opacity(0.7),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }
    }

    /// Bounded as it is typed rather than at submission, because the field is
    /// sent to public lyric sources and a paste of a whole document is a
    /// request nobody meant to make.
    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            // The shape every other field in this application has. Left bare it
            // was the one input with no border, which reads as decoration
            // rather than as somewhere to type.
            .textFieldStyle(.roundedBorder)
            .onChange(of: text.wrappedValue) { _, value in
                let bounded = String(value.prefix(RouterModel.maximumHandLyricsFieldLength))
                if bounded != value { text.wrappedValue = bounded }
            }
            .onSubmit { run() }
    }

    private func run() {
        guard model.findWordsByTitle(title, artist: artist) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { isExpanded = false }
    }

    private func identifier(_ name: String) -> String {
        (scale.isWindow ? "KTV" : "Panel") + name
    }
}
