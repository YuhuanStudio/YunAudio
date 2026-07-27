import SwiftUI
import YunAudioEngine
import YunDesign

/// Balancing every source from one short recording.
///
/// Shaped like the record button on purpose. It is the same gesture — press,
/// something happens for a fixed time, then you get a result — and it is the
/// only one in this application where the user has to do something in the world
/// rather than on screen.
struct CalibrationPanel: View {
    @Bindable var model: RouterModel

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            switch model.calibrationPhase {
            case .idle: invitation
            case .countdown(let seconds): countdown(seconds)
            case .listening: listening
            case .proposing: proposal
            case .failed(let message): failure(message)
            }
        }
    }

    // MARK: Idle

    private var invitation: some View {
        HStack(alignment: .top, spacing: Yun.Space.md) {
            Button(action: { model.startCalibration() }) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.below.square.filled.and.square")
                        .font(.system(size: 11))
                    Text(loc("Balance"))
                }
            }
            .buttonStyle(YunButtonStyle(.secondary, small: true))
            .disabled(!model.canCalibrate)

            VStack(alignment: .leading, spacing: 1) {
                Text(loc("Balance every source"))
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.textPrimary)
                Text(
                    loc(
                        "Everyone speaks in turn for ten seconds. Each source is measured only while it is actually producing something, then the voices are put on one level and the music underneath them."
                    )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Running

    private func countdown(_ seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack(spacing: Yun.Space.md) {
                Text("\(seconds)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(Yun.Palette.accent)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Text(loc("Get ready — everyone speaks in turn."))
                    .font(Yun.Text.body)
                    .foregroundStyle(Yun.Palette.textSecondary)
                Spacer(minLength: 0)
                cancelButton
            }
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack(spacing: Yun.Space.md) {
                Circle()
                    .fill(Yun.Palette.danger)
                    .frame(width: 10, height: 10)
                Text(loc("Listening — say something, each of you."))
                    .font(Yun.Text.body)
                    .foregroundStyle(Yun.Palette.textPrimary)
                Spacer(minLength: 0)
                Text(String(format: "%.0f", ceil(model.calibrationRemaining)))
                    .font(Yun.Text.mono)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .monospacedDigit()
                cancelButton
            }

            // Per-source progress while it listens, so somebody can tell they
            // are not being heard before the ten seconds are over rather than
            // afterwards.
            ForEach(Array(model.sourceGroups.enumerated()), id: \.element.id) { index, group in
                if index < model.calibrationHeard.count,
                    let route = model.representative(of: group)
                {
                    HStack(spacing: Yun.Space.sm) {
                        Image(
                            systemName: model.calibrationHeard[index] >= 1
                                ? "checkmark.circle.fill" : "circle.dotted"
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(
                            model.calibrationHeard[index] >= 1
                                ? Yun.Palette.success : Yun.Palette.textMuted)
                        Text(model.routeTitle(route))
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.textSecondary)
                        Spacer(minLength: 0)
                        Text(String(format: "%.1fs", model.calibrationHeard[index]))
                            .font(Yun.Text.mono)
                            .foregroundStyle(Yun.Palette.textMuted)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var cancelButton: some View {
        Button(loc("Cancel")) { model.cancelCalibration() }
            .buttonStyle(YunButtonStyle(.ghost, small: true))
    }

    // MARK: Result

    private var proposal: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            Text(loc("What this would change"))
                .font(Yun.Text.label)
                .foregroundStyle(Yun.Palette.textPrimary)

            // Shown before it is applied rather than applied and announced.
            // A tool that silently moves somebody's faders is one they stop
            // trusting the first time it gets something wrong.
            ForEach(model.calibrationProposals, id: \.id) { entry in
                if entry.id < model.calibrationGroups.count,
                    let route = model.representative(of: model.calibrationGroups[entry.id])
                {
                    HStack(spacing: Yun.Space.sm) {
                        Text(model.routeTitle(route))
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.textSecondary)
                        YunBadge(loc(model.role(of: route).title))
                        Spacer(minLength: 0)
                        Text(String(format: "%+.1f dB", entry.change))
                            .font(Yun.Text.mono)
                            .foregroundStyle(
                                entry.change > 0 ? Yun.Palette.info : Yun.Palette.warning
                            )
                            .monospacedDigit()
                    }
                }
            }

            HStack(spacing: Yun.Space.sm) {
                Button(loc("Apply")) { model.applyCalibration() }
                    .buttonStyle(YunButtonStyle(.primary, small: true))
                Button(loc("Discard")) { model.cancelCalibration() }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
                Spacer(minLength: 0)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Yun.Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Yun.Palette.warning)
            Text(message)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(loc("Again")) { model.startCalibration() }
                .buttonStyle(YunButtonStyle(.ghost, small: true))
        }
    }
}
