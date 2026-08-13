import Foundation
import SwiftUI
import YunAudioControl
import YunDesign

/// Routes a Dock reopen without involving AppKit in the test.
///
/// Constructing `NSApplication.shared` from the SwiftPM test process asks
/// LaunchServices to start the registered app bundle. That produced an orphaned
/// normal YunAudio process at 30–40% CPU while a supposedly pure unit test was
/// running. Keep the decision and callback in a value that needs no application
/// object; the delegate is only its adapter.
enum MainWindowReopenPolicy {
    /// True when AppKit still needs to choose a window.
    nonisolated static func appKitShouldChooseWindow(hasPresenter: Bool) -> Bool {
        !hasPresenter
    }
}

/// Idempotent policy for AppKit's deferred termination handshake.
struct ApplicationTerminationGate {
    enum Decision: Equatable {
        case terminateNow
        case beginLater
        case awaitExistingReply
    }

    private(set) var isPending = false

    mutating func begin(hasTeardown: Bool) -> Decision {
        guard hasTeardown else { return .terminateNow }
        guard !isPending else { return .awaitExistingReply }
        isPending = true
        return .beginLater
    }

    mutating func complete() {
        precondition(isPending)
        isPending = false
    }
}

/// Joins audio ownership and the control socket without making either owner wait for the other.
@MainActor
final class ApplicationControlTerminationJoin {
    typealias Completion =
        @MainActor @Sendable (ApplicationAudioTeardownResult, Bool) -> Void

    private var audio: ApplicationAudioTeardownResult?
    private var controlAcknowledged: Bool?
    private var didPublish = false
    private let completion: Completion

    init(completion: @escaping Completion) {
        self.completion = completion
    }

    func receive(audio result: ApplicationAudioTeardownResult) {
        precondition(audio == nil)
        audio = result
        publishIfComplete()
    }

    func receiveControl(acknowledged: Bool) {
        precondition(controlAcknowledged == nil)
        controlAcknowledged = acknowledged
        publishIfComplete()
    }

    private func publishIfComplete() {
        guard !didPublish, let audio, let controlAcknowledged else { return }
        didPublish = true
        completion(audio, controlAcknowledged)
    }
}

/// Watches for the application quitting.
///
/// Routing changes the sample rate of real hardware, and that change outlives
/// the process. `deinit` is not enough — a SwiftUI app that is quit from the
/// menu tears down without necessarily releasing the model first, which is
/// exactly how someone's microphone ends up left at 96 kHz.
@MainActor
final class TerminationObserver: NSObject, NSApplicationDelegate {
    /// The adaptor instance, without assuming it is `NSApp.delegate`.
    ///
    /// SwiftUI installs its own forwarding delegate around
    /// `@NSApplicationDelegateAdaptor`; verification must therefore reach the
    /// actual observer through this weak reference.
    private(set) static weak var current: TerminationObserver?

    /// Starts teardown and calls back only after every audio owner has drained.
    var onTerminate: (@MainActor (@escaping @MainActor (Bool) -> Void) -> Void)?
    private var terminationGate = ApplicationTerminationGate()
    /// The Dock represents the application, so reopening it means the main
    /// router — never whichever auxiliary window happened to close last.
    var onReopenMainWindow: (@MainActor () -> Void)?
    /// Owned here because the status item has to outlive the scene body that
    /// created it, and a SwiftUI scene is not a place to keep a reference.
    var statusItem: StatusItemController?
    /// The control socket, for the same reason. Held so that quitting can take
    /// the socket file away — a stale one left on disk is what the next launch
    /// has to reason about.
    var controlLifecycle: ControlListenerLifecycleOwner?

