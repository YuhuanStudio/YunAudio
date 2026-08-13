import SwiftUI
import YunAudioEngine
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
            self == .stage ? Yun.Palette.OnStage.tertiary : Yun.Palette.textSecondary
        }
    }

    @Bindable var model: RouterModel
    var scale: Scale = .stage

    /// Below this the key is reported as a guess rather than as a fact.
    ///
    /// Relative major and minor share every note, so the two best candidates
    /// are routinely within a few per cent of each other and the winner is
    /// arbitrary. Naming the number here rather than writing 0.3 twice is the
    /// difference between a threshold and a coincidence.
    static let aGuessBelow: Double = 0.3

    var body: some View {
        let _ = BodyCount.tick(scale == .stage ? "KTVScoringStage" : "KTVScoringPanel")
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack(spacing: Yun.Space.sm) {
                // `YunSwitch`, not SwiftUI's `.switch`. The design system has
                // had a switch for custom-labelled rows all along; this used
                // the platform one because the stage is dark and the system
                // one was not, which is a reason to extend the system rather
                // than to leave it.
                YunSwitch(
                    isOn: Binding(
                        get: { model.isScoringRequested },
                        set: { model.setScoringRequested($0) }),
                    onDark: scale == .stage
                )
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
            // The learned head, with what it is for rather than what it is.
            // "Neural pitch" tells somebody nothing they can act on; "helps
            // when the backing track is louder than you" is the decision.
            if model.isScoringSinging, !SingerPitch.isForcedOff {
                HStack(spacing: Yun.Space.sm) {
                    YunSwitch(isOn: $model.usesLearnedPitch, onDark: scale == .stage)
                        .accessibilityLabel(loc("Hear me over the backing track"))
                        .accessibilityIdentifier(identifier("LearnedPitch"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(loc("Hear me over the backing track"))
                            .font(scale.caption)
                            .foregroundStyle(scale.tint)
                        Text(
                            loc(
                                "A small on-device model picks your voice out when the accompaniment is louder than you. It cannot help when it is quieter."
                            )
                        )
                        .font(scale.caption)
                        .foregroundStyle(scale.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let error = model.singingError {
                Text(error)
                    .font(scale.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .yunBoundedMessage(error)
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
                // Said out loud when it is a guess. Relative major and minor
                // share every note, so a weak match is common and printing a
                // letter with a straight face would be a lie.
                //
                // The inspector said it and the stage did not, because the two
                // had grown separate key readouts — the panel's own, and this
                // one. One of them had the honesty and the other had the reach.
                if songKey.confidence <= Self.aGuessBelow {
                    YunBadge(loc("a guess"))
                }
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
        } else if model.isScoringSinging || model.comfortableMidi == nil {
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
