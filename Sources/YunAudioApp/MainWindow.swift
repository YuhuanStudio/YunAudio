import SwiftUI
import YunAudioEngine
import YunAudioHAL
import YunDesign

/// The application proper.
///
/// The menu bar panel is for glancing at and toggling; this is where the work
/// happens. It is laid out in columns rather than as one tall stack because a
/// desktop window has width to spend and a routing tool has three things you
/// want visible at once — what is coming in, what the mixer is doing with it,
/// and what the signal path costs. Stacking those vertically is a phone layout
/// on a machine that is not a phone.
struct MainWindow: View {
    @Bindable var model: RouterModel
    /// Skips the scroll views. `ImageRenderer` gives a ScrollView no height, so
    /// the offscreen design captures come out as three empty columns otherwise.
    var isRendering = false

    @ViewBuilder
    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        if isRendering {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView { content() }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Yun.Palette.borderHairline).frame(height: 1)

            HStack(alignment: .top, spacing: 0) {
                sources
                    .frame(width: 260)
                Rectangle().fill(Yun.Palette.borderHairline).frame(width: 1)
                mixer
                    .frame(maxWidth: .infinity)
                Rectangle().fill(Yun.Palette.borderHairline).frame(width: 1)
                inspector
                    .frame(width: 280)
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(Yun.Palette.borderHairline).frame(height: 1)
            footer
        }
        .frame(minWidth: 940, minHeight: 560)
        .background(Yun.Palette.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Yun.Space.md) {
            Text("YunAudio")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Yun.Palette.textPrimary)

            Rectangle()
                .fill(Yun.Palette.borderHairline)
                .frame(width: 1, height: 18)

            ForEach(RoutePreset.builtIn) { preset in
                Button(preset.name) { model.apply(preset) }
                    .buttonStyle(
                        YunButtonStyle(model.matches(preset) ? .primary : .ghost, small: true))
                    .help(preset.note)
            }

            Spacer()

