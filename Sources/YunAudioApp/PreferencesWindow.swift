import SwiftUI
import YunAudioControl
import YunAudioEngine
import YunAudioHAL
import YunDesign

/// The standalone preferences window.
///
/// Everything here is deliberately *not* in the menu bar panel: the panel is for
/// what you change during a session, and this is for what you set once. Mixing
/// them made the panel tall enough to matter on a laptop screen.
struct PreferencesWindow: View {
    @Bindable var model: RouterModel
    /// The design system's own settings — language, appearance and accent —
    /// which are not the router's state and outlive any particular model.
    @Bindable private var theme = YunTheme.shared
    @State private var selection: Section
    /// Mirrored rather than read through a computed binding: the activation
    /// policy lives on `NSApp`, nothing observes it, and a switch bound
    /// straight to it would not move when clicked.
    @State private var showsDockIcon = InterfaceOptions.showsDockIcon
    /// Something for the accent preview to act on.
    @State private var previewSwitch = true

    /// Skips the ScrollView. `ImageRenderer` gives a ScrollView no height even
    /// when the surrounding frame is fixed, so the offscreen design captures
    /// come out as an empty pane unless the scrolling is taken out of the way.
    private let isRendering: Bool

    init(model: RouterModel, initialSection: Section = .general, isRendering: Bool = false) {
        self.model = model
        self.isRendering = isRendering
        _selection = State(initialValue: initialSection)
    }

