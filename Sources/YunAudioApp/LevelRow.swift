import SwiftUI
import YunDesign

/// A mute button, a fader and the value, for one end of the signal.
///
/// Shared because it was written twice on the day it was added — once in the
/// window and once in the panel — which is how the application lists, the
/// recording controls and the app-bundle assembly each ended up as two copies
/// that drifted. The pattern is reliable enough to be worth naming: anything
/// both surfaces show belongs in one view.
struct LevelRow: View {
    @Binding var decibels: Float
    @Binding var muted: Bool
    let label: String
    /// The panel is 340 points wide and has no room for a units suffix.
    var isCompact = false

    var body: some View {
        HStack(spacing: Yun.Space.sm) {
            Button {
                muted.toggle()
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(
                        muted ? Yun.Palette.danger : Yun.Palette.textSecondary
                    )
                    .frame(width: 22, height: 22)
                    .background(
                        isCompact ? Color.clear : Yun.Palette.elevated,
                        in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(muted ? loc("Muted") : loc("Unmuted")))

            YunFader(decibels: $decibels)
                .accessibilityLabel(Text(label))
                .opacity(muted ? 0.4 : 1)

            Text(reading)
                .font(Yun.Text.mono)
                .foregroundStyle(Yun.Palette.textTertiary)
                .monospacedDigit()
                .frame(width: isCompact ? 40 : 58, alignment: .trailing)
        }
    }

    private var reading: String {
        guard decibels > RouterModel.minimumDecibels else { return "−∞" }
        return String(format: isCompact ? "%+.1f" : "%+.1f dB", decibels)
    }
}
