import SwiftUI
import YunDesign

/// Where the words came from, and what went wrong if nothing did.
///
/// The stage showed a bare 「歌詞來源：網易雲音樂」 and nothing else: not whether
/// the timing came from the file or was inferred, not which catalogue region
/// answered, not the copyright the index asks to be shown, and — the one that
/// matters when there are no words at all — not a single line about why.
/// Somebody looking at an empty stage had no way to tell a rate limit from a
/// song nobody has ever transcribed.
///
/// All of it existed, in the inspector column behind the window.
struct KTVLyricsProvenance: View {

    enum Scale {
        case stage
        case inspector

        var caption: Font {
            self == .stage ? .system(size: 12, weight: .medium) : Yun.Text.caption
        }
        var quiet: Color {
            self == .stage ? Yun.Palette.OnStage.tertiary : Yun.Palette.textTertiary
        }
        var loud: Color {
            self == .stage ? Yun.Palette.OnStage.secondary : Yun.Palette.textSecondary
        }
    }

    @Bindable var model: RouterModel
    var scale: Scale = .stage

    var body: some View {
        let _ = BodyCount.tick(scale == .stage ? "KTVProvenanceStage" : "KTVProvenancePanel")
        VStack(alignment: .leading, spacing: Yun.Space.xs) {
            HStack(spacing: Yun.Space.xs) {
                if let source = model.lyricsSourceName {
                    Text(String(format: loc("Words from %@"), source))
                        .font(scale.caption)
                        .foregroundStyle(scale.quiet)
                }
                // Timed against plain: a plain lyric cannot sweep, and somebody
                // wondering why the words are not lighting up is owed the
                // answer rather than left to conclude the feature is broken.
                if model.lyrics != nil {
                    YunBadge(
                        model.lyricsAreTimed ? loc("timed") : loc("plain words"))
                }
                if let region = model.lyricsRegion {
                    YunBadge(String(format: loc("Catalogue region %@"), region))
                }
                Spacer(minLength: 0)
            }
            if let copyright = model.lyricsCopyright {
                Text(copyright)
                    .font(scale.caption)
                    .foregroundStyle(scale.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            problems
        }
    }

    /// Why there are no words, in words.
    ///
    /// An empty stage is the moment somebody most needs telling, and it is
    /// exactly the moment this said nothing at all.
    @ViewBuilder
    private var problems: some View {
        if let problem = model.singingError {
            line(problem, tint: Yun.Palette.warning)
        }
        if let problem = model.nowPlayingProblem {
            line(problem, tint: scale.loud)
        }
        if let problem = model.musicRecognitionProblem {
            line(problem, tint: scale.loud)
        }
        if model.lyricsLookupStatus == .rateLimited {
            HStack(spacing: Yun.Space.sm) {
                line(
                    loc("The lyric index is rate limiting us. It usually clears in a minute."),
                    tint: Yun.Palette.warning)
                Button(loc("Try again")) { model.retryLyricsLookup() }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
                    .accessibilityIdentifier(
                        scale == .stage ? "KTVRetryLyrics" : "PanelRetryLyrics")
            }
        }
    }

    private func line(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(scale.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
