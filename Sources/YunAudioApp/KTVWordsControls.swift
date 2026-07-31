import SwiftUI
import YunDesign

/// Everything that can be done to the words, in one construction.
///
/// The stage and the panel had grown different halves of this. The stage had
/// pronunciation, script, size, the remembered offset and the source switch; the
/// panel had a nudge of its own that moved nothing. Neither had all of it, and
/// the one thing they both had they disagreed about.
///
/// That disagreement was the worst part. `lyricNudge` was a transient ±2 s that
/// only reached `seekToLyricLine` — press 「早一點」 and the label changed, the
/// seek target moved, and the words stayed exactly where they were. The stage's
/// `LyricOffsets` is the real one: it moves the words, and it remembers per
/// song, which is what 「慢冷」 needs because that file has no lead-in and no
/// better one exists to find. One of them had to go, and it was not the one that
/// works.
///
/// Two sizes, because the stage sits on a photograph in a row of 24-point
/// circles and the inspector column is 380 points of card. Same controls, same
/// order, same words.
struct KTVWordsControls: View {

    enum Scale {
        case stage
        case inspector

        var button: CGFloat { self == .stage ? 24 : 22 }
        var spacing: CGFloat { self == .stage ? Yun.Space.sm : 6 }
        var tint: Color { self == .stage ? .white : Yun.Palette.textPrimary }
        var quiet: Color {
            self == .stage ? .white.opacity(0.62) : Yun.Palette.textTertiary
        }
        var well: Double { self == .stage ? 0.10 : 0.07 }
        var lit: Double { self == .stage ? 0.18 : 0.14 }
    }

    @Bindable var model: RouterModel
    var scale: Scale = .stage

    var body: some View {
        let _ = BodyCount.tick(scale == .stage ? "KTVWordsStage" : "KTVWordsPanel")
        HStack(spacing: scale.spacing) {
            offset
            Divider().frame(height: scale.button * 0.7).opacity(0.35)
            romanisation
            if model.lyricsHaveChinese { script }
            Divider().frame(height: scale.button * 0.7).opacity(0.35)
            size
            if model.lyricAlternatives.count > 1 { source }
        }
    }

    /// 早一點／晚一點, against the remembered offset rather than a label.
    @ViewBuilder
    private var offset: some View {
        round("chevron.left", label: loc("Earlier")) { model.nudgeLyricOffset(by: 0.2) }
        Text(
            model.lyricOffsetSeconds == 0
                ? loc("as written")
                : String(format: "%+.1f s", model.lyricOffsetSeconds)
        )
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(model.lyricOffsetSeconds == 0 ? scale.quiet : Yun.Palette.accent)
        .frame(minWidth: 54)
        .contentShape(.rect)
        // Tapping the reading clears it, which is where somebody looks for
        // "put it back" — a third button for it would be a third button.
        .onTapGesture { model.clearLyricOffset() }
        .accessibilityLabel(loc("As written"))
        .accessibilityIdentifier(identifier("LyricOffsetReading"))
        round("chevron.right", label: loc("Later")) { model.nudgeLyricOffset(by: -0.2) }
    }

    @ViewBuilder
    private var romanisation: some View {
        glyph("拼", isOn: model.showsRomanisation, label: loc("Show pronunciation")) {
            model.showsRomanisation.toggle()
        }
    }

    @ViewBuilder
    private var script: some View {
        glyph(
            model.lyricScript.mark, isOn: model.lyricScript != .asWritten,
            label: model.lyricScript.title
        ) {
            model.lyricScript = model.lyricScript.next
        }
    }

    @ViewBuilder
    private var size: some View {
        round("textformat.size.smaller", label: loc("Smaller words")) {
            model.nudgeLyricScale(by: -0.1)
        }
        round("textformat.size.larger", label: loc("Larger words")) {
            model.nudgeLyricScale(by: 0.1)
        }
    }

    @ViewBuilder
    private var source: some View {
        round("arrow.triangle.2.circlepath", label: loc("Try another source")) {
            model.useNextLyricSource()
        }
    }

    private func identifier(_ name: String) -> String {
        (scale == .stage ? "KTV" : "Panel") + name
    }

    private func round(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: scale.button * 0.44, weight: .semibold))
                .foregroundStyle(scale.tint)
                .frame(width: scale.button, height: scale.button)
                .background(scale.tint.opacity(scale.well), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier(symbol))
    }

    private func glyph(
        _ text: String, isOn: Bool, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(verbatim: text)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isOn ? Yun.Palette.accent : scale.quiet)
                .frame(width: scale.button, height: scale.button)
                .background(
                    scale.tint.opacity(isOn ? scale.lit : scale.well), in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier(text))
    }
}
