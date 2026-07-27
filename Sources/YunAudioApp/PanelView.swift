import SwiftUI
import YunAudioEngine
import YunAudioHAL
import YunDesign

/// The menu bar panel.
///
/// Liquid Glass carries the shell so the window sits in macOS 26's material
/// language; everything inside it is YunUI Zinc. Mixing the two at the same
/// level would muddy both, so they stay in separate layers.
struct PanelView: View {
    @Bindable var model: RouterModel
    /// Forces the routed layout for the offscreen design captures. The panel
    /// otherwise shows the onboarding card whenever the driver is absent, which
    /// hides everything worth inspecting.
    var forcesRoutedLayout = false
    @Environment(\.openWindow) private var openWindow

    // Only the mixer starts open: it is the one section watched while routing.
    // Devices open on first run, when there is nothing configured to collapse.
    @State private var showsDevices: Bool?
    @State private var showsApps = false
    @State private var showsProcessing = false

    private var devicesExpanded: Binding<Bool> {
        Binding(
            get: { showsDevices ?? (model.selectedDestination == nil) },
            set: { showsDevices = $0 })
    }

    /// Width of the leading label column. Sized for the longest label in the
    /// panel — "Channels" wrapped mid-word when this was narrower.
    private static let labelColumn: CGFloat = 62

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                header
                if model.isDriverInstalled || forcesRoutedLayout {
                    // A menu bar panel can be long — it scrolls, and the ones
                    // people actually use are. Sections that are read rather
                    // than watched still collapse, so the height is the user's
                    // choice instead of a fixed cost.
                    presets
                    signalPath
                    devicePickers
                    appSources
                    if !model.activeRoutes.isEmpty { mixer }
                    if model.isRunning { runtimeDetail }
                    if let error = model.lastError { errorRow(error) }
                    voiceIsolation
                    footer
                } else {
                    driverMissing
                }
            }
            .padding(Yun.Space.lg)
            .frame(width: 340)
        }
        .background(.clear)
        // Covers the whole subtree. The system focus effect is a blue ring, and
        // blue is the one colour this design system never uses; the controls
        // that can take focus draw their own ring in --border-strong instead.
        .focusEffectDisabled()
    }

    // MARK: Header

    private var header: some View {
        HStack {
            if let mark = YunAppIcon.image {
                Image(nsImage: mark)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            }
            Text(loc("YunAudio"))
                .font(Yun.Text.title)
                .foregroundStyle(Yun.Palette.textPrimary)
            Spacer()
            YunStatusPill(
                loc(model.isRunning ? "Routing" : "Idle"),
                tone: model.isRunning ? .success : .neutral)
        }
    }

    // MARK: Presets

    private var presets: some View {
        HStack(spacing: 6) {
            ForEach(RoutePreset.builtIn) { preset in
                let isActive = model.matches(preset)
                Button {
                    model.apply(preset)
                } label: {
                    Text(loc(preset.name))
                }
                .buttonStyle(YunButtonStyle(isActive ? .primary : .secondary, small: true))
                .help(preset.note)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Signal path

    private var signalPath: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                YunSignalPath(
                    source: model.selectedSource?.name ?? "No input",
                    destination: model.selectedDestination?.name ?? "No output",
                    level: model.peakLevel,
                    isActive: model.isRunning)

                YunLevelMeter(level: model.isRunning ? model.peakLevel : 0)
            }
        }
    }

    // MARK: Pickers

    private var devicePickers: some View {
        YunDisclosure(
            loc("Devices"),
            subtitle: model.selectedSource.map {
                "\($0.name) → \(model.selectedDestination?.name ?? "none")"
            },
            isExpanded: devicesExpanded
        ) {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                picker(
                    "Input", selection: $model.selectedSourceUID,
                    devices: model.inputDevices, channelLabel: { "\($0.inputChannels)ch" })

                YunDivider()

                picker(
                    "Output", selection: $model.selectedDestinationUID,
                    devices: model.outputDevices, channelLabel: { "\($0.outputChannels)ch" })

                if let source = model.selectedSource, source.inputChannels > 1 {
                    YunDivider()
                    channelModeControl(source: source)
                }
            }
        }
    }

    private func picker(
        _ label: String,
        selection: Binding<String?>,
        devices: [AudioDevice],
        channelLabel: @escaping (AudioDevice) -> String
    ) -> some View {
        HStack(spacing: Yun.Space.sm) {
            Text(label)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .frame(width: Self.labelColumn, alignment: .leading)

            YunSelect(
                selection: selection,
                options: devices.map {
                    .init(value: $0.uid as String?, title: $0.name, detail: channelLabel($0))
                })
        }
    }

    private func channelModeControl(source: AudioDevice) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack {
                Text(loc("Channels"))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .frame(width: Self.labelColumn, alignment: .leading)

                YunSegmented(
                    selection: $model.channelMode,
                    options: SourceChannelMode.allCases.map { ($0, loc($0.title)) })
            }

            if model.channelMode == .mono {
                HStack {
                    Text(loc("Source"))
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .frame(width: Self.labelColumn, alignment: .leading)
                    YunSegmented(
                        selection: $model.monoChannel,
                        options: (0..<source.inputChannels).map { ($0, "Ch \($0 + 1)") })
                }
                // The Seiren V3 Pro presents three input channels with only the
                // first carrying the capsule, so this is not an exotic case.
                Text(
                    "This device reports \(source.inputChannels) input channels; not all of them necessarily carry audio."
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Runtime detail

    private var runtimeDetail: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                if let quality = model.pathQuality {
                    YunDetailRow(
                        "Path",
                        value: quality.isBitExact
                            ? "bit-exact"
                            : (quality.hasProcessing ? "processed" : "resampled"),
                        tone: quality.isBitExact ? .success : .warning)
                    YunDetailRow(loc("Rate"), value: "\(Int(quality.sampleRate)) Hz")
                    YunDetailRow(
                        loc("Buffer"),
                        value: String(
                            format: "%d frames · %.2f ms",
                            quality.bufferFrames, quality.bufferLatencyMilliseconds))
                }
                if model.isClockLocked {
                    YunDetailRow(
                        loc("Clock"),
                        value: String(format: "locked · %.6f", model.measuredRateRatio),
                        tone: .success)
                }
                if model.clockLockFailed {
                    Text(
                        "The clock lock dropped, so drift correction was switched back on. Audio is safe but no longer bit-exact."
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Driver onboarding

    private var driverMissing: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                Text(loc("The YunAudio device is not installed"))
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.textPrimary)
                Text(
                    "Routing needs the virtual audio device. Installing it copies a plug-in into /Library/Audio/Plug-Ins/HAL and restarts coreaudiod, which briefly stops all audio."
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Yun.Space.sm) {
                    if model.canInstallDriver {
                        Button(model.isInstallingDriver ? "Installing…" : "Install") {
                            model.installDriver()
                        }
                        .buttonStyle(YunButtonStyle(.primary, small: true))
                        .disabled(model.isInstallingDriver)
                    }
                    Button(loc("Check again")) { model.refreshDevices() }
                        .buttonStyle(YunButtonStyle(.secondary, small: true))
                }
                if !model.canInstallDriver {
                    Text(
                        "Run ./Driver/build-driver.sh --install from the source tree, or use the copy on the disk image."
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let message = model.driverMessage {
                    Text(message)
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Application sources

    private var appSources: some View {
        YunDisclosure(
            loc("Application audio"),
            subtitle: model.capturedAppBundleIDs.isEmpty
                ? "none captured" : "\(model.capturedAppBundleIDs.count) captured",
            isExpanded: $showsApps
        ) {
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                HStack {
                    Text(loc("Pick the applications to mix in"))
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                    Spacer()
                    Button(loc("Refresh")) { model.refreshApps() }
                        .buttonStyle(YunButtonStyle(.ghost, small: true))
                }

                if model.availableApps.isEmpty {
                    Text(loc("No applications are producing audio right now."))
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                } else {
                    ForEach(model.availableApps.prefix(6)) { process in
                        appRow(process)
                    }
                }

                if !model.capturedAppBundleIDs.isEmpty {
                    YunDivider()
                    HStack {
                        Text(loc("While routed"))
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.textTertiary)
                            .frame(width: Self.labelColumn, alignment: .leading)
                        YunSegmented(
                            selection: $model.tapMuteBehavior,
                            options: TapMuteBehavior.allCases.map { ($0, loc($0.title)) })
                    }
                }
            }
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
            YunHoverRow {
                HStack(spacing: Yun.Space.sm) {
                    Image(systemName: isCaptured ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(
                            isCaptured ? Yun.Palette.accent : Yun.Palette.textMuted)
                    Text(process.name)
                        .font(Yun.Text.body)
                        .foregroundStyle(Yun.Palette.textPrimary)
                        .lineLimit(1)
                    if process.isPlaying {
                        YunBadge("playing")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(bundle.isEmpty)
    }

    // MARK: Route mixer

    private var mixer: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                Text(loc("Mixer"))
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.textPrimary)
                ForEach(Array(model.activeRoutes.enumerated()), id: \.offset) { index, route in
                    routeRow(index: index, route: route)
                    if index < model.activeRoutes.count - 1 { YunDivider() }
                }
            }
        }
    }

    private func routeRow(index: Int, route: Route) -> some View {
        let level = index < model.routeLevels.count ? model.routeLevels[index] : 0
        let isMuted = index < model.routeMutes.count ? model.routeMutes[index] : false
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Yun.Space.sm) {
                Button {
                    model.setMuted(!isMuted, forRouteAt: index)
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(
                            isMuted ? Yun.Palette.danger : Yun.Palette.textSecondary
                        )
                        .frame(width: 18, height: 18)
                        .background(Yun.Palette.elevated, in: .rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                Text(model.label(for: route))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: Yun.Space.sm)

                YunLevelMeter(level: isMuted ? 0 : level, segments: 12)
                    .frame(width: 90)
            }

            YunFader(
                decibels: Binding(
                    get: { model.faderDecibels(forRouteAt: index) },
                    set: { model.setFaderDecibels($0, forRouteAt: index) }))
        }
    }

    // MARK: Voice isolation

    private var voiceIsolation: some View {
        YunDisclosure(
            loc("Processing"),
            subtitle: model.voiceIsolationEnabled ? "voice isolation on" : "bypass",
            isExpanded: $showsProcessing
        ) {
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                Toggle(loc("Voice isolation"), isOn: $model.voiceIsolationEnabled)
                    .toggleStyle(YunToggleStyle())

                if model.voiceIsolationEnabled {
                    // The cost is stated up front. Enabling this is a different
                    // product from the 1.3 ms bypass path, and the panel should
                    // not let that happen quietly.
                    Text(
                        model.isRunning
                            ? String(
                                format:
                                    "Apple's on-device model. Adds %.0f ms and ends bit-exactness.",
                                model.voiceIsolationLatencyMilliseconds)
                            : "Apple's on-device model. Adds about 56 ms and ends bit-exactness."
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(
                        "Removes background noise using the model behind FaceTime's Voice Isolation."
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Yun.Space.sm) {
            Button(model.isBusy ? "…" : loc(model.isRunning ? "Stop" : "Start")) {
                model.toggle()
            }
            .buttonStyle(YunButtonStyle(.primary))
            .disabled(model.isBusy)

            Button(loc("Open YunAudio")) { openWindow(id: "main") }
                .buttonStyle(YunButtonStyle(.secondary, small: true))

            Spacer()

            SettingsLink {
                Text(loc("Settings"))
            }
            .buttonStyle(YunButtonStyle(.ghost, small: true))

            Button(loc("Quit")) { NSApplication.shared.terminate(nil) }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
        }
    }
}
