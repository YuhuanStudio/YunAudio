import AppKit
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

    /// Which tab is showing, on the model rather than in `@State`.
    ///
    /// Two reasons, and the second is why it moved. It is worth remembering
    /// across launches — coming back to the tab you were working in is the
    /// ordinary expectation. And the photograph of the real window had no way
    /// to reach it: the offscreen renderer builds a fresh view per tab and
    /// cycles them, but the live window is built once by the scene, so five of
    /// the six tabs had never been photographed at all. A tab nobody
    /// photographs is a tab where anything can be wrong.
    private var inspectorTab: Binding<Inspector> {
        Binding(get: { model.inspectorTab }, set: { model.inspectorTab = $0 })
    }

    init(model: RouterModel, initialInspector: Inspector? = nil, isRendering: Bool = false) {
        self.model = model
        if let initialInspector { model.inspectorTab = initialInspector }
        self.isRendering = isRendering
    }

    @State private var setupName = ""
    @State private var isNamingSetup = false
    @State private var setupOutcome: String?
    @State private var setupOperationID: UUID?
    @State private var isNamingPreset = false
    @State private var presetName = ""
    /// Which buses have their processing open. Empty at launch on purpose.
    @State private var expandedBuses: Set<String> = []
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
            // Fixed depth. This was the mask's last six per cent, which is a
            // different depth at every window size — and nothing could catch
            // that, because the offscreen design render takes the `isRendering`
            // branch above and never builds the scroll view at all.
            .yunScrollFade()
        }
    }

    /// Offscreen renders have no traffic lights. The live header shares their
    /// surface, but its controls still need an internal top margin.
    private var trafficLightInset: CGFloat {
        isRendering ? Yun.Space.lg : WindowChrome.controlClearance
    }

    var body: some View {
        let _ = BodyCount.tick("MainWindow")
        VStack(spacing: 0) {
            header

            if model.deviceInventoryIsReady && !model.isDriverInstalled {
                DriverOnboarding(model: model, isCompact: true)
                    .padding(.horizontal, Yun.Space.xl)
                    .padding(.bottom, Yun.Space.md)
            } else if model.driverIsOutOfDate {
                staleDriverBanner
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

            StatusPills(model: model)
        }
        .frame(minWidth: 980, minHeight: 600)
        // `fullSizeContentView` gives SwiftUI the title-bar row, but SwiftUI
        // still treats it as a safe-area inset unless the root accepts it.
        .ignoresSafeArea(.container, edges: .top)
        .yunWindowBackground()
        .focusEffectDisabled()
        .background(WindowChromeInstaller().frame(width: 0, height: 0))
        .background(shortcuts)
        .background(RemembersFrame(name: "YunAudioMainWindow").frame(width: 0, height: 0))
        // The analysers keep running either way — the ring has to be drained or
        // it overflows — but publishing a reading twenty times a second to a
        // window nobody has open is work for nothing.
        .onAppear {
            model.isAnalysisVisible = true
            // The gain sliders and the volume-key notice are read from a stored
            // copy rather than off the device, and the timer that keeps it
            // fresh only runs while this window is up. Ask once on the way in,
            // or the first frame draws the reading from whenever the window was
            // last closed.
            model.refreshDeviceControls()
        }
        .onDisappear { model.isAnalysisVisible = false }
    }

    /// The installed driver predates the version bundled with this release.
    ///
    /// Loud rather than quiet, because an older driver is missing whatever the
    /// newer one added and every symptom of that looks like a bug in the
    /// application. It cost an hour once: the virtual device published no
    /// volume control, the driver source implemented it perfectly, and the
    /// installed copy simply predated the commit.
    private var staleDriverBanner: some View {
        HStack(spacing: Yun.Space.sm) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .font(.system(size: 11))
                .foregroundStyle(Yun.Palette.warning)
            Text(
                loc(
                    "The installed YunAudio virtual audio driver is out of date. Reinstall the driver included with this version to receive the latest features and fixes."
                )
            )
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(loc("Reinstall driver")) { model.installDriver() }
                .buttonStyle(YunButtonStyle(.primary, small: true))
                .disabled(model.isInstallingDriver)
        }
        .padding(.horizontal, Yun.Space.md)
        .padding(.vertical, Yun.Space.sm)
        .background(
            Yun.Palette.warning.opacity(0.10), in: .rect(cornerRadius: Yun.Radius.button))
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

    /// The header is one row, and it sits below the window buttons rather than
    /// beside them.
    ///
    /// It used to dodge sideways by 56 points, which put the wordmark and the
    /// scenes in the same band as the buttons — reading as shoved out of the
    /// way — and broke the left edge the column headings below share. Splitting
    /// it into two bands fixed the edge and cost a row of height for one gap.
    /// Clearing the buttons vertically does both: everything stays on one
    /// horizontal line, at the window's own margin.
    private var header: some View {
        HStack(spacing: Yun.Space.md) {
            identityRow
            headerActions
        }
        .padding(.horizontal, Yun.Space.xl)
        .padding(.top, trafficLightInset)
        .padding(.bottom, Yun.Space.md)
    }

    /// The wordmark and the scenes, at the window's own left margin — the same
    /// edge the column headings below start from.
    @ViewBuilder
    private var identityRow: some View {
        HStack(spacing: Yun.Space.md) {
            // Trimmed, not the raw file: the mark is a portrait shape stored in
            // a square PNG, so fitting the file to a 22-point square left the
            // mark smaller than 22 points and a little left of where it looked
            // like it should be.
            Image(nsImage: YunAppIcon.trimmed)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 22)
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

            // Saved ones after the built-in four, with the same shape: the
            // distinction between "the four we chose" and "the ones you saved"
            // matters when deleting and nowhere else.
            ForEach(
                YunUIBenchmarkConfiguration.process.isEnabled ? [] : model.userPresets
            ) { preset in
                Button(preset.name) { model.apply(preset) }
                    .buttonStyle(
                        YunButtonStyle(
                            model.activePresetName == preset.name ? .primary : .ghost,
                            small: true)
                    )
                    .help(preset.note)
                    .contextMenu {
                        Button(loc("Delete")) { model.deletePreset(preset) }
                    }
            }

            Button {
                isNamingPreset = true
                presetName = ""
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10))
                    .frame(width: 14)
            }
            .buttonStyle(YunButtonStyle(.ghost, small: true))
            .help(loc("Save the current setup as a preset"))
            .popover(isPresented: $isNamingPreset, arrowEdge: .bottom) {
                savePreset
            }

            Spacer(minLength: 0)
        }
    }

    /// Everything that belongs in the corner: what went wrong, what needs
    /// granting, the settings door, and the one action the window exists for.
    @ViewBuilder
    private var headerActions: some View {
        Group {
            if let error = model.lastError {
                Text(error)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.danger)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(error)
            }
            if !YunUIBenchmarkConfiguration.process.isEnabled,
                PermissionCentre.shared.systemAudio == .needsRequest
                    || PermissionCentre.shared.microphone == .needsRequest
                    || model.autoStartNeedsPermissionReview
            {
                Button(loc("Review permissions")) {
                    SettingsWindow.open(model: model, initialSection: .permissions)
                }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
            }

            // The Settings scene accepted both its responder action and its
            // link without presenting a window while the app was an accessory.
            // This opens the retained window that the non-audio UI check can
            // find and measure.
            Button {
                SettingsWindow.open(model: model)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .frame(width: 14)
            }
            .buttonStyle(YunButtonStyle(.ghost, small: true))
            .keyboardShortcut(",", modifiers: [.command])
            .help(loc("Settings (⌘,)"))
            .accessibilityLabel(Text(loc("Settings")))

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
                                        detail: $0.inputChannelDetail)
                                })
                        }
                        if let waiting = model.displacedSourceName {
                            fallbackNotice(waiting)
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

                        // The microphone feeding itself back in its own
                        // silicon. Offered rather than switched on, because
                        // what comes back is the unprocessed capsule — none of
                        // this application's processing can be in it, since
                        // none of it has happened yet.
                        if model.hasHardwareMonitoring {
                            HStack(spacing: Yun.Space.sm) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Yun.Palette.textMuted)
                                    .frame(width: 22, height: 22)
                                YunSlider(
                                    fraction: Binding(
                                        get: { Double(model.hardwareMonitorScalar) },
                                        set: { model.hardwareMonitorScalar = Float($0) }))
                                Text(model.hardwareMonitorLabel)
                                    .font(Yun.Text.mono)
                                    .foregroundStyle(Yun.Palette.textTertiary)
                                    .monospacedDigit()
                                    .frame(width: 58, alignment: .trailing)
                            }
                            .help(
                                loc(
                                    "The microphone's own zero-latency monitoring, done in the device. What comes back is the raw capsule — nothing this application does is in it."
                                ))
                        }

                        // After the microphone's own controls rather than
                        // between them and the picker. Put directly under the
                        // picker it read as a heading for the three sliders
                        // below it, so the Seiren's gain, trim and monitoring
                        // looked like settings for a device nobody had chosen
                        // yet. It belongs at the end of the group it extends.
                        ExtraDeviceList(model: model, isInput: true)

                        YunDivider()

                        deviceRow(loc("Out"), symbol: "arrow.right.to.line") {
                            YunSelect(
                                selection: $model.selectedDestinationUID,
                                options: model.outputDevices.map {
                                    .init(
                                        value: $0.uid as String?, title: $0.name,
                                        detail: $0.outputChannelDetail)
                                })
                        }
                        if let waiting = model.displacedDestinationName {
                            fallbackNotice(waiting)
                        }
                        if let status = model.deviceSelectionStatus {
                            Text(status)
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textTertiary)
                        }
                        if model.volumeKeysAreDead {
                            HStack(spacing: Yun.Space.sm) {
                                Image(systemName: "speaker.slash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Yun.Palette.textMuted)
                                Text(
                                    loc(
                                        "This output publishes no volume control, so the keyboard's volume keys do nothing on it. The fader below still works."
                                    )
                                )
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        LevelRow(
                            decibels: $model.outputDecibels, muted: $model.isOutputMuted,
                            label: loc("Output level"))

                        ExtraDeviceList(model: model, isInput: false)

                        YunDivider()
                        pushToTalk

                        if !model.monitorOptions.isEmpty {
                            YunDivider()
                            monitor
                        }

                        if let source = model.selectedSource, source.inputChannels > 1 {
                            YunDivider()
                            YunSegmented(
                                selection: $model.channelMode,
                                options: SourceChannelMode.allCases.map { ($0, loc($0.title)) })
                            if model.channelMode == .mono {
                                // Wrapped, because how many of these there
                                // are is the device's decision and not this
                                // window's. A BlackHole 16ch puts sixteen
                                // buttons in a 370-point column; an HStack will
                                // not compress below their combined width, so
                                // it made the *column* wider than its share and
                                // the middle one was drawn over the top of it.
                                // The whole three-column layout came apart, and
                                // it was one picker asking for room nobody had.
                                YunSegmented(
                                    selection: $model.monoChannel,
                                    options: (0..<source.inputChannels).map {
                                        ($0, model.sourceChannelLabel($0))
                                    },
                                    wraps: true)
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
                        if !YunUIBenchmarkConfiguration.process.isEnabled,
                            !model.capturedAppBundleIDs.isEmpty
                        {
                            YunDivider()
                            Text(loc("While routed"))
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textTertiary)
                            YunSegmented(
                                selection: $model.tapMuteBehavior,
                                options: TapMuteBehavior.allCases.map { ($0, loc($0.title)) })

                            YunDivider()
                            ducking
                        }
                    }
                }
            }
        }
    }

    /// Application audio stepping out of the way of a voice.
    ///
    /// Placed with the applications rather than with the processing, because it
    /// is a property of what those applications do rather than a stage in the
    /// microphone's chain — and because it never touches the microphone at all.
    @ViewBuilder
    private var ducking: some View {
        HStack(spacing: Yun.Space.sm) {
            YunSwitch(isOn: $model.isDucking)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc("Duck under my voice"))
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.textPrimary)
                Text(
                    loc(
                        "Turns these down while you talk. The level triggers it instantly and the sound model confirms it was speech, so a cough or a keyboard does not pull the music down."
                    )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        if model.isDucking {
            HStack(spacing: Yun.Space.sm) {
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Yun.Palette.textMuted)
                    .frame(width: 22, height: 22)
                YunSlider(
                    fraction: Binding(
                        get: { Double(model.duckFraction) },
                        set: { model.duckFraction = Float($0) }))
                Text(String(format: "%.0f dB", model.duckDecibels))
                    .font(Yun.Text.mono)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }

    /// Naming a preset before it is saved.
    ///
    /// A snapshot of everything, not a chosen subset: somebody saving a preset
    /// has just spent time getting a setup right, and one that quietly left out
    /// the thing they were adjusting is worse than none.
    private var savePreset: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            Text(loc("Save this setup"))
                .font(Yun.Text.label)
                .foregroundStyle(Yun.Palette.textPrimary)
            Text(
                loc(
                    "Devices, levels, the processing chain, the voice and which applications are captured."
                )
            )
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            TextField(loc("Name"), text: $presetName)
                .textFieldStyle(.plain)
                .font(Yun.Text.body)
                .padding(.horizontal, Yun.Space.sm)
                .padding(.vertical, 6)
                .background(Yun.Palette.elevated, in: .rect(cornerRadius: Yun.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Yun.Radius.control)
                        .strokeBorder(Yun.Palette.border, lineWidth: 1)
                }
                .onSubmit { commitPreset() }

            HStack(spacing: Yun.Space.sm) {
                Button(loc("Save")) { commitPreset() }
                    .buttonStyle(YunButtonStyle(.primary, small: true))
                    .disabled(
                        presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(loc("Cancel")) { isNamingPreset = false }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
                Spacer(minLength: 0)
            }
        }
        .padding(Yun.Space.lg)
        .frame(width: 320)
    }

    private func commitPreset() {
        model.saveCurrentAsPreset(named: presetName)
        isNamingPreset = false
    }

    /// A whole voice, rather than the two stages it is made of.
    ///
    /// Pitch and formants are separate stages below because they are separate
    /// physical facts. Nobody wants to be told that: they want to sound like
    /// somebody else, and that is a specific pair of settings rather than one
    /// control. The stages stay available for anybody who wants to move them by
    /// hand.
    @ViewBuilder
    private var voice: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            YunSelect(
                selection: $model.voicePreset,
                options: VoicePreset.allCases.map {
                    .init(value: $0, title: loc($0.title))
                })
            Text(loc(model.voicePreset.detail))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if model.voicePreset != .none {
                HStack(spacing: Yun.Space.md) {
                    figure(
                        loc("Pitch"),
                        String(format: "%+.0f", model.voicePreset.cents), loc("cents"))
                    figure(
                        loc("Formants"),
                        String(format: "%+.0f", model.voicePreset.formantPercent), "%")
                    figure(
                        loc("Latency"),
                        String(format: "%.0f", model.voiceLatencyMilliseconds), loc("ms"))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func figure(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Yun.Palette.textPrimary)
                    .monospacedDigit()
                Text(unit)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textMuted)
            }
        }
    }

    /// Third-party Audio Units.
    ///
    /// The one place in this application where somebody else's code runs.
    /// Only in-process units which pass format, capacity and latency admission
    /// can enter this list; that reduces realtime risk without pretending the
    /// third-party code is sandboxed or crash-contained.
    @ViewBuilder
    private var pluginList: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            ForEach(model.enabledPlugins) { plugin in
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    HStack(spacing: Yun.Space.sm) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(plugin.name)
                                .font(Yun.Text.label)
                                .foregroundStyle(Yun.Palette.textPrimary)
                            Text(plugin.manufacturerName)
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            model.removePlugin(plugin)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 10))
                                .frame(width: 14)
                        }
                        .buttonStyle(YunButtonStyle(.ghost, small: true))
                        .accessibilityLabel(Text(loc("Remove")))
                    }
                    if !plugin.loadsInProcess {
                        // Said before it is in the path rather than discovered
                        // afterwards: an out-of-process render is an XPC round
                        // trip inside a callback with a 2.7 ms deadline.
                        Text(
                            loc(
                                "This one runs in its own process, so every block makes a round trip. Expect it to cost latency."
                            )
                        )
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.isRunning {
                        let parameters = model.pluginParameters(plugin)
                        if parameters.isEmpty {
                            // A card with a name and nothing under it reads as a
                            // unit that did not load. It loaded and it is
                            // rendering; it simply publishes no parameter list —
                            // the one installed here answers zero bytes to
                            // kAudioUnitProperty_ParameterList and keeps all of
                            // its controls in a window of its own.
                            Text(
                                loc(
                                    "It is running, and it publishes nothing a host can set. Its controls are all in its own window, which this does not open."
                                )
                            )
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(parameters.prefix(6)) { parameter in
                            pluginParameterRow(parameter, in: plugin)
                        }
                    }
                }
            }

            // One line each, with the reason and the status behind it. A bare
            // "could not be loaded" leaves somebody switching a stereo-only
            // unit on and off; "it will not take the chain's mono format" is
            // something they can act on, and the number is the only part its
            // author can.
            ForEach(model.failedPlugins) { failure in
                Text(
                    String(
                        format: loc("%1$@ could not be loaded. %2$@ (%3$d)"),
                        failure.name, failure.explanation, Int(failure.status))
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !model.enabledPlugins.isEmpty { YunDivider() }

            // The application's own picker rather than a `Menu`.
            //
            // Two reasons, and the second is the one that decided it: a system
            // menu is styled by AppKit and looks like nothing else here, and it
            // does not render at all in the offscreen design captures — it
            // came out as a yellow bar with a prohibitory sign across it, so
            // the one card that could not be checked was the newest.
            YunSelect(
                selection: Binding(
                    get: { String?.none },
                    set: { id in
                        guard let plugin = model.availablePlugins.first(where: { $0.id == id })
                        else { return }
                        model.addPlugin(plugin)
                    }),
                placeholder: loc("Add an Audio Unit"),
                options: model.availablePlugins.map {
                    .init(
                        value: $0.id as String?, title: $0.name,
                        detail: $0.manufacturerName)
                })

            HStack(spacing: Yun.Space.sm) {
                Text(
                    String(
                        format: loc("%d installed."), model.availablePlugins.count)
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                Spacer(minLength: 0)
                // The scan ran once, in `init`, and there was no way to ask for
                // another: an Audio Unit installed while this was open stayed
                // absent from the list until the application was restarted, and
                // nothing on screen suggested that was why. The application list
                // beside it has had a Refresh since the beginning; this is the
                // same button for the same reason.
                Button(loc("Rescan")) { model.refreshPlugins() }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
                    .help(loc("Look for Audio Units installed since this window opened"))
            }
        }
    }

    private func pluginParameterRow(
        _ parameter: EffectParameter, in plugin: AudioUnitPlugin
    ) -> some View {
        let value = model.pluginValue(of: parameter, in: plugin)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(parameter.title)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                Spacer()
                Text(parameter.formatted(value))
                    .font(Yun.Text.mono)
                    .foregroundStyle(Yun.Palette.textSecondary)
            }
            YunSlider(
                fraction: Binding(
                    get: {
                        parameter.fraction(
                            for: model.pluginValue(of: parameter, in: plugin))
                    },
                    set: {
                        model.setPluginValue(
                            parameter.value(atFraction: $0), of: parameter, in: plugin)
                    }))
        }
    }

    /// Held to talk rather than clicked to mute.
    ///
    /// Sits with the input because that is what it takes over: while it is
    /// armed the microphone is muted unless the key is down, and the mute
    /// button above reflects that rather than fighting it.
    @ViewBuilder
    private var pushToTalk: some View {
        HStack(spacing: Yun.Space.sm) {
            YunSwitch(isOn: $model.isPushToTalkEnabled)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Yun.Space.sm) {
                    Text(loc("Hold to talk"))
                        .font(Yun.Text.label)
                        .foregroundStyle(Yun.Palette.textPrimary)
                    if !YunUIBenchmarkConfiguration.process.isEnabled,
                        let shortcut = model.activeShortcuts[.pushToTalk]
                    {
                        YunBadge(shortcut.displayName)
                    }
                    if model.isPushToTalkEnabled && model.isPushToTalkHeld {
                        Text(loc("Open"))
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.success)
                    }
                }
                Text(
                    loc(
                        "The microphone stays muted until the key is down. Switching it off puts the mute back where it was."
                    )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Hearing yourself, on a second output.
    ///
    /// It sits with the devices rather than under processing because it is not
    /// processing — nothing about the signal going to the far end changes. It
    /// is a second destination, which is exactly what the picker says.
    @ViewBuilder
    private var monitor: some View {
        deviceRow(loc("Monitor"), symbol: "headphones") {
            YunSelect(
                selection: $model.monitorDeviceUID,
                placeholder: loc("Off"),
                options: [.init(value: String?.none, title: loc("Off"))]
                    + model.monitorOptions.map {
                        .init(
                            value: $0.uid as String?, title: $0.name,
                            detail: $0.outputChannelDetail)
                    })
        }
        // The picker has gone back to "Off" on its own, which is a change the
        // user did not make and would otherwise have to guess at. One line,
        // without making an implementation detail look like something they
        // could fix. The verbatim CoreAudio reason remains diagnostic evidence
        // in the model; a channel number or aggregate UID is not interface copy.
        if let message = model.droppedMonitorMessage {
            Text(message)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
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
                    .frame(width: 58, alignment: .trailing)
            }
            Text(
                model.monitorMayFeedBack
                    ? loc(
                        "This output does not look like headphones. Monitoring on speakers puts the microphone back into the room it is listening to."
                    )
                    : String(
                        format: loc("Hear yourself, %@ ms behind."),
                        String(format: "%.1f", model.monitorLatencyMilliseconds))
            )
            .font(Yun.Text.caption)
            .foregroundStyle(
                model.monitorMayFeedBack
                    ? Yun.Palette.warning : Yun.Palette.textTertiary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Mixer

    private var mixer: some View {
        column {
            VStack(alignment: .leading, spacing: Yun.Space.lg) {
                RoutingCanvas(model: model)

                sectionHeading(loc("Analysis"))
                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.md) {
                        LiveSpectrum(model: model)
                        YunDivider()
                        LoudnessReadout(model: model)
                    }
                }

                sectionHeading(loc("Mixer"))
                if !model.buses.isEmpty {
                    YunCard { busLegend }
                    ForEach(model.buses) { bus in
                        busProcessing(bus)
                    }
                }
                if model.isRunning {
                    YunCard { CalibrationPanel(model: model) }
                }

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
                    ForEach(model.sourceGroups) { group in
                        YunCard { RouteStrip(model: model, group: group) }
                    }
                }
            }
        }
    }

    /// What the two mixes are and where each one goes.
    ///
    /// One card above the strips, because the faders underneath are meaningless
    /// until somebody knows which mix each column belongs to. Everything here
    /// was already true; none of it was said.
    private var busLegend: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            ForEach(model.buses) { bus in
                HStack(spacing: Yun.Space.sm) {
                    Text(bus.letter)
                        .font(Yun.Text.label)
                        .foregroundStyle(Yun.Palette.accent)
                        .frame(width: 14)
                    Image(
                        systemName: bus.kind == .monitor
                            ? "headphones" : "dot.radiowaves.left.and.right"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(Yun.Palette.textMuted)
                    .frame(width: 16)
                    Text(bus.deviceName)
                        .font(Yun.Text.body)
                        .foregroundStyle(Yun.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Yun.Space.sm)
                    Text(
                        bus.kind == .monitor
                            ? loc("what you hear") : loc("what the far end hears")
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    if bus.followsMaster {
                        YunBadge(loc("master"))
                    }
                }
            }
        }
    }

    /// One bus's own tone control and headphone correction.
    ///
    /// Under the legend that names the buses rather than on the device tab,
    /// because this is the answer to "why is A different from B" and it should
    /// be next to the thing that says what A and B are. VoiceMeeter's whole
    /// reputation rests on the stream mix and the headphone mix being shaped
    /// independently; until now every effect here ran before the matrix, so
    /// both buses got the same one whether that made sense or not.
    ///
    /// Collapsed until asked for. Two buses is two sets of ten sliders, and a
    /// mixer column that opens on four hundred points of equaliser has hidden
    /// the faders it exists to show.
    @ViewBuilder
    private func busProcessing(_ bus: RouterModel.Bus) -> some View {
        YunDisclosure(
            String(format: loc("Bus %@ processing"), bus.letter),
            subtitle: busProcessingSummary(bus),
            isExpanded: Binding(
                get: { isRendering || expandedBuses.contains(bus.id) },
                set: { expanded in
                    if expanded {
                        expandedBuses.insert(bus.id)
                    } else {
                        expandedBuses.remove(bus.id)
                    }
                })
        ) {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                graphicBands(forBus: bus.id)
                if !model.headphoneProfiles.isEmpty {
                    YunDivider()
                    headphonePicker(forBus: bus.id)
                }
            }
        }
    }

    /// What the collapsed row says, so somebody can see which bus is shaped
    /// without opening either.
    private func busProcessingSummary(_ bus: RouterModel.Bus) -> String {
        let moved = model.graphicEQ(forBus: bus.id).filter { abs($0) > 0.05 }.count
        let profile = model.headphoneProfile(forBus: bus.id)?.name
        switch (moved, profile) {
        case (0, nil): return loc("flat")
        case (0, let name?): return name
        case (let count, nil): return String(format: loc("%d band(s)"), count)
        case (let count, let name?):
            return String(format: loc("%d band(s), %@"), count, name)
        }
    }

    // MARK: Inspector

    /// What the right-hand column is showing.
    ///
    /// It used to be everything, stacked: voice, ten processing stages,
    /// plugins, the light ring, recording, echo cancellation and the signal
    /// path, in one column a mile long. Each of them arrived reasonably and the
    /// result stopped being reasonable somewhere around the sixth — you cannot
    /// see the thing you are adjusting and the thing it affects at the same
    /// time, and finding anything means remembering where in the scroll it was.
    ///
    /// The left and middle columns stay put on purpose: devices and the live
    /// meters are what you check *while* changing something in here, so hiding
    /// them behind a tab would trade one problem for a worse one.
    enum Inspector: String, CaseIterable, Identifiable {
        case sound
        case plugins
        case singing
        case recording
        case scripting
        case hardware

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sound: loc("Sound")
            case .plugins: loc("Plugins")
            case .singing: loc("Sing")
            case .recording: loc("Record")
            case .scripting: loc("Script")
            case .hardware: loc("Device")
            }
        }
    }

    private var inspector: some View {
        column {
            VStack(alignment: .leading, spacing: Yun.Space.lg) {
                inspectorPicker

                switch model.inspectorTab {
                case .sound: soundTab
                case .plugins: pluginsTab
                case .singing: singingTab
                case .recording: recordingTab
                case .scripting: scriptingTab
                case .hardware: hardwareTab
                }
            }
        }
    }

    private var inspectorPicker: some View {
        // Wrapping, because six of them do not fit across the ordinary
        // inspector column at the window's minimum width. The expanded singing
        // workspace uses the same control, so leaving the stage never depends
        // on a hidden keyboard shortcut.
        YunSegmented(
            selection: inspectorTab,
            options: Inspector.allCases.map { ($0, $0.title) },
            wraps: true)
    }

    /// Three regions rather than one column of eleven switches.
    ///
    /// The stages were listed in the order the enum happened to declare them,
    /// under one heading that said "Processing", and that reads as a list of
    /// things rather than as a set of decisions. Cleaning a signal up, changing
    /// whose voice it is and putting that voice somewhere have nothing to do
    /// with each other: they are wanted at different times, by different
    /// people, for different reasons, and only one of the three is meant to be
    /// audible as an effect at all.
    ///
    /// The engine is untouched by this. It sorts the whole chain into signal
    /// order whatever the grouping says, and the limiter is still last.
    @ViewBuilder
    private var soundTab: some View {
        Group {
            effectGroupHeading(.cleanUp)
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    effectStack(.cleanUp)
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

            effectGroupHeading(.voice)
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    // The whole voice first, the two stages it is made of
                    // under it. Almost nobody wants to set a formant ratio;
                    // they want to sound like somebody else, and the stages are
                    // there for whoever does want to move them by hand.
                    voice
                    YunDivider()
                    effectStack(.voice)
                }
            }

            effectGroupHeading(.colour)
            YunCard { effectStack(.colour) }
        }
    }

    /// A region's name and what it is for.
    ///
    /// The sentence is not decoration. The one thing the old flat list could
    /// not say is which switches somebody reaching for "make me sound less
    /// noisy" should be looking at, and that is exactly what this answers.
    private func effectGroupHeading(_ group: EffectGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeading(loc(group.title))
            Text(loc(group.detail))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func effectStack(_ group: EffectGroup) -> some View {
        let stages = EffectKind.stages(in: group)
        return VStack(alignment: .leading, spacing: Yun.Space.md) {
            ForEach(stages) { kind in
                effectRow(kind)
                if kind != stages.last { YunDivider() }
            }
        }
    }

    @ViewBuilder
    private var pluginsTab: some View {
        Group {
            sectionHeading(loc("Plugins"))
            YunCard { pluginList }
        }
        .onAppear { model.refreshPluginsIfNeeded() }
    }

    @ViewBuilder
    private var hardwareTab: some View {
        Group {
            sectionHeading(loc("Setups"))
            YunCard { setups }

            sectionHeading(loc("Output tone"))
            YunCard { graphicEqualiser }

            sectionHeading(loc("Headphone correction"))
            YunCard { headphoneCorrection }

            sectionHeading(loc("Output alignment"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    Text(
                        loc(
                            "Two outputs fed from one cycle do not arrive together. Delay the early one until they line up — the system applies it, so it costs nothing."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    ForEach(model.alignableOutputs, id: \.uid) { device in
                        outputDelayRow(device)
                    }
                }
            }

            if model.lighting.isAvailable {
                sectionHeading(loc("Light ring"))
                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.md) {
                        YunSegmented(
                            selection: Binding(
                                get: { model.lightingMode },
                                set: { model.lightingMode = $0 }
                            ),
                            options: LightingMode.allCases.map { ($0, $0.title) })
                        Text(
                            loc(
                                "The microphone renders nothing itself — every effect is computed here, so the ring can show the level and turn red the moment you mute."
                            )
                        )
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        if model.lightingMode != .off {
                            YunDivider()
                            // A hue strip rather than a colour well: the
                            // ring is one saturated colour at a time, and a
                            // full picker would offer greys it cannot show.
                            if model.lightingMode != .spectrum {
                                HStack(spacing: Yun.Space.sm) {
                                    Text(loc("Colour"))
                                        .font(Yun.Text.caption)
                                        .foregroundStyle(Yun.Palette.textTertiary)
                                        .frame(width: 62, alignment: .leading)
                                    HueStrip(hue: $model.lightingHue)
                                }
                            }
                            HStack(spacing: Yun.Space.sm) {
                                Text(loc("Brightness"))
                                    .font(Yun.Text.caption)
                                    .foregroundStyle(Yun.Palette.textTertiary)
                                    .frame(width: 62, alignment: .leading)
                                YunSlider(
                                    fraction: Binding(
                                        get: { model.lightingBrightness },
                                        set: { model.lightingBrightness = $0 }))
                                Text("\(Int(model.lightingBrightness * 100))%")
                                    .font(Yun.Text.mono)
                                    .foregroundStyle(Yun.Palette.textTertiary)
                                    .monospacedDigit()
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }

                        if let error = model.lighting.lastError {
                            Text(error)
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
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
                        ClockLockRows(model: model)
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
        .onAppear {
            model.refreshHeadphoneProfilesIfNeeded()
            model.refreshLightingDeviceIfPermitted()
        }
    }

    /// Singing to a backing track, with the words and whether you are on the
    /// note.
    ///
    /// Everything this needs already existed and none of it was joined up. The
    /// pitch tracker has been in the analysis panel since it was written; the
    /// music players publish what they are playing through a scripting
    /// dictionary that has not changed in twenty years; the microphone is
    /// already routed. What was missing was the words, and those are a file.
    @ViewBuilder
    private var singingTab: some View {
        Group {
            sectionHeading(loc("Sing"))
            if model.isKTVWindowOpen {
                // The stage is somewhere else, so it is not built twice.
                //
                // Both presentations used to draw at once whenever this tab was
                // open behind the window: two lyric layouts, two backdrops, two
                // sets of meters, every frame, for one song — and the copy
                // nobody could see cost exactly as much as the one they were
                // watching. What stands here instead is a card that says where
                // the song went and puts it back in front.
                onItsOwnStage
            } else {
                Button {
                    KTVWindow.open(model: model)
                } label: {
                    Label(loc("Open KTV window"), systemImage: "rectangle.inset.filled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(YunButtonStyle(.primary, small: true))
                .accessibilityIdentifier("OpenKTV")
                YunCard(padding: 0) { SingingPanel(model: model) }
            }
        }
        .onAppear { model.isSingingVisible = true }
        .onDisappear {
            if !KTVWindow.isVisible {
                model.isSingingVisible = false
            }
        }
    }

    /// What this tab shows while the stage has a window of its own.
    ///
    /// Deliberately small and deliberately not a copy of anything: the song's
    /// name, so the tab is not simply blank, and the two things somebody would
    /// want from here — bring it back to the front, or put it back inside.
    @ViewBuilder
    private var onItsOwnStage: some View {
        let _ = BodyCount.tick("SingingTabAside")
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                Label(
                    loc("The stage has its own window"), systemImage: "macwindow.on.rectangle"
                )
                .font(Yun.Text.title)
                if let title = model.nowPlaying?.title, !title.isEmpty {
                    Text(title)
                        .font(Yun.Text.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(loc("Nothing is drawn here while it is open, so it costs nothing."))
                    .font(Yun.Text.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Yun.Space.sm) {
                    Button {
                        KTVWindow.open(model: model)
                    } label: {
                        Label(loc("Bring it forward"), systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(YunButtonStyle(.primary, small: true))
                    .accessibilityIdentifier("BringKTVForward")
                    Button {
                        KTVWindow.close()
                    } label: {
                        Label(
                            loc("Put it back here"), systemImage: "rectangle.compress.vertical"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(YunButtonStyle(.secondary, small: true))
                    .accessibilityIdentifier("PutKTVBack")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The script that stays loaded.
    ///
    /// It had no interface at all when it shipped — the whole feature was
    /// reachable only from a URL, which is a feature nobody finds. The real
    /// screenshot is what said so: the offscreen render draws whatever tab is
    /// selected and is structurally incapable of noticing that a tab is
    /// missing from the row.
    private var scriptingTab: some View {
        Group {
            sectionHeading(loc("Script"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    Text(
                        loc(
                            "JavaScript that stays loaded and reacts. Register a handler with yun.on(event, function), and drive the router with yun.routing(), yun.mute(), yun.preset(name) and the rest."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textSecondary)

                    // ImageRenderer cannot host AppKit's NSTextView. It draws
                    // the system's giant yellow prohibition placeholder and a
                    // capture full of that used to pass the design gate. The
                    // running window still gets the real editor; the offscreen
                    // path gets the same text, type and surface without an
                    // AppKit-backed control.
                    if isRendering {
                        ScrollView {
                            Text(verbatim: model.residentScript)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Yun.Palette.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(minHeight: 120)
                        .padding(Yun.Space.xs)
                        .background(
                            Yun.Palette.elevated, in: .rect(cornerRadius: Yun.Radius.control))
                    } else {
                        // A plain editor rather than anything clever. Syntax
                        // colouring is somebody's week and this is a text field
                        // that has to accept a paste.
                        TextEditor(text: $model.residentScript)
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 120)
                            .padding(Yun.Space.xs)
                            .background(
                                Yun.Palette.elevated,
                                in: .rect(cornerRadius: Yun.Radius.control))
                    }

                    // Running one once had no control at all: the tab installs
                    // a script that reacts to events, and the other half of the
                    // feature — run this, now — was reachable only from a URL,
                    // the command line and the MCP tool. Loading a script that
                    // only registers handlers tells you nothing about whether
                    // it works; pressing this does.
                    HStack(spacing: Yun.Space.sm) {
                        Button(loc("Run it now")) {
                            model.runScriptNow(model.residentScript)
                        }
                        .buttonStyle(YunButtonStyle(.secondary, small: true))
                        .disabled(
                            model.residentScript.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty || model.isScriptRunPending
                        )
                        .help(loc("Run the script above once, top to bottom"))

                        // The error goes next to the script rather than in a
                        // status bar somewhere else: a syntax error is about the
                        // thing on screen, and a script that failed to load is
                        // otherwise indistinguishable from one that never fires.
                        if model.isResidentScriptLoading {
                            Text(loc("Loading…"))
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textSecondary)
                        } else if let problem = model.residentScriptError {
                            Text(problem)
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.danger)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !model.residentScript.isEmpty {
                            Text(loc("Loaded."))
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.success)
                        }
                        Spacer(minLength: 0)
                    }

                    // What the handlers have said. Without it a script that
                    // logs is writing to nowhere, and the first thing anybody
                    // does with a new scripting interface is print something.
                    if !model.scriptLog.isEmpty {
                        Divider().overlay(Yun.Palette.border)
                        Text(loc("What it has said"))
                            .font(Yun.Text.label)
                            .foregroundStyle(Yun.Palette.textSecondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(
                                    Array(model.scriptLog.suffix(12).enumerated()), id: \.offset
                                ) {
                                    _, line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Yun.Palette.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
            }

            sectionHeading(loc("Events"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.xs) {
                    // Listed rather than documented elsewhere. The names are a
                    // closed set and a typo is refused at load, so the one
                    // thing somebody needs is the list.
                    Text(
                        ScriptService.Event.allCases.map(\.rawValue).sorted()
                            .joined(separator: "   ")
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Yun.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var recordingTab: some View {
        Group {
            sectionHeading(loc("Recording"))
            YunCard {
                RecordingControls(model: model)
            }
            sectionHeading(loc("Transcript"))
            YunCard {
                transcription
            }
        }
    }

    /// Live transcription, attributed by construction.
    ///
    /// The claim on the button is the one worth making: every source is written
    /// down under its own name because they were never mixed, not because
    /// anything worked out who was speaking. So the interface says "each source
    /// separately" rather than the word diarization, which is the thing being
    /// avoided rather than the thing being offered.
    @ViewBuilder
    private var transcription: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            HStack(spacing: Yun.Space.sm) {
                Button(
                    model.isTranscribing ? loc("Stop transcribing") : loc("Transcribe")
                ) {
                    if model.isTranscribing {
                        model.stopTranscribing()
                    } else {
                        model.startTranscribing()
                    }
                }
                .buttonStyle(YunButtonStyle(model.isTranscribing ? .danger : .primary))
                .disabled(model.transcriptionUnavailableReason != nil)

                if model.isTranscribing {
                    YunStatusPill(loc("Listening"), tone: .success)
                }
                Spacer()
                if !model.transcript.isEmpty {
                    Button(
                        model.isSavingTranscript ? loc("Saving…") : loc("Save")
                    ) {
                        _ = model.saveTranscript()
                    }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
                    .disabled(model.isSavingTranscript)
                }
            }

            // Said before it is pressed rather than after: a control that is
            // simply dead teaches nothing, and this one is dead for a reason
            // somebody can act on.
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
            } else if let warning = model.transcriptionAdmissionWarning {
                Text(warning)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = model.transcriptSaveError {
                Text(error)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let url = model.lastSavedTranscriptURL {
                Text(String(format: loc("Saved to %@."), url.lastPathComponent))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.success)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.transcript.isEmpty {
                Text(
                    loc(
                        "Up to four routed sources are written down under their own names, on this device."
                    )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !model.transcript.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Yun.Space.sm) {
                        ForEach(model.transcript) { line in
                            transcriptLine(line)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
            }
        }
    }

    private func transcriptLine(_ line: Transcriber.Line) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Yun.Space.sm) {
                Text(line.speaker)
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.accent)
                Text(String(format: "%02d:%02d", Int(line.start) / 60, Int(line.start) % 60))
                    .font(Yun.Text.mono)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .monospacedDigit()
            }
            Text(line.text)
                .font(Yun.Text.body)
                .foregroundStyle(Yun.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whole-machine arrangements: which devices everything is pointed at.
    ///
    /// Kept apart from the scene tabs at the top of the window on purpose. A
    /// scene says how to process and leaves devices alone; this says what
    /// everything is plugged into. Putting them in one list would mean somebody
    /// choosing "podcast" could not know whether they had just changed a
    /// compressor or unplugged their headphones.
    @ViewBuilder
    private var setups: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            Text(
                loc(
                    "A setup remembers what everything is pointed at — the system's own input and output, this router's devices, and what is being captured."
                )
            )
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(model.quickConfigs) { configuration in
                HStack(spacing: Yun.Space.sm) {
                    Button(configuration.name) {
                        let operationID = UUID()
                        setupOperationID = operationID
                        setupOutcome = loc("Applying…")
                        model.requestApplyQuickConfig(configuration) { result in
                            guard setupOperationID == operationID else { return }
                            setupOperationID = nil
                            switch result {
                            case .superseded:
                                setupOutcome = nil
                            case .completed(let outcome):
                                setupOutcome =
                                    outcome.isComplete
                                    ? nil
                                    : loc("missing") + " "
                                        + model.describeMissing(outcome.missing)
                            }
                        }
                    }
                    .buttonStyle(YunButtonStyle(.secondary, small: true))
                    Spacer()
                    Button(loc("Delete")) { model.deleteQuickConfig(named: configuration.name) }
                        .buttonStyle(YunButtonStyle(.ghost, small: true))
                }
            }

            if let setupOutcome {
                Text(setupOutcome)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The name is asked for in a popover rather than in a field sitting
            // in the card, and not only for tidiness: a `TextField` renders as
            // a yellow bar with a prohibitory sign in the offscreen design
            // capture, so a field here would blind that check for this whole
            // section. The popover is not in the rendered tree, and it is the
            // pattern the scene presets already use.
            Button(loc("Save the current setup")) {
                isNamingSetup = true
                setupName = ""
            }
            .buttonStyle(YunButtonStyle(.primary, small: true))
            .popover(isPresented: $isNamingSetup, arrowEdge: .bottom) {
                saveSetup
            }
        }
    }

    /// Ten bands on one bus, at the centres Razer's own software publishes.
    ///
    /// Vertical, because that is what a graphic equaliser looks like everywhere
    /// and the shape of the curve is the thing being read — a column of
    /// horizontal sliders would carry the same numbers and none of the meaning.
    ///
    /// It sits above the headphone correction rather than inside it because
    /// they are different intentions: the correction undoes a fault somebody
    /// measured, this is taste. They run one after the other, so neither has to
    /// be given up for the other.
    @ViewBuilder
    private func graphicBands(forBus id: String) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(ParametricEQ.graphicBands.enumerated()), id: \.offset) {
                    index, hertz in
                    VStack(spacing: 4) {
                        YunVerticalSlider(
                            fraction: Binding(
                                get: {
                                    let span =
                                        ParametricEQ.graphicRange.upperBound
                                        - ParametricEQ.graphicRange.lowerBound
                                    return Double(
                                        (model.graphicEQ(forBus: id)[index]
                                            - ParametricEQ.graphicRange.lowerBound) / span)
                                },
                                set: {
                                    let span =
                                        ParametricEQ.graphicRange.upperBound
                                        - ParametricEQ.graphicRange.lowerBound
                                    model.setGraphicBand(
                                        ParametricEQ.graphicRange.lowerBound
                                            + Float($0) * span, at: index, forBus: id)
                                }))
                        Text(Self.bandLabel(hertz))
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 108)

            HStack(spacing: Yun.Space.sm) {
                Text(
                    model.graphicEQIsFlat(forBus: id)
                        ? loc("Flat. These are the band centres Razer's own software uses.")
                        : String(
                            format: loc("%d band(s) moved."),
                            model.graphicEQ(forBus: id).filter { abs($0) > 0.05 }.count)
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !model.graphicEQIsFlat(forBus: id) {
                    Button(loc("Flatten")) { model.resetGraphicEQ(forBus: id) }
                        .buttonStyle(YunButtonStyle(.ghost, small: true))
                }
            }
        }
    }

    /// The device tab's tone card, which edits the bus a correction has always
    /// landed on.
    ///
    /// Kept as a shortcut to the one bus most people have rather than removed
    /// once every bus got its own: it is where somebody already knows to look.
    /// The line above the sliders says which bus that is, because with two of
    /// them a control that does not name its target is a guess.
    @ViewBuilder
    private var graphicEqualiser: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            primaryBusNote
            if let bus = model.correctedOutputUID {
                graphicBands(forBus: bus)
            }
        }
    }

    /// Which bus the device tab's two cards are editing, and where the others
    /// are.
    private var primaryBusNote: some View {
        Text(
            model.buses.first(where: { $0.id == model.correctedOutputUID }).map {
                String(
                    format: loc("Bus %@ · %@. Every bus has its own, in the mixer."),
                    $0.letter, $0.deviceName)
            } ?? loc("No output is chosen, so there is no bus to shape yet.")
        )
        .font(Yun.Text.caption)
        .foregroundStyle(Yun.Palette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Which correction one bus runs, and what it costs in headroom.
    @ViewBuilder
    private func headphonePicker(forBus id: String) -> some View {
        YunSelect(
            selection: Binding(
                get: { model.headphoneProfileName(forBus: id) },
                set: { model.setHeadphoneProfileName($0, forBus: id) }),
            options: [.init(value: String?.none, title: loc("Off"))]
                + model.headphoneProfiles.map {
                    .init(
                        value: $0.name as String?, title: $0.name,
                        detail: "\($0.filters.count)")
                })
        if let profile = model.headphoneProfile(forBus: id) {
            Text(
                String(
                    format: loc("%d filters, %.1f dB of headroom taken."),
                    profile.filters.count, -profile.preampDecibels)
            )
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
        }
    }

    /// 30, 120, 1k, 16k — read at a glance rather than spelled out.
    private static func bandLabel(_ hertz: Float) -> String {
        hertz >= 1000
            ? String(format: "%.0fk", hertz / 1000) : String(format: "%.0f", hertz)
    }

    /// Headphone correction, read from files somebody dropped in a folder.
    ///
    /// The empty state does most of the work here, because the feature needs a
    /// file that has to be fetched from somewhere else. A picker with nothing
    /// in it and no explanation is a dead end; saying where the files come from
    /// and offering to open the folder is the whole difference.
    @ViewBuilder
    private var headphoneCorrection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            primaryBusNote
            if model.headphoneProfiles.isEmpty {
                Text(
                    loc(
                        "Drop an AutoEq ParametricEQ.txt for your headphones into the folder below. Every headphone is wrong in a way somebody has already measured."
                    )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                if let bus = model.correctedOutputUID {
                    headphonePicker(forBus: bus)
                }
                if let profile = model.headphoneProfile {
                    // What it does, drawn from the coefficients that will
                    // actually run rather than from the filter list — a picture
                    // built from the definitions would stay right while the
                    // arithmetic under it went wrong.
                    EQCurveView(curve: profile)
                        .frame(height: 64)
                }
                if model.headphoneCorrectionIsIdle {
                    Text(loc("Nothing is being corrected until routing starts."))
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                }
            }
            HStack(spacing: Yun.Space.sm) {
                Button(loc("Open the folder")) {
                    guard let directory = RouterModel.headphoneDirectory else { return }
                    FolderRevealWorker.shared.submit(directory)
                }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
                Button(loc("Refresh")) {
                    model.refreshHeadphoneProfilesAsynchronously()
                }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
            }
        }
    }

    private var saveSetup: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            Text(loc("Name this setup"))
                .font(Yun.Text.label)
                .foregroundStyle(Yun.Palette.textSecondary)
            TextField("", text: $setupName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { commitSetup() }
            HStack {
                Spacer()
                Button(loc("Cancel")) { isNamingSetup = false }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
                Button(loc("Save")) { commitSetup() }
                    .buttonStyle(YunButtonStyle(.primary, small: true))
                    .disabled(setupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Yun.Space.lg)
    }

    private func commitSetup() {
        let name = setupName
        let operationID = UUID()
        setupOperationID = operationID
        setupOutcome = loc("Saving…")
        model.requestSaveQuickConfig(named: name) { result in
            guard setupOperationID == operationID else { return }
            setupOperationID = nil
            switch result {
            case .saved:
                setupOutcome = nil
            case .failed:
                setupOutcome = loc("The system audio defaults could not be read.")
            case .invalidName:
                setupOutcome = loc("Name this setup")
            case .superseded:
                setupOutcome = nil
            }
        }
        setupName = ""
        isNamingSetup = false
    }

    /// One output's delay, in milliseconds.
    ///
    /// Milliseconds rather than frames, even though frames is what the system
    /// is told: nobody knows what 240 frames sounds like, and the answer
    /// changes with the sample rate. Distance is the other honest unit — sound
    /// covers about 34 cm in a millisecond — so the two readings together let
    /// somebody dial it in by measuring the room rather than by ear.
    private func outputDelayRow(_ device: AudioDevice) -> some View {
        // Two lines rather than one. A device name, a slider and two units of
        // readout do not fit across an inspector column: laid out in a row the
        // slider came out a few points wide, which is a control nobody can use,
        // and the offscreen capture showed it plainly.
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Yun.Space.sm) {
                Text(device.name)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Yun.Space.sm)
                Text(
                    model.outputDelay(of: device.uid) < 0.05
                        ? "—"
                        : String(
                            format: "%.0f ms · %.0f cm", model.outputDelay(of: device.uid),
                            model.outputDelay(of: device.uid) * 34.3)
                )
                .font(Yun.Text.mono)
                .foregroundStyle(Yun.Palette.textTertiary)
                .monospacedDigit()
            }
            YunSlider(
                fraction: Binding(
                    get: { model.outputDelay(of: device.uid) / RouterModel.maximumOutputDelay },
                    set: {
                        model.previewOutputDelay(
                            $0 * RouterModel.maximumOutputDelay, for: device.uid)
                    }),
                onEditingEnded: { model.commitOutputDelays() })
        }
    }

    /// Says which device the route is waiting to go back to.
    ///
    /// Not an error, and deliberately not styled as one: nothing went wrong
    /// that anybody has to act on, the call carried on, and the only thing
    /// worth saying is that this is temporary. Without it the microphone
    /// silently changes underneath somebody and the only clue is a name in a
    /// picker they were not looking at.
    private func fallbackNotice(_ name: String) -> some View {
        HStack(spacing: Yun.Space.sm) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 11))
                .foregroundStyle(Yun.Palette.accent)
            Text(String(format: loc("Standing in for %@ until it is back."), name))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A reduction meter, drawn right to left.
    ///
    /// Away from zero rather than towards it, because reduction is something
    /// being taken away — the same convention every compressor uses, and the
    /// reason nobody has to be told which way it reads.
    fileprivate static func gainReductionMeter(_ decibels: Float) -> some View {
        HStack(spacing: Yun.Space.sm) {
            Text(loc("Reducing"))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            GeometryReader { proxy in
                let span: Float = 24
                let fraction = CGFloat(min(1, decibels / span))
                ZStack(alignment: .trailing) {
                    Capsule()
                        .fill(Yun.Palette.elevated)
                        .frame(height: 4)
                    Capsule()
                        .fill(
                            decibels > 12 ? Yun.Palette.warning : Yun.Palette.accent
                        )
                        .frame(width: proxy.size.width * fraction, height: 4)
                }
                .frame(height: proxy.size.height, alignment: .center)
            }
            .frame(height: 10)
            Text(decibels >= 0.1 ? String(format: "−%.1f", decibels) : "—")
                .font(Yun.Text.mono)
                .foregroundStyle(Yun.Palette.textTertiary)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
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

            // What the stage is actually doing to the signal, for the two that
            // can be set to do nothing without saying so — and only those two.
            // A row for the other nine reads a property the poll rewrites and
            // then draws nothing, which cost 220 body evaluations a second for
            // two meters.
            if RouterModel.meteredStages.contains(kind) {
                GainReductionRow(model: model, kind: kind)
            }

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

    @ViewBuilder
    private func parameterRow(_ parameter: EffectParameter, in kind: EffectKind) -> some View {
        // A choice is not a quantity. Nobody wants "ring modulator at 137 Hz"
        // on a slider — they want to pick "robot" — and a slider that lands
        // between two named voices is a control with no correct position.
        if parameter.isChoice {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc(parameter.title))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                YunSegmented(
                    selection: Binding(
                        get: { Int(model.value(of: parameter, in: kind).rounded()) },
                        set: { model.setValue(Float($0), of: parameter, in: kind) }),
                    options: parameter.options.enumerated().map {
                        ($0.offset, loc($0.element))
                    },
                    // How many of these there are comes from a third-party
                    // unit, so it is not a number this window gets to assume.
                    wraps: true
                )
            }
        } else {
            slider(parameter, in: kind)
        }
    }

    private func slider(_ parameter: EffectParameter, in kind: EffectKind) -> some View {
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

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Yun.Palette.textTertiary)
            .textCase(.uppercase)
    }
}

/// How far one dynamics stage is pulling the signal down, reading the model
/// itself.
///
/// A view of its own for the same reason as `LiveSpectrum`. `gainReduction` is
/// rewritten on every poll while a compressor or a gate is on, and a dictionary
/// subscript is a read of the whole property — so switching on one compressor
/// pinned the entire window, header and device pickers and all, to twenty
/// re-evaluations a second.
private struct GainReductionRow: View {
    let model: RouterModel
    let kind: EffectKind

    var body: some View {
        let _ = BodyCount.tick("GainReductionRow")
        if let reduction = model.gainReduction[kind] {
            MainWindow.gainReductionMeter(reduction)
        }
    }
}

/// The clock's moving reading, isolated from the hardware inspector.
///
/// The ratio is sampled with the meters and can move by a few parts per
/// million each poll. Reading it in `MainWindow` made that tiny number rebuild
/// all three columns even though only these two rows can change.
private struct ClockLockRows: View {
    let model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("ClockLockRows")
        if model.isClockLocked {
            YunDetailRow(
                loc("Clock"),
                value: String(format: "locked %.6f", model.measuredRateRatio),
                tone: .success)
            YunDetailRow(
                loc("Crystal"),
                value: String(
                    format: "%+.1f ppm",
                    (model.measuredRateRatio - 1) * 1_000_000))
        }
    }
}

extension AudioUnitLoadFailure {
    /// The refusal in a sentence somebody can act on.
    ///
    /// The engine reports a case and an `OSStatus` and stops there, because it
    /// has no localisation and should not grow one; turning that into words is
    /// the interface's job.
    var explanation: String {
        switch reason {
        case .notInstalled:
            loc("It is no longer installed.")
        case .couldNotInstantiate:
            loc("It would not start.")
        case .formatRejected:
            // The ordinary answer from a unit that only works in stereo, and
            // the one worth naming: nothing the user changes here will help.
            loc("It will not take this chain's mono format.")
        case .wouldNotInitialise:
            loc("It took the format and then would not start.")
        }
    }
}
