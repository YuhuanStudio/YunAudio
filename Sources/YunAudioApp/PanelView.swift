import SwiftUI
import YunAudioEngine
import YunAudioHAL
import YunDesign

/// The menu bar panel.
///
/// Liquid Glass carries the shell so the window sits in macOS 26's material
/// language; everything inside it is YunUI Zinc. Mixing the two at the same
/// level would muddy both, so they stay in separate layers.
///
/// What belongs in here is what somebody reaches for without opening the
/// window: the two ends of the signal, the trim, the master, the monitor, the
/// scene, and the switches that decide what a call sounds like. It had fallen a
/// long way behind — the window grew ducking, hold-to-talk, transcription, a
/// monitor send and an eleven-stage chain, and none of it existed here, so the
/// panel quietly became a worse copy of the application rather than a faster
/// way into it.
struct PanelView: View {
    @Bindable var model: RouterModel
    /// Forces the routed layout for the offscreen design captures. The panel
    /// otherwise shows the onboarding card whenever the driver is absent, which
    /// hides everything worth inspecting.
    var forcesRoutedLayout = false
    @Environment(\.openWindow) private var openWindow

    // Only the live card and the quick switches start open: they are what the
    // panel is opened for. Devices open on first run, when there is nothing
    // configured to collapse.
    @State private var showsDevices: Bool?
    @State private var showsApps = false
    @State private var showsProcessing = false
    @State private var showsEchoCancellation = false

    private var devicesExpanded: Binding<Bool> {
        Binding(
            get: { showsDevices ?? (model.selectedDestination == nil) },
            set: { showsDevices = $0 })
    }

    /// Width of the leading label column. Sized for the longest label in the
    /// panel — "Channels" wrapped mid-word when this was narrower.
    private static let labelColumn: CGFloat = 62

