import CoreAudio
import Foundation
import Observation
import YunAudioEngine
import YunAudioHAL
import YunDesign

/// How the source's channels map onto a stereo destination.
public enum SourceChannelMode: String, CaseIterable, Identifiable, Sendable {
    /// One channel sent to both destination channels.
    case mono
    /// Channels 1 and 2 sent straight through.
    case stereo

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .mono: loc("Mono")
        case .stereo: loc("Stereo")
        }
    }
}

@Observable
@MainActor
final class RouterModel {
    // MARK: Devices

    private(set) var inputDevices: [AudioDevice] = []
    private(set) var outputDevices: [AudioDevice] = []

    var selectedSourceUID: String? {
        didSet {
            guard oldValue != selectedSourceUID else { return }
            applyChannelDefaults()
            persist()
            restartIfRunning()
        }
    }
    var selectedDestinationUID: String? {
        didSet {
            guard oldValue != selectedDestinationUID else { return }
            persist()
            restartIfRunning()
        }
    }
    var channelMode: SourceChannelMode = .mono {
        didSet {
            guard oldValue != channelMode else { return }
            persist()
            // Only the channel map moves, so this can be swapped in silently.
            if !reconfigureIfPossible() { restartIfRunning() }
        }
    }
    /// Which source channel a mono route takes, zero-based.
    var monoChannel: Int = 0 {
        didSet {
            guard oldValue != monoChannel else { return }
            persist()
            if !reconfigureIfPossible() { restartIfRunning() }
        }
    }

    /// Registered with the system, not mirrored locally — the login item state
    /// belongs to `SMAppService`.
    var launchesAtLogin: Bool {
        get { LoginItem.isEnabled }
        set { loginItemError = LoginItem.setEnabled(newValue) }
    }
    private(set) var loginItemError: String?

    var autoStart: Bool = false {
        didSet { if oldValue != autoStart { persist() } }
    }

    /// Apple's voice isolation model. Off by default: it costs 56 ms of latency
    /// and by definition ends bit-exactness, so it is a deliberate trade rather
    /// than something to enable quietly on the user's behalf.
    var voiceIsolationEnabled = false {
        didSet {
            guard oldValue != voiceIsolationEnabled else { return }
            if voiceIsolationEnabled {
                enabledEffects.insert(.voiceIsolation)
            } else {
                enabledEffects.remove(.voiceIsolation)
            }
        }
    }
    var voiceIsolationMix: Float = 100 {
        didSet { if oldValue != voiceIsolationMix { persist(); restartIfRunning() } }
    }

    /// Sample rate a preset asked for. Applied when both devices support it.
    var preferredSampleRate: Double = 48000 {
        didSet { if oldValue != preferredSampleRate { persist(); restartIfRunning() } }
    }
    /// Name of the preset last applied, cleared when a setting is changed by
    /// hand so the UI never claims a preset is active when it is not.
    var activePresetName: String?

    // MARK: Application sources

    /// Applications that can be captured. Refreshed on demand — the list churns
    /// as apps come and go, and polling it continuously would be wasteful for
    /// something only looked at when a menu is opened.
    private(set) var availableApps: [AudioProcess] = []

    /// Bundle identifiers of the applications being captured alongside the
    /// microphone. Stored by bundle id rather than pid so the choice survives
    /// the app being quit and relaunched.
    var capturedAppBundleIDs: Set<String> = [] {
        didSet { if oldValue != capturedAppBundleIDs { persist(); restartIfRunning() } }
    }

    var tapMuteBehavior: TapMuteBehavior = .unmuted {
        didSet { if oldValue != tapMuteBehavior { persist(); restartIfRunning() } }
    }

