import SwiftUI
import YunAudioEngine
import YunDesign

/// Starting and stopping a recording.
///
/// The engine has been able to record since the recorder was written, the tests
/// cover it, and there is a preset in the header literally named "Recording" —
/// but nothing in the interface could start one. A feature reachable only from
/// a CLI flag is a feature the application does not have.
///
/// Shared between the panel and the window rather than written twice, which is
/// how the two application lists drifted apart before them.
struct RecordingControls: View {
    @Bindable var model: RouterModel
    /// The panel is 340 points wide and stacks; the window has room for a row.
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack(spacing: Yun.Space.sm) {
                Button {
                    model.toggleRecording()
                } label: {
                    HStack(spacing: 6) {
                        // A filled circle, red only while it is armed. A red
                        // dot on an idle control reads as an alert.
                        Circle()
                            .fill(
                                model.isRecording
                                    ? Yun.Palette.danger : Yun.Palette.textMuted
                            )
                            .frame(width: 8, height: 8)
                        Text(model.isRecording ? loc("Stop recording") : loc("Record"))
                    }
                }
                .buttonStyle(
                    YunButtonStyle(
                        model.isRecording ? .primary : .secondary, small: true)
                )
                .disabled(!model.isRunning && !model.isRecording)
                .help(loc(model.isRecording ? "Stop recording (⌘R)" : "Record (⌘R)"))

                if model.isRecording {
                    // Pause rather than stop is what somebody wants when the
                    // doorbell goes: the file stays open and what comes out is
                    // one clean splice instead of two files to join later.
                    Button {
                        model.toggleRecordingPause()
                    } label: {
                        Image(
                            systemName: model.isRecordingPaused ? "play.fill" : "pause.fill"
                        )
                        .font(.system(size: 10))
                        .frame(width: 14)
                    }
                    .buttonStyle(YunButtonStyle(.secondary, small: true))
                    .help(loc(model.isRecordingPaused ? "Resume" : "Pause"))

                    Text(Self.elapsed(model.recordingSeconds))
                        .font(Yun.Text.mono)
                        .foregroundStyle(
                            model.isRecordingPaused
                                ? Yun.Palette.textTertiary : Yun.Palette.textPrimary
                        )
                        .monospacedDigit()
                    if model.isRecordingPaused {
                        Text(loc("Paused"))
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.warning)
                    }
                } else {
                    // No fixed width. It was pinned at 140 points, which fitted
                    // two formats and truncated three the day FLAC was added —
                    // the picker read "W… F… …" and nothing in the code said
                    // so. A segmented control should be as wide as its
                    // segments.
                    YunSegmented(
                        selection: $model.recordingFormat,
                        options: Recorder.Format.allCases.map { ($0, $0.title) }
                    )
                    .fixedSize()
                }

                Spacer(minLength: 0)
            }

            if !isCompact {
                HStack(spacing: Yun.Space.sm) {
                    Toggle(isOn: $model.recordsStems) { EmptyView() }
                        .toggleStyle(YunToggleStyle())
                        .labelsHidden()
                        .disabled(model.isRecording)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(loc("A file per source as well"))
                            .font(Yun.Text.label)
                            .foregroundStyle(Yun.Palette.textPrimary)
                        Text(
                            loc(
                                "The mix says what the far end heard. A file per source says what each of you said, which no amount of editing can recover from a mix."
                            )
                        )
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }

            if !model.isRunning && !model.isRecording {
                Text(loc("Start routing before recording."))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
            } else if let url = model.recordingURL {
                // The finished file, with the one action anyone wants for it.
                // Naming the file rather than the folder because the folder is
                // Music and that says nothing.
                Button {
                    model.revealRecording()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(url.path)
            }
        }
    }

    /// Elapsed time from frames written, not from a wall clock: a writer that
    /// stalls should stop the counter rather than keep it ticking over a file
    /// that is no longer growing.
    private static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
