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
    /// One logical source and all of its channels, rather than one wire.
    ///
    /// A stereo source used to be two strips: two faders, two mutes and two
    /// solo buttons for one microphone, kept in step by hand until somebody
    /// moved one of them.
    let group: RouterModel.SourceGroup
    /// The panel is 340 points wide; the window has room for the readout.
    var isCompact = false

    var body: some View {
        guard let route = model.representative(of: group) else {
            return AnyView(EmptyView())
        }
        let muted = model.isMuted(group)
        let silenced = model.isSilenced(group)
        let soloed = model.soloedGroup == group.uid
        let level = model.level(of: group)
        let hold = model.peakHold(of: group)
        let clipping = model.isClipped(group)
        return AnyView(
            strip(
                route: route, muted: muted, silenced: silenced, soloed: soloed,
                level: level, hold: hold, clipping: clipping))
    }

    private func strip(
        route: Route, muted: Bool, silenced: Bool, soloed: Bool,
        level: Float, hold: Float, clipping: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            HStack(spacing: Yun.Space.sm) {
                iconButton(
                    symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    tone: muted ? Yun.Palette.danger : Yun.Palette.textSecondary,
                    label: muted ? loc("Unmute") : loc("Mute")
                ) {
                    model.setMuted(!muted, for: group)
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
                    model.toggleSolo(group)
                }

                Text(model.sourceLabel(for: group))
                    .font(Yun.Text.body)
                    .foregroundStyle(
                        silenced ? Yun.Palette.textMuted : Yun.Palette.textPrimary
                    )
                    .lineLimit(1)

                // What this source counts as, and a way to correct it.
                //
                // The balance pass needs to know which sources are people and
                // which are music, and it guesses from the bundle identifier —
                // a guess that is right for Discord and Spotify and cannot
                // possibly be right for everything. Putting it on the strip
                // means correcting it is one click at the moment somebody
                // notices, rather than a setting they have to go and find.
                if !isCompact, model.canChangeRole(of: route) {
                    Button {
                        model.toggleRole(of: route)
                    } label: {
                        YunBadge(loc(model.role(of: route).title))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(loc("What this source counts as when balancing. Click to change."))
                }

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
                    get: { model.faderDecibels(of: group) },
                    set: { model.setFaderDecibels($0, for: group) }))

            // The second mix. What you hear, separately from what the far end
            // hears — which is the thing every tool praised for this is praised
            // for, and cannot be expressed with one fader however many of them
            // there are.
            if model.monitorDeviceUID != nil, !isCompact {
                HStack(spacing: Yun.Space.sm) {
                    Image(systemName: "headphones")
                        .font(.system(size: 9))
                        .foregroundStyle(Yun.Palette.textMuted)
                        .frame(width: 14)
                    YunFader(
                        decibels: Binding(
                            get: { model.monitorSendDecibels(of: group) },
                            set: { model.setMonitorSend($0, for: group) }))
                    Text(monitorReadout)
                        .font(Yun.Text.mono)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private var monitorReadout: String {
        let decibels = model.monitorSendDecibels(of: group)
        return decibels <= RouterModel.minimumDecibels
            ? loc("off") : String(format: "%+.1f", decibels)
    }

    private var readout: String {
        let decibels = model.faderDecibels(of: group)
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
