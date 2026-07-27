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
    @State private var showsEchoCancellation = false
    @State private var showsRecording = false

    private var devicesExpanded: Binding<Bool> {
        Binding(
            get: { showsDevices ?? (model.selectedDestination == nil) },
            set: { showsDevices = $0 })
    }

    /// Width of the leading label column. Sized for the longest label in the
    /// panel — "Channels" wrapped mid-word when this was narrower.
    private static let labelColumn: CGFloat = 62

    var body: some View {
        // Under glass the whole panel is one material; flat, it is a plain
        // surface the cards sit on. Wrapping a flat panel in a glass container
        // is what made the menu bar look like a different application from the
        // window.
        panelBody
            .padding(Yun.Space.lg)
            .frame(width: 340)
            .yunPanelShell()
            // Covers the whole subtree. The system focus effect is a blue ring,
            // and blue is the one colour this design system never uses; the
            // controls that can take focus draw their own ring in
            // --border-strong instead.
            .focusEffectDisabled()
    }

    @ViewBuilder
    private var panelBody: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            header
            // The onboarding card sits above the controls rather than
            // replacing them. Another loopback endpoint routes audio
            // perfectly well, so hiding everything behind "install the
            // driver" turned a working configuration into a dead end.
            if !model.isDriverInstalled && !forcesRoutedLayout {
                DriverOnboarding(model: model)
            }
            if model.selectedDestination != nil || forcesRoutedLayout {
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
                echoCancellation
                recording
                footer
            }
        }
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
                .help(loc(preset.note))
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
                    loc("Input"), selection: $model.selectedSourceUID,
                    devices: model.inputDevices, channelLabel: { "\($0.inputChannels)ch" })
                LevelRow(
                    decibels: $model.inputDecibels, muted: $model.isInputMuted,
                    label: loc("Input level"), isCompact: true)

                YunDivider()

                picker(
                    loc("Output"), selection: $model.selectedDestinationUID,
                    devices: model.outputDevices, channelLabel: { "\($0.outputChannels)ch" })
                LevelRow(
                    decibels: $model.outputDecibels, muted: $model.isOutputMuted,
                    label: loc("Output level"), isCompact: true)

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
                        options: (0..<source.inputChannels).map {
                            ($0, model.sourceChannelLabel($0))
                        })
                }
                // The Seiren V3 Pro presents three input channels with only the
                // first carrying the capsule, so this is not an exotic case.
                Text(
                    model.sourceChannelNames.flatMap {
                        $0.indices.contains(model.monoChannel)
                            ? loc($0[model.monoChannel].detail) : nil
                    }
                        ?? String(
                            format: loc(
                                "This device reports %d input channels; not all of them necessarily carry audio."
                            ), source.inputChannels)
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
                        loc("Path"),
                        value: loc(quality.integrityKey),
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
                        loc(
                            "The clock lock dropped, so drift correction was switched back on. Audio is safe but no longer bit-exact."
                        )
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

    // MARK: Application sources

    private var appSources: some View {
        YunDisclosure(
            loc("Application audio"),
            subtitle: model.capturedAppBundleIDs.isEmpty
                ? loc("none captured")
                : String(
                    format: loc("%d captured"), model.capturedAppBundleIDs.count),
            isExpanded: $showsApps
        ) {
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                AppSourceList(model: model, limit: 6)

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

    // MARK: Route mixer

    private var mixer: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                Text(loc("Mixer"))
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.textPrimary)
                ForEach(Array(model.sourceGroups.enumerated()), id: \.element.id) {
                    index, group in
                    RouteStrip(model: model, group: group, isCompact: true)
                    if index < model.sourceGroups.count - 1 { YunDivider() }
                }
            }
        }
    }

    // MARK: Echo cancellation

    private var echoCancellation: some View {
        YunDisclosure(
            loc("Echo cancellation"),
            subtitle: model.cancelsEcho ? loc("on") : loc("off"),
            isExpanded: $showsEchoCancellation
        ) {
            EchoCancellationControls(model: model, labelColumn: Self.labelColumn)
        }
    }

    // MARK: Recording

    private var recording: some View {
        YunDisclosure(
            loc("Recording"),
            subtitle: model.isRecording ? loc("recording") : loc("idle"),
            isExpanded: $showsRecording
        ) {
            RecordingControls(model: model, isCompact: true)
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
                        loc(
                            "Removes background noise using the model behind FaceTime's Voice Isolation."
                        )
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
