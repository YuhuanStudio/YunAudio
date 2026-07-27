import Foundation
import Observation
import YunAudioEngine
import YunAudioHAL

/// How the source's channels map onto a stereo destination.
public enum SourceChannelMode: String, CaseIterable, Identifiable, Sendable {
    /// One channel sent to both destination channels.
    case mono
    /// Channels 1 and 2 sent straight through.
    case stereo

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .mono: "Mono"
        case .stereo: "Stereo"
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
        didSet { if oldValue != channelMode { persist(); restartIfRunning() } }
    }
    /// Which source channel a mono route takes, zero-based.
    var monoChannel: Int = 0 {
        didSet { if oldValue != monoChannel { persist(); restartIfRunning() } }
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
        didSet { if oldValue != voiceIsolationEnabled { persist(); restartIfRunning() } }
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

    /// Global mute, applied through the lock-free command queue so it takes
    /// effect on the next IO cycle without rebuilding anything.
    private(set) var isMuted = false
    private(set) var hotkeyFailures: [String] = []

    private let engine = RoutingEngine()
    private let hotkeys = HotkeyManager()
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
            let handler: () -> Void
            switch action {
            case .toggleRouting: handler = { [weak self] in self?.toggle() }
            case .toggleMute: handler = { [weak self] in self?.toggleMute() }
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
        voiceIsolationEnabled = saved.voiceIsolationEnabled
        voiceIsolationMix = saved.voiceIsolationMix
        preferredSampleRate = saved.preferredSampleRate
        monoChannel = saved.monoChannel
        channelMode = SourceChannelMode(rawValue: saved.channelMode) ?? .mono

        if let uid = saved.sourceDeviceUID, inputDevices.contains(where: { $0.uid == uid }) {
            selectedSourceUID = uid
        }
        if let uid = saved.destinationDeviceUID,
           outputDevices.contains(where: { $0.uid == uid }) {
            selectedDestinationUID = uid
        }
        selectDefaults()
    }

    private func persist() {
        guard !isRestoring else { return }
        PreferencesStore.save(Preferences(
            sourceDeviceUID: selectedSourceUID,
            destinationDeviceUID: selectedDestinationUID,
            channelMode: channelMode.rawValue,
            monoChannel: monoChannel,
            bufferFrames: 128,
            autoStart: autoStart,
            voiceIsolationEnabled: voiceIsolationEnabled,
            voiceIsolationMix: voiceIsolationMix,
            preferredSampleRate: preferredSampleRate))
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
            selectedSourceUID = systemInput.map(\.uid)
                ?? inputDevices.first { $0.transport == .usb }?.uid
                ?? inputDevices.first?.uid
        }
        if selectedDestinationUID == nil {
            selectedDestinationUID = outputDevices
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
        channelMode = source.inputChannels % 2 == 0 && source.inputChannels >= 2
            ? .stereo : .mono
        monoChannel = 0
    }

    private func handleDeviceChange() {
        refreshDevices()
        let sourceGone = selectedSourceUID.map { uid in
            !inputDevices.contains { $0.uid == uid }
        } ?? false
        let destinationGone = selectedDestinationUID.map { uid in
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
        guard let source = selectedSource, let destination = selectedDestination else { return [] }
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
        guard let source = selectedSourceUID, let destination = selectedDestinationUID else {
            lastError = "pick an input and an output first"
            return
        }
        guard source != destination else {
            lastError = "the input and output cannot be the same device"
            return
        }
        let routeList = routes
        guard !routeList.isEmpty else {
            lastError = "no usable channels between those devices"
            return
        }

        do {
            clockLockFailed = false
            engine.allowClockLockRetry()
            try engine.start(
                sourceDeviceUID: source,
                destinationDeviceUID: destination,
                routes: routeList,
                preferredSampleRate: preferredSampleRate,
                voiceIsolation: voiceIsolationEnabled
                    ? VoiceIsolationSettings(mixPercent: voiceIsolationMix)
                    : nil)
            isRunning = true
            lastError = nil
            startPolling()
        } catch {
            isRunning = false
            lastError = String(describing: error)
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
        stopPolling()
        levels = []
        pathQuality = nil
        isClockLocked = false
    }

    func toggle() { isRunning ? stop() : start() }

    private func restartIfRunning() {
        guard isRunning else { return }
        stop()
        start()
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
