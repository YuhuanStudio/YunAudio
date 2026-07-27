import SwiftUI
import YunDesign

@main
struct YunAudioApp: App {
    @State private var model = RouterModel()

    init() {
        // Design verification path. A menu bar popover cannot be opened without
        // accessibility permission, so the panel is rendered offscreen instead —
        // in both appearances, which is the only way to catch a colour that
        // works in one theme and vanishes in the other.
        if let directory = ProcessInfo.processInfo.environment["YUNAUDIO_RENDER"] {
            MainActor.assumeIsolated {
                PanelRenderer.write(to: directory, model: RouterModel())
            }
            exit(0)
        }
    }

    var body: some Scene {
        // The application proper. A routing tool wants width — sources, mixer
        // and signal path side by side — not a tall column.
        Window("YunAudio", id: "main") {
            MainWindow(model: model)
        }
        .defaultSize(width: 1000, height: 620)
        .windowResizability(.contentMinSize)

        Settings {
            PreferencesWindow(model: model)
        }

        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarIcon(level: model.isRunning ? model.peakLevel : nil)
        }
        // A real window rather than a menu: the panel holds pickers, meters and
        // a live readout, none of which belong in a list of menu items.
        .menuBarExtraStyle(.window)
    }
}

/// The status item glyph.
///
/// Idle is a plain waveform. While routing, the bars move with the signal —
/// enough to confirm at a glance that audio is flowing without opening the
/// panel, which is the one question a menu bar utility should answer for free.
struct MenuBarIcon: View {
    let level: Float?

    private static let barHeights: [CGFloat] = [0.35, 0.7, 1.0, 0.6, 0.45]

    var body: some View {
        if level != nil {
            HStack(spacing: 1.5) {
                ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { index, weight in
                    Capsule()
                        .frame(width: 1.5, height: barHeight(weight: weight, index: index))
                }
            }
            .frame(height: 14)
        } else {
            Image(systemName: "waveform")
        }
    }

    private func barHeight(weight: CGFloat, index: Int) -> CGFloat {
        let amplitude = CGFloat(level ?? 0)
        // Amplitude is compressed rather than used raw: speech sits low on a
        // linear scale and the glyph would barely move.
        let scaled = pow(min(1, amplitude * 4), 0.5)
        let minimum: CGFloat = 2
        let maximum: CGFloat = 13
        return minimum + (maximum - minimum) * scaled * weight
    }
}
