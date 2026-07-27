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
            // The clip edge used to land wherever it landed, which at the
            // window's minimum height meant a line of text sliced in half a few
            // points above the footer. That reads as broken rather than as
            // scrolled, and macOS hides its scrollers until you touch them, so
            // there was nothing else saying the column continued. Trailing space
            // plus a short fade says it.
            ScrollView {
                content()
                    .padding(.bottom, Yun.Space.xl)
            }
            // The system scroller is drawn in a style this design has no
            // relationship to — a thick grey bar on a light track — and with
            // three columns there would be three of them, laid over the content
            // rather than beside it. The fade below is the cue instead.
            .scrollIndicators(.never)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.94),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom))
        }
    }

    /// Room for the traffic lights, which float over the content now that the
    /// system title bar is hidden.
    ///
    /// Vertical rather than horizontal: indenting the header past them left the
    /// wordmark hanging seventy points to the right of every column heading
    /// beneath it, and that shared left edge is doing more work than the few
    /// points of height it costs to keep.
    /// A hidden title bar still reserves its height, so the header only has to
    /// clear the traffic lights inside that reserved band — not start below it.
    /// Forty points on top of the reservation put the wordmark seventy-five
    /// points down an eight-hundred-point window.
    private var trafficLightInset: CGFloat { isRendering ? Yun.Space.lg : Yun.Space.xs }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !model.isDriverInstalled {
                DriverOnboarding(model: model, isCompact: true)
                    .padding(.horizontal, Yun.Space.xl)
                    .padding(.bottom, Yun.Space.md)
            } else if let next = model.nextStep {
                nextStepBanner(next)
                    .padding(.horizontal, Yun.Space.xl)
                    .padding(.bottom, Yun.Space.md)
            }

            // Columns separated by space rather than rules: the cards already
            // carry the boundaries, and a 1px line through the middle of a card
            // layout is what made this read as a wireframe.
            HStack(alignment: .top, spacing: Yun.Space.lg) {
                sources
                    .frame(width: 268)
                mixer
                    .frame(maxWidth: .infinity)
                inspector
                    .frame(width: 292)
            }
            .padding(.horizontal, Yun.Space.xl)
            .padding(.bottom, Yun.Space.lg)
            .frame(maxHeight: .infinity, alignment: .top)

            statusBar
        }
        .frame(minWidth: 980, minHeight: 600)
        .yunWindowBackground()
        .focusEffectDisabled()
        .background(shortcuts)
        .background(RemembersFrame(name: "YunAudioMainWindow").frame(width: 0, height: 0))
    }

    /// The last step, which happens in another application.
    ///
    /// Quiet rather than an alert: it is the normal state of a working setup,
    /// not a problem. It disappears when routing stops.
    private func nextStepBanner(_ text: String) -> some View {
        HStack(spacing: Yun.Space.sm) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11))
                .foregroundStyle(Yun.Palette.success)
            Text(text)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Yun.Space.md)
        .padding(.vertical, Yun.Space.sm)
        .background(Yun.Palette.elevated, in: .rect(cornerRadius: Yun.Radius.button))
    }

    /// Keyboard shortcuts for the things done most often.
    ///
    /// An accessory application has no menu bar to hang them on, so they are
    /// attached to zero-sized buttons instead. `.hidden()` would remove them
    /// from the responder chain along with the view, which takes the shortcut
    /// with it — the size has to go to zero while the button stays real.
    private var shortcuts: some View {
        ZStack {
            Button(loc("Record")) { model.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!model.isRunning && !model.isRecording)
            Button(loc("Mute")) { model.toggleMute() }
                .keyboardShortcut("m", modifiers: [.command])
            ForEach(Array(RoutePreset.builtIn.enumerated()), id: \.offset) { index, preset in
                Button(preset.name) { model.apply(preset) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Yun.Space.md) {
            if let mark = YunAppIcon.image {
                Image(nsImage: mark)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
            }
            Text(loc("YunAudio"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Yun.Palette.textPrimary)

            Rectangle()
                .fill(Yun.Palette.borderHairline)
                .frame(width: 1, height: 18)

            ForEach(Array(RoutePreset.builtIn.enumerated()), id: \.offset) { index, preset in
                Button(loc(preset.name)) { model.apply(preset) }
                    .buttonStyle(
                        YunButtonStyle(model.matches(preset) ? .primary : .ghost, small: true)
                    )
                    .help("\(loc(preset.note))  (⌘\(index + 1))")
            }

            Spacer()

            if let error = model.lastError {
                Text(error)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.danger)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(error)
            }

            // The one action the window exists for, in the corner the eye goes
            // to last and reaches for first. It used to sit in a tall bar along
            // the bottom, which spent forty points of height on a single button.
            Button(model.isBusy ? "…" : loc(model.isRunning ? "Stop" : "Start")) {
                model.toggle()
            }
            .buttonStyle(YunButtonStyle(.primary))
            .disabled(model.isBusy)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(loc(model.isRunning ? "Stop routing (⌘↩)" : "Start routing (⌘↩)"))
        }
        .padding(.horizontal, Yun.Space.xl)
        .padding(.top, trafficLightInset)
        .padding(.bottom, Yun.Space.md)
    }

    /// A labelled device picker. The glyph carries the direction so the label
    /// can stay two characters wide and the picker gets the rest.
    private func deviceRow(
        _ label: String, symbol: String, @ViewBuilder _ control: () -> some View
    ) -> some View {
        HStack(spacing: Yun.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(Yun.Palette.textMuted)
                .frame(width: 14)
            control()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }

    // MARK: Sources

    private var sources: some View {
        column {
            VStack(alignment: .leading, spacing: Yun.Space.lg) {
                // One card for both ends of the signal. They were a column
                // apart, with the output alone in a bar across the bottom —
                // which put the two halves of a single decision at opposite
                // corners of the window.
                sectionHeading(loc("Devices"))
                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.md) {
                        deviceRow(loc("In"), symbol: "mic") {
                            YunSelect(
                                selection: $model.selectedSourceUID,
                                options: model.inputDevices.map {
                                    .init(
                                        value: $0.uid as String?, title: $0.name,
                                        detail: "\($0.inputChannels)ch")
                                })
                        }
                        // Hardware gain first, because it is first in the
                        // signal: it happens before the converter, so it is the
                        // one that costs nothing.
                        if let gain = model.hardwareGain, gain.isSettable {
                            HStack(spacing: Yun.Space.sm) {
                                Image(systemName: "dial.medium")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Yun.Palette.textMuted)
                                    .frame(width: 22, height: 22)
                                YunSlider(
                                    fraction: Binding(
                                        get: { Double(model.hardwareGainScalar) },
                                        set: { model.hardwareGainScalar = Float($0) }))
                                Text(model.hardwareGainLabel)
                                    .font(Yun.Text.mono)
                                    .foregroundStyle(Yun.Palette.textTertiary)
                                    .monospacedDigit()
                                    .frame(width: 58, alignment: .trailing)
                            }
                            .help(
                                loc(
                                    "The microphone's own gain, before its converter. Raise this before the trim below — it costs no headroom."
                                ))
                        }

                        LevelRow(
                            decibels: $model.inputDecibels, muted: $model.isInputMuted,
                            label: loc("Input level"))

                        YunDivider()

                        deviceRow(loc("Out"), symbol: "arrow.right.to.line") {
                            YunSelect(
                                selection: $model.selectedDestinationUID,
                                options: model.outputDevices.map {
                                    .init(
                                        value: $0.uid as String?, title: $0.name,
                                        detail: "\($0.outputChannels)ch")
                                })
                        }
                        LevelRow(
                            decibels: $model.outputDecibels, muted: $model.isOutputMuted,
                            label: loc("Output level"))

                        if let source = model.selectedSource, source.inputChannels > 1 {
                            YunDivider()
                            YunSegmented(
                                selection: $model.channelMode,
                                options: SourceChannelMode.allCases.map { ($0, loc($0.title)) })
                            if model.channelMode == .mono {
                                YunSegmented(
                                    selection: $model.monoChannel,
                                    options: (0..<source.inputChannels).map {
                                        ($0, model.sourceChannelLabel($0))
                                    })
                                // Where the device's topology is known, say
                                // what the chosen channel actually is instead
                                // of admitting we do not know.
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
                }

                HStack {
                    sectionHeading(loc("Application audio"))
                    Spacer()
                    Button(loc("Refresh")) { model.refreshApps() }
                        .buttonStyle(YunButtonStyle(.ghost, small: true))
                }

                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.sm) {
                        AppSourceList(model: model, limit: 8, showsRefresh: false)
                        if !model.capturedAppBundleIDs.isEmpty {
                            YunDivider()
                            Text(loc("While routed"))
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textTertiary)
                            YunSegmented(
                                selection: $model.tapMuteBehavior,
                                options: TapMuteBehavior.allCases.map { ($0, loc($0.title)) })
                        }
                    }
                }
            }
        }
    }

    // MARK: Mixer

    private var mixer: some View {
        column {
            VStack(alignment: .leading, spacing: Yun.Space.lg) {
                RoutingCanvas(model: model)

                sectionHeading(loc("Mixer"))

                if model.activeRoutes.isEmpty {
                    YunCard {
                        Text(
                            loc(
                                model.isRunning
                                    ? "No routes are carrying audio."
                                    : "Start routing to see the mix.")
                        )
                        .font(Yun.Text.body)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(Array(model.activeRoutes.enumerated()), id: \.offset) {
                        index, route in
                        YunCard { RouteStrip(model: model, index: index, route: route) }
                    }
                }
            }
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        column {
            VStack(alignment: .leading, spacing: Yun.Space.lg) {
                sectionHeading(loc("Processing"))
                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.md) {
                        ForEach(EffectKind.allCases) { kind in
                            effectRow(kind)
                            if kind != EffectKind.allCases.last { YunDivider() }
                        }
                        if model.enabledEffects.contains(.voiceIsolation) {
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

                sectionHeading(loc("Recording"))
                YunCard {
                    RecordingControls(model: model)
                }

                sectionHeading(loc("Echo cancellation"))
                YunCard {
                    EchoCancellationControls(model: model, labelColumn: nil)
                }

                sectionHeading(loc("Signal path"))
                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.sm) {
                        if let quality = model.pathQuality {
                            YunDetailRow(
                                loc("Integrity"),
                                value: loc(quality.integrityKey),
                                tone: quality.isBitExact ? .success : .warning)
                            YunDetailRow(loc("Rate"), value: "\(Int(quality.sampleRate)) Hz")
                            YunDetailRow(
                                loc("Buffer"),
                                value: String(
                                    format: "%d · %.2f ms",
                                    quality.bufferFrames, quality.bufferLatencyMilliseconds))
                            if model.isClockLocked {
                                YunDetailRow(
                                    loc("Clock"),
                                    value: String(
                                        format: "locked %.6f", model.measuredRateRatio),
                                    tone: .success)
                                YunDetailRow(
                                    loc("Crystal"),
                                    value: String(
                                        format: "%+.1f ppm",
                                        (model.measuredRateRatio - 1) * 1_000_000))
                            }
                        } else {
                            YunEmptyState(
                                symbol: "waveform.path.ecg",
                                message: loc("Start routing to measure the path.")
                            )
                            .frame(maxWidth: .infinity)
                        }
                        if model.addedLatencyMilliseconds > 0 {
                            YunDetailRow(
                                loc("Added by DSP"),
                                value: String(
                                    format: "%.0f ms", model.addedLatencyMilliseconds),
                                tone: .warning)
                        }
                    }
                }
            }
        }
    }

    private func effectRow(_ kind: EffectKind) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(
                loc(kind.title),
                isOn: Binding(
                    get: { model.enabledEffects.contains(kind) },
                    set: { model.setEffect(kind, enabled: $0) })
            )
            .toggleStyle(YunToggleStyle())
            Text(loc(kind.detail))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // The knobs appear only for a stage that is on: a slider for
            // something bypassed invites the reasonable assumption that moving
            // it will do something.
            if model.enabledEffects.contains(kind) {
                ForEach(kind.parameters) { parameter in
                    parameterRow(parameter, in: kind)
                }
                .padding(.top, 2)
            }
        }
    }

    private func parameterRow(_ parameter: EffectParameter, in kind: EffectKind) -> some View {
        let value = model.value(of: parameter, in: kind)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(loc(parameter.title))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                Spacer()
                Text(parameter.formatted(value))
                    .font(Yun.Text.mono)
                    .foregroundStyle(Yun.Palette.textSecondary)
            }
            YunSlider(
                fraction: Binding(
                    get: { parameter.fraction(for: model.value(of: parameter, in: kind)) },
                    set: {
                        model.setValue(parameter.value(atFraction: $0), of: parameter, in: kind)
                    }
                ))
        }
    }

    // MARK: Status bar

    /// A thin strip of live numbers along the bottom, after OBS.
    ///
    /// What was here before was a forty-point bar carrying one device picker
    /// and one button, both of which belong somewhere else — the picker beside
    /// its opposite number, the button in the corner. What a bottom bar is
    /// actually good for is the readings you glance at without stopping: is it
    /// running, at what rate, how much latency, how long have I been recording.
    private var statusBar: some View {
        HStack(spacing: 0) {
            // The lamp. Green while audio moves, red while recording, grey at
            // rest — the one thing readable from across a desk.
            HStack(spacing: 6) {
                Circle()
                    .fill(lampColour)
                    .frame(width: 7, height: 7)
                Text(statusWord)
                    .foregroundStyle(Yun.Palette.textSecondary)
            }
            .padding(.trailing, Yun.Space.md)

            if let quality = model.pathQuality {
                statusDivider
                statusField("\(Int(quality.sampleRate / 1000)) kHz")
                statusDivider
                statusField(
                    String(
                        format: "%d f · %.2f ms", quality.bufferFrames,
                        quality.bufferLatencyMilliseconds))
                statusDivider
                statusField(
                    loc(quality.integrityKey),
                    tone: quality.isBitExact ? Yun.Palette.success : Yun.Palette.warning)
                if model.isClockLocked {
                    statusDivider
                    statusField(
                        String(
                            format: "%+.1f ppm", (model.measuredRateRatio - 1) * 1_000_000),
                        tone: Yun.Palette.success)
                }
            }

            if model.isRecording {
                statusDivider
                statusField(
                    "\(loc("REC"))  \(Self.clock(model.recordingSeconds))",
                    tone: Yun.Palette.danger)
            }

            Spacer(minLength: Yun.Space.md)

            // Dropouts last, on the right, where a number that is normally zero
            // can sit without drawing the eye until it is not.
            if model.watchesIOAllocations && model.allocationViolations > 0 {
                statusField(
                    String(
                        format: loc("%d IO allocations"), model.allocationViolations),
                    tone: Yun.Palette.warning)
            }
            if let dropped = model.echoStatus?.dropped, dropped > 0 {
                statusDivider
                statusField(
                    String(format: loc("%llu dropped"), dropped),
                    tone: Yun.Palette.danger)
            }
            statusField(model.isDriverInstalled ? loc("YunAudio") : loc("no driver"))
        }
        .font(Yun.Text.mono)
        .frame(height: 26)
        .padding(.horizontal, Yun.Space.xl)
        .background(statusBarBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(Yun.Palette.borderHairline).frame(height: 1)
        }
    }

    @ViewBuilder
    private var statusBarBackground: some View {
        if YunTheme.shared.style == .glass {
            Rectangle().fill(.ultraThinMaterial)
        } else {
            Rectangle().fill(Yun.Palette.card)
        }
    }

    private var lampColour: Color {
        if model.isRecording { return Yun.Palette.danger }
        return model.isRunning ? Yun.Palette.success : Yun.Palette.textMuted
    }

    private var statusWord: String {
        if model.isBusy { return loc("Working") }
        return loc(model.isRunning ? "Routing" : "Idle")
    }

    private func statusField(_ text: String, tone: Color? = nil) -> some View {
        Text(text)
            .foregroundStyle(tone ?? Yun.Palette.textTertiary)
            .monospacedDigit()
            .fixedSize()
            .padding(.horizontal, Yun.Space.md)
    }

    private var statusDivider: some View {
        Rectangle()
            .fill(Yun.Palette.borderHairline)
            .frame(width: 1, height: 12)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Yun.Palette.textTertiary)
            .textCase(.uppercase)
    }
}