    override init() {
        super.init()
        Self.current = self
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        switch terminationGate.begin(hasTeardown: onTerminate != nil) {
        case .terminateNow:
            return .terminateNow
        case .awaitExistingReply:
            return .terminateLater
        case .beginLater:
            onTerminate? { shouldTerminate in
                self.terminationGate.complete()
                sender.reply(toApplicationShouldTerminate: shouldTerminate)
            }
            return .terminateLater
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        let hasPresenter = onReopenMainWindow != nil
        onReopenMainWindow?()
        // The retained action has handled presentation. Returning true would
        // let AppKit additionally choose its last window, which is how clicking
        // YunAudio in the Dock brought Settings forward instead of the router.
        return MainWindowReopenPolicy.appKitShouldChooseWindow(
            hasPresenter: hasPresenter)
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

        // This path exists to put symbols behind the application's UI cost,
        // without mixing in a route, HAL inventory or MIDI. The benchmark
        // launcher also supplies the ordinary no-audio screenshot guard, so it
        // cannot accidentally become a normal launch with restored hardware.
        if environment["YUNAUDIO_UI_BENCHMARK"] != nil {
            guard
                environment["YUNAUDIO_SCREENSHOT_NO_AUDIO"] != nil,
                let model = flowCheckModel
            else {
                exit(1)
            }
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                let passed = await UIResourceBenchmark.run(model: model)
                if passed {
                    NSApp.terminate(nil)
                } else {
                    exit(1)
                }
            }
            return
        }

        if AppStartup.startsLiveSystemServices(environment: environment) {
            flowCheckModel?.beginMIDI()
            flowCheckModel?.beginInitialDeviceDiscovery()
        }

        if environment["YUNAUDIO_SETTINGS_CHECK"] != nil {
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                let passed = await SettingsEntryCheck.run()
                if passed {
                    NSApp.terminate(nil)
                } else {
                    exit(1)
                }
            }
            return
        }

        // Photographing the real window has to happen here for the same reason:
        // there is no window until the scene has been through the run loop.
        if let directory = environment["YUNAUDIO_SCREENSHOT"] {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title == "YunAudio" {
                window.makeKeyAndOrderFront(nil)
            }
            Task { @MainActor in
                let passed = await WindowCapture.write(to: directory, model: flowCheckModel)
                if passed,
                    Self.markCaptureComplete(environment["YUNAUDIO_CAPTURE_COMPLETION"])
                {
                    NSApp.terminate(nil)
                } else {
                    exit(1)
                }
            }
            return
        }

