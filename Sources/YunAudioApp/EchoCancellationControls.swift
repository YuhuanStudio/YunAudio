import SwiftUI
import YunDesign

/// Switching the echo canceller on, and saying what it costs.
///
/// Shared rather than written once per surface. Every time a control has been
/// added to both the window and the panel separately in this project, the two
/// copies have drifted — different wording, one localised and one not, one
/// showing the status and one not. This is the fourth extraction of that shape.
struct EchoCancellationControls: View {
    @Bindable var model: RouterModel
    /// The panel lays its label column out to a fixed width; the window does
    /// not.
    var labelColumn: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            Toggle(
                loc("Remove the speakers from the microphone"), isOn: $model.cancelsEcho
            )
            .toggleStyle(YunToggleStyle())

            Text(
                loc(
                    "For speakers rather than headphones. Apple's canceller takes the microphone, so the path loses its clock lock and gains a buffer of latency each way."
                )
            )
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            if model.cancelsEcho {
                YunDivider()
                HStack(spacing: Yun.Space.sm) {
                    Text(loc("Cancel against"))
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .frame(width: labelColumn, alignment: .leading)
                    YunSelect(
                        selection: $model.echoSpeakerUID,
                        options: model.echoSpeakerOptions.map {
                            .init(
                                value: $0.uid as String?, title: $0.name,
                                detail: "\($0.outputChannels)ch")
                        })
                }

                // Asked for and not running. Until this row existed the engine
                // knew and only the command-line harness could be told.
                if let message = model.echoCancellationMessage {
                    YunDetailRow(loc("Canceller"), value: message, tone: .danger)
                }

                if let status = model.echoStatus {
                    YunDetailRow(
                        loc("Reference"),
                        value: loc(status.hasReference ? "present" : "absent"),
                        tone: status.hasReference ? .success : .warning)
                    YunDetailRow(
                        loc("Buffered"),
                        value: String(format: loc("%d frames"), Int(status.buffered)))
                    if status.dropped > 0 {
                        YunDetailRow(
                            loc("Dropped"), value: "\(status.dropped)", tone: .danger)
                    }
                    // "Should be zero; anything else means the device changed
                    // its buffer size underneath the unit", said the field's
                    // own doc comment — while nothing read it. Every sibling
                    // in that struct was already shown somewhere.
                    if status.truncatedBlocks > 0 {
                        YunDetailRow(
                            loc("Truncated"), value: "\(status.truncatedBlocks)",
                            tone: .warning)
                    }
                }
            }
        }
    }
}