    var body: some View {
        let _ = BodyCount.tick("PanelView")
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
                live
                StatusPills(model: model, isCompact: true)
                devicePickers
                quickSwitches
                appSources
                if !model.activeRoutes.isEmpty { mixer }
                processing
                echoCancellation
                if let error = model.lastError { errorRow(error) }
                footer
            }
        }
    }

    // MARK: Header

    /// The mark, and the one action the panel exists for.
    ///
    /// Start and stop used to sit in the footer, under everything else and
    /// below the fold on a short screen. What state it produced is a pill in
    /// the row below now, so the header does not have to say it twice.
    private var header: some View {
        HStack(spacing: Yun.Space.sm) {
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
            Button(model.isBusy ? "…" : loc(model.isRunning ? "Stop" : "Start")) {
                model.toggle()
            }
            .buttonStyle(YunButtonStyle(.primary, small: true))
            .disabled(model.isBusy)
        }
    }

    // MARK: Presets

    /// The scenes, wrapped rather than run off the edge.
    ///
    /// The panel offered only the built-in four, because four is what fits
    /// across 340 points in a row. Saved presets are in the window's header and
    /// were nowhere here, which is the wrong way round — a preset is saved
    /// precisely so it can be reached in a hurry. Wrapping costs a line of
    /// height when there is a fifth and nothing when there is not.
    private var presets: some View {
        YunWrap(spacing: 6) {
            ForEach(model.allPresets) { preset in
                let isActive =
                    preset.isUserDefined
                    ? model.activePresetName == preset.name : model.matches(preset)
                Button {
                    model.apply(preset)
                } label: {
                    Text(preset.isUserDefined ? preset.name : loc(preset.name))
                }
                .buttonStyle(YunButtonStyle(isActive ? .primary : .secondary, small: true))
                .help(preset.isUserDefined ? preset.note : loc(preset.note))
            }
        }
    }

    // MARK: The live card

    /// Where the signal is going, how loud it arrives and how loud it leaves.
    ///
    /// The trim and the master were inside the devices disclosure, one click
    /// away in a panel whose whole point is not needing one. They are the two
    /// faders somebody opens this to move.
    private var live: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                YunSignalPath(
                    source: model.selectedSource?.name ?? loc("No input"),
                    destination: model.selectedDestination?.name ?? loc("No output"),
                    level: model.peakLevel,
                    isActive: model.isRunning)

                YunLevelMeter(level: model.isRunning ? model.peakLevel : 0)

                // Named, because two identical faders one above the other are
                // not two controls — they are one control somebody is guessing
                // about. The window can lean on the section each sits in; here
                // they are in the same card.
                levelRow(
                    loc("Input"), decibels: $model.inputDecibels,
                    muted: $model.isInputMuted, label: loc("Input level"))
                levelRow(
                    loc("Master"), decibels: $model.outputDecibels,
                    muted: $model.isOutputMuted, label: loc("Output level"))
            }
        }
    }

    private func levelRow(
        _ caption: String, decibels: Binding<Float>, muted: Binding<Bool>, label: String
    ) -> some View {
        HStack(spacing: Yun.Space.sm) {
            Text(caption)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .frame(width: 44, alignment: .leading)
            LevelRow(decibels: decibels, muted: muted, label: label, isCompact: true)
        }
    }

    // MARK: Pickers

    private var devicePickers: some View {
        YunDisclosure(
            loc("Devices"),
            subtitle: model.selectedSource.map {
                // "No output" rather than "None": the table carries two
                // entries under that key — the other one is the voice preset —
                // and the later of the two is what comes back.
                "\($0.name) → \(model.selectedDestination?.name ?? loc("No output"))"
            },
            isExpanded: devicesExpanded
        ) {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                picker(
                    loc("Input"), selection: $model.selectedSourceUID,
                    devices: model.inputDevices, channelLabel: { "\($0.inputChannels)ch" })
                picker(
                    loc("Output"), selection: $model.selectedDestinationUID,
                    devices: model.outputDevices, channelLabel: { "\($0.outputChannels)ch" })

                if !model.monitorOptions.isEmpty {
                    YunDivider()
                    monitor
                }

                if let source = model.selectedSource, source.inputChannels > 1 {
                    YunDivider()
                    channelModeControl(source: source)
                }
            }
        }
    }

    /// Hearing yourself, on a second output.
    ///
    /// A picker and a send, as in the window. It is not processing — nothing
    /// about the signal going to the far end changes — so it sits with the
    /// devices, which is what it is.
    @ViewBuilder
    private var monitor: some View {
        HStack(spacing: Yun.Space.sm) {
            Text(loc("Monitor"))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .frame(width: Self.labelColumn, alignment: .leading)
            YunSelect(
                selection: $model.monitorDeviceUID,
                placeholder: loc("Off"),
                options: [.init(value: String?.none, title: loc("Off"))]
                    + model.monitorOptions.map {
                        .init(
                            value: $0.uid as String?, title: $0.name,
                            detail: "\($0.outputChannels)ch")
                    })
        }
        if model.monitorDeviceUID != nil {
            HStack(spacing: Yun.Space.sm) {
                Image(systemName: "speaker.wave.1")
                    .font(.system(size: 10))
                    .foregroundStyle(Yun.Palette.textMuted)
                    .frame(width: 22, height: 22)
                YunSlider(
                    fraction: Binding(
                        get: { Double(model.monitorFraction) },
                        set: { model.monitorFraction = Float($0) }))
                Text(model.monitorLabel)
                    .font(Yun.Text.mono)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            if model.monitorMayFeedBack {
                Text(
                    loc(
                        "This output does not look like headphones. Monitoring on speakers puts the microphone back into the room it is listening to."
                    )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
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

    // MARK: Quick switches

    /// The things that decide what a call sounds like.
    ///
    /// Uncollapsed on purpose. Each of these arrived in the window and never
    /// reached here, and each is a decision taken in the ten seconds before a
    /// call starts — which is exactly when this application is a menu bar icon
    /// rather than a window. The paragraph each one carries in the window stays
    /// there and becomes a tooltip here: 340 points is not a place to read.
    private var quickSwitches: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                Text(loc("Quick controls"))
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.textPrimary)

                switchRow(
                    loc("Hold to talk"), isOn: $model.isPushToTalkEnabled,
                    badge: model.activeShortcuts[.pushToTalk]?.displayName,
                    note: model.isPushToTalkEnabled && model.isPushToTalkHeld
                        ? loc("Open") : nil
                )
                .help(
                    loc(
                        "The microphone stays muted until the key is down. Switching it off puts the mute back where it was."
                    ))

                switchRow(loc("Duck under my voice"), isOn: $model.isDucking)
                    .help(
                        loc(
                            "Turns these down while you talk. The level triggers it instantly and the sound model confirms it was speech, so a cough or a keyboard does not pull the music down."
                        ))

                transcription

                YunDivider()
                RecordingControls(model: model, isCompact: true)
            }
        }
    }

    /// Live transcription, as a switch rather than a pair of buttons.
    ///
    /// Said before it is reached for rather than after: on macOS 26 there is no
    /// model to run it, and a dead switch with no explanation teaches nothing.
    @ViewBuilder
    private var transcription: some View {
        switchRow(
            loc("Transcribe"),
            isOn: Binding(
                get: { model.isTranscribing },
                set: { $0 ? model.startTranscribing() : model.stopTranscribing() }),
            note: model.isTranscribing ? loc("Listening") : nil,
            isEnabled: model.transcriptionUnavailableReason == nil)
        if let reason = model.transcriptionUnavailableReason {
            Text(reason)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let error = model.transcriptionError {
            Text(error)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line: what it is, what it is doing, and the switch.
    private func switchRow(
        _ title: String,
        isOn: Binding<Bool>,
        badge: String? = nil,
        note: String? = nil,
        isEnabled: Bool = true
    ) -> some View {
        HStack(spacing: Yun.Space.sm) {
            Text(title)
                .font(Yun.Text.label)
                .foregroundStyle(
                    isEnabled ? Yun.Palette.textPrimary : Yun.Palette.textMuted
                )
                .lineLimit(1)
            if let badge { YunBadge(badge) }
            if let note {
                Text(note)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.success)
            }
            Spacer(minLength: Yun.Space.sm)
            YunSwitch(isOn: isOn)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.5)
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

    // MARK: Processing

    /// The voice and the chain, as the window has them.
    ///
    /// The panel offered one switch — voice isolation — for a chain of eleven
    /// stages, so a setup made in the window could not be read here at all, let
    /// alone changed. The knobs stay in the window: from here a stage is on or
    /// off, which is the part of the decision taken in a hurry.
    private var processing: some View {
        YunDisclosure(
            loc("Processing"),
            subtitle: model.enabledEffects.isEmpty
                ? loc("bypass")
                : String(format: loc("%d on"), model.enabledEffects.count),
            isExpanded: $showsProcessing
        ) {
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                YunSelect(
                    selection: $model.voicePreset,
                    options: VoicePreset.allCases.map {
                        .init(value: $0, title: loc($0.title))
                    })

                YunDivider()

                ForEach(EffectKind.allCases) { kind in
                    Toggle(
                        loc(kind.title),
                        isOn: Binding(
                            get: { model.enabledEffects.contains(kind) },
                            set: { model.setEffect(kind, enabled: $0) })
                    )
                    .toggleStyle(YunToggleStyle())
                    .help(loc(kind.detail))
                }

                if model.enabledEffects.contains(.voiceIsolation) {
                    // The cost is stated up front. Enabling this is a different
                    // product from the 1.3 ms bypass path, and the panel should
                    // not let that happen quietly.
                    Text(
                        loc(
                            "Processing means the path is no longer bit-exact. That is the trade, not a fault."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Yun.Space.sm) {
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
