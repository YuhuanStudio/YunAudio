import SwiftUI
import YunAudioControl
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
    /// Owned here because the status item has to outlive the scene body that
    /// created it, and a SwiftUI scene is not a place to keep a reference.
    var statusItem: StatusItemController?
    /// The control socket, for the same reason. Held so that quitting can take
    /// the socket file away — a stale one left on disk is what the next launch
    /// has to reason about.
    var controlListener: ControlListener?

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }

    /// Runs the flow check once the run loop is alive.
    ///
    /// It cannot run from `App.init()`: starting a route hops to a queue and
    /// back through `Task { @MainActor }`, and with no run loop yet that
    /// continuation never executes, so the first wait spins until the process is
    /// killed. That is exactly what happened the first time this was written.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment

        // Here rather than in `App.init`, where there is no `NSApp` yet to put
        // either of them on. A chosen appearance that only takes effect once
        // the settings window has been opened looks exactly like one that was
        // never saved.
        YunTheme.shared.applyAppearance()
        InterfaceOptions.apply()

        // Photographing the real window has to happen here for the same reason:
        // there is no window until the scene has been through the run loop.
        if let directory = environment["YUNAUDIO_SCREENSHOT"] {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title == "YunAudio" {
                window.makeKeyAndOrderFront(nil)
            }
            Task { @MainActor in
                await WindowCapture.write(to: directory, model: flowCheckModel)
                NSApp.terminate(nil)
            }
            return
        }

        guard environment["YUNAUDIO_FLOWCHECK"] != nil, let model = flowCheckModel
        else { return }
        Task { @MainActor in
            await UIFlowCheck.run(model: model)
        }
    }

    var flowCheckModel: RouterModel?

    /// Where a URL handed to the application ends up.
    ///
    /// Taken off the Apple Event directly rather than through SwiftUI's
    /// `onOpenURL` or the delegate's `application(_:open:)`. Both were tried
    /// and neither fires here: `onOpenURL` needs a scene on screen, and this
    /// application is a menu bar accessory that spends most of its life with no
    /// window at all — which is exactly the state a Stream Deck button presses
    /// into. The delegate method is swallowed somewhere between SwiftUI's own
    /// delegate and the adaptor, and `open` still reports success, so the
    /// symptom is a URL that resolves, launches nothing, and does nothing.
    ///
    /// The event handler is the layer underneath both and cannot be
    /// intercepted.
    var onURL: (@MainActor (URL) -> Void)?

    /// Claims the URL event.
    ///
    /// Called from the same place the menu bar item is installed rather than
    /// from `applicationWillFinishLaunching`, because that is the one hook this
    /// application can prove runs — SwiftUI owns the real delegate and forwards
    /// what it chooses to.
    func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURLEvent(
        _ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor
    ) {
        guard
            let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: string)
        else { return }
        onURL?(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { onURL?(url) }
    }
}

@main
struct YunAudioApp: App {
    @State private var model = RouterModel()
    @NSApplicationDelegateAdaptor(TerminationObserver.self) private var termination

    init() {
        // Before anything else: a second copy would put a second icon in the
        // menu bar and quietly fight the first over the same devices.
        let environment = ProcessInfo.processInfo.environment
        if environment["YUNAUDIO_RENDER"] == nil,
            environment["YUNAUDIO_FLOWCHECK"] == nil,
            environment["YUNAUDIO_SCREENSHOT"] == nil,
            environment["YUNAUDIO_ICON"] == nil,
            !MainActor.assumeIsolated({ SingleInstance.claim() })
        {
            exit(0)
        }
        // The .lproj folders ship with this module, not with the main bundle.
        YunStrings.bundle = AppResources.bundle

        // The application draws its own icon. `make-icon.sh` used to scale one
        // 180-point bitmap into all ten slots of the iconset, which meant the
        // largest was a five-fold upscale of it — soft in Finder, and mushy at
        // 16 points where the small ones live. Drawing each slot at its own
        // resolution costs nothing and needs the code that already knows where
        // the mark's ink is, which is in this binary. See `YunIconBadge`.
        if let directory = environment["YUNAUDIO_ICON"] {
            let style = YunIconBadge.style(named: environment["YUNAUDIO_ICON_STYLE"])
            let wrote = MainActor.assumeIsolated {
                YunIconBadge.writeIconset(to: directory, style: style)
            }
            exit(wrote ? 0 : 1)
        }

        // Design verification path. A menu bar popover cannot be opened without
        // accessibility permission, so the panel is rendered offscreen instead —
        // in both appearances, which is the only way to catch a colour that
        // works in one theme and vanishes in the other.
        if let directory = ProcessInfo.processInfo.environment["YUNAUDIO_RENDER"] {
            MainActor.assumeIsolated {
                PanelRenderer.write(to: directory, model: RouterModel())
            }
            // Non-zero when anything could not be written. A design check whose
            // output is missing must not look like one that passed.
            exit(MainActor.assumeIsolated { PanelRenderer.wroteEverything } ? 0 : 1)
        }
    }

