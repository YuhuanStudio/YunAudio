import SwiftUI
import YunAudioEngine
import YunDesign

/// One channel strip: mute, solo, name, level, fader.
///
/// Shared between the window and the panel from the start, rather than after
/// the two copies drift — which is what happened to the application list, the
/// recording controls, the echo cancellation controls and the level row.
struct RouteStrip: View {
    @Bindable var model: RouterModel
    let index: Int
    let route: Route
    /// The panel is 340 points wide; the window has room for the readout.
    var isCompact = false

    var body: some View {
        let muted = index < model.routeMutes.count && model.routeMutes[index]
        let silenced = model.isSilenced(index)
        let soloed = model.soloedRoute == index
        let level = index < model.routeLevels.count ? model.routeLevels[index] : 0
        let hold = index < model.peakHolds.count ? model.peakHolds[index] : 0
        let clipping = index < model.clipped.count && model.clipped[index]

        VStack(alignment: .leading, spacing: Yun.Space.md) {
            HStack(spacing: Yun.Space.sm) {
                iconButton(
                    symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    tone: muted ? Yun.Palette.danger : Yun.Palette.textSecondary,
                    label: muted ? loc("Unmute") : loc("Mute")
                ) {
                    model.setMuted(!muted, forRouteAt: index)
                }

                // Solo is a view of the mix, not a setting: it silences
                // everything else without touching what each route's own mute
                // says, so releasing it puts the mix back as it was.
                iconButton(
                    symbol: "headphones",
                    tone: soloed ? Yun.Palette.accentForeground : Yun.Palette.textSecondary,
                    background: soloed ? Yun.Palette.accent : Yun.Palette.elevated,
                    label: loc("Solo")
                ) {
                    model.toggleSolo(index)
                }

                Text(model.label(for: route))
                    .font(Yun.Text.body)
                    .foregroundStyle(
                        silenced ? Yun.Palette.textMuted : Yun.Palette.textPrimary
                    )
                    .lineLimit(1)

                Spacer(minLength: Yun.Space.sm)

                if clipping {
                    // Latched, and clearing it is a deliberate click: a clip
                    // indicator that resets itself is one nobody ever sees.
                    Button(loc("CLIP")) { model.clearClipping() }
                        .font(Yun.Text.mono)
                        .foregroundStyle(Yun.Palette.danger)
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(loc("The signal reached full scale. Click to reset."))
                }

                if !isCompact {
                    Text(readout)
                        .font(Yun.Text.mono)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .monospacedDigit()
                }
            }

            YunLevelMeter(
                level: silenced ? 0 : level,
                peakHold: silenced ? 0 : hold,
                segments: isCompact ? 12 : 32)

            YunFader(
                decibels: Binding(
                    get: { model.faderDecibels(forRouteAt: index) },
                    set: { model.setFaderDecibels($0, forRouteAt: index) }))
        }
    }

    private var readout: String {
        let decibels = model.faderDecibels(forRouteAt: index)
        return decibels <= RouterModel.minimumDecibels
            ? "−∞" : String(format: "%+.1f dB", decibels)
    }

    private func iconButton(
        symbol: String, tone: Color, background: Color = Yun.Palette.elevated,
        label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tone)
                .frame(width: 24, height: 24)
                .background(background, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(Text(label))
    }
}