            YunStatusPill(
                model.isRunning ? "Routing" : "Idle",
                tone: model.isRunning ? .success : .neutral)
        }
        .padding(.horizontal, Yun.Space.lg)
        .padding(.vertical, Yun.Space.md)
    }

    // MARK: Sources

    private var sources: some View {
        column {
            VStack(alignment: .leading, spacing: Yun.Space.lg) {
                sectionHeading("Input")
                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.md) {
                        YunSelect(
                            selection: $model.selectedSourceUID,
                            options: model.inputDevices.map {
                                .init(value: $0.uid as String?, title: $0.name,
                                      detail: "\($0.inputChannels)ch")
                            })

                        if let source = model.selectedSource, source.inputChannels > 1 {
                            YunDivider()
                            YunSegmented(
                                selection: $model.channelMode,
                                options: SourceChannelMode.allCases.map { ($0, $0.title) })
                            if model.channelMode == .mono {
                                YunSegmented(
                                    selection: $model.monoChannel,
                                    options: (0..<source.inputChannels).map {
                                        ($0, "Ch \($0 + 1)")
                                    })
                                Text("This device reports \(source.inputChannels) input channels; not all of them necessarily carry audio.")
                                    .font(Yun.Text.caption)
                                    .foregroundStyle(Yun.Palette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                HStack {
                    sectionHeading("Application audio")
                    Spacer()
                    Button("Refresh") { model.refreshApps() }
                        .buttonStyle(YunButtonStyle(.ghost, small: true))
                }

                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.sm) {
                        if model.availableApps.isEmpty {
                            Text("Nothing is producing audio right now.")
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textTertiary)
                        } else {
                            ForEach(model.availableApps.prefix(10)) { process in
                                appRow(process)
                            }
                        }
                        if !model.capturedAppBundleIDs.isEmpty {
                            YunDivider()
                            Text("While routed")
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textTertiary)
                            YunSegmented(
                                selection: $model.tapMuteBehavior,
                                options: TapMuteBehavior.allCases.map { ($0, $0.title) })
                        }
                    }
                }
            }
            .padding(Yun.Space.lg)
        }
    }

    private func appRow(_ process: AudioProcess) -> some View {
        let bundle = process.bundleID ?? ""
        let isCaptured = model.capturedAppBundleIDs.contains(bundle)
        return Button {
            guard !bundle.isEmpty else { return }
            if isCaptured {
                model.capturedAppBundleIDs.remove(bundle)
            } else {
                model.capturedAppBundleIDs.insert(bundle)
            }
        } label: {
            HStack(spacing: Yun.Space.sm) {
                Image(systemName: isCaptured ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isCaptured ? Yun.Palette.accent : Yun.Palette.textMuted)
                Text(process.name)
                    .font(Yun.Text.body)
                    .foregroundStyle(Yun.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if process.isPlaying { YunBadge("playing") }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(bundle.isEmpty)
    }

    // MARK: Mixer

    private var mixer: some View {
        column {
            VStack(alignment: .leading, spacing: Yun.Space.lg) {
                sectionHeading("Mixer")

                if model.activeRoutes.isEmpty {
                    YunCard {
                        Text(model.isRunning
                            ? "No routes are carrying audio."
                            : "Start routing to see the mix.")
                            .font(Yun.Text.body)
                            .foregroundStyle(Yun.Palette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(Array(model.activeRoutes.enumerated()), id: \.offset) { index, route in
                        routeStrip(index: index, route: route)
                    }
                }
            }
            .padding(Yun.Space.lg)
        }
    }

    private func routeStrip(index: Int, route: Route) -> some View {
        let level = index < model.routeLevels.count ? model.routeLevels[index] : 0
        let isMuted = index < model.routeMutes.count ? model.routeMutes[index] : false
        let decibels = model.faderDecibels(forRouteAt: index)

        return YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                HStack(spacing: Yun.Space.md) {
                    Button {
                        model.setMuted(!isMuted, forRouteAt: index)
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(
                                isMuted ? Yun.Palette.danger : Yun.Palette.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(Yun.Palette.elevated, in: .rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()

                    Text(model.label(for: route))
                        .font(Yun.Text.body)
                        .foregroundStyle(Yun.Palette.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: Yun.Space.md)

                    Text(decibels <= -40 ? "−∞" : String(format: "%+.1f dB", decibels))
                        .font(Yun.Text.mono)
                        .foregroundStyle(Yun.Palette.textTertiary)
                }

                YunLevelMeter(level: isMuted ? 0 : level, segments: 32)

                YunFader(decibels: Binding(
                    get: { model.faderDecibels(forRouteAt: index) },
                    set: { model.setFaderDecibels($0, forRouteAt: index) }))
            }
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        column {
            VStack(alignment: .leading, spacing: Yun.Space.lg) {
                sectionHeading("Processing")
                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.md) {
                        ForEach(EffectKind.allCases) { kind in
                            effectRow(kind)
                            if kind != EffectKind.allCases.last { YunDivider() }
                        }
                        if model.enabledEffects.contains(.voiceIsolation) {
                            Text("Processing means the path is no longer bit-exact. That is the trade, not a fault.")
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                sectionHeading("Signal path")
                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.sm) {
                        if let quality = model.pathQuality {
                            YunDetailRow(
                                "Integrity",
                                value: quality.isBitExact
                                    ? "bit-exact"
                                    : (quality.hasProcessing ? "processed" : "resampled"),
                                tone: quality.isBitExact ? .success : .warning)
                            YunDetailRow("Rate", value: "\(Int(quality.sampleRate)) Hz")
                            YunDetailRow(
                                "Buffer",
                                value: String(
                                    format: "%d · %.2f ms",
                                    quality.bufferFrames, quality.bufferLatencyMilliseconds))
                            if model.isClockLocked {
                                YunDetailRow(
                                    "Clock",
                                    value: String(format: "locked %.6f", model.measuredRateRatio),
                                    tone: .success)
                                YunDetailRow(
                                    "Crystal",
                                    value: String(
                                        format: "%+.1f ppm",
                                        (model.measuredRateRatio - 1) * 1_000_000))
                            }
                        } else {
                            Text("Start routing to measure the path.")
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textTertiary)
                        }
                        if model.addedLatencyMilliseconds > 0 {
                            YunDetailRow(
                                "Added by DSP",
                                value: String(
                                    format: "%.0f ms", model.addedLatencyMilliseconds),
                                tone: .warning)
                        }
                    }
                }
            }
            .padding(Yun.Space.lg)
        }
    }

    private func effectRow(_ kind: EffectKind) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(kind.title, isOn: Binding(
                get: { model.enabledEffects.contains(kind) },
                set: { model.setEffect(kind, enabled: $0) }))
                .toggleStyle(YunToggleStyle())
            Text(kind.detail)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Yun.Space.md) {
            Text("Output")
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            YunSelect(
                selection: $model.selectedDestinationUID,
                options: model.outputDevices.map {
                    .init(value: $0.uid as String?, title: $0.name,
                          detail: "\($0.outputChannels)ch")
                })
            .frame(width: 280)

            if let error = model.lastError {
                Text(error)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.danger)
                    .lineLimit(1)
            }

            Spacer()

            Button(model.isRunning ? "Stop" : "Start") { model.toggle() }
                .buttonStyle(YunButtonStyle(.primary))
        }
        .padding(.horizontal, Yun.Space.lg)
        .padding(.vertical, Yun.Space.md)
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Yun.Palette.textTertiary)
            .textCase(.uppercase)
    }
}