    enum Section: String, CaseIterable, Identifiable {
        case general, appearance, audio, shortcuts, midi, diagnostics, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: loc("General")
            case .appearance: loc("Appearance")
            case .audio: loc("Audio")
            case .shortcuts: loc("Shortcuts")
            case .midi: loc("MIDI control")
            case .diagnostics: loc("Diagnostics")
            case .about: loc("About")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .audio: "waveform"
            case .shortcuts: "command"
            case .midi: "pianokeys"
            case .diagnostics: "waveform.path.ecg"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Yun.Palette.borderHairline)
                .frame(width: 1)
            if isRendering {
                content
                    .padding(Yun.Space.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    content
                        .padding(Yun.Space.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(minWidth: 620, minHeight: 440)
        .background(Yun.Palette.background)
        .focusEffectDisabled()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: Yun.Space.sm) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 11))
                            .frame(width: 16)
                        Text(section.title)
                            .font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(
                        selection == section
                            ? Yun.Palette.textPrimary : Yun.Palette.textSecondary
                    )
                    .padding(.horizontal, Yun.Space.sm)
                    .padding(.vertical, 6)
                    .background(
                        selection == section ? Yun.Palette.accentSubtle : .clear,
                        in: .rect(cornerRadius: Yun.Radius.control)
                    )
                    .contentShape(.rect(cornerRadius: Yun.Radius.control))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            Spacer()
        }
        .padding(Yun.Space.md)
        .frame(width: 168)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general: generalSection
        case .appearance: appearanceSection
        case .audio: audioSection
        case .shortcuts: shortcutsSection
        case .midi: midiSection
        case .diagnostics: diagnosticsSection
        case .about: aboutSection
        }
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading(loc("Language"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunSegmented(
                        selection: $theme.language,
                        options: YunLanguage.allCases.map { ($0, $0.title) })
                    Text(
                        loc(
                            "Takes effect at once. Kept separately from the system's own language, so this application can be read in one language on a Mac set up in another."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            heading(loc("At launch"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    Toggle(
                        loc("Open at login"),
                        isOn: Binding(
                            get: { model.launchesAtLogin },
                            set: { model.launchesAtLogin = $0 })
                    )
                    .toggleStyle(YunToggleStyle())
                    YunDivider()
                    Toggle(loc("Start routing at launch"), isOn: $model.autoStart)
                        .toggleStyle(YunToggleStyle())
                    if let error = model.loginItemError {
                        Text(error)
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            heading(loc("Where it lives"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    Toggle(
                        loc("Show in the Dock"),
                        isOn: Binding(
                            get: { showsDockIcon },
                            set: {
                                showsDockIcon = $0
                                InterfaceOptions.showsDockIcon = $0
                            })
                    )
                    .toggleStyle(YunToggleStyle())
                    Text(
                        loc(
                            "Off, this is a menu bar accessory: no Dock icon and no application menu. On, it is an ordinary application and ⌘-tab reaches it."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading(loc("Theme"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunSegmented(
                        selection: $theme.appearance,
                        options: YunAppearance.allCases.map { ($0, $0.title) })
                    Text(
                        loc(
                            "Set on the application rather than on the window, so the menu bar panel follows it too."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            heading(loc("Surfaces"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunSegmented(
                        selection: $model.style,
                        options: YunStyle.allCases.map { ($0, $0.title) })
                    Text(model.style.detail)
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            heading(loc("Application icon"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    iconSwatches
                    Text(
                        loc(
                            "Changes the icon this application draws — the About panel, its alerts and its notifications. The icon Finder shows is built into the app; rebuild it with ./App/make-icon.sh --style <name>."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            heading(loc("Accent colour"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    accentSwatches
                    if theme.accent == .custom {
                        HStack(spacing: Yun.Space.md) {
                            HueStrip(hue: $theme.accentHue)
                            Text("\(Int(theme.accentHue * 360))°")
                                .font(Yun.Text.mono)
                                .foregroundStyle(Yun.Palette.textSecondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    YunDivider()
                    accentPreview
                }
            }
        }
    }

    /// The icons, drawn as themselves and at a size somebody judges an icon at.
    ///
    /// A segmented control of three words would be asking people to choose
    /// between "graphite", "paper" and "mist" without showing them any of it.
    private var iconSwatches: some View {
        HStack(alignment: .top, spacing: Yun.Space.md) {
            ForEach(YunIconBadge.styles, id: \.name) { style in
                let isSelected = model.iconStyle == style.name
                Button {
                    model.iconStyle = style.name
                } label: {
                    VStack(spacing: 6) {
                        Image(nsImage: YunIconBadge.image(size: 52, style: style))
                            .frame(width: 52, height: 52)
                            .overlay {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(
                                        isSelected
                                            ? Yun.Palette.textPrimary : Color.clear,
                                        lineWidth: 2
                                    )
                                    .padding(-4)
                            }
                            .padding(4)
                        Text(loc(style.name))
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(
                                isSelected
                                    ? Yun.Palette.textPrimary : Yun.Palette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(Text(loc(style.name)))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
    }

    /// The accents, drawn in themselves. A list of colour names would be the
    /// one control in this window that cannot be read at a glance.
    private var accentSwatches: some View {
        HStack(alignment: .top, spacing: Yun.Space.md) {
            ForEach(YunAccent.allCases) { accent in
                let isSelected = theme.accent == accent
                Button {
                    theme.accent = accent
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(accent.colour(hue: theme.accentHue))
                            .frame(width: 22, height: 22)
                            .overlay {
                                // Two rings rather than one: the inner gap in
                                // the card's own colour is what stops a
                                // selected near-white swatch from merging into
                                // its own selection ring on a dark theme.
                                Circle()
                                    .strokeBorder(Yun.Palette.card, lineWidth: 2)
                                    .padding(-3)
                            }
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        isSelected
                                            ? Yun.Palette.textPrimary : Yun.Palette.border,
                                        lineWidth: isSelected ? 2 : 1
                                    )
                                    .padding(-5)
                            }
                            .padding(5)
                        Text(accent.title)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(
                                isSelected
                                    ? Yun.Palette.textPrimary : Yun.Palette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(Text(accent.title))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
    }

    /// What the accent actually reaches. Three controls that all take their
    /// colour from it, so the choice can be judged where it is used rather
    /// than on a swatch.
    private var accentPreview: some View {
        HStack(spacing: Yun.Space.lg) {
            YunSwitch(isOn: $previewSwitch)
            YunLevelMeter(level: 0.42, peakHold: 0.6, segments: 16)
                .frame(width: 120)
            YunProgressBar(fraction: 0.62)
                .frame(width: 90)
            Spacer(minLength: 0)
            Text(loc("Preview"))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
        }
    }

    // MARK: Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading(loc("Sample rate"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunSegmented(
                        selection: $model.preferredSampleRate,
                        options: model.availableSampleRates.map {
                            ($0, Format.sampleRate($0))
                        })
                    Text(
                        loc(
                            "Applied when both devices support it. A voice chat gains nothing above 48 kHz — the far end resamples it back down."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            heading(loc("Buffer size"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunSegmented(
                        selection: $model.bufferFrames,
                        options: RouterModel.bufferSizes.map { ($0, "\($0)") })
                    YunDetailRow(
                        loc("One IO cycle"),
                        value: String(format: "%.2f ms", cycleMilliseconds))
                    Text(
                        loc(
                            "Frames the engine is handed at a time. Smaller is less delay and less room to do the work in; a route that is running restarts to take the new size."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            heading(loc("Loudness target"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunSegmented(
                        selection: $model.loudnessTarget,
                        options: LoudnessTarget.allCases.map { ($0, $0.title) })
                    YunDetailRow(
                        loc("Target"),
                        value: String(format: "%.0f LUFS", model.loudnessTarget.lufs))
                    Text(
                        loc(
                            "What the loudness readout is compared against, and what automatic levelling aims for. Every platform normalises to its own number."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            heading(loc("Recording"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    Toggle(
                        loc("Write a file per source as well as the mix"),
                        isOn: $model.recordsStems
                    )
                    .toggleStyle(YunToggleStyle())
                    Text(
                        loc(
                            "Stems are taken before the fader, so each one is what that source produced rather than a record of this session's mix decisions."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One IO cycle at the requested rate, which is the part of the latency
    /// this window can actually decide. The device's own offset is measured
    /// under Diagnostics once a route is up.
    private var cycleMilliseconds: Double {
        let rate = model.preferredSampleRate
        guard rate > 0 else { return 0 }
        return Double(model.bufferFrames) / rate * 1000
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading(loc("Anywhere"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    ForEach(
                        Array(model.hotkeyDescriptions.filter(\.isGlobal).enumerated()),
                        id: \.offset
                    ) {
                        _, entry in
                        HStack {
                            Text(entry.title)
                                .font(Yun.Text.body)
                                .foregroundStyle(Yun.Palette.textPrimary)
                            Spacer()
                            Text(entry.shortcut)
                                .font(Yun.Text.mono)
                                .foregroundStyle(Yun.Palette.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Yun.Palette.elevated, in: .rect(cornerRadius: 6)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Yun.Palette.border, lineWidth: 1)
                                }
                        }
                    }
                }
            }

            heading(loc("In the window"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    ForEach(
                        Array(model.hotkeyDescriptions.filter { !$0.isGlobal }.enumerated()),
                        id: \.offset
                    ) {
                        _, entry in
                        HStack {
                            Text(entry.title)
                                .font(Yun.Text.body)
                                .foregroundStyle(Yun.Palette.textPrimary)
                            Spacer()
                            Text(entry.shortcut)
                                .font(Yun.Text.mono)
                                .foregroundStyle(Yun.Palette.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Yun.Palette.elevated, in: .rect(cornerRadius: 6)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Yun.Palette.border, lineWidth: 1)
                                }
                        }
                    }
                }
            }

            if model.hotkeyFailures.isEmpty {
                Text(
                    loc(
                        "Registered with the window server, so they work without Input Monitoring permission."
                    )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.hotkeyFailures, id: \.self) { failure in
                    Text(failure)
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.warning)
                }
            }
        }
    }

    // MARK: MIDI

    /// Beside the shortcuts rather than under Audio, because this is the same
    /// kind of thing a keyboard shortcut is: a way of reaching a control
    /// without the window. The difference is that a fader has a position, which
    /// is why every continuous row also says whether the hardware has taken
    /// over yet.
    private var midiSection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading(loc("Controller"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunDetailRow(
                        loc("Connected"),
                        value: model.midiControl.sourceNames.isEmpty
                            ? loc("nothing") : midiSourceSummary,
                        tone: model.midiControl.sourceNames.isEmpty ? .neutral : .success)
                    // The one line that separates "nothing is bound" from
                    // "nothing is arriving". Without it a controller sending on
                    // a channel nobody is listening to looks exactly like a
                    // controller that is not plugged in.
                    YunDetailRow(loc("Last received"), value: midiLastMessage)
                    if let error = model.midiControl.startupError {
                        Text(error)
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            heading(loc("Levels"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    ForEach(MIDITarget.Fader.allCases, id: \.self) { fader in
                        midiRow(.fader(fader))
                    }
                }
            }

            heading(loc("Buttons"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    ForEach(RemoteCommand.bindable, id: \.url) { command in
                        midiRow(.command(url: command.url.absoluteString))
                    }
                }
            }

            if !model.midiSourceTargets.isEmpty {
                heading(loc("Sources"))
                YunCard {
                    VStack(alignment: .leading, spacing: Yun.Space.md) {
                        ForEach(model.midiSourceTargets, id: \.uid) { source in
                            Text(source.label)
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textTertiary)
                            ForEach(source.targets, id: \.self) { target in
                                midiRow(target)
                            }
                        }
                    }
                }
            }

            Text(
                loc(
                    "Press Learn, then move the knob or hit the pad. A fader does nothing until it passes through the level already set, so picking one up cannot slam the signal."
                )
            )
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One row: what it drives, what it is bound to, and the two buttons.
    private func midiRow(_ target: MIDITarget) -> some View {
        let midi = model.midiControl
        let isLearning = midi.learningTarget == target
        let bound = midi.binding(for: target)
        return HStack(spacing: Yun.Space.sm) {
            Text(target.title)
                .font(Yun.Text.body)
                .foregroundStyle(Yun.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Yun.Space.sm)

            // Filled once the hardware has caught up with the software value.
            // A hollow ring is the whole of soft takeover made visible: the
            // knob is bound, it is being received, and it is deliberately not
            // doing anything yet.
            if bound != nil, target.isContinuous {
                Circle()
                    .fill(
                        midi.isEngaged(target)
                            ? Yun.Palette.accent : Color.clear
                    )
                    .overlay {
                        Circle().strokeBorder(Yun.Palette.borderStrong, lineWidth: 1)
                    }
                    .frame(width: 7, height: 7)
            }

            Text(bound?.displayName ?? loc("unbound"))
                .font(Yun.Text.mono)
                .foregroundStyle(
                    bound == nil ? Yun.Palette.textMuted : Yun.Palette.textSecondary
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Yun.Palette.elevated, in: .rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Yun.Palette.border, lineWidth: 1)
                }

            Button(isLearning ? loc("Listening…") : loc("Learn")) {
                midi.learningTarget = isLearning ? nil : target
            }
            .buttonStyle(YunButtonStyle(isLearning ? .primary : .secondary, small: true))

            Button(loc("Clear")) { midi.forget(target) }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
                .disabled(bound == nil)
                .opacity(bound == nil ? 0.35 : 1)
        }
    }

    private var midiSourceSummary: String {
        model.midiControl.sourceNames.joined(separator: " · ")
    }

    private var midiLastMessage: String {
        guard let message = model.midiControl.lastMessage else { return loc("nothing yet") }
        var line = message.address.displayName + " · \(message.value)"
        // When it arrived, which the controller has recorded since it was
        // written and nothing showed. Without it a pad pressed a minute ago and
        // a pad pressed just now read identically, which is exactly the
        // question somebody staring at this row is asking.
        if let at = model.midiControl.lastMessageAt {
            line += " · " + String(format: loc("%ds ago"), Int(-at.timeIntervalSinceNow))
        }
        return line
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading(loc("Signal path"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    if let quality = model.pathQuality {
                        YunDetailRow(
                            loc("Integrity"),
                            value: loc(quality.integrityKey),
                            tone: quality.isBitExact ? .success : .warning)
                        YunDetailRow(loc("Sample rate"), value: "\(Int(quality.sampleRate)) Hz")
                        YunDetailRow(
                            loc("Buffer"),
                            value: String(
                                format: "%d frames · %.2f ms",
                                quality.bufferFrames, quality.bufferLatencyMilliseconds))
                        YunDetailRow(
                            loc("Clock"),
                            value: model.isClockLocked
                                ? String(
                                    format: loc("locked · %.6f"), model.measuredRateRatio)
                                : loc("not locked"),
                            tone: model.isClockLocked ? .success : .neutral)
                        if model.isClockLocked {
                            YunDetailRow(
                                loc("Crystal error"),
                                value: String(
                                    format: "%.1f ppm",
                                    (model.measuredRateRatio - 1) * 1_000_000))
                        }
                    } else {
                        Text(loc("Start routing to see live measurements."))
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            heading(loc("Integrity check"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    Text(
                        loc(
                            "Sends a known sequence through the whole path and compares every sample that comes back. The only way to know whether your own path is lossless, rather than being told it is."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Yun.Space.sm) {
                        Button(
                            model.isCheckingIntegrity
                                ? loc("Checking…") : loc("Run the check")
                        ) {
                            model.checkIntegrity()
                        }
                        .buttonStyle(YunButtonStyle(.primary, small: true))
                        .disabled(!model.canCheckIntegrity)

                        if model.isCheckingIntegrity {
                            YunProgressBar(fraction: model.integrityProgress)
                        }
                    }

                    if let result = model.integrityResult {
                        YunDivider()
                        YunDetailRow(
                            loc("Result"),
                            value: loc(
                                result.isBitExact
                                    ? "bit-exact"
                                    : (result.didAlign
                                        ? "resampled" : "the signal did not come back")),
                            tone: result.isBitExact
                                ? .success : (result.didAlign ? .warning : .danger))
                        YunDetailRow(
                            loc("Samples compared"),
                            value: "\(result.exactMatches) / \(result.comparedFrames)")
                        YunDetailRow(
                            loc("Loopback delay"),
                            value: String(
                                format: loc("%d frames"), result.delayFrames))
                        if !result.isBitExact && result.didAlign {
                            // Mean before max: on a resampled path the maximum
                            // is a single worst sample and says little, while
                            // the mean is the size of the conversion.
                            YunDetailRow(
                                loc("Mean error"),
                                value: String(format: "%.6f", result.meanAbsoluteError))
                            YunDetailRow(
                                loc("Largest error"),
                                value: String(format: "%.6f", result.maxAbsoluteError))
                        }
                        if !result.didAlign {
                            Text(
                                loc(
                                    "Nothing recognisable came back. The output may not loop back to its own input, or something else is writing to the same channel."
                                )
                            )
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let error = model.integrityError {
                        Text(error)
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if model.selectedDestination?.inputChannels == 0 {
                        // A destination with no input cannot be read back, so
                        // there is nothing to compare against. Saying which
                        // devices can beats greying out a button in silence.
                        Text(
                            loc(
                                "This output has no input to read back from. Pick a loopback device — the YunAudio device, or another virtual endpoint."
                            )
                        )
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            heading(loc("Realtime safety"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    Toggle(
                        loc("Watch the IO thread for allocations"),
                        isOn: $model.watchesIOAllocations
                    )
                    .toggleStyle(YunToggleStyle())
                    Text(
                        loc(
                            "The hook sits in front of every allocation the whole process makes, so it is a measurement to switch on rather than leave running."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                    if model.watchesIOAllocations {
                        YunDivider()
                        YunDetailRow(
                            loc("IO thread allocations"),
                            value: "\(model.allocationViolations)",
                            tone: model.allocationViolations == 0 ? .success : .warning)
                        Text(
                            loc(
                                "Anything above zero is a broken realtime contract. Voice isolation raises it — the allocations come from inside Apple's model, not from this app."
                            )
                        )
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                        if model.isDebugBuild {
                            Text(
                                loc(
                                    "This is an unoptimised build, so the count is Swift's own bounds and exclusivity checking and says nothing about the code that ships."
                                )
                            )
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            HStack(spacing: Yun.Space.md) {
                // The application icon proper, not the bare mark. This is the
                // one place in an accessory application where somebody looks
                // for the icon they see in Finder, and showing a different
                // thing here is how an About panel reads as somebody else's.
                Image(
                    nsImage: YunIconBadge.image(
                        size: 56, style: YunIconBadge.style(named: model.iconStyle))
                )
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("YunAudio"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Yun.Palette.textPrimary)
                    Text(
                        String(
                            format: loc("Version %@"),
                            Bundle.main.object(
                                forInfoDictionaryKey: "CFBundleShortVersionString")
                                as? String ?? "—")
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                }
            }

            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunDetailRow(
                        loc("Virtual device"),
                        value: loc(
                            model.isDriverInstalled ? "installed" : "not installed"),
                        tone: model.isDriverInstalled ? .success : .warning)
                    // The way back out. The application offered to install a
                    // driver and gave no way at all to remove one — the command
                    // was in the README and nowhere in the interface, which
                    // makes an installation somebody cannot undo without going
                    // to look something up.
                    if model.isDriverInstalled {
                        HStack {
                            Text(
                                loc(
                                    "Removing it restarts coreaudiod, so all audio stops for a moment, and it needs an administrator password."
                                )
                            )
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.textSecondary)
                            Spacer(minLength: Yun.Space.sm)
                            Button(loc("Remove")) { model.removeDriver() }
                                .buttonStyle(.plain)
                                .disabled(model.isInstallingDriver)
                                .foregroundStyle(Yun.Palette.danger)
                        }
                        if let message = model.driverMessage {
                            Text(message)
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.danger)
                                .textSelection(.enabled)
                        }
                    }
                    YunDetailRow(loc("Licence"), value: "MIT")
                }
            }

            // What the project actually achieves, in the numbers it was
            // measured at rather than in adjectives. The page said none of this
            // — a version number, a licence and one sentence — for a thing
            // whose entire argument is that it can prove what it claims.
            heading(loc("Measured"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunDetailRow(
                        loc("Signal path"), value: loc("bit-exact"), tone: .success)
                    // The numbers are arguments rather than part of the
                    // translated sentence. Baked in, a measurement lives in two
                    // `.strings` files and changing it means editing both — and
                    // "0.40% of one core" as a *key* puts a bare `%` in front of
                    // a letter, which is an octal conversion the day anybody
                    // passes it through `String(format:)`.
                    YunDetailRow(
                        loc("Round trip"),
                        value: String(
                            format: loc("%@ at %d frames"),
                            Format.milliseconds(Measured.roundTripMilliseconds),
                            Measured.roundTripFrames))
                    YunDetailRow(
                        loc("Processor"),
                        value: String(
                            format: loc("%@ of one core"),
                            Format.percent(Measured.processorShare)))
                    YunDetailRow(
                        loc("IO thread allocations"), value: "0", tone: .success)
                    Text(
                        loc(
                            "Run the integrity check under Diagnostics to measure your own path rather than taking these."
                        )
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(
                loc(
                    "The virtual device is written from scratch against CoreAudio's AudioServerPlugIn interface. It shares no code with BlackHole, which is GPL-3.0."
                )
            )
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Yun.Palette.textTertiary)
            .textCase(.uppercase)
    }
}
