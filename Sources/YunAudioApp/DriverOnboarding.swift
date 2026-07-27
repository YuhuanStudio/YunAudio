import SwiftUI
import YunDesign

/// What to do when the virtual device is not there.
///
/// The window used to say nothing at all: without the driver it opened with an
/// empty output picker reading "None", an empty patchbay and an empty signal
/// path, and no hint that anything was missing or what to do about it. A first
/// run is the one moment where the app is guaranteed to be in that state.
struct DriverOnboarding: View {
    @Bindable var model: RouterModel
    /// The window shows this above a working layout, so it is a strip rather
    /// than the whole content; the panel has nothing else to show and gives it
    /// the full width.
    var isCompact = false

    var body: some View {
        YunCard(padding: isCompact ? Yun.Space.md : Yun.Space.lg) {
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                HStack(spacing: Yun.Space.sm) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.system(size: 12))
                        .foregroundStyle(Yun.Palette.warning)
                    Text(loc("The YunAudio device is not installed"))
                        .font(Yun.Text.label)
                        .foregroundStyle(Yun.Palette.textPrimary)
                    Spacer(minLength: Yun.Space.md)
                    if isCompact { actions }
                }

                Text(
                    loc(
                        "Routing needs the virtual audio device. Installing it copies a plug-in into /Library/Audio/Plug-Ins/HAL and restarts coreaudiod, which briefly stops all audio."
                    )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                // Another loopback endpoint will route audio perfectly well; it
                // just cannot be clock-locked, so the path is resampled rather
                // than bit-exact. Saying so beats implying the app is unusable.
                if let fallback = model.loopbackFallback {
                    Text(
                        String(
                            format: loc(
                                "%@ is being used instead. Routing works; the path is resampled rather than bit-exact."
                            ), fallback.name)
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if !isCompact { actions }

                if !model.canInstallDriver {
                    Text(
                        loc(
                            "Run ./Driver/build-driver.sh --install from the source tree, or use the copy on the disk image."
                        )
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

    private var actions: some View {
        HStack(spacing: Yun.Space.sm) {
            if model.canInstallDriver {
                Button(loc(model.isInstallingDriver ? "Installing…" : "Install")) {
                    model.installDriver()
                }
                .buttonStyle(YunButtonStyle(.primary, small: true))
                .disabled(model.isInstallingDriver)
            }
            Button(loc("Check again")) { model.refreshDevices() }
                .buttonStyle(YunButtonStyle(.secondary, small: true))
        }
    }
}
