import SwiftUI
import YunDesign

/// Watches for the application quitting.
///
/// Routing changes the sample rate of real hardware, and that change outlives
/// the process. `deinit` is not enough — a SwiftUI app that is quit from the
/// menu tears down without necessarily releasing the model first, which is
/// exactly how someone's microphone ends up left at 96 kHz.
@MainActor
final class TerminationObserver: NSObject, NSApplicationDelegate {
    var onTerminate: (@MainActor () -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}

@main
struct YunAudioApp: App {
    @State private var model = RouterModel()
    @NSApplicationDelegateAdaptor(TerminationObserver.self) private var termination

    init() {
        // The .lproj folders ship with this module, not with the main bundle.
        YunStrings.bundle = Bundle.module

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
                .onAppear { termination.onTerminate = { model.shutDown() } }
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
/// The mark is always present, because it is the only place this application is
/// visible: an accessory app has no Dock icon and no window of its own until one
/// is opened. Level bars appear beside it while routing, which answers the one
/// question a menu bar utility should answer without being clicked — is audio
/// actually flowing.
struct MenuBarIcon: View {
    let level: Float?

    private static let barHeights: [CGFloat] = [0.45, 0.85, 0.6]

    var body: some View {
        HStack(spacing: 3) {
            if let mark = NSImage(named: "Icon") ?? Bundle.module.image(forResource: "Icon") {
                Image(nsImage: mark)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 15, height: 15)
            } else {
                // The icon is a resource, and a resource can be missing.
                Image(systemName: "waveform")
            }

            if level != nil {
                HStack(spacing: 1.5) {
                    ForEach(Array(Self.barHeights.enumerated()), id: \.offset) {
                        index, weight in
                        Capsule()
                            .frame(width: 1.5, height: barHeight(weight: weight, index: index))
                    }
                }
                .frame(height: 13)
            }
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