    /// Populates the model with representative state for the offscreen design
    /// captures. Not called by the running app.
    func prepareForRendering() {
        refreshApps()
        guard let source = selectedSource else { return }
        let destinationUID = selectedDestination?.uid ?? "preview-destination"
        activeRoutes = (0..<2).map { channel in
            Route(
                source: ChannelRef(deviceUID: source.uid, channel: 0),
                destination: ChannelRef(deviceUID: destinationUID, channel: channel))
        }
        routeGains = [1.0, 0.7]
        routeMutes = [false, true]
        levels = [0.28, 0.0]
    }

    // MARK: Driver

    private(set) var driverMessage: String?
    private(set) var isInstallingDriver = false

    /// True when the driver can be installed from here, rather than only
    /// described. False means the app was launched without the driver beside
    /// it — running from a build directory, usually.
    var canInstallDriver: Bool { DriverInstaller.bundledDriverURL != nil }

    func installDriver() {
        isInstallingDriver = true
        driverMessage = nil
        let outcome = DriverInstaller.install()
        isInstallingDriver = false
        switch outcome {
        case .installed:
            driverMessage = nil
            // coreaudiod needs a moment to publish the new device.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.refreshDevices()
                self.selectedDestinationUID =
                    self.outputDevices
                    .first { $0.uid == ClockAnchorPublisher.driverDeviceUID }?.uid
                    ?? self.selectedDestinationUID
            }
        case .cancelled:
            driverMessage = nil
        case let .failed(reason):
            driverMessage = reason
        case .removed:
            break
        }
    }

    func refreshApps() {
        availableApps = (try? AudioProcesses.all()) ?? []
    }

    /// Resolves the saved bundle identifiers to the processes running right now.
    /// An application splits its audio across helper processes — Discord uses
    /// four — so every process sharing the prefix is captured, not just the one
    /// the user picked.
    private var tappableProcessIDs: [AudioObjectID] {
        guard !capturedAppBundleIDs.isEmpty else { return [] }
        return
            availableApps
            .filter { process in
                guard let bundle = process.bundleID else { return false }
                return capturedAppBundleIDs.contains { bundle.hasPrefix($0) }
            }
            .map(\.id)
    }

    /// Per-route peak levels, aligned with `routes`.
    var routeLevels: [Float] { levels }

    // MARK: Per-route control

    private(set) var routeGains: [Float] = []
    private(set) var routeMutes: [Bool] = []

    func setGain(_ gain: Float, forRouteAt index: Int) {
        guard index < routeGains.count else { return }
        routeGains[index] = gain
        engine.setGain(gain, forRouteAt: index)
        persist()
    }

    /// A route's fader position in decibels.
    func faderDecibels(forRouteAt index: Int) -> Float {
        guard index < routeGains.count else { return 0 }
        let gain = routeGains[index]
        return gain <= 0 ? -40 : 20 * log10(gain)
    }

    func setFaderDecibels(_ decibels: Float, forRouteAt index: Int) {
        setGain(yunGainMultiplier(decibels: decibels), forRouteAt: index)
    }

    /// Human label for a route.
    ///
    /// The source name is dropped when every route shares it, which is the
    /// common case: repeating "Razer Seiren V3 Pro" on each row only pushes the
    /// channels out of view behind an ellipsis.
    func label(for route: Route) -> String {
        let channels = "ch\(route.source.channel + 1) → ch\(route.destination.channel + 1)"
        let sources = Set(activeRoutes.map(\.source.deviceUID))
        guard sources.count > 1 else { return channels }
        return "\(sourceName(for: route))  \(channels)"
    }

    private func sourceName(for route: Route) -> String {
        let source: String
        if let device = inputDevices.first(where: { $0.uid == route.source.deviceUID }) {
            source = device.name
        } else if route.source.deviceUID.contains("-") {
            // Tap UIDs are UUIDs; name the applications they carry instead.
            source =
                capturedAppBundleIDs.isEmpty
                ? "Application audio"
                : availableApps
                    .first { process in
                        guard let bundle = process.bundleID else { return false }
                        return capturedAppBundleIDs.contains { bundle.hasPrefix($0) }
                    }?.name ?? "Application audio"
        } else {
            source = route.source.deviceUID
        }
        return source
    }

    func setMuted(_ muted: Bool, forRouteAt index: Int) {
        guard index < routeMutes.count else { return }
        routeMutes[index] = muted
        engine.setMuted(muted, forRouteAt: index)
        persist()
    }

    // MARK: Processing chain

    /// Effects switched on, in whatever order they were toggled. The engine
    /// sorts them into signal order — a limiter ahead of a compressor is a
    /// configuration mistake, not a preference.
    var enabledEffects: Set<EffectKind> = [] {
        didSet { if oldValue != enabledEffects { persist(); restartIfRunning() } }
    }

    func setEffect(_ kind: EffectKind, enabled: Bool) {
        if enabled { enabledEffects.insert(kind) } else { enabledEffects.remove(kind) }
        // The old single toggle stays in step so saved settings and the menu bar
        // panel keep working.
        voiceIsolationEnabled = enabledEffects.contains(.voiceIsolation)
    }

    /// Latency every enabled stage adds together, in milliseconds.
    var addedLatencyMilliseconds: Double {
        let rate = pathQuality?.sampleRate ?? 48000
        guard rate > 0 else { return 0 }
        return Double(engine.effectLatencyFrames) / rate * 1000
    }

    /// Latency the isolation stage adds, in milliseconds.
    var voiceIsolationLatencyMilliseconds: Double {
        let rate = pathQuality?.sampleRate ?? 48000
        guard rate > 0 else { return 0 }
        return Double(engine.voiceIsolationLatencyFrames) / rate * 1000
    }

    // MARK: Runtime

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var levels: [Float] = []
    private(set) var pathQuality: PathQuality?
    private(set) var isClockLocked = false
    private(set) var measuredRateRatio: Double = 1
    private(set) var clockLockFailed = false
    /// The routes actually running, including any built from application taps.
    private(set) var activeRoutes: [Route] = []

    /// Global mute, applied through the lock-free command queue so it takes
    /// effect on the next IO cycle without rebuilding anything.
    private(set) var isMuted = false
    private(set) var hotkeyFailures: [String] = []

    private let engine = RoutingEngine()
    private let hotkeys = HotkeyManager()
    /// Engine start and stop go here rather than running inline.
    ///
    /// Measured: bringing a route up takes about 108 ms and tearing it down
    /// about 17 ms, nearly all of it inside blocking CoreAudio calls. Run on the
    /// main actor that is a visible stall every time someone hits the button.
    private let engineQueue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.engine", qos: .userInitiated)
    /// Set while a start or stop is in flight so the button cannot be pressed
    /// twice into a half-built route.
    private(set) var isBusy = false
    private var levelTimer: Timer?
    private var deviceWatcher: DeviceChangeWatcher?

    var selectedSource: AudioDevice? {
        inputDevices.first { $0.uid == selectedSourceUID }
    }
    var selectedDestination: AudioDevice? {
        outputDevices.first { $0.uid == selectedDestinationUID }
    }

    /// True when the YunAudio driver is installed, which is what the onboarding
    /// flow keys off.
    var isDriverInstalled: Bool {
        outputDevices.contains { $0.uid == ClockAnchorPublisher.driverDeviceUID }
    }

    private var isRestoring = false

    init() {
        refreshDevices()
        restore()

        engine.onClockLockFailure = { [weak self] in
            Task { @MainActor in self?.clockLockFailed = true }
        }

        // Hardware comes and goes; the route has to follow it rather than
        // silently pointing at a device that is no longer there.
        deviceWatcher = DeviceChangeWatcher { [weak self] in
            Task { @MainActor in self?.handleDeviceChange() }
        }

        // The tripwire is on from launch so the diagnostics page reports a real
        // number rather than zero-because-nobody-was-counting.
        RoutingEngine.enableAllocationTripwire()
        installHotkeys()

        if autoStart, selectedSource != nil, selectedDestination != nil {
            start()
        }
    }

    // MARK: Hotkeys

    private func installHotkeys() {
        for action in HotkeyManager.Action.allCases {
            let handler: @Sendable () -> Void
            switch action {
            case .toggleRouting:
                handler = { [weak self] in
                    MainActor.assumeIsolated { self?.toggle() }
                }
            case .toggleMute:
                handler = { [weak self] in
                    MainActor.assumeIsolated { self?.toggleMute() }
                }
            }
            if !hotkeys.register(action, shortcut: action.defaultShortcut, handler: handler) {
                // Another application owns the combination. Say so — a shortcut
                // that quietly does nothing is worse than none at all.
                hotkeyFailures.append(
                    "\(action.defaultShortcut.displayName) could not be registered — "
                        + "another application already owns it")
            }
        }
    }

    var hotkeyDescriptions: [(title: String, shortcut: String)] {
        HotkeyManager.Action.allCases.map {
            ($0.title, $0.defaultShortcut.displayName)
        }
    }

    func toggleMute() {
        isMuted.toggle()
        for index in routes.indices {
            engine.setMuted(isMuted, forRouteAt: index)
        }
    }

    // MARK: Persistence

    /// Restores the saved route, resolving device UIDs against what is actually
    /// present now. A device that has gone missing leaves its slot empty rather
    /// than silently falling back to some other input.
    private func restore() {
        isRestoring = true
        defer { isRestoring = false }

        let saved = PreferencesStore.load()
        autoStart = saved.autoStart
        capturedAppBundleIDs = Set(saved.capturedAppBundleIDs)
        enabledEffects = Set(saved.enabledEffects.compactMap(EffectKind.init(rawValue:)))
        voiceIsolationEnabled = enabledEffects.contains(.voiceIsolation)
        voiceIsolationMix = saved.voiceIsolationMix
        preferredSampleRate = saved.preferredSampleRate
        monoChannel = saved.monoChannel
        channelMode = SourceChannelMode(rawValue: saved.channelMode) ?? .mono

        if let uid = saved.sourceDeviceUID, inputDevices.contains(where: { $0.uid == uid }) {
            selectedSourceUID = uid
        }
        if let uid = saved.destinationDeviceUID,
            outputDevices.contains(where: { $0.uid == uid })
        {
            selectedDestinationUID = uid
        }
        selectDefaults()
    }

    private func persist() {
        guard !isRestoring else { return }
        PreferencesStore.save(
            Preferences(
                sourceDeviceUID: selectedSourceUID,
                destinationDeviceUID: selectedDestinationUID,
                channelMode: channelMode.rawValue,
                monoChannel: monoChannel,
                bufferFrames: 128,
                autoStart: autoStart,
                voiceIsolationEnabled: voiceIsolationEnabled,
                voiceIsolationMix: voiceIsolationMix,
                preferredSampleRate: preferredSampleRate,
                capturedAppBundleIDs: Array(capturedAppBundleIDs),
                enabledEffects: enabledEffects.map(\.rawValue)))
    }

    // MARK: Devices

    func refreshDevices() {
        let all = (try? AudioDevices.all()) ?? []
        inputDevices = all.filter(\.hasInput)
        outputDevices = all.filter(\.hasOutput)
    }

    private func selectDefaults() {
        if selectedSourceUID == nil {
            // Prefer the system input, but never the virtual endpoint we are
            // about to write into — that would be a feedback loop.
            let systemInput = try? AudioDevices.defaultInput()
            selectedSourceUID =
                systemInput.map(\.uid)
                ?? inputDevices.first { $0.transport == .usb }?.uid
                ?? inputDevices.first?.uid
        }
        if selectedDestinationUID == nil {
            selectedDestinationUID =
                outputDevices
                .first { $0.uid == ClockAnchorPublisher.driverDeviceUID }?.uid
        }
        applyChannelDefaults()
    }

    /// Picks a sensible channel mode for the selected source.
    ///
    /// An odd channel count is a strong hint that the device is not presenting
    /// a stereo pair — the Seiren V3 Pro reports three input channels where only
    /// the first carries the capsule, and routing 1→1, 2→2 would send silence
    /// down one side of every call.
    private func applyChannelDefaults() {
        // Restoring must not overwrite what the user chose last time.
        guard !isRestoring, let source = selectedSource else { return }
        channelMode =
            source.inputChannels % 2 == 0 && source.inputChannels >= 2
            ? .stereo : .mono
        monoChannel = 0
    }

    private func handleDeviceChange() {
        refreshDevices()
        let sourceGone =
            selectedSourceUID.map { uid in
                !inputDevices.contains { $0.uid == uid }
            } ?? false
        let destinationGone =
            selectedDestinationUID.map { uid in
                !outputDevices.contains { $0.uid == uid }
            } ?? false

        if isRunning, sourceGone || destinationGone {
            stop()
            lastError = "a device in the route was unplugged"
        } else if !isRunning, lastError != nil, !sourceGone, !destinationGone {
            // Everything is back; pick up where we left off.
            lastError = nil
            start()
        }
    }

    // MARK: Routing

    var routes: [Route] {
        guard let source = selectedSource, let destination = selectedDestination else {
            return []
        }
        let destinationChannels = min(2, destination.outputChannels)
        guard destinationChannels > 0, source.inputChannels > 0 else { return [] }

        switch channelMode {
        case .mono:
            let channel = min(monoChannel, source.inputChannels - 1)
            return (0..<destinationChannels).map { destinationChannel in
                Route(
                    source: ChannelRef(deviceUID: source.uid, channel: channel),
                    destination: ChannelRef(
                        deviceUID: destination.uid, channel: destinationChannel))
            }
        case .stereo:
            let pairs = min(destinationChannels, source.inputChannels)
            return (0..<pairs).map { channel in
                Route(
                    source: ChannelRef(deviceUID: source.uid, channel: channel),
                    destination: ChannelRef(deviceUID: destination.uid, channel: channel))
            }
        }
    }

    func start() {
        guard !isBusy else { return }
        guard let source = selectedSourceUID, let destination = selectedDestinationUID else {
            lastError = "pick an input and an output first"
            return
        }
        guard source != destination else {
            lastError = "the input and output cannot be the same device"
            return
        }
        refreshApps()
        var routeList = routes
        var taps: [ProcessTap] = []

        // Application audio joins as extra source channels on the same
        // aggregate, so a tapped app is addressable exactly like a microphone.
        let processIDs = tappableProcessIDs
        if !processIDs.isEmpty {
            if let tap = try? ProcessTap(
                processIDs: processIDs, muteBehavior: tapMuteBehavior)
            {
                taps.append(tap)
                let destinationChannels = min(2, selectedDestination?.outputChannels ?? 0)
                let tapChannels = Int(tap.format?.mChannelsPerFrame ?? 2)
                for channel in 0..<min(destinationChannels, tapChannels) {
                    routeList.append(
                        Route(
                            source: ChannelRef(deviceUID: tap.uid, channel: channel),
                            destination: ChannelRef(
                                deviceUID: destination, channel: channel)))
                }
            } else {
                lastError = "could not capture the selected applications"
            }
        }

        guard !routeList.isEmpty else {
            lastError = "no usable channels between those devices"
            return
        }

        clockLockFailed = false
        isBusy = true

        let engine = engine
        let effects = Array(enabledEffects)
        let isolation =
            enabledEffects.contains(.voiceIsolation)
            ? VoiceIsolationSettings(mixPercent: voiceIsolationMix) : nil
        let rate = preferredSampleRate
        let handle = TapHandle(taps: taps)
        // Copied so the queue closure and the main actor are not reading and
        // writing the same array. Route is a value type, so this is a real copy.
        let routes = routeList

        engineQueue.async {
            engine.allowClockLockRetry()
            var failure: String?
            do {
                try engine.start(
                    sourceDeviceUID: source,
                    destinationDeviceUID: destination,
                    routes: routes,
                    taps: handle.taps,
                    effects: effects,
                    preferredSampleRate: rate,
                    voiceIsolation: isolation)
            } catch {
                failure = String(describing: error)
            }
            Task { @MainActor [failure] in
                self.isBusy = false
                if let failure {
                    self.isRunning = false
                    self.lastError = failure
                    return
                }
                self.isRunning = true
                self.lastError = nil
                self.activeRoutes = routes
                self.routeGains = routes.map(\.gain)
                self.routeMutes = routes.map(\.isMuted)
                self.startPolling()
            }
        }
    }

    func stop() {
        guard !isBusy else { return }
        isBusy = true
        let engine = engine
        engineQueue.async {
            engine.stop()
            Task { @MainActor in
                self.isBusy = false
                self.finishStop()
            }
        }
    }

    private func finishStop() {
        isRunning = false
        stopPolling()
        levels = []
        activeRoutes = []
        routeGains = []
        routeMutes = []
        pathQuality = nil
        isClockLocked = false
    }

    func toggle() { isRunning ? stop() : start() }

    /// Tears everything down synchronously.
    ///
    /// Called while the application is quitting, so it cannot hop to a queue and
    /// hope to be finished — the process may be gone before the closure runs.
    /// The 17 ms this blocks for is the price of not leaving someone's hardware
    /// reconfigured.
    func shutDown() {
        hotkeys.tearDown()
        stopPolling()
        engine.stop()
        isRunning = false
    }

    /// Carries the taps across the queue hop. `ProcessTap` is a class the audio
    /// system owns, and the queue closure has to be `Sendable`.
    private struct TapHandle: @unchecked Sendable {
        let taps: [ProcessTap]
    }

    /// Applies a configuration change to a running route.
    ///
    /// Changes that only move channels around are swapped in place, which is
    /// silent. Anything that changes the devices, the taps or the processing
    /// chain still has to rebuild the aggregate, and that costs about 108 ms of
    /// audio — so the two cases are kept apart rather than treated alike.
    private func restartIfRunning() {
        guard isRunning else { return }
        stop()
        start()
    }

    /// Reroutes without stopping. Returns false when the change needs a rebuild.
    @discardableResult
    private func reconfigureIfPossible() -> Bool {
        guard isRunning, capturedAppBundleIDs.isEmpty else { return false }
        let updated = routes
        guard !updated.isEmpty, engine.updateRoutes(updated) else { return false }
        activeRoutes = engine.currentRoutes
        routeGains = activeRoutes.map(\.gain)
        routeMutes = activeRoutes.map(\.isMuted)
        return true
    }

    // MARK: Polling

    private func startPolling() {
        stopPolling()
        // Twenty hertz: fast enough that a meter reads as live, slow enough that
        // an idle menu bar app is not waking the CPU sixty times a second.
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func poll() {
        guard isRunning else { return }
        levels = engine.routePeaks
        pathQuality = engine.pathQuality
        isClockLocked = engine.isClockLocked
        measuredRateRatio = engine.measuredRateRatio
    }

    /// Sample rates both selected devices can present.
    var availableSampleRates: [Double] {
        guard let source = selectedSource, let destination = selectedDestination else {
            return [44100, 48000, 96000]
        }
        let shared = Set(source.availableSampleRates)
            .intersection(destination.availableSampleRates)
        return shared.sorted()
    }

    /// Allocations recorded on the IO thread. Surfaced in diagnostics because
    /// the number is only meaningful if someone looks at it.
    var allocationViolations: UInt64 { RoutingEngine.allocationViolations }

    /// Loudest route, for the menu bar icon and the signal path graphic.
    var peakLevel: Float { levels.max() ?? 0 }
}
