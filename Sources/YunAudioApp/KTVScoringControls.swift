import SwiftUI
import YunDesign

/// The scoring switch, the note being sung, and how far the song would have to
/// move for this singer.
///
/// The stage — the surface people actually sing at — could not turn scoring on,
/// could not see the note it was hearing, and could not act on the key it was
/// suggesting. All of that lived in the inspector column behind it, which is
/// the one place nobody looks while singing.
///
/// Two sizes, one construction, like the transport and the words. The stage puts
/// it under the artwork where there is room; the panel keeps it in the column.
struct KTVScoringControls: View {

    enum Scale {
        case stage
        case inspector

        var title: Font {
            self == .stage ? .system(size: 13, weight: .semibold) : Yun.Text.label
        }
        var caption: Font {
            self == .stage ? .system(size: 11, weight: .regular) : Yun.Text.caption
        }
        var tint: Color { self == .stage ? .white : Yun.Palette.textPrimary }
        var quiet: Color {
            self == .stage ? .white.opacity(0.6) : Yun.Palette.textSecondary
        }
    }

    @Bindable var model: RouterModel
    var scale: Scale = .stage

    var body: some View {
        let _ = BodyCount.tick(scale == .stage ? "KTVScoringStage" : "KTVScoringPanel")
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack(spacing: Yun.Space.sm) {
                Toggle(loc("Score the singing"), isOn: $model.isScoringSinging)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel(loc("Score the singing"))
                    .accessibilityIdentifier(identifier("ScoreSwitch"))
                Text(loc("Score the singing"))
                    .font(scale.title)
                    .foregroundStyle(scale.tint)
                Spacer(minLength: Yun.Space.sm)
                // The note being heard, which is the one reading that is useful
                // before a single line has been scored: it says the microphone
                // is hearing *you*.
                if let note = model.heardNote {
                    Text(note)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Yun.Palette.accent)
                        .accessibilityIdentifier(identifier("HeardNote"))
                }
            }
            if let error = model.singingError {
                Text(error)
                    .font(scale.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            key
        }
    }

    /// What key the song is in, and how far it would have to move.
    ///
    /// The suggestion is the KTV feature people actually want and it was
    /// reachable from one presentation only: sing a few lines, and it works out
    /// the shift that puts the song in your range. Acting on it from the stage
    /// is the whole point — that is where somebody is standing when they
    /// discover the song is too high.
    @ViewBuilder
    private var key: some View {
        if let songKey = model.songKey {
            HStack(spacing: Yun.Space.sm) {
                Text(String(format: loc("This song is in %@"), songKey.name))
                    .font(scale.caption)
                    .foregroundStyle(scale.quiet)
                if let shift = model.suggestedShift, shift != 0 {
                    Button {
                        model.applySuggestedShift()
                    } label: {
                        Text(
                            String(
                                format: loc("Move it %@ for you"),
                                SongKeys.title(shift, original: loc("Original key")))
                        )
                        .font(scale.caption)
                    }
                    .buttonStyle(YunButtonStyle(.primary, small: true))
                    .accessibilityIdentifier(identifier("ApplySuggestedShift"))
                }
            }
        } else if model.isScoringSinging {
            Text(loc("Sing a little and it will work out how far to move it."))
                .font(scale.caption)
                .foregroundStyle(scale.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func identifier(_ name: String) -> String {
        (scale == .stage ? "KTV" : "Panel") + name
    }
}
