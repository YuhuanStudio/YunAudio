import SwiftUI
import YunDesign

/// Previous, play or pause, next — and the two knobs a KTV machine has that a
/// player does not.
///
/// Extracted because the panel inside the main window had none of it. The stage
/// grew a transport, a key and 原唱／伴奏 over several rounds and the panel was
/// left behind: it could show the words for a song it had no way to pause. Two
/// presentations of one song that disagree about what can be done to it is the
/// same defect as two that disagree about who is singing.
///
/// One construction, two sizes. The stage has room for 32-point circles and the
/// inspector column does not, so the size is a parameter rather than a second
/// copy of the layout.
struct KTVTransportBar: View {

    enum Scale {
        case stage
        case inspector

        var play: CGFloat { self == .stage ? 32 : 28 }
        var step: CGFloat { self == .stage ? 26 : 23 }
        var spacing: CGFloat { self == .stage ? Yun.Space.sm : 6 }
        /// White on the stage, which sits on a darkened photograph; the
        /// inspector's own text colour otherwise, so the row belongs to the
        /// card rather than looking pasted on.
        var tint: Color { self == .stage ? .white : Yun.Palette.textPrimary }
        var wellOpacity: Double { self == .stage ? 0.16 : 0.10 }
    }

    @Bindable var model: RouterModel
    let track: NowPlaying.Track
    var scale: Scale = .stage
    /// Whether the key and 原唱／伴奏 controls are offered. They only mean
    /// anything for a song this application is playing itself.
    var showsKaraokeControls = true

    var body: some View {
        HStack(spacing: scale.spacing) {
            button(
                "backward.fill", label: loc("Previous track"), size: scale.step,
                identifier: identifier("PreviousTrack")
            ) { model.sendTransport(.previous) }
            button(
                track.isPlaying ? "pause.fill" : "play.fill",
                label: track.isPlaying ? loc("Pause") : loc("Play"), size: scale.play,
                identifier: identifier("PlayPause")
            ) { model.sendTransport(.playPause) }
            button(
                "forward.fill", label: loc("Next track"), size: scale.step,
                identifier: identifier("NextTrack")
            ) { model.sendTransport(.next) }

            if showsKaraokeControls, model.canTransposeSong {
                Divider().frame(height: scale.step * 0.7).opacity(0.35)
                button(
                    "minus", label: loc("Lower the key"), size: scale.step,
                    identifier: identifier("KeyDown")
                ) { model.shiftSongKey(by: -1) }
                Text(SongKeys.title(model.songKeySemitones, original: loc("Original key")))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(scale.tint.opacity(0.85))
                    .frame(minWidth: 34)
                button(
                    "plus", label: loc("Raise the key"), size: scale.step,
                    identifier: identifier("KeyUp")
                ) { model.shiftSongKey(by: 1) }
            }

            if showsKaraokeControls, model.canCancelLeadVocal {
                button(
                    model.isCancellingLeadVocal ? "music.mic.circle.fill" : "music.mic.circle",
                    label: model.isCancellingLeadVocal
                        ? loc("Bring the lead vocal back") : loc("Take the lead vocal out"),
                    size: scale.step,
                    identifier: identifier("LeadVocal")
                ) { model.toggleLeadVocal() }
            }
        }
    }

    /// Distinct identifiers per presentation, so a check that presses the
    /// stage's play button cannot accidentally press the panel's.
    private func identifier(_ name: String) -> String {
        scale == .stage ? "KTV\(name)" : "Panel\(name)"
    }

    private func button(
        _ symbol: String, label: String, size: CGFloat, identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(scale.tint)
                .frame(width: size, height: size)
                .background(
                    scale.tint.opacity(size > 30 ? scale.wellOpacity : scale.wellOpacity * 0.62),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
