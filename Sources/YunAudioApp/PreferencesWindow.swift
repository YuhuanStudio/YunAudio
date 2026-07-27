import SwiftUI
import YunAudioHAL
import YunDesign

/// The standalone preferences window.
///
/// Everything here is deliberately *not* in the menu bar panel: the panel is for
/// what you change during a session, and this is for what you set once. Mixing
/// them made the panel tall enough to matter on a laptop screen.
struct PreferencesWindow: View {
    @Bindable var model: RouterModel
    @State private var selection: Section

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
        case general, shortcuts, diagnostics, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            case .diagnostics: "Diagnostics"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .shortcuts: "command"
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
        case .shortcuts: shortcutsSection
        case .diagnostics: diagnosticsSection
        case .about: aboutSection
        }
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading(loc("General"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    Toggle(
                        "Open at login",
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

            heading(loc("Sample rate"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunSegmented(
                        selection: $model.preferredSampleRate,
                        options: model.availableSampleRates.map {
                            ($0, "\(Int($0 / 1000)) kHz")
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
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading(loc("Shortcuts"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.md) {
                    ForEach(Array(model.hotkeyDescriptions.enumerated()), id: \.offset) {
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

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading(loc("Signal path"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    if let quality = model.pathQuality {
                        YunDetailRow(
                            loc("Integrity"),
                            value: loc(
                                quality.isBitExact
                                    ? "bit-exact"
                                    : (quality.hasProcessing ? "processed" : "resampled")),
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
                    }
                }
            }

            heading(loc("Realtime safety"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
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
                }
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Yun.Space.lg) {
            heading(loc("YunAudio"))
            YunCard {
                VStack(alignment: .leading, spacing: Yun.Space.sm) {
                    YunDetailRow(loc("Version"), value: "0.1.0")
                    YunDetailRow(
                        loc("Virtual device"),
                        value: loc(
                            model.isDriverInstalled ? "installed" : "not installed"),
                        tone: model.isDriverInstalled ? .success : .warning)
                    YunDetailRow(loc("Licence"), value: "MIT")
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