    @State private var hasLaunched = false

    /// Wires the URL handler to the one model the interface is using.
    ///
    /// It has to be the same instance: a command that started routing on a
    /// second model would start a second aggregate over the top of the first.
    @MainActor
    private func installRemoteControl() {
        termination.onURL = { [model] url in
            // Logged either way. A command that arrives and is not understood
            // is indistinguishable, from outside, from one that never arrived,
            // and somebody debugging a Stream Deck button has nothing else to
            // look at.
            guard let command = RemoteCommand.parse(url) else {
                FileHandle.standardError.write(Data("yunaudio: ignored \(url)\n".utf8))
                return
            }
            let outcome = model.perform(command) ?? "no such scene"
            FileHandle.standardError.write(Data("yunaudio: \(url) — \(outcome)\n".utf8))
        }
        termination.installURLHandler()

        // One way to be asked a question, because a URL cannot carry an answer:
        // a Unix socket that `yunaudio-cli` and `yunaudio-mcp` both connect to.
        //
        // There were two. The command line had a distributed-notification
        // channel of its own, and one vocabulary over two transports was one
        // transport too many. The socket is the half that survived: a failed
        // `connect` is an immediate, unambiguous "not running", where a
        // notification cannot tell that apart from "has not answered yet" until
        // a timeout expires; a reply belongs to its request without an id
        // invented to correlate them; and the access control is the
        // filesystem's rather than "anything on the machine can watch".
        termination.controlListener = ControlServer.start(model: model)
    }

    /// Creates the menu bar presence once, on whichever scene is evaluated
    /// first. SwiftUI offers no launch hook for an app with no primary window.
    @MainActor
    private func installStatusItem() {
        guard termination.statusItem == nil else { return }
        installRemoteControl()
        termination.onTerminate = { [termination] in
            // The ring is hardware state that outlives the process. Leaving it
            // lit after quitting would look like a fault rather than a setting.
            model.lighting.stop()
            // Before the model goes: a socket still accepting connections would
            // hand requests to a torn-down router.
            termination.controlListener?.stop()
            model.shutDown()
        }
        termination.flowCheckModel = model
        // Again here, and for the reason the appearance is applied from the
        // delegate rather than from `App.init`: the model restores this while
        // there is no `NSApp` to put it on, and `NSApp?.` makes that a silent
        // no-op rather than a crash. A chosen icon that only appears once the
        // preferences window has been opened looks exactly like one that was
        // never saved.
        model.applyIconStyle()
        termination.statusItem = StatusItemController(model: model) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title == "YunAudio" {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    var body: some Scene {
        // The application proper. A routing tool wants width — sources, mixer
        // and signal path side by side — not a tall column.
        Window("YunAudio", id: "main") {
            MainWindow(model: model)
        }
        // The window drew "YunAudio" in its title bar and the header drew it
        // again eight points below, with a rule between them. Hiding the system
        // title bar leaves the traffic lights floating over the header, which is
        // what the header is inset for.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 620)
        .windowResizability(.contentMinSize)

        .onChange(of: hasLaunched, initial: true) { _, _ in installStatusItem() }

        Settings {
            PreferencesWindow(model: model)
                .onAppear { installStatusItem() }
        }

    }
}