        guard environment["YUNAUDIO_FLOWCHECK"] != nil, let model = flowCheckModel
        else { return }
        Task { @MainActor in
            await UIFlowCheck.run(model: model)
        }
    }

    /// Marks the boundary between drawing and application teardown.
    ///
    /// A complete set of images used to be accepted even when the process then
    /// wedged while releasing CoreAudio. The gate gives termination five seconds
    /// from this marker, so a shutdown hang is evidence rather than a process it
    /// silently kills and calls successful.
    private static func markCaptureComplete(_ path: String?) -> Bool {
        guard let path else { return true }
        do {
            try Data("capture complete\n".utf8).write(
                to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            NonBlockingDiagnostic.write(
                "could not write capture completion marker: \(error)\n")
            return false
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

/// Carries the Window scene's opener into the AppKit-owned menu bar panel.
///
/// Reading `openWindow` on the `App` itself returns the default action rather
/// than one belonging to this scene. This zero-sized view is mounted inside the
/// Window content and therefore receives the action belonging to that scene.
private struct MainWindowOpenerInjector: View {
    @Environment(\.openWindow) private var openWindow
    let inject: @MainActor (OpenWindowAction) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: false, initial: true) { _, _ in
                inject(openWindow)
            }
    }
}

@main
struct YunAudioApp: App {
    @State private var model: RouterModel
    @NSApplicationDelegateAdaptor(TerminationObserver.self) private var termination

    init() {
        let environment = ProcessInfo.processInfo.environment
        onTheMainThread {
            UIResourceBenchmark.beginColdLaunchProbe(environment: environment)
        }
        let modelPolicy = AppStartup.modelPolicy(environment: environment)
        // The .lproj folders ship with this module, not with the main bundle.
        YunStrings.bundle = AppResources.bundle

        // This decision has to precede model construction. A default value on
        // the `@State` above runs before `App.init()`, which let a second copy
        // enumerate every device, open MIDI and even honour auto-start before
        // the single-instance claim told it to exit.
        let startup = onTheMainThread {
            AppStartup.prepare(
                environment: environment,
                claimSingleInstance: { SingleInstance.claim() },
                makeModel: { RouterModel(startupPolicy: modelPolicy) })
        }

        switch startup {
        case .duplicate:
            exit(0)
        case .bundleCheck:
            exit(BundleSmokeCheck.run() ? 0 : 1)
        case .normal(let model):
            _model = State(initialValue: model)
        case .icon:
            // The application draws its own icon. `make-icon.sh` used to scale one
            // 180-point bitmap into all ten slots of the iconset, which meant the
            // largest was a five-fold upscale of it — soft in Finder, and mushy at
            // 16 points where the small ones live. Drawing each slot at its own
            // resolution costs nothing and needs the code that already knows where
            // the mark's ink is, which is in this binary. See `YunIconBadge`.
            guard let directory = environment["YUNAUDIO_ICON"] else { exit(1) }
            let style = YunIconBadge.style(named: environment["YUNAUDIO_ICON_STYLE"])
            let wrote = onTheMainThread {
                YunIconBadge.writeIconset(to: directory, style: style)
            }
            exit(wrote ? 0 : 1)
        case .render(let model):
            // Design verification path. A menu bar popover cannot be opened without
            // accessibility permission, so the panel is rendered offscreen instead —
            // in both appearances, which is the only way to catch a colour that
            // works in one theme and vanishes in the other.
            guard let directory = environment["YUNAUDIO_RENDER"] else { exit(1) }
            onTheMainThread {
                PanelRenderer.write(to: directory, model: model)
            }
            // Non-zero when anything could not be written. A design check whose
            // output is missing must not look like one that passed.
            exit(onTheMainThread { PanelRenderer.wroteEverything } ? 0 : 1)
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
                NonBlockingDiagnostic.write("yunaudio: ignored \(url)\n")
                return
            }
            model.submitRemoteCommand(command) { outcome in
                let detail = outcome.message ?? loc("The command was refused.")
                NonBlockingDiagnostic.write("yunaudio: \(url) — \(detail)\n")
            }
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
        termination.controlLifecycle = ControlServer.start(model: model)
    }

    /// Creates the menu bar presence once, on whichever scene is evaluated
    /// first. SwiftUI offers no launch hook for an app with no primary window.
    @MainActor
    private func installStatusItem() {
        guard termination.statusItem == nil else { return }
        installRemoteControl()
        termination.onTerminate = { [termination] reply in
            let controlLifecycle = termination.controlLifecycle
            let join = ApplicationControlTerminationJoin { result, controlAcknowledged in
                if !controlAcknowledged {
                    NonBlockingDiagnostic.write(
                        "control listener did not acknowledge termination\n")
                }
                if !result.allowsProcessExit {
                    // AppKit keeps the process alive after a refused reply. Put
                    // control back too, so Stop can be retried without finding
                    // a healthy UI behind a stale absent socket.
                    if let controlLifecycle {
                        ControlServer.start(controlLifecycle, model: model) { start in
                            if case .failed(let message) = start {
                                NonBlockingDiagnostic.write(
                                    "control listener recovery: \(message)\n")
                            }
                            reply(false)
                        }
                    } else {
                        reply(false)
                    }
                    return
                }
                termination.controlLifecycle = nil
                // Stop was reversible until the route proved process exit safe.
                // Only now close this owner's admission permanently.
                controlLifecycle?.shutdown()
                model.finaliseAcceptedTermination()
                let persistence = ApplicationPersistenceFlushJoin { persistence in
                    if !result.isComplete {
                        NonBlockingDiagnostic.write(
                            "secondary owner did not acknowledge termination: \(result)\n")
                    }
                    if !persistence.isAccepted {
                        NonBlockingDiagnostic.write(
                            "persistence flush before termination: \(persistence)\n")
                    }
                    reply(true)
                }
                // Persistence is lower-priority ownership than CoreAudio: route
                // teardown gets its complete deadline first. All three sole
                // writers then share one parallel bounded window to reach
                // UserDefaults' explicit synchronisation boundary. A stuck
                // preferences daemon must not turn Quit into another spinning
                // system surface, and serial one-second waits would triple the
                // application's own exit budget.
                PreferencesStore.flush(timeout: .seconds(1)) {
                    persistence.receivePreferences($0)
                }
                QuickConfigStore.flush(timeout: .seconds(1)) {
                    persistence.receiveQuickConfigurations($0)
                }
                UserPresets.flush(timeout: .seconds(1)) {
                    persistence.receiveUserPresets($0)
                }
            }
            // `shutDown` submits every audio owner before listener revocation.
            // The socket's 250 ms join runs on its dedicated lifecycle owner,
            // so it cannot delay either Core Audio release or MainActor delivery.
            model.shutDown { join.receive(audio: $0) }
            if let controlLifecycle {
                controlLifecycle.stop { join.receiveControl(acknowledged: $0) }
            } else {
                join.receiveControl(acknowledged: true)
            }
        }
        termination.flowCheckModel = model
        // Again here, and for the reason the appearance is applied from the
        // delegate rather than from `App.init`: the model restores this while
        // there is no `NSApp` to put it on, and `NSApp?.` makes that a silent
        // no-op rather than a crash. A chosen icon that only appears once the
        // preferences window has been opened looks exactly like one that was
        // never saved.
        model.applyIconStyle()
        termination.statusItem = StatusItemController(model: model)
        // Present only after the re-entrancy guard above owns a status item.
        // Ordering a window can evaluate the scene again in the same run-loop
        // turn; presenting earlier could install a second socket and menu item.
        FirstLaunchPermissions.presentGuideIfNeeded(model: model)
    }

    /// Updates the status item with the real Window scene action.
    ///
    /// The item itself is installed independently so a scene that has not
    /// mounted yet still leaves the application controllable from the menu bar.
    @MainActor
    private func injectMainWindowOpener(_ openWindow: OpenWindowAction) {
        installStatusItem()
        let showMainWindow: @MainActor () -> Void = {
            openWindow(id: "main")
            // Scene presentation completes after the action returns. Looking in
            // the same stack frame can miss a window that opens correctly and
            // turn this back into a no-op. On the next actor turn, activation is
            // conditional on SwiftUI having produced something visible.
            Task { @MainActor in
                await Task.yield()
                guard
                    let window = NSApp.windows.first(where: {
                        $0.title == "YunAudio" && $0.isVisible
                    })
                else {
                    // Said out loud. Reopening silently doing nothing is how
                    // clicking the Dock icon came to bring Settings forward,
                    // and a guard that returns without a word is a guard that
                    // hides the reason for a year.
                    NonBlockingDiagnostic.write(
                        "reopen found no visible window titled YunAudio among "
                            .appending(
                                NSApp.windows
                                    .map { "\($0.title):\($0.isVisible)" }
                                    .joined(separator: ", ") + "\n"))
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        termination.statusItem?.setOpenMainWindow(showMainWindow)
        termination.onReopenMainWindow = showMainWindow
    }

    var body: some Scene {
        // The application proper. A routing tool wants width — sources, mixer
        // and signal path side by side — not a tall column.
        Window("YunAudio", id: "main") {
            MainWindow(model: model)
                .background(
                    MainWindowOpenerInjector { openWindow in
                        injectMainWindowOpener(openWindow)
                    })
        }
        // The window drew "YunAudio" in its title bar and the header drew it
        // again eight points below, with a rule between them. Hiding the system
        // title bar leaves the traffic lights floating over the header, which is
        // what the header is inset for.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 620)
        .windowResizability(.contentMinSize)
        .onChange(of: hasLaunched, initial: true) { _, _ in installStatusItem() }

    }
}
