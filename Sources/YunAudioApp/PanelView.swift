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

    /// Width of the leading label column. Sized for the longest label in the
    /// panel — "Channels" wrapped mid-word when this was narrower.
    private static let labelColumn: CGFloat = 62

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                header
                if model.isDriverInstalled {
                    signalPath
                    devicePickers
                    if model.isRunning { runtimeDetail }
                    if let error = model.lastError { errorRow(error) }
                    voiceIsolation
                    settings
                    footer
                } else {
                    driverMissing
                }
            }
            .padding(Yun.Space.lg)
            .frame(width: 340)
        }
        .background(.clear)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("YunAudio")
                .font(Yun.Text.title)
                .foregroundStyle(Yun.Palette.textPrimary)
            Spacer()
            YunStatusPill(
                model.isRunning ? "Routing" : "Idle",
                tone: model.isRunning ? .success : .neutral)
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
        YunCard {
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
                Text("Channels")
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .frame(width: Self.labelColumn, alignment: .leading)

                YunSegmented(
                    selection: $model.channelMode,
                    options: SourceChannelMode.allCases.map { ($0, $0.title) })
            }

            if model.channelMode == .mono {
                HStack {
                    Text("Source")
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .frame(width: Self.labelColumn, alignment: .leading)
                    YunSegmented(
                        selection: $model.monoChannel,
                        options: (0..<source.inputChannels).map { ($0, "Ch \($0 + 1)") })
                }
                // The Seiren V3 Pro presents three input channels with only the
                // first carrying the capsule, so this is not an exotic case.
                Text("This device reports \(source.inputChannels) input channels; not all of them necessarily carry audio.")
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
                    YunDetailRow("Rate", value: "\(Int(quality.sampleRate)) Hz")
                    YunDetailRow(
                        "Buffer",
                        value: String(
                            format: "%d frames · %.2f ms",
                            quality.bufferFrames, quality.bufferLatencyMilliseconds))
                }
                if model.isClockLocked {
                    YunDetailRow(
                        "Clock",
                        value: String(format: "locked · %.6f", model.measuredRateRatio),
                        tone: .success)
                }
                if model.clockLockFailed {
                    Text("The clock lock dropped, so drift correction was switched back on. Audio is safe but no longer bit-exact.")
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
                Text("The YunAudio device is not installed")
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.textPrimary)
                Text("Routing needs the virtual audio device. Installing it copies a plug-in into /Library/Audio/Plug-Ins/HAL and restarts coreaudiod, which briefly stops all audio.")
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check again") { model.refreshDevices() }
                    .buttonStyle(YunButtonStyle(.secondary, small: true))
            }
        }
    }

    // MARK: Voice isolation

    private var voiceIsolation: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                Toggle("Voice isolation", isOn: $model.voiceIsolationEnabled)
                    .toggleStyle(YunToggleStyle())

                if model.voiceIsolationEnabled {
                    // The cost is stated up front. Enabling this is a different
                    // product from the 1.3 ms bypass path, and the panel should
                    // not let that happen quietly.
                    Text(model.isRunning
                        ? String(
                            format: "Apple's on-device model. Adds %.0f ms and ends bit-exactness.",
                            model.voiceIsolationLatencyMilliseconds)
                        : "Apple's on-device model. Adds about 56 ms and ends bit-exactness.")
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Removes background noise using the model behind FaceTime's Voice Isolation.")
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Settings

    private var settings: some View {
        YunCard {
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                Toggle("Start routing at launch", isOn: $model.autoStart)
                    .toggleStyle(YunToggleStyle())
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.launchesAtLogin = $0 }))
                    .toggleStyle(YunToggleStyle())
                if let error = model.loginItemError {
                    Text(error)
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
            Button(model.isRunning ? "Stop" : "Start") { model.toggle() }
                .buttonStyle(YunButtonStyle(.primary))

            Button("Refresh") { model.refreshDevices() }
                .buttonStyle(YunButtonStyle(.secondary, small: true))

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
        }
    }
}
