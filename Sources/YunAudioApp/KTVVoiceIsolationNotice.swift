import SwiftUI
import YunDesign

/// The warning that voice isolation is about to remove the song.
///
/// This is the setting that produced the complaint "everything sounds wrong":
/// Apple's model keeps one person speaking and treats everything else as noise,
/// which is the backing track and, on a held note, the singing too. Somebody who
/// picked the 語音通話 preset months ago has no reason to connect the two, and
/// the reading they get is a signal that collapses to nothing.
///
/// It was written for the inspector and lived only there — so the surface people
/// actually sing at, the one that fills the screen and hides the panel behind it,
/// said nothing at all. A warning that only appears where nobody is looking is
/// not a warning.
///
/// Said rather than overridden: it is a setting somebody chose, and an
/// application that silently undoes choices is worse than one that explains
/// them. The button is there because being told without being able to act is
/// only half of it.
struct KTVVoiceIsolationNotice: View {

    enum Scale {
        case stage
        case inspector

        /// The stage sits on a darkened photograph, where the inspector's warm
        /// grey is unreadable and the amber has to carry itself.
        var title: Font {
            self == .stage ? .system(size: 13, weight: .semibold) : Yun.Text.label
        }
        var caption: Font {
            self == .stage ? .system(size: 11, weight: .regular) : Yun.Text.caption
        }
        var quiet: Color {
            self == .stage ? Yun.Palette.OnStage.secondary : Yun.Palette.textSecondary
        }
        var well: Double { self == .stage ? 0.18 : 0.10 }
    }

    @Bindable var model: RouterModel
    var scale: Scale = .stage

    var body: some View {
        let _ = BodyCount.tick(
            scale == .stage ? "KTVVoiceIsolationStage" : "KTVVoiceIsolationPanel")
        if model.voiceIsolationWillHurtSinging {
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                Label(
                    loc("Voice isolation is on, and it will treat the song as noise."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(scale.title)
                .foregroundStyle(Yun.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    loc(
                        "Apple's model keeps one person speaking and removes everything else, which is the backing track and the singing. It also adds about 56 ms."
                    )
                )
                .font(scale.caption)
                .foregroundStyle(scale.quiet)
                .fixedSize(horizontal: false, vertical: true)
                Button(loc("Turn it off while singing")) {
                    model.voiceIsolationEnabled = false
                }
                .buttonStyle(YunButtonStyle(.primary, small: true))
                .accessibilityIdentifier(identifier("DisableVoiceIsolation"))
            }
            .padding(Yun.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Yun.Palette.warning.opacity(scale.well),
                in: .rect(cornerRadius: Yun.Radius.card)
            )
            .accessibilityIdentifier(identifier("VoiceIsolationWarning"))
        }
    }

    /// The panel's identifiers are the ones the flow check and the offscreen
    /// render already name, so they keep their old spelling rather than the
    /// component's.
    private func identifier(_ name: String) -> String {
        (scale == .stage ? "KTV" : "Singing") + name
    }
}
