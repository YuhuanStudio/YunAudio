import AppKit
import CoreAudio
import Foundation
import Observation
import YunAudioEngine
import YunAudioHAL
import YunAudioRazer
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
            recentSourceUIDs = Self.remember(selectedSourceUID, in: recentSourceUIDs)
            // Choosing a microphone by hand ends any claim on the one that was
            // unplugged. Putting somebody back on a device they have since
            // moved off would be overriding a decision rather than undoing an
            // accident.
            if !isSubstitutingDevice {
                displacedSourceUID = nil
                displacedSourceName = nil
            }
            applyChannelDefaults()
            persist()
            restartIfRunning()
        }
    }
    var selectedDestinationUID: String? {
        didSet {
            guard oldValue != selectedDestinationUID else { return }
            recentDestinationUIDs = Self.remember(
                selectedDestinationUID, in: recentDestinationUIDs)
            if !isSubstitutingDevice {
                displacedDestinationUID = nil
                displacedDestinationName = nil
            }
            persist()
            restartIfRunning()
        }
    }

    // MARK: Headphone correction

    /// Corrections found on disk, by name.
    ///
    /// Documents rather than a bundled database. Every headphone has a
    /// frequency response that is wrong in a way somebody has already measured,
    /// and AutoEq publishes the correction for thousands of them as a
    /// `ParametricEQ.txt` — the file people already download for their model.
    /// Shipping a copy of all of them would be a licensing problem, an update
    /// problem, and worse than the file for somebody's exact unit.
    private(set) var headphoneProfiles: [ParametricEQ] = []

    /// Which one is in use, by name, or nil for none.
    var headphoneProfileName: String? {
        didSet {
            guard oldValue != headphoneProfileName else { return }
            persist()
            applyHeadphoneCorrection()
        }
    }

    var headphoneProfile: ParametricEQ? {
        headphoneProfiles.first { $0.name == headphoneProfileName }
    }

    /// Ten slider positions in decibels, at the band centres in `ParametricEQ`.
    ///
    /// Kept apart from the headphone profile because they are different
    /// intentions: a correction undoes a fault somebody measured in the
    /// hardware, and this is taste. Somebody wants both at once without having
    /// to choose, and cascaded biquads compose, so they run one after the
    /// other rather than one replacing the other.
    private(set) var graphicEQ: [Float] = [Float](repeating: 0, count: 10)

    var graphicEQIsFlat: Bool { graphicEQ.allSatisfy { abs($0) < 0.05 } }

    func setGraphicBand(_ decibels: Float, at index: Int) {
        guard graphicEQ.indices.contains(index) else { return }
        let clamped = max(
            ParametricEQ.graphicRange.lowerBound,
            min(ParametricEQ.graphicRange.upperBound, decibels))
        guard abs(graphicEQ[index] - clamped) > 0.001 else { return }
        graphicEQ[index] = clamped
        persist()
        applyHeadphoneCorrection()
    }

    func resetGraphicEQ() {
        guard !graphicEQIsFlat else { return }
        graphicEQ = [Float](repeating: 0, count: 10)
        persist()
        applyHeadphoneCorrection()
    }

    /// What is actually run on the output: the correction, the tone control, or
    /// both cascaded.
    var headphoneCurve: ParametricEQ? {
        var curves: [ParametricEQ] = []
        if let profile = headphoneProfile { curves.append(profile) }
        if !graphicEQIsFlat { curves.append(ParametricEQ.graphic(graphicEQ)) }
        return ParametricEQ.combined(curves, name: loc("Output"))
    }

    /// Where corrections are read from.
    static var headphoneDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YunAudio/Headphones", isDirectory: true)
    }

    func refreshHeadphoneProfiles() {
        guard let directory = Self.headphoneDirectory,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else {
            headphoneProfiles = []
            return
        }
        headphoneProfiles =
            names
            .filter { $0.lowercased().hasSuffix(".txt") }
            .sorted()
            .compactMap { file in
                guard
                    let text = try? String(
                        contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
                else { return nil }
                // Named after the file rather than after anything inside it:
                // AutoEq's exports carry no name, and the file is called after
                // the headphone because that is how somebody downloaded it.
                return ParametricEQ.parse(
                    text, name: (file as NSString).deletingPathExtension)
            }
        // A profile that has been deleted from the folder must stop being used,
        // not silently keep running from memory.
        if let chosen = headphoneProfileName,
            !headphoneProfiles.contains(where: { $0.name == chosen })
        {
            headphoneProfileName = nil
        }
    }

    /// Which output the correction belongs on.
    ///
    /// The monitor when there is one, because that is the headphone path by
    /// definition. Otherwise the destination — somebody routing straight to
    /// their headphones with no separate monitor is still wearing them.
    var correctedOutputUID: String? { monitorDeviceUID ?? selectedDestinationUID }

    /// True when a correction is chosen but is not reaching anything.
    var headphoneCorrectionIsIdle: Bool {
        headphoneCurve != nil && (!isRunning || correctedOutputUID == nil)
    }

    func applyHeadphoneCorrection() {
        engine.setHeadphoneCorrection(headphoneCurve, forDeviceUID: correctedOutputUID)
    }

    // MARK: Output alignment

    /// Extra delay per output device, in milliseconds.
    ///
    /// Two outputs fed from one IO cycle do not arrive together — a set of
    /// speakers and an interface can be tens of milliseconds apart, which is
    /// audible as a smear rather than as an echo, and there was no way to line
    /// them up. The HAL applies the delay itself, so nothing on the realtime
    /// path changes and it costs no processing at all.
    private(set) var outputDelays: [String: Double] = [:]

    /// The same, in frames, which is what the HAL is told.
    private var outputLatencyFrames: [String: Int] {
        let rate = pathQuality?.sampleRate ?? preferredSampleRate
        return outputDelays.compactMapValues { milliseconds in
            let frames = Int((milliseconds / 1000) * rate)
            return frames > 0 ? frames : nil
        }
    }

    /// True when the system's volume keys will not move the selected output.
    ///
    /// Aggregates, multi-output devices and much HDMI publish no volume control
    /// at all, so F10–F12 do nothing and there is no indication why. This
    /// application's master fader reaches the output regardless, so the answer
    /// is to say so — which is worth more than the keys would have been.
    var volumeKeysAreDead: Bool {
        guard let destination = selectedDestination else { return false }
        return !destination.hasSettableVolume(scope: kAudioObjectPropertyScopeOutput)
    }

    /// True when two device UIDs are two faces of one piece of hardware.
    ///
    /// Compared by name rather than by UID, because the UIDs are deliberately
    /// different — that is how a headset publishes its microphone and its
    /// speakers separately — while the name is the one thing that says they are
    /// the same object in the world. A `:input`/`:output` pair on a shared
    /// prefix is the other tell, and both are cheap to check.
    func isSamePhysicalDevice(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        let stem = { (uid: String) in uid.split(separator: ":").first.map(String.init) ?? uid }
        if stem(first) == stem(second), first != stem(first) || second != stem(second) {
            return true
        }
        guard let one = deviceNames[first], let other = deviceNames[second] else {
            return false
        }
        return one == other
    }

    // MARK: The microphone's own monitoring

    /// True when the selected microphone can feed itself back in hardware.
    var hasHardwareMonitoring: Bool { selectedSource?.playThrough()?.isSettable ?? false }

    /// Where that feedback level sits, 0 to 1.
    ///
    /// Read from the device every time rather than cached: it is the device's
    /// state, not ours, and Audio MIDI Setup can move it.
    var hardwareMonitorScalar: Float {
        get { selectedSource?.playThrough()?.scalar ?? 0 }
        set {
            try? selectedSource?.setPlayThrough(scalar: max(0, min(1, newValue)))
        }
    }

    var hardwareMonitorLabel: String {
        guard let level = selectedSource?.playThrough() else { return "—" }
        guard let decibels = level.decibels, decibels.isFinite else {
            return String(format: "%.0f%%", level.scalar * 100)
        }
        return String(format: "%+.1f dB", decibels)
    }

    // MARK: Singing

    /// What a music player is playing right now, when the panel is open.
    private(set) var nowPlaying: NowPlaying.Track?
    /// Lyrics for it, when a file was found.
    private(set) var lyrics: Lyrics?
    /// Which line is being sung, and how far through it.
    private(set) var lyricLine: Int?
    private(set) var lyricProgress: Double = 0
    /// Set while somebody is looking at the lyrics, so nothing is asked of the
    /// music players when nobody is.
    var isSingingVisible = false {
        didSet {
            guard oldValue != isSingingVisible else { return }
            if isSingingVisible { refreshNowPlaying(); updateSinging() } else { clearSinging() }
        }
    }

    /// What key the backing track is in, once enough of it has been heard.
    private(set) var songKey: KeyDetector.Key?
    /// How far the song would have to move for this singer, in semitones.
    private(set) var suggestedShift: Int?
    /// Every note sung since the panel was opened, as MIDI numbers.
    ///
    /// Kept as a running sum rather than a list: what is wanted is the middle
    /// of somebody's range, and a mean over a few thousand frames is that.
    @ObservationIgnored private var sungTotal: Double = 0
    @ObservationIgnored private var sungCount: Int = 0
    /// The middle of the singer's measured range, or nil before they have sung.
    var comfortableMidi: Double? {
        // Twenty frames is about a second of actual singing, which is the least
        // that can be called a range rather than a note.
        sungCount >= 20 ? sungTotal / Double(sungCount) : nil
    }

    /// Folds the current chroma into the key estimate.
    ///
    /// Accumulated rather than judged frame by frame: a single window of a song
    /// is a chord, and a chord is in several keys at once. A few seconds of
    /// them is a key.
    @ObservationIgnored private var chromaTotal = [Double](repeating: 0, count: 12)

    private func updateSinging() {
        // The singer, from the pitch tracker that is already running.
        let hertz = analysis.pitchHertz
        if hertz > 0 {
            sungTotal += 69 + 12 * log2(Double(hertz) / 440)
            sungCount += 1
        }

        guard let chroma = analyser?.chroma(), chroma.count == 12 else { return }
        for index in 0..<12 { chromaTotal[index] += chroma[index] }
        guard let key = KeyDetector.key(from: chromaTotal) else { return }
        songKey = key
        suggestedShift = comfortableMidi.map {
            KeyDetector.suggestedShift(songKey: key, comfortableMidi: $0)
        }
    }

    /// Applies the suggested shift to the pitch stage, which is what the
    /// transpose button on a karaoke machine does.
    func applySuggestedShift() {
        guard let semitones = suggestedShift, semitones != 0 else { return }
        setEffect(.pitch, enabled: true)
        if let parameter = EffectKind.pitch.parameters.first(where: { $0.id == "shift" }) {
            setValue(KeyDetector.cents(fromSemitones: semitones), of: parameter, in: .pitch)
        }
    }

    /// The note the microphone is hearing, or nil when there is no pitch to
    /// find. The tracker has been here since it was written; this is the first
    /// thing that gave it a reason to be looked at.
    var heardNote: String? { PitchTracker.noteName(analysis.pitchHertz) }

    private func clearSinging() {
        songKey = nil
        suggestedShift = nil
        sungTotal = 0
        sungCount = 0
        chromaTotal = [Double](repeating: 0, count: 12)
        nowPlaying = nil
        lyrics = nil
        lyricLine = nil
        lyricProgress = 0
    }

    /// Where lyrics are read from.
    static var lyricsDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YunAudio/Lyrics", isDirectory: true)
    }

    /// Asks the players what is playing, and finds words for it.
    ///
    /// Cheap enough to do on the interface's own timer only because the panel
    /// has to be open: an Apple event is a process hop each way, and doing it
    /// while nobody is looking would be paying for a feature nobody asked for.
    func refreshNowPlaying() {
        guard isSingingVisible else { return }
        let track = NowPlaying.current()
        if track?.title != nowPlaying?.title || track?.artist != nowPlaying?.artist {
            lyrics = track.flatMap(Self.findLyrics)
        }
        nowPlaying = track

        guard let track, let lyrics else {
            lyricLine = nil
            lyricProgress = 0
            return
        }
        lyricLine = lyrics.index(at: track.position)
        lyricProgress = lyrics.progress(at: track.position)
    }

    /// Finds an `.lrc` for a track by name.
    ///
    /// Matched loosely on purpose. A file somebody downloaded is called
    /// whatever the person who made it called it — "Artist - Title.lrc",
    /// "Title.lrc", with or without accents — and refusing to find it because
    /// of a hyphen would make the feature useless in exactly the case it exists
    /// for.
    static func findLyrics(for track: NowPlaying.Track) -> Lyrics? {
        guard let directory = lyricsDirectory,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        let wanted = normalised(track.searchKey)
        let title = normalised(track.title)

        let candidates = names.filter { $0.lowercased().hasSuffix(".lrc") }
        // Both names present is a better match than the title alone, so it is
        // preferred rather than taking whatever the directory listed first.
        let best =
            candidates.first { normalised($0).contains(wanted) }
            ?? candidates.first {
                let file = normalised($0)
                return file.contains(title) && file.contains(normalised(track.artist))
            }
            ?? candidates.first { normalised($0).contains(title) }
        guard let best,
            let text = try? String(
                contentsOf: directory.appendingPathComponent(best), encoding: .utf8)
        else { return nil }
        return Lyrics.parse(text)
    }

    /// Lower case, no accents, letters and digits only — so "Björk – Jóga.lrc"
    /// matches "Bjork Joga".
    static func normalised(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    // MARK: Buses

    /// One of the mixes a source can be sent to.
    ///
    /// The idea is VoiceMeeter's and it is the one thing everybody who is
    /// praised for this is praised for: two independent mixes with a level per
    /// source on each. This project has had both since monitoring became a
    /// second mix rather than a sidetone — what it did not have was the
    /// *vocabulary*, so the interface showed a fader and another fader with a
    /// headphone symbol beside it, and nothing said that one of them is what
    /// other applications capture and the other is what you hear.
    ///
    /// Naming them is nearly all of the work. A streamer already knows what an
    /// A bus and a B bus are; an abstract matrix makes them work it out.
    struct Bus: Identifiable, Equatable {
        enum Kind: Equatable {
            /// A physical output. What you hear.
            case monitor
            /// A virtual output other applications open as a microphone. What
            /// the far end hears.
            case send
        }
        let id: String
        let letter: String
        let kind: Kind
        let deviceName: String
        /// True when this bus is the one the master fader governs.
        let followsMaster: Bool
    }

    /// The mixes currently in the path, in the order they are shown.
    ///
    /// The send is always there — it is the route. The monitor appears only
    /// when somebody has chosen one, because a bus with nowhere to go is a
    /// control that cannot do anything.
    var buses: [Bus] {
        var list: [Bus] = []
        if let monitor = monitorDeviceUID,
            let device = outputDevices.first(where: {
                $0.uid == monitor
            })
        {
            list.append(
                Bus(
                    id: monitor, letter: "A", kind: .monitor, deviceName: device.name,
                    // Exempt on purpose: the master is the level going to the
                    // far end, and pulling it down must not stop somebody
                    // hearing their own voice.
                    followsMaster: false))
        }
        if let destination = selectedDestination {
            list.append(
                Bus(
                    id: destination.uid,
                    letter: list.isEmpty ? "A" : "B",
                    kind: destination.transport.isVirtual ? .send : .monitor,
                    deviceName: destination.name,
                    followsMaster: true))
        }
        return list
    }

    /// Outputs currently in the path, which are the only ones worth aligning.
    ///
    /// Aligning something that is not being written to is a control that
    /// cannot do anything, and a list of every output the machine has would be
    /// mostly that.
    var alignableOutputs: [AudioDevice] {
        var wanted: [String] = []
        if let destination = selectedDestinationUID { wanted.append(destination) }
        if let monitor = monitorDeviceUID, monitor != selectedDestinationUID {
            wanted.append(monitor)
        }
        return wanted.compactMap { uid in outputDevices.first { $0.uid == uid } }
    }

    func outputDelay(of uid: String) -> Double { outputDelays[uid] ?? 0 }

    func setOutputDelay(_ milliseconds: Double, for uid: String) {
        let clamped = max(0, min(Self.maximumOutputDelay, milliseconds))
        guard outputDelays[uid] != clamped else { return }
        if clamped == 0 { outputDelays[uid] = nil } else { outputDelays[uid] = clamped }
        persist()
        // The delay is a property of the aggregate, decided when it is built,
        // so it cannot be swapped in the way a fader can.
        restartIfRunning()
    }

    /// Half a second. Beyond that it is not alignment any more, and a delay
    /// somebody set by accident should not be able to make the application look
    /// broken.
    static let maximumOutputDelay: Double = 500

    /// Devices chosen before, most recent first. See `Preferences`.
    private(set) var recentSourceUIDs: [String] = []
    private(set) var recentDestinationUIDs: [String] = []

    /// The device the route was forced off, so it can be taken back when it
    /// returns.
    ///
    /// Only set when the substitution was not somebody's choice. Picking a
    /// different microphone by hand clears it, because switching back later
    /// would then be overriding a decision rather than undoing an accident.
    private(set) var displacedSourceUID: String?
    private(set) var displacedDestinationUID: String?
    /// The name of the device the route is waiting to go back to, if any.
    ///
    /// A name rather than a UID, and it survives the device being absent: the
    /// whole point is that it is not in the list any more, so it has to be
    /// remembered rather than looked up.
    private(set) var displacedSourceName: String?
    private(set) var displacedDestinationName: String?

    /// True only while the model itself is moving the route, so the setter can
    /// tell an accident from a choice.
    @ObservationIgnored private var isSubstitutingDevice = false

    private func substituting(_ change: () -> Void) {
        isSubstitutingDevice = true
        change()
        isSubstitutingDevice = false
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

    // MARK: Voice

    /// A whole voice, rather than two knobs somebody has to find the
    /// combination of.
    ///
    /// Pitch and formants are separate stages because they are separate
    /// physical facts. Nobody wants to be told that — they want to sound like
    /// somebody else, and that is a specific pair of settings rather than one
    /// control.
    var voicePreset: VoicePreset = .none {
        didSet {
            guard oldValue != voicePreset else { return }
            applyVoicePreset()
            persist()
        }
    }

    private func applyVoicePreset() {
        let wanted = voicePreset.stages
        // Only the stages the preset actually moves. An idle stage still costs
        // its latency, so switching on a formant shifter set to zero would add
        // twenty-one milliseconds for nothing.
        var effects = enabledEffects
        effects.remove(.pitch)
        effects.remove(.formant)
        effects.formUnion(wanted)

        effectValues["pitch.cents"] = voicePreset.cents
        effectValues["formant.shift"] = voicePreset.formantPercent

        if effects != enabledEffects {
            enabledEffects = effects
        } else {
            // Same stages, different numbers: push them without a rebuild.
            engine.setEffectParameter("cents", of: .pitch, to: voicePreset.cents)
            engine.setEffectParameter("shift", of: .formant, to: voicePreset.formantPercent)
        }
    }

    /// What the chosen voice costs, in milliseconds.
    var voiceLatencyMilliseconds: Double {
        let rate = pathQuality?.sampleRate ?? 48000
        guard rate > 0 else { return 0 }
        return Double(voicePreset.latencyFrames(sampleRate: rate)) / rate * 1000
    }

    // MARK: Third-party units

    /// Every Audio Unit effect installed on this machine, minus Apple's own —
    /// those are the built-in stages already.
    ///
    /// Read once and kept: enumerating components walks the whole plugin
    /// registry, which is not something to do on every view update.
    private(set) var availablePlugins: [AudioUnitPlugin] = []

    /// The ones in the chain, in order.
    var enabledPlugins: [AudioUnitPlugin] = [] {
        didSet {
            guard oldValue != enabledPlugins else { return }
            persist()
            restartIfRunning()
        }
    }

    /// Ones that were asked for and would not load.
    private(set) var failedPlugins: [String] = []

    func refreshPlugins() {
        availablePlugins = AudioUnitPlugins.installed()
        // Anything remembered that is no longer installed is dropped rather
        // than carried: a reference to a plugin somebody uninstalled would fail
        // to load on every start and say so every time.
        let installed = Set(availablePlugins.map(\.id))
        let surviving = enabledPlugins.filter { installed.contains($0.id) }
        if surviving.count != enabledPlugins.count { enabledPlugins = surviving }
    }

    func addPlugin(_ plugin: AudioUnitPlugin) {
        guard !enabledPlugins.contains(plugin) else { return }
        enabledPlugins.append(plugin)
    }

    func removePlugin(_ plugin: AudioUnitPlugin) {
        enabledPlugins.removeAll { $0 == plugin }
    }

    func pluginParameters(_ plugin: AudioUnitPlugin) -> [EffectParameter] {
        engine.pluginParameters(plugin.id)
    }

    func setPluginValue(
        _ value: Float, of parameter: EffectParameter, in plugin: AudioUnitPlugin
    ) {
        pluginValues["\(plugin.id).\(parameter.id)"] = value
        engine.setPluginParameter(parameter.id, ofPlugin: plugin.id, to: value)
        persist()
    }

    func pluginValue(of parameter: EffectParameter, in plugin: AudioUnitPlugin) -> Float {
        pluginValues["\(plugin.id).\(parameter.id)"] ?? parameter.defaultValue
    }

    /// Knob positions, keyed by plugin and parameter.
    var pluginValues: [String: Float] = [:]

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

    /// IO cycle size, in frames.
    ///
    /// Persisted and carried by every preset since the day they were written,
    /// and never once passed to the engine — so the recording preset's 256
    /// frames did nothing at all and every route ran at the default 128. The
    /// status bar reported the real value, which is how it stayed hidden: it
    /// was right about the wrong number being used.
    var bufferFrames: UInt32 = 128 {
        didSet {
            guard oldValue != bufferFrames else { return }
            persist()
            restartIfRunning()
        }
    }

    /// What the buffer picker offers. Below 64 the IO thread has no room for a
    /// processing stage; above 512 the latency stops being worth the safety.
    static let bufferSizes: [UInt32] = [64, 128, 256, 512]

    /// Sample rate a preset asked for. Applied when both devices support it.
    var preferredSampleRate: Double = 48000 {
        didSet { if oldValue != preferredSampleRate { persist(); restartIfRunning() } }
    }
    /// Name of the preset last applied, cleared when a setting is changed by
    /// hand so the UI never claims a preset is active when it is not.
    var activePresetName: String?

    /// Presets somebody saved themselves.
    /// Whole-machine arrangements, remembered under a name. See `QuickConfig`.
    var quickConfigs: [QuickConfig] = [] {
        didSet {
            guard oldValue != quickConfigs else { return }
            QuickConfigStore.save(quickConfigs)
        }
    }

    var userPresets: [RoutePreset] = [] {
        didSet {
            guard oldValue != userPresets else { return }
            UserPresets.save(userPresets)
        }
    }

    // MARK: Application sources

    /// Applications that can be captured. Refreshed on demand — the list churns
    /// as apps come and go, and polling it continuously would be wasteful for
    /// something only looked at when a menu is opened.
    private(set) var availableApps: [AudioApplication] = []

    /// Whether the daemons are shown alongside the applications. Off by
    /// default: they outnumber the real applications four to one, and none of
    /// them is what anyone came here to capture.
    var showsBackgroundApps = false

    /// What the list actually offers, which is the applications plus, when
    /// asked for, everything else. A background process that is audible right
    /// now is always shown — something making noise is worth being able to
    /// point at, whatever its activation policy says.
    var visibleApps: [AudioApplication] {
        showsBackgroundApps ? availableApps : offeredApps
    }

    /// The applications, plus anything audible whatever its activation policy
    /// says — something making noise is worth being able to point at.
    private var offeredApps: [AudioApplication] {
        availableApps.filter { !$0.isBackground || $0.isPlaying }
    }

    /// The daemons: no Dock presence and silent. These are the ones the toggle
    /// is about.
    private var backgroundApps: [AudioApplication] {
        availableApps.filter { $0.isBackground && !$0.isPlaying }
    }

    /// How many entries the toggle is offering to reveal.
    ///
    /// Counted from the list rather than from the difference between the two
    /// views of it, because that difference is zero exactly when they are being
    /// shown — so the number was only ever right while it was not needed.
    var hiddenAppCount: Int { backgroundApps.count }

    /// What one list draws, given how many rows the caller has room for.
    ///
    /// The truncation used to be `visibleApps.prefix(limit)`, applied to the
    /// whole list with the daemons already folded in, and that is why expanding
    /// them looked broken: on this machine four foreground applications against
    /// the panel's limit of six left room for two of nineteen daemons, and the
    /// other seventeen turned into "and 17 more". Pressing the toggle moved two
    /// rows. So the limit belongs to the applications, which are what it exists
    /// to keep short, and the daemons — asked for explicitly, one press ago —
    /// are all shown.
    ///
    /// - Parameter limit: How many application rows to draw before the rest are
    ///   summarised.
    /// - Returns: The rows to draw, in the two groups the list draws them in.
    func appListing(limit: Int) -> AppListing {
        let offered = offeredApps
        return AppListing(
            applications: Array(offered.prefix(limit)),
            overflow: max(0, offered.count - limit),
            background: showsBackgroundApps ? backgroundApps : [])
    }

    struct AppListing {
        /// The applications, truncated to what there is room for.
        var applications: [AudioApplication]
        /// How many applications the truncation left out.
        var overflow: Int
        /// The daemons, in full, when they have been asked for.
        var background: [AudioApplication]
    }

    /// When the application list was last enumerated, so a view can ask for it
    /// to be fresh without asking for it to be re-read on every redraw.
    private(set) var appsRefreshedAt: Date?

    /// Enumerates the applications if nobody has done so recently.
    ///
    /// The list was refreshed only by the Refresh button, by starting a route,
    /// and by the offscreen renderer — so opening the panel for the first time
    /// after launch showed an empty list, with an empty state saying nothing
    /// was producing audio, on a machine playing three things. Nothing had gone
    /// wrong; nothing had ever run.
    ///
    /// Gated rather than unconditional because it is not free: 12 to 25 ms
    /// warm on this machine and 118 ms cold, which is fine when a panel opens
    /// and is not fine on every redraw of a list that is inside a disclosure.
    ///
    /// - Parameter seconds: How stale the list may be before it is re-read.
    func refreshAppsIfStale(olderThan seconds: TimeInterval = 3) {
        if let refreshed = appsRefreshedAt, Date().timeIntervalSince(refreshed) < seconds {
            return
        }
        refreshApps()
    }

    /// Applications this router will not touch, whatever anybody clicks.
    ///
    /// Every product in this category added one of these *after* the breakage
    /// reports rather than before — Steam games, DAWs, Krisp, Roon, Bitwig. A
    /// process tap changes how an application's audio leaves the machine, and
    /// some of them notice: a DAW that finds its output redirected mid-session
    /// is a lost take, and the person it happens to has no reason to suspect a
    /// menu bar utility they set up weeks ago.
    ///
    /// Deliberately stronger than "not selected". Selecting is a click, and a
    /// click can be an accident; this survives one, survives a preset, and
    /// survives the "capture everything audible" path.
    var excludedAppBundleIDs: Set<String> = [] {
        didSet {
            guard oldValue != excludedAppBundleIDs else { return }
            // Anything newly excluded stops being captured at once. Leaving it
            // running until the next restart would make the exclusion look like
            // it had not worked.
            let released = capturedAppBundleIDs.intersection(excludedAppBundleIDs)
            if !released.isEmpty { capturedAppBundleIDs.subtract(released) }
            persist()
        }
    }

    func isExcluded(_ bundleID: String) -> Bool { excludedAppBundleIDs.contains(bundleID) }

    func setExcluded(_ excluded: Bool, bundleID: String) {
        if excluded {
            excludedAppBundleIDs.insert(bundleID)
        } else {
            excludedAppBundleIDs.remove(bundleID)
        }
    }

    /// Bundle identifiers of the applications being captured alongside the
    /// microphone. Stored by bundle id rather than pid so the choice survives
    /// the app being quit and relaunched.
    var capturedAppBundleIDs: Set<String> = [] {
        didSet {
            guard oldValue != capturedAppBundleIDs else { return }
            // The exclusion wins over the selection, here rather than at every
            // place that reads the set: a rule enforced in one place cannot be
            // forgotten by the next thing that writes to it — a preset, a URL,
            // or a restore from a file written before the exclusion existed.
            let forbidden = capturedAppBundleIDs.intersection(excludedAppBundleIDs)
            if !forbidden.isEmpty {
                capturedAppBundleIDs.subtract(forbidden)
                return
            }
            persist()
            restartIfRunning()
        }
    }

    var tapMuteBehavior: TapMuteBehavior = .unmuted {
        didSet { if oldValue != tapMuteBehavior { persist(); restartIfRunning() } }
    }

    // MARK: Input trim and master

    /// How loud the microphone is, and how loud the whole mix comes out.
    ///
    /// The per-route faders balance sources against each other; these are the
    /// two controls anybody looks for first, and the app had neither. Stored in
    /// decibels because that is what the fader shows and what gets persisted —
    /// a scalar would round-trip badly through the −40 dB floor.
    var inputDecibels: Float = 0 {
        didSet {
            guard oldValue != inputDecibels else { return }
            engine.setInputGain(Self.gain(fromDecibels: inputDecibels))
            persist()
        }
    }
    var isInputMuted = false {
        didSet {
            guard oldValue != isInputMuted else { return }
            engine.setInputMuted(isInputMuted)
            persist()
        }
    }
    var outputDecibels: Float = 0 {
        didSet {
            guard oldValue != outputDecibels else { return }
            engine.setOutputGain(Self.gain(fromDecibels: outputDecibels))
            persist()
        }
    }
    var isOutputMuted = false {
        didSet {
            guard oldValue != isOutputMuted else { return }
            engine.setOutputMuted(isOutputMuted)
            persist()
        }
    }

    // MARK: Direct monitoring

    /// Where the microphone is also sent so the user can hear themselves, or
    /// nil when monitoring is off.
    ///
    /// This goes through the same IOProc cycle as everything else, so the delay
    /// is one buffer plus the output device's own — 2.7 ms at 128 frames, which
    /// is below what anybody perceives as an echo of their own voice. Software
    /// monitoring through a conferencing app is typically thirty times that,
    /// which is why people reach for a mixer instead.
    var monitorDeviceUID: String? {
        didSet {
            guard oldValue != monitorDeviceUID else { return }
            persist()
            restartIfRunning()
        }
    }

    /// How loud the monitor is, independent of everything else.
    var monitorDecibels: Float = -6 {
        didSet {
            guard oldValue != monitorDecibels else { return }
            applyMonitorGain()
            persist()
        }
    }

    /// Outputs that can be monitored on: anything with output channels that is
    /// not already carrying the mix, and never our own virtual device — sending
    /// the microphone back into the thing the far end is listening to is a loop,
    /// not a monitor.
    var monitorOptions: [AudioDevice] {
        outputDevices.filter {
            $0.uid != selectedDestinationUID && $0.uid != selectedSourceUID
                && !$0.name.localizedCaseInsensitiveContains("YunAudio")
        }
    }

    /// True when the chosen monitor is a loudspeaker rather than headphones, as
    /// far as its transport can say. Monitoring on speakers puts the microphone
    /// into the room the microphone is in, which is feedback.
    var monitorMayFeedBack: Bool {
        guard let uid = monitorDeviceUID,
            let device = outputDevices.first(where: { $0.uid == uid })
        else { return false }
        let name = device.name.lowercased()
        let headphoneWords = ["headphone", "耳機", "earphone", "headset", "airpods"]
        return !headphoneWords.contains { name.contains($0) }
    }

    /// Which routes carry each source into the monitor, so a send can be moved
    /// without rebuilding anything.
    @ObservationIgnored private var monitorRouteIndices: [String: [Int]] = [:]

    /// How much of each source goes to the monitor, by source UID.
    ///
    /// Absent means the default: the microphone at whatever the monitor level
    /// is set to, and everything else off. Somebody who turns monitoring on
    /// wants to hear themselves; whether they also want the music in their ears
    /// is a decision, not a default.
    var monitorSends: [String: Float] = [:] {
        didSet { if oldValue != monitorSends { persist() } }
    }

    func monitorSendDecibels(forSource uid: String) -> Float {
        if let stored = monitorSends[uid] { return stored }
        return uid == selectedSourceUID ? monitorDecibels : Self.minimumDecibels
    }

    func monitorSendDecibels(of group: SourceGroup) -> Float {
        monitorSendDecibels(forSource: group.uid)
    }

    /// Moves a source's monitor send.
    ///
    /// Without a rebuild when the routes already exist; with one when they do
    /// not, because a send coming up from silence needs routes that were never
    /// built.
    func setMonitorSend(_ decibels: Float, for group: SourceGroup) {
        let wasAudible = monitorSendDecibels(of: group) > Self.minimumDecibels
        monitorSends[group.uid] = decibels
        guard decibels > Self.minimumDecibels, wasAudible,
            let indices = monitorRouteIndices[group.uid]
        else {
            restartIfRunning()
            return
        }
        let gain = Self.gain(fromDecibels: decibels)
        for index in indices { engine.setGain(gain, forRouteAt: index) }
    }

    /// The monitor fader as a 0...1 travel, matching the hardware gain slider
    /// beside it rather than the decibel rows above.
    var monitorFraction: Float {
        get {
            let span = -Self.minimumDecibels
            return max(0, min(1, (monitorDecibels - Self.minimumDecibels) / span))
        }
        set {
            let span = -Self.minimumDecibels
            monitorDecibels = Self.minimumDecibels + max(0, min(1, newValue)) * span
        }
    }

    var monitorLabel: String {
        monitorDecibels <= Self.minimumDecibels
            ? "−∞ dB" : String(format: "%+.1f dB", monitorDecibels)
    }

    /// What the monitor actually costs, end to end.
    ///
    /// One IO cycle through the shared aggregate plus the output device's own
    /// reported latency and safety offset. Quoting only the buffer would be the
    /// flattering number rather than the true one.
    var monitorLatencyMilliseconds: Double {
        let rate = pathQuality?.sampleRate ?? 48000
        guard rate > 0 else { return 0 }
        let bufferFrames = Double(pathQuality?.bufferFrames ?? Int(self.bufferFrames))
        let device = monitorDeviceUID.flatMap { uid in
            outputDevices.first(where: { $0.uid == uid })
        }
        let deviceFrames = Double(
            device?.latencyFrames(scope: kAudioObjectPropertyScopeOutput) ?? 0)
        return (bufferFrames + deviceFrames) / rate * 1000
    }

    private func applyMonitorGain() {
        // The microphone's own send follows the monitor level unless somebody
        // has moved it themselves.
        guard let uid = selectedSourceUID, monitorSends[uid] == nil,
            let indices = monitorRouteIndices[uid]
        else { return }
        let gain = Self.gain(fromDecibels: monitorDecibels)
        for index in indices { engine.setGain(gain, forRouteAt: index) }
    }

    /// Below this the fader reads as −∞ and the gain is exactly zero, so the
    /// bottom of the travel is silence rather than something very quiet.
    static let minimumDecibels: Float = -40

    static func gain(fromDecibels decibels: Float) -> Float {
        decibels <= minimumDecibels ? 0 : pow(10, decibels / 20)
    }

    // MARK: Light ring

    /// The microphone's own light ring, driven from the same numbers the meters
    /// use.
    ///
    /// The capture established that the device renders no effects of its own —
    /// every animation is computed on the host and pushed — which turns the
    /// ring into a twelve-pixel display this application already has something
    /// to put on.
    let lighting = LightingController()

    var lightingMode: LightingMode {
        get { lighting.mode }
        set {
            guard lighting.mode != newValue else { return }
            lighting.mode = newValue
            persist()
        }
    }

    /// The ring's colour, as a hue from 0 to 1.
    ///
    /// A hue rather than three channels: the ring is one colour at a time and
    /// what anybody wants from it is "make it green", not a colour space. Full
    /// saturation is the only setting that reads properly on twelve LEDs
    /// through a diffuser.
    var lightingHue: Double = 0.55 {
        didSet {
            guard oldValue != lightingHue else { return }
            lighting.colour = RazerRing.hue(lightingHue)
            persist()
        }
    }

    var lightingBrightness: Double {
        get { Double(lighting.brightness) / 255 }
        set {
            let level = UInt8(max(0, min(255, newValue * 255)))
            guard lighting.brightness != level else { return }
            lighting.brightness = level
            persist()
        }
    }

    // MARK: Hardware gain

    /// The microphone's own gain, if it publishes one.
    ///
    /// Kept separate from the trim on purpose. This happens in the hardware
    /// before the converter, so turning it up costs no headroom; the trim
    /// happens afterwards and can only amplify what the converter already
    /// decided, noise and all. The right order is this first.
    var hardwareGain: AudioDevice.HardwareGain? {
        selectedSource?.hardwareGain(scope: kAudioObjectPropertyScopeInput)
    }

    /// Read through a stored copy so the slider does not fight the device: a
    /// bare read every frame would snap the thumb back while it is being
    /// dragged, because the device rounds what it was given.
    var hardwareGainScalar: Float {
        get { pendingHardwareGain ?? hardwareGain?.scalar ?? 0 }
        set {
            pendingHardwareGain = newValue
            guard let source = selectedSource else { return }
            try? source.setHardwareGain(
                scalar: newValue, scope: kAudioObjectPropertyScopeInput)
        }
    }
    private var pendingHardwareGain: Float?

    /// What the hardware gain reads as, in the device's own units where it has
    /// them.
    var hardwareGainLabel: String {
        guard let gain = hardwareGain else { return "" }
        // Re-derived from the range rather than re-read, so it tracks the
        // slider rather than lagging a device round trip behind it.
        if let range = gain.decibelRange {
            let span = range.upperBound - range.lowerBound
            let value = range.lowerBound + hardwareGainScalar * span
            return String(format: "%+.1f dB", value)
        }
        return String(format: "%.0f%%", hardwareGainScalar * 100)
    }

    // MARK: Echo cancellation

    /// Whether the microphone is captured through the echo canceller.
    ///
    /// Off by default and deliberately not a preset: it takes the microphone
    /// out of the router's own aggregate, which costs the clock lock, bit
    /// exactness and a buffer of latency each way. Worth every bit of that on
    /// laptop speakers, worth none of it on headphones.
    var cancelsEcho = false {
        didSet { if oldValue != cancelsEcho { persist(); restartIfRunning() } }
    }

    /// The speaker the canceller listens for. Nil means the current default.
    var echoSpeakerUID: String? {
        didSet { if oldValue != echoSpeakerUID { persist(); restartIfRunning() } }
    }

    /// Outputs worth cancelling against: real hardware only. Cancelling against
    /// a virtual endpoint removes nothing, because nothing acoustic came out
    /// of it.
    var echoSpeakerOptions: [AudioDevice] {
        outputDevices.filter { !$0.transport.isVirtual }
    }

    var resolvedEchoSpeaker: AudioDevice? {
        echoSpeakerOptions.first { $0.uid == echoSpeakerUID }
            ?? (try? AudioDevices.defaultOutput()).flatMap { device in
                device.transport.isVirtual ? nil : device
            }
            ?? echoSpeakerOptions.first
    }

    private func echoSettings(
        fallbackProcessIDs: [AudioObjectID]
    ) -> EchoCancellationSettings? {
        guard cancelsEcho, let speaker = resolvedEchoSpeaker else { return nil }
        let reference =
            fallbackProcessIDs.isEmpty
            ? availableApps.filter(\.isPlaying).flatMap(\.processIDs)
            : fallbackProcessIDs
        // Unmuted: the applications keep playing to the speaker themselves. The
        // alternative routes their audio through the canceller instead, which
        // cancels better but puts this app in the path of everything the user
        // hears — too much to take without being asked.
        return EchoCancellationSettings(
            speakerUID: speaker.uid, farEndProcessIDs: reference,
            tapMuteBehavior: .unmuted)
    }

    /// What the canceller is doing, or nil when it is not in the path.
    var echoStatus: EchoCancellationStatus? { engine.echoCancellationStatus }

    // MARK: Recording

    /// Container to write. WAV keeps a bit-exact path bit-exact on disk; AAC is
    /// a quarter the size and a lossy copy of the thing this project spends
    /// most of its effort keeping intact.
    var recordingFormat: Recorder.Format = .wav

    private(set) var isRecording = false
    private(set) var recordingURL: URL?
    private(set) var recordingSeconds: TimeInterval = 0

    /// Where files go. The user's Music folder rather than a folder of our own:
    /// a recording is theirs, and burying it somewhere only this app knows
    /// about is how recordings get lost.
    var recordingDirectory: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Paused, with the file still open.
    ///
    /// Kept in the model as well as the engine because a paused recording is a
    /// state the interface has to render, and asking the engine sixty times a
    /// second for something that changes on a click is work for nothing.
    private(set) var isRecordingPaused = false

    /// Pausing rather than stopping, which is what somebody wants when the
    /// doorbell goes: the file stays open and what comes out is a clean splice
    /// rather than two files to join afterwards.
    func toggleRecordingPause() {
        guard isRecording else { return }
        isRecordingPaused.toggle()
        engine.setRecordingPaused(isRecordingPaused)
    }

    /// Write a separate file per source alongside the mix.
    ///
    /// The mix answers "what did the far end hear". The stems answer "what did
    /// each of us say" — which cannot be recovered from a mix at any price, and
    /// is the question anybody editing a podcast afterwards actually has.
    var recordsStems = false {
        didSet { if oldValue != recordsStems { persist() } }
    }

    private(set) var stemURLs: [URL] = []

    /// Samples any stem had to drop. Non-zero means a file has gaps in it.
    var engineStemDrops: UInt64 { engine.stemDroppedSamples }

    /// How many sources are being listened to for transcription. One per
    /// source is the whole mechanism, so it is worth being able to check.
    var engineTranscriptTaps: Int { engine.transcriptTapCount }

    func toggleRecording() {
        if isRecording {
            isRecordingPaused = false
            engine.setRecordingPaused(false)
            engine.stopStemRecording()
            // Read the duration first: stopping releases the recorder, and
            // asking a released recorder how long it ran returns zero, so the
            // elapsed time snapped back to 00:00 exactly when someone would
            // look at it.
            recordingSeconds = engine.recordingDuration
            engine.stopRecording()
            isRecording = false
            return
        }
        guard isRunning else {
            lastError = loc("Start routing before recording.")
            return
        }
        do {
            recordingURL = try engine.startRecording(
                to: recordingDirectory, format: recordingFormat)
            if recordsStems {
                let groups = sourceGroups
                stemURLs =
                    (try? engine.startStemRecording(
                        to: recordingDirectory,
                        groups: groups.map(\.routes),
                        names: groups.map { group in
                            representative(of: group).map(routeTitle) ?? ""
                        },
                        format: recordingFormat)) ?? []
            }
            isRecording = true
            isRecordingPaused = false
            recordingSeconds = 0
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Shows the finished file in the Finder, which is the only thing anyone
    /// wants to do with a recording the moment it stops.
    func revealRecording() {
        guard let url = recordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Called from the same tick that drives the meters, so the elapsed time
    /// comes from frames actually written rather than from a wall clock that
    /// would keep counting through a stalled writer.
    private func refreshRecordingState() {
        guard isRecording else { return }
        recordingSeconds = engine.recordingDuration
        // The writer stops itself on a file-system error. Left unnoticed, the
        // button would go on saying "recording" over a file that stopped
        // growing minutes ago.
        if !engine.isRecording {
            isRecording = false
            lastError = loc("Recording stopped: the file could not be written.")
        }
    }

    /// Populates the model with representative state for the offscreen design
    /// captures. Not called by the running app.
    func prepareForRendering() {
        refreshApps()
        // Everything that does not depend on a device comes first.
        //
        // It used to sit after the guard below, so on any machine where no
        // input was selected the whole analysis card rendered empty — every
        // figure a dash — and the design captures showed nothing of the panel
        // they exist to check.
        voicePreset = .masculineToFeminine
        analysis = SignalAnalyser.Reading(
            momentary: -19.4, shortTerm: -18.6, integrated: -18.2, range: 6.4,
            peak: -8.1,
            bands: (0..<SpectrumAnalyser.bandCount).map { band in
                // A voice-shaped curve, so the analyser looks like a voice
                // rather than like noise.
                let position = Double(band) / Double(SpectrumAnalyser.bandCount - 1)
                return Float(max(0.05, 0.85 * exp(-pow((position - 0.34) / 0.28, 2))))
            },
            duration: 42, verdict: .speech, verdictConfidence: 0.86,
            verdictLabel: "speech", pitchHertz: 147)
        outputPeak = 0.39

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

    /// True when the installed driver is not the one this app ships.
    ///
    /// Worth saying out loud: an older driver is missing whatever the newer one
    /// added, silently, and every symptom looks like a bug in the application.
    var driverIsOutOfDate: Bool { DriverInstaller.installedIsOutOfDate }

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
        availableApps = (try? AudioApplications.grouped()) ?? []
        appsRefreshedAt = Date()
    }

    /// Resolves the saved bundle identifiers to the processes running right now.
    /// An application splits its audio across helper processes — Discord uses
    /// four — so the whole group is captured, not just the process that happened
    /// to head the entry.
    private var tappableProcessIDs: [AudioObjectID] {
        guard !capturedAppBundleIDs.isEmpty else { return [] }
        return
            availableApps
            .filter { capturedAppBundleIDs.contains($0.bundleID) }
            .flatMap(\.processIDs)
    }

    /// Which application each tap is capturing, by bundle identifier.
    ///
    /// A tap's UID is how a route names its source, and it is generated by
    /// CoreAudio — so this is the only way back from a route to the application
    /// behind it, which is what per-application volume and roles need.
    @ObservationIgnored private(set) var tapOwners: [String: String] = [:]

    /// The application a route's source belongs to, if it is one.
    func application(of route: Route) -> AudioApplication? {
        guard let bundleID = tapOwners[route.source.deviceUID] else { return nil }
        return availableApps.first { $0.bundleID == bundleID }
    }

    /// Per-route peak levels, aligned with `routes`.
    var routeLevels: [Float] { levels }

    /// The highest level each route has reached lately, and whether it has ever
    /// hit full scale.
    ///
    /// A bar that only shows the instantaneous peak is unreadable for speech:
    /// the loudest moment is a few milliseconds long and the eye never catches
    /// it. The hold marker is the one that tells you whether you are actually
    /// near clipping, and the clip latch is the one that tells you that you
    /// were — once, twenty seconds ago, which is exactly the event a meter that
    /// only falls will hide.
    private(set) var peakHolds: [Float] = []
    private(set) var clipped: [Bool] = []

    /// Clears the clip latches. Deliberately manual: a latch that clears itself
    /// is a latch nobody sees.
    func clearClipping() {
        clipped = clipped.map { _ in false }
        engine.clearOutputClipping()
        outputClippedSamples = 0
    }

    // MARK: What actually leaves

    /// Loudest sample on the destination bus after every gain stage, and how
    /// many have already been truncated.
    ///
    /// The route meters are taken before gain on purpose — a meter should show
    /// what arrived. The consequence was that nothing in the application could
    /// see the trim or the master pushing the signal past full scale: the far
    /// end heard distortion and every meter here read healthy.
    private(set) var outputPeak: Float = 0
    private(set) var outputClippedSamples: UInt64 = 0

    var outputPeakDecibels: Double {
        outputPeak > 0 ? Double(20 * log10(outputPeak)) : -.infinity
    }

    /// A one-line verdict on the level going out, which is the question behind
    /// "why does this sound bad on the call".
    ///
    /// Both failure modes are silent otherwise. Too loud is truncation, which
    /// no meter here was watching for. Too quiet is worse in practice: a
    /// conferencing application will run its own automatic gain over whatever
    /// it is given, so a signal 30 dB down arrives as amplified room noise, and
    /// nothing about that looks wrong from this side.
    enum OutputVerdict: Sendable { case clipping, hot, good, quiet, veryQuiet, silent }

    var outputVerdict: OutputVerdict {
        if outputClippedSamples > 0 { return .clipping }
        let decibels = outputPeakDecibels
        guard decibels.isFinite else { return .silent }
        if decibels > -1 { return .clipping }
        if decibels > -3 { return .hot }
        if decibels > -24 { return .good }
        if decibels > -36 { return .quiet }
        return .veryQuiet
    }

    /// The level on a particular route, for the patchbay to draw on its cable.
    func level(of route: Route) -> Float {
        guard let index = activeRoutes.firstIndex(of: route), index < levels.count,
            !isSilenced(index)
        else { return 0 }
        return levels[index]
    }

    /// Full scale in float is 1.0, and anything at or above it has already been
    /// truncated by whatever converts to the wire format downstream.
    private static let clipThreshold: Float = 0.999

    private func refreshPeaks(_ current: [Float]) {
        if peakHolds.count != current.count {
            peakHolds = current
            clipped = current.map { $0 >= Self.clipThreshold }
            return
        }
        for index in current.indices {
            // Rises at once, falls slowly. The poll runs twenty times a second,
            // so this is roughly a second and a half of hold.
            peakHolds[index] =
                current[index] > peakHolds[index]
                ? current[index] : peakHolds[index] * 0.97
            if current[index] >= Self.clipThreshold { clipped[index] = true }
        }
    }

    // MARK: Patchbay

    /// Ports the canvas offers on the left.
    ///
    /// The selected input plus every captured application: a tap is a source
    /// like any other as far as the matrix is concerned.
    var canvasSources: [PortGroup] {
        var groups: [PortGroup] = []
        if let source = selectedSource {
            groups.append(
                PortGroup(
                    uid: source.uid, name: source.name,
                    channels: Array(0..<min(source.inputChannels, 8))))
        }
        // Tap channels only exist while a route is up, since the tap is created
        // then; before that there is nothing to offer.
        for route in activeRoutes
        where !inputDevices.contains(where: {
            $0.uid == route.source.deviceUID
        }) {
            guard !groups.contains(where: { $0.uid == route.source.deviceUID }) else {
                continue
            }
            groups.append(
                PortGroup(
                    uid: route.source.deviceUID,
                    name: loc("Application audio"),
                    channels: [0, 1]))
        }
        return groups
    }

    /// Whether the canvas offers every channel a device has, or only the ones
    /// worth looking at.
    var showsAllCanvasChannels = false

    var canvasDestinations: [PortGroup] {
        guard let destination = selectedDestination else { return [] }
        return [
            PortGroup(
                uid: destination.uid, name: destination.name,
                channels: Array(0..<canvasChannelCount(of: destination)))
        ]
    }

    /// Channels a sixteen-channel device offers on the canvas.
    ///
    /// Showing all of them turned the patchbay into a column of fourteen empty
    /// ports — the card was mostly dead space and it pushed the mixer off the
    /// bottom of the window. Two past the highest one in use is enough to make
    /// the next connection without hunting, and the rest are one click away.
    private func canvasChannelCount(of device: AudioDevice) -> Int {
        let total = device.outputChannels
        guard !showsAllCanvasChannels else { return min(total, 16) }
        let highestInUse =
            activeRoutes
            .filter { $0.destination.deviceUID == device.uid }
            .map(\.destination.channel)
            .max() ?? -1
        return min(total, max(2, highestInUse + 3))
    }

    /// Channels the canvas is holding back, so the button can say how many.
    var hiddenCanvasChannels: Int {
        guard let destination = selectedDestination else { return 0 }
        return min(destination.outputChannels, 16) - canvasChannelCount(of: destination)
    }

    /// Adds a cable. Silent when the route is already up, because the graph is
    /// swapped rather than rebuilt.
    func connect(source: ChannelRef, destination: ChannelRef) {
        guard
            !activeRoutes.contains(where: {
                $0.source == source && $0.destination == destination
            })
        else { return }
        applyPatch(activeRoutes + [Route(source: source, destination: destination)])
    }

    /// Pulls one cable, leaving everything else where it is.
    func disconnectRoute(source: ChannelRef, destination: ChannelRef) {
        let remaining = activeRoutes.filter {
            !($0.source == source && $0.destination == destination)
        }
        guard remaining.count != activeRoutes.count else { return }
        applyPatch(remaining)
    }

    /// Pulls every cable reaching a destination.
    func disconnect(destination: ChannelRef) {
        let remaining = activeRoutes.filter { $0.destination != destination }
        guard remaining.count != activeRoutes.count else { return }
        applyPatch(remaining)
    }

    private func applyPatch(_ routes: [Route]) {
        guard isRunning else {
            // Nothing to swap into; the patch takes effect when routing starts.
            activeRoutes = routes
            return
        }
        if engine.updateRoutes(routes) {
            activeRoutes = engine.currentRoutes
            routeGains = activeRoutes.map(\.gain)
            routeMutes = activeRoutes.map(\.isMuted)
        }
    }

    // MARK: Per-route control

    private(set) var routeGains: [Float] = []
    private(set) var routeMutes: [Bool] = []

    /// The route being soloed, if any.
    ///
    /// Solo is a view of the mix rather than a setting: it mutes everything
    /// else without touching what each route's own mute says, so turning it off
    /// puts the mix back exactly as it was. Storing it as "which one" rather
    /// than a flag per route is what makes that reversible.
    private(set) var soloedRoute: Int?

    func toggleSolo(_ index: Int) {
        soloedRoute = soloedRoute == index ? nil : index
        applyMutes()
    }

    /// True when this route is silent right now, for whatever reason.
    ///
    /// Including reasons upstream of the route. Peaks are metered before the
    /// fader on purpose — a meter should show what arrived, not what the fader
    /// did to it — but that also meant muting the microphone left every meter
    /// moving, which reads as "the mute did not work".
    func isSilenced(_ index: Int) -> Bool {
        if index < activeRoutes.count,
            activeRoutes[index].source.deviceUID == selectedSourceUID,
            isInputMuted
        {
            return true
        }
        if isOutputMuted { return true }
        if let soloedRoute { return index != soloedRoute }
        return index < routeMutes.count && routeMutes[index]
    }

    private func applyMutes() {
        for index in routeMutes.indices {
            engine.setMuted(isSilenced(index), forRouteAt: index)
        }
    }

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
    // MARK: Sources rather than wires

    /// One logical source and every route carrying it.
    ///
    /// A stereo source is two routes, and the mixer used to show two strips for
    /// it — two faders, two mutes and two solo buttons for one microphone,
    /// which have to be kept in step by hand and silently drift apart the first
    /// time somebody moves one. The balance pass made that worse rather than
    /// better: it measured each channel separately and proposed a gain for
    /// each, so applying it to a stereo source would put the two sides at
    /// different levels and pull the image apart.
    ///
    /// It is the same mistake as capturing every application through one tap,
    /// pointing the other way. That one collapsed several things into one so
    /// they could not be addressed separately; this one split one thing into
    /// several so it could not be addressed at all. Both come from letting the
    /// wiring decide what the interface shows.
    struct SourceGroup: Identifiable, Equatable {
        let uid: String
        /// Indices into `activeRoutes`, in order.
        let routes: [Int]
        var id: String { uid }
    }

    /// Routes grouped by where they come from, in the order they appear.
    var sourceGroups: [SourceGroup] {
        var order: [String] = []
        var members: [String: [Int]] = [:]
        for (index, route) in activeRoutes.enumerated() {
            let uid = route.source.deviceUID
            if members[uid] == nil { order.append(uid) }
            members[uid, default: []].append(index)
        }
        return order.map { SourceGroup(uid: $0, routes: members[$0] ?? []) }
    }

    /// The first route of a group, which is what every per-route accessor is
    /// keyed on.
    func representative(of group: SourceGroup) -> Route? {
        guard let first = group.routes.first, first < activeRoutes.count else { return nil }
        return activeRoutes[first]
    }

    func level(of group: SourceGroup) -> Float {
        group.routes.compactMap { $0 < levels.count ? levels[$0] : nil }.max() ?? 0
    }

    func peakHold(of group: SourceGroup) -> Float {
        group.routes.compactMap { $0 < peakHolds.count ? peakHolds[$0] : nil }.max() ?? 0
    }

    func isClipped(_ group: SourceGroup) -> Bool {
        group.routes.contains { $0 < clipped.count && clipped[$0] }
    }

    func isMuted(_ group: SourceGroup) -> Bool {
        // Muted only when every channel is: a half-muted source is a state the
        // interface should never be able to produce, but it can arrive from a
        // preset written before grouping existed.
        !group.routes.isEmpty
            && group.routes.allSatisfy { $0 < routeMutes.count && routeMutes[$0] }
    }

    func isSilenced(_ group: SourceGroup) -> Bool {
        group.routes.allSatisfy { isSilenced($0) }
    }

    func setMuted(_ muted: Bool, for group: SourceGroup) {
        for index in group.routes { setMuted(muted, forRouteAt: index) }
    }

    var soloedGroup: String? {
        guard let soloedRoute, soloedRoute < activeRoutes.count else { return nil }
        return activeRoutes[soloedRoute].source.deviceUID
    }

    func toggleSolo(_ group: SourceGroup) {
        guard let first = group.routes.first else { return }
        toggleSolo(first)
    }

    /// The group's fader. Every channel moves together, which is the whole
    /// point — moving one side of a stereo pair is not a volume change, it is
    /// a balance change nobody asked for.
    func faderDecibels(of group: SourceGroup) -> Float {
        guard let first = group.routes.first else { return 0 }
        return faderDecibels(forRouteAt: first)
    }

    func setFaderDecibels(_ decibels: Float, for group: SourceGroup) {
        for index in group.routes { setFaderDecibels(decibels, forRouteAt: index) }
    }

    /// What a source is called in the mixer: its name, and how many channels
    /// it carries when that is worth saying.
    func sourceLabel(for group: SourceGroup) -> String {
        guard let route = representative(of: group) else { return "" }
        let name = routeTitle(route)
        guard group.routes.count > 1 else { return name }
        return "\(name)  \(group.routes.count)ch"
    }

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
        } else if let application = application(of: route) {
            // A tap's UID is a UUID, so the only way to a name is the map built
            // when the taps were created. This used to name whichever captured
            // application happened to be first in the list, which was right
            // exactly when there was one of them — every strip said "Discord"
            // whether it carried Discord or Spotify.
            source = application.name
        } else if route.source.deviceUID.contains("-") {
            source = loc("Application audio")
        } else {
            source = route.source.deviceUID
        }
        return source
    }

    func setMuted(_ muted: Bool, forRouteAt index: Int) {
        // Solo owns what is audible while it is on, so a mute pressed under it
        // records the intent and takes effect when solo is released.
        guard soloedRoute == nil else {
            if index < routeMutes.count { routeMutes[index] = muted }
            persist()
            return
        }
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
        didSet {
            guard oldValue != enabledEffects else { return }
            persist()
            // The chain is swapped under the running IOProc when it can be, and
            // only falls back to a restart when it cannot. A restart for one
            // switch cost seconds of silence — the single worst interaction in
            // the application.
            if !swapChainIfPossible() { restartIfRunning() }
        }
    }

    /// Puts the new chain in without stopping the route. Returns false when the
    /// change has to go through a rebuild after all.
    ///
    /// The engine call is the slow part — it instantiates Audio Units — so it
    /// goes to `engineQueue` like every other piece of engine work, and the
    /// answer comes back through the main actor. Taking the engine's lock from
    /// here would block the main actor for the length of the build.
    private func swapChainIfPossible() -> Bool {
        // A batch is about to restart anyway, and a swap in the middle of one
        // would be work thrown away.
        guard !isApplyingPreset, isRunning, !isBusy else { return false }
        isBusy = true
        let engine = engine
        let kinds = Array(enabledEffects)
        let pluginList = enabledPlugins
        let isolation =
            enabledEffects.contains(.voiceIsolation)
            ? VoiceIsolationSettings(mixPercent: voiceIsolationMix) : nil
        engineQueue.async {
            let swapped = engine.updateEffects(
                kinds, plugins: pluginList, voiceIsolation: isolation)
            Task { @MainActor in
                self.isBusy = false
                guard swapped else {
                    self.restartIfRunning()
                    return
                }
                self.failedPlugins = engine.failedPlugins
                // A freshly built chain comes up at each stage's own defaults,
                // so the stored knob positions have to be pushed back — the
                // same reason a restart does it.
                self.applyEffectValues()
            }
        }
        return true
    }

    /// The stages actually rendering. Not the same as `enabledEffects`: one
    /// that will not instantiate is dropped, and until recently a single
    /// enabled stage built no chain at all.
    var activeEffectStages: [EffectKind] { engine.activeEffectStages }

    /// How much each dynamics stage is pulling the signal down, in decibels.
    ///
    /// A compressor with its threshold set wrong is completely silent about it:
    /// it sounds like a compressor doing nothing, which is what it is. The only
    /// way to tell is to watch the reduction, which is why every compressor
    /// ever shipped has this meter and why two knobs without one are guesswork.
    private(set) var gainReduction: [EffectKind: Float] = [:]

    private func refreshGainReduction() {
        for kind in [EffectKind.compressor, .gate] where enabledEffects.contains(kind) {
            let value = engine.gainReduction(of: kind)
            // Falls at a readable rate rather than following the unit exactly:
            // the reduction moves at the release time, which at 150 ms is a
            // flicker rather than a reading.
            let previous = gainReduction[kind] ?? 0
            gainReduction[kind] = value > previous ? value : previous * 0.82 + value * 0.18
        }
        // Snapshotted, because the loop mutates the dictionary it is walking.
        for kind in Array(gainReduction.keys) where !enabledEffects.contains(kind) {
            gainReduction[kind] = nil
        }
    }

    /// Knob positions, keyed by "<stage>.<parameter>". Persisted so a chain
    /// comes back tuned the way it was left rather than at its defaults.
    ///
    /// Settable rather than read-only because a saved preset restores the whole
    /// chain, and a chain restored without its knob positions is a different
    /// chain wearing the same name.
    var effectValues: [String: Float] = [:]

    func value(of parameter: EffectParameter, in kind: EffectKind) -> Float {
        effectValues["\(kind.rawValue).\(parameter.id)"] ?? parameter.defaultValue
    }

    /// What the running unit holds for that knob, rather than what this model
    /// remembers setting. Nil when nothing is rendering that stage.
    ///
    /// The two agree only if the value actually reached the engine, which is
    /// the whole point of asking: a chain rebuilt at its defaults is invisible
    /// from the model's side.
    func renderedValue(of parameter: EffectParameter, in kind: EffectKind) -> Float? {
        engine.effectParameter(parameter.id, of: kind)
    }

    func setValue(_ value: Float, of parameter: EffectParameter, in kind: EffectKind) {
        effectValues["\(kind.rawValue).\(parameter.id)"] = value
        // Audio Unit parameter writes are realtime-safe, so this takes effect
        // immediately without rebuilding anything.
        engine.setEffectParameter(parameter.id, of: kind, to: value)
        persist()
    }

    /// Pushes every stored knob position into a chain that has just been built.
    ///
    /// A rebuilt chain comes up at each stage's own defaults, and nothing was
    /// putting the stored values back — so every knob anybody had moved
    /// silently reverted on the next restart while the interface went on
    /// showing the number they had chosen. It survived because the interface
    /// reads the model and the model was right; only the engine disagreed, and
    /// nothing asked it. It is what made a scene carrying a gate threshold
    /// change nothing at all.
    ///
    /// Only the values actually stored: a knob nobody has touched is already
    /// sitting at the default this would send it.
    private func applyEffectValues() {
        for kind in enabledEffects {
            for parameter in kind.parameters {
                guard let value = effectValues["\(kind.rawValue).\(parameter.id)"] else {
                    continue
                }
                engine.setEffectParameter(parameter.id, of: kind, to: value)
            }
        }
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

    /// What the whole path costs, in milliseconds.
    ///
    /// One IO cycle, the destination's own reported latency and safety offset,
    /// and whatever the enabled stages add. The buffer alone was the only
    /// figure on show along the bottom of the window, and it is the flattering
    /// one: a chain adding 56 ms of voice isolation to a 2.7 ms buffer still
    /// read "2.67 ms" there. Zero when nothing is running, because there is no
    /// measurement to report rather than a very good one.
    var pathLatencyMilliseconds: Double {
        guard let quality = pathQuality, quality.sampleRate > 0 else { return 0 }
        let deviceFrames = Double(
            selectedDestination?.latencyFrames(scope: kAudioObjectPropertyScopeOutput) ?? 0)
        return (Double(quality.bufferFrames) + deviceFrames) / quality.sampleRate * 1000
            + addedLatencyMilliseconds
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
    private(set) var hotkeyFailures: [String] = []
    /// The combination each action actually got, which is not always the first
    /// one it asked for.
    private(set) var activeShortcuts: [HotkeyManager.Action: HotkeyManager.Shortcut] = [:]

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
    /// What each of the source's input channels carries, when the device is one
    /// whose topology is known.
    ///
    /// The interface used to say "this device reports 3 input channels; not all
    /// of them necessarily carry audio" — true, unhelpful, and on the Seiren V3
    /// Pro actively misleading. All three carry audio; they are three different
    /// versions of the same microphone, and picking the wrong one gets a signal
    /// that sounds nearly right.
    var sourceChannelNames: [DeviceChannelNames.Channel]? {
        guard let source = selectedSource else { return nil }
        return DeviceChannelNames.channels(
            modelUID: source.modelUID, name: source.name,
            scope: kAudioObjectPropertyScopeInput)
    }

    /// Label for one source channel, named where the device is known.
    func sourceChannelLabel(_ channel: Int) -> String {
        if let names = sourceChannelNames, channel < names.count {
            // Through loc() like everything else. The translations for these
            // were in both tables from the day the names were added and the
            // label was returning the raw English, so a Chinese interface
            // showed "After the expander" next to "單聲道".
            return loc(names[channel].name)
        }
        return "\(loc("Ch")) \(channel + 1)"
    }

    /// What the user still has to do somewhere else for any of this to matter.
    ///
    /// The application routed audio into a virtual device and never said the
    /// one thing it exists to enable: that the conferencing application has to
    /// be pointed at that device. Somebody could get everything here right,
    /// watch the meters move, and still be on a call with the wrong microphone.
    var nextStep: String? {
        guard isRunning, let destination = selectedDestination else { return nil }
        guard destination.transport.isVirtual else {
            // A real output is monitoring rather than routing somewhere, and
            // needs no further step.
            return nil
        }
        return String(
            format: loc("Now choose %@ as the microphone in Discord, Zoom or OBS."),
            destination.name)
    }

    /// The loopback endpoint standing in for our driver, when it is absent and
    /// something else is doing the job.
    var loopbackFallback: AudioDevice? {
        guard !isDriverInstalled else { return nil }
        return selectedDestination.flatMap { $0.transport.isVirtual ? $0 : nil }
    }

    var isDriverInstalled: Bool {
        outputDevices.contains { $0.uid == ClockAnchorPublisher.driverDeviceUID }
    }

    private var isRestoring = false

    init() {
        refreshDevices()
        // Before restoring, so a remembered plugin that has since been
        // uninstalled is dropped rather than failing to load on every start.
        refreshPlugins()
        userPresets = UserPresets.load()
        quickConfigs = QuickConfigStore.load()
        refreshHeadphoneProfiles()
        restore()

        engine.onClockLockFailure = { [weak self] in
            Task { @MainActor in self?.clockLockFailed = true }
        }

        // Hardware comes and goes; the route has to follow it rather than
        // silently pointing at a device that is no longer there.
        deviceWatcher = DeviceChangeWatcher { [weak self] in
            Task { @MainActor in self?.handleDeviceChange() }
        }

        installHotkeys()
        installMIDI()

        if autoStart, selectedSource != nil, selectedDestination != nil {
            start()
        }
    }

    // MARK: Push to talk

    /// Held to talk, released to go quiet.
    ///
    /// Off by default, and deliberately not the same switch as the mute button.
    /// Turning it on takes over the microphone's mute: while it is armed the
    /// microphone is muted unless the key is down, and the button reflects that
    /// rather than fighting it. The alternative — two independent notions of
    /// muted — is how somebody ends up broadcasting a room they were sure was
    /// silent.
    var isPushToTalkEnabled = false {
        didSet {
            guard oldValue != isPushToTalkEnabled else { return }
            // Arming it mutes immediately: the whole point is that silence is
            // the resting state. Disarming restores whatever the mute was
            // before, rather than leaving somebody muted by a feature they just
            // switched off.
            if isPushToTalkEnabled {
                muteBeforePushToTalk = isInputMuted
                isPushToTalkHeld = false
                isInputMuted = true
            } else {
                isInputMuted = muteBeforePushToTalk
            }
            persist()
        }
    }

    private(set) var isPushToTalkHeld = false
    @ObservationIgnored private var muteBeforePushToTalk = false

    private func setPushToTalk(held: Bool) {
        guard isPushToTalkEnabled else { return }
        guard isPushToTalkHeld != held else { return }
        isPushToTalkHeld = held
        isInputMuted = !held
    }

    // MARK: Hotkeys

    private func installHotkeys() {
        for action in HotkeyManager.Action.allCases {
            let handler: @Sendable (Bool) -> Void
            switch action {
            case .toggleRouting:
                handler = { [weak self] isPressed in
                    guard isPressed else { return }
                    MainActor.assumeIsolated { self?.toggle() }
                }
            case .toggleMute:
                handler = { [weak self] isPressed in
                    guard isPressed else { return }
                    MainActor.assumeIsolated { self?.toggleMute() }
                }
            case .pushToTalk:
                handler = { [weak self] isPressed in
                    MainActor.assumeIsolated { self?.setPushToTalk(held: isPressed) }
                }
            }
            // Work down the candidates until one is free. Another application
            // owning the first choice is common — both of the originals were
            // taken on the machine this was written on.
            let taken = action.candidateShortcuts.first { candidate in
                hotkeys.register(action, shortcut: candidate, handler: handler)
            }
            if let taken {
                activeShortcuts[action] = taken
            } else {
                // A shortcut that quietly does nothing is worse than none, so
                // this is said out loud rather than swallowed.
                hotkeyFailures.append(
                    String(
                        format: loc("No free shortcut for %@ — every combination is taken."),
                        action.title))
            }
        }
    }

    /// What the shortcuts page lists: the global hot keys with whatever
    /// combination they actually got, then the ones that work inside the
    /// window.
    ///
    /// The in-window shortcuts were missing from this page entirely — they were
    /// added to the views and nowhere else, which makes them undiscoverable
    /// except by accident.
    var hotkeyDescriptions: [(title: String, shortcut: String, isGlobal: Bool)] {
        var entries = HotkeyManager.Action.allCases.map { action in
            (
                action.title,
                (activeShortcuts[action] ?? action.defaultShortcut).displayName,
                true
            )
        }
        entries.append((loc("Start / stop routing"), "⌘↩", false))
        entries.append((loc("Record"), "⌘R", false))
        entries.append((loc("Mute / unmute"), "⌘M", false))
        for (index, preset) in RoutePreset.builtIn.enumerated() {
            entries.append((preset.name, "⌘\(index + 1)", false))
        }
        return entries
    }

    // MARK: MIDI

    /// Physical faders and pads. Everything it does lives in `MIDIControl.swift`;
    /// what is here is the ownership and the two lines of persistence.
    let midiControl = MIDIController()

    /// Written down on its own rather than through `persist()`, because a
    /// binding can be learned while a preset is being applied and `persist()`
    /// declines to write during those.
    func persistMIDIBindings() {
        var saved = PreferencesStore.load()
        saved.midiBindings = midiControl.storedBindings
        PreferencesStore.save(saved)
    }

    /// What the mute hotkey does, and what the menu bar glyph reflects.
    ///
    /// It used to mute every route one by one, which meant the shortcut also
    /// silenced any application audio being mixed in — pressing mute on a call
    /// stopped the music you were sharing too. And it kept its own flag, so the
    /// hotkey and the input mute button disagreed about whether the microphone
    /// was muted. Both were the same bug: a mute key means the microphone.
    func toggleMute() { isInputMuted.toggle() }

    /// True when the microphone is muted, whichever way it was done.
    var isMuted: Bool { isInputMuted }

    // MARK: Persistence

    /// Restores the saved route, resolving device UIDs against what is actually
    /// present now. A device that has gone missing leaves its slot empty rather
    /// than silently falling back to some other input.
    private func restore() {
        isRestoring = true
        defer { isRestoring = false }

        let saved = PreferencesStore.load()
        autoStart = saved.autoStart
        excludedAppBundleIDs = Set(saved.excludedAppBundleIDs ?? [])
        // A process with no bundle identifier is listed under its PID, and a
        // PID means nothing after a restart: the number gets reused, and the
        // capture would silently attach to whatever inherited it. Selecting one
        // of those is a decision about this session.
        capturedAppBundleIDs = Set(
            saved.capturedAppBundleIDs.filter {
                !$0.hasPrefix(AudioApplications.pidIdentityPrefix)
            })
        enabledEffects = Set(saved.enabledEffects.compactMap(EffectKind.init(rawValue:)))
        effectValues = saved.effectValues
        cancelsEcho = saved.cancelsEcho ?? false
        echoSpeakerUID = saved.echoSpeakerUID
        lighting.mode =
            saved.lightingMode.flatMap(LightingMode.init(rawValue:)) ?? .off
        lightingHue = saved.lightingHue ?? 0.55
        lighting.colour = RazerRing.hue(lightingHue)
        lightingBrightness = saved.lightingBrightness ?? 1
        inputDecibels = saved.inputDecibels ?? 0
        isInputMuted = saved.isInputMuted ?? false
        outputDecibels = saved.outputDecibels ?? 0
        isOutputMuted = saved.isOutputMuted ?? false
        loudnessTarget =
            saved.loudnessTarget.flatMap(LoudnessTarget.init(rawValue:)) ?? .discord
        outputDelays = saved.outputDelays ?? [:]
        headphoneProfileName = saved.headphoneProfileName
        if let bands = saved.graphicEQ, bands.count == 10 { graphicEQ = bands }
        recentSourceUIDs = saved.recentSourceUIDs ?? []
        recentDestinationUIDs = saved.recentDestinationUIDs ?? []
        monitorDecibels = saved.monitorDecibels ?? -6
        isAutoLevelling = saved.isAutoLevelling ?? false
        duckDecibels = saved.duckDecibels ?? -14
        isDucking = saved.isDucking ?? false
        sourceRoles = (saved.sourceRoles ?? [:]).compactMapValues(
            LevelCalibration.Role.init(rawValue:))
        isPushToTalkEnabled = saved.isPushToTalkEnabled ?? false
        enabledPlugins = saved.plugins ?? []
        pluginValues = saved.pluginValues ?? [:]
        voicePreset = saved.voicePreset.flatMap(VoicePreset.init(rawValue:)) ?? .none
        recordsStems = saved.recordsStems ?? false
        monitorSends = saved.monitorSends ?? [:]
        // Only restored when the device is actually present: a monitor pointing
        // at headphones that are not plugged in would fail the whole start.
        if let uid = saved.monitorDeviceUID,
            outputDevices.contains(where: { $0.uid == uid })
        {
            monitorDeviceUID = uid
        }
        style = saved.style.flatMap(YunStyle.init(rawValue:)) ?? .flat
        YunTheme.shared.style = style
        voiceIsolationEnabled = enabledEffects.contains(.voiceIsolation)
        voiceIsolationMix = saved.voiceIsolationMix
        preferredSampleRate = saved.preferredSampleRate
        bufferFrames =
            Self.bufferSizes.contains(saved.bufferFrames) ? saved.bufferFrames : 128
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
        guard !isRestoring, !isApplyingPreset, !isAutoAdjusting else { return }
        PreferencesStore.save(
            Preferences(
                sourceDeviceUID: selectedSourceUID,
                destinationDeviceUID: selectedDestinationUID,
                channelMode: channelMode.rawValue,
                monoChannel: monoChannel,
                bufferFrames: bufferFrames,
                autoStart: autoStart,
                voiceIsolationEnabled: voiceIsolationEnabled,
                voiceIsolationMix: voiceIsolationMix,
                preferredSampleRate: preferredSampleRate,
                capturedAppBundleIDs: Array(capturedAppBundleIDs),
                excludedAppBundleIDs: Array(excludedAppBundleIDs),
                enabledEffects: enabledEffects.map(\.rawValue),
                effectValues: effectValues,
                cancelsEcho: cancelsEcho,
                echoSpeakerUID: echoSpeakerUID,
                style: style.rawValue,
                lightingMode: lighting.mode.rawValue,
                lightingHue: lightingHue,
                lightingBrightness: lightingBrightness,
                inputDecibels: inputDecibels,
                isInputMuted: isInputMuted,
                outputDecibels: outputDecibels,
                isOutputMuted: isOutputMuted,
                loudnessTarget: loudnessTarget.rawValue,
                monitorDeviceUID: monitorDeviceUID,
                monitorDecibels: monitorDecibels,
                isAutoLevelling: isAutoLevelling,
                isDucking: isDucking,
                duckDecibels: duckDecibels,
                sourceRoles: sourceRoles.mapValues(\.rawValue),
                isPushToTalkEnabled: isPushToTalkEnabled,
                plugins: enabledPlugins,
                pluginValues: pluginValues,
                voicePreset: voicePreset.rawValue,
                recordsStems: recordsStems,
                monitorSends: monitorSends,
                outputDelays: outputDelays,
                headphoneProfileName: headphoneProfileName,
                graphicEQ: graphicEQ,
                recentSourceUIDs: recentSourceUIDs,
                recentDestinationUIDs: recentDestinationUIDs,
                // Written on every save, not only when a binding changes: this
                // rebuilds the whole file, so leaving it out would quietly
                // erase somebody's controller the next time they moved a fader.
                midiBindings: midiControl.storedBindings))
    }

    // MARK: Devices

    func refreshDevices() {
        let all = (try? AudioDevices.all()) ?? []
        inputDevices = all.filter(\.hasInput)
        outputDevices = all.filter(\.hasOutput)
        for device in all { deviceNames[device.uid] = device.name }
    }

    private func selectDefaults() {
        if selectedSourceUID == nil {
            // Prefer the system input, but never a loopback — and least of all
            // our own device.
            //
            // The comment saying so was here from the start and the code never
            // did it. It matters more than it looks: the point of this app is
            // that the conferencing application uses YunAudio, so somebody will
            // set YunAudio as the system input, and then the app picked its own
            // destination as its source and refused to start with "the input
            // and the output cannot be the same device" — on a first run, with
            // nothing to suggest what to change.
            let systemInput = try? AudioDevices.defaultInput()
            let realInput = systemInput.flatMap { device in
                device.transport.isVirtual ? nil : device
            }
            selectedSourceUID =
                realInput.map(\.uid)
                ?? inputDevices.first { $0.transport == .usb }?.uid
                ?? inputDevices.first { !$0.transport.isVirtual }?.uid
                ?? inputDevices.first?.uid
        }
        // Whatever the source ended up as, it must not also be the destination.
        // Two faces of one headset count as the same device here too, or the
        // default selection quietly picks a Bluetooth headset's microphone and
        // its own speakers and the route cannot be built at all.
        if let source = selectedSourceUID, let destination = selectedDestinationUID,
            isSamePhysicalDevice(source, destination)
        {
            selectedSourceUID =
                inputDevices.first {
                    !$0.transport.isVirtual && !isSamePhysicalDevice($0.uid, destination)
                }?.uid
                ?? inputDevices.first { !isSamePhysicalDevice($0.uid, destination) }?.uid
        }
        if selectedDestinationUID == nil {
            // Our own device first, then any other loopback endpoint. Never a
            // real output: routing the microphone into the speakers the moment
            // someone presses Start is an acoustic feedback loop, and "it
            // preselected something" is no defence for handing a user howling
            // feedback in a call.
            selectedDestinationUID =
                outputDevices
                .first { $0.uid == ClockAnchorPublisher.driverDeviceUID }?.uid
                ?? outputDevices.first { $0.transport.isVirtual && $0.inputChannels > 0 }?.uid
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
        // A device whose topology is known says which channel is the one
        // anybody wants, which is better than the first one by position: on the
        // Seiren the first is right, but that is luck rather than a rule.
        if let names = sourceChannelNames,
            let preferred = names.firstIndex(where: \.isDefault)
        {
            channelMode = .mono
            monoChannel = preferred
            return
        }
        channelMode =
            source.inputChannels % 2 == 0 && source.inputChannels >= 2
            ? .stereo : .mono
        monoChannel = 0
    }

    /// True when routing stopped because hardware went away, rather than
    /// because anybody asked it to.
    ///
    /// A flag of its own, not `lastError != nil`. Using the error as the marker
    /// meant that any unrelated failure — a start that found no usable
    /// channels, a recording that could not be written — armed the resume, and
    /// then plugging in headphones started routing that nobody had asked for.
    private var wasInterruptedByDeviceLoss = false

    private func handleDeviceChange() {
        refreshDevices()

        // Taking a device back has to happen before noticing one is missing,
        // or unplugging the fallback while the original is already home again
        // would fall back a second time from a device nobody is using.
        restoreDisplacedDevices()

        // A device list read once during a change is not evidence that anything
        // was unplugged. Creating an aggregate — which this application does
        // itself, and which the flow check does deliberately — produces a burst
        // of notifications, and the enumeration in the middle of one can be
        // missing a device that is perfectly well plugged in.
        //
        // That was harmless when the response was to stop and wait. It is not
        // harmless now that the response is to move the route: acting on a
        // transient would take somebody off their microphone mid-sentence and
        // leave them on the built-in one, for no reason they could see. So a
        // disappearance is confirmed before it is believed. Unplugging is not
        // urgent to the millisecond.
        // A device coming *back* needs no confirmation: starting a route
        // requires both ends to be present, so acting on a transient can only
        // fail harmlessly. Only a disappearance is worth waiting on.
        if !isMissingDevice, !isRunning, wasInterruptedByDeviceLoss {
            wasInterruptedByDeviceLoss = false
            lastError = nil
            start()
            return
        }

        guard isMissingDevice else { return }
        confirmationTask?.cancel()
        confirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.refreshDevices()
            guard self.isMissingDevice else { return }
            self.handleConfirmedDeviceLoss()
        }
    }

    @ObservationIgnored private var confirmationTask: Task<Void, Never>?

    /// Every device name seen since launch, by UID.
    ///
    /// Kept because the one moment a name is wanted is after the device has
    /// gone: "standing in for the Seiren" is a sentence, and "standing in for
    /// AppleUSBAudioEngine:Razer:…" is not.
    @ObservationIgnored private var deviceNames: [String: String] = [:]

    /// True when either end of the route is not in the device list.
    private var isMissingDevice: Bool {
        let sourceGone =
            selectedSourceUID.map { uid in !inputDevices.contains { $0.uid == uid } } ?? false
        let destinationGone =
            selectedDestinationUID.map { uid in
                !outputDevices.contains { $0.uid == uid }
            } ?? false
        return sourceGone || destinationGone
    }

    private func handleConfirmedDeviceLoss() {
        let sourceGone =
            selectedSourceUID.map { uid in
                !inputDevices.contains { $0.uid == uid }
            } ?? false
        let destinationGone =
            selectedDestinationUID.map { uid in
                !outputDevices.contains { $0.uid == uid }
            } ?? false

        // Unplugging the microphone used to stop everything and wait. That is
        // the right answer only when there is nowhere else to go: somebody on a
        // call whose USB microphone falls out wants the call to carry on
        // through the built-in one, and wants their own microphone back the
        // moment it is plugged in again — not a stopped router and an error.
        if sourceGone, let lost = selectedSourceUID,
            let replacement = Self.replacement(
                for: lost, recent: recentSourceUIDs, available: inputDevices.map(\.uid))
        {
            let name = deviceNames[lost]
            substituting {
                displacedSourceUID = lost
                displacedSourceName = name ?? lost
                selectedSourceUID = replacement
            }
            lastError = loc("The microphone was unplugged; carrying on with another.")
        }
        if destinationGone, let lost = selectedDestinationUID,
            let replacement = Self.replacement(
                for: lost, recent: recentDestinationUIDs,
                available: outputDevices.map(\.uid))
        {
            let name = deviceNames[lost]
            substituting {
                displacedDestinationUID = lost
                displacedDestinationName = name ?? lost
                selectedDestinationUID = replacement
            }
            lastError = loc("The output was unplugged; carrying on with another.")
        }

        let stillGone =
            (sourceGone && displacedSourceUID == nil)
            || (destinationGone && displacedDestinationUID == nil)
        if isRunning, stillGone {
            stop()
            wasInterruptedByDeviceLoss = true
            lastError = loc("A device in the route was unplugged.")
        }
    }

    private func restoreDisplacedDevices() {
        if let wanted = displacedSourceUID, inputDevices.contains(where: { $0.uid == wanted }) {
            substituting {
                displacedSourceUID = nil
                displacedSourceName = nil
                selectedSourceUID = wanted
            }
            lastError = nil
        }
        if let wanted = displacedDestinationUID,
            outputDevices.contains(where: { $0.uid == wanted })
        {
            substituting {
                displacedDestinationUID = nil
                displacedDestinationName = nil
                selectedDestinationUID = wanted
            }
            lastError = nil
        }
    }

    /// Puts a device at the front of the list of ones used before.
    static func remember(_ uid: String?, in recent: [String], limit: Int = 8) -> [String] {
        guard let uid else { return recent }
        return Array(([uid] + recent.filter { $0 != uid }).prefix(limit))
    }

    /// What the route should use instead of a device that has gone.
    ///
    /// The most recently used one that is actually present, because that is
    /// almost always where somebody wants to land — the microphone they were on
    /// yesterday rather than whatever the system enumerates first. Falls back
    /// to any present device rather than to nothing: carrying on through the
    /// wrong microphone is recoverable, and a stopped call is not.
    ///
    /// - Returns: Nil when there is nothing left to move to, which is the one
    ///   case where stopping is right.
    static func replacement(for lost: String, recent: [String], available: [String]) -> String?
    {
        let usable = available.filter { $0 != lost }
        guard !usable.isEmpty else { return nil }
        return recent.first { usable.contains($0) } ?? usable.first
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

    func start() { start(selftest: false) }

    /// - Parameter selftest: Installs the loopback integrity check alongside
    ///   the routes. It overwrites one destination channel with a known
    ///   sequence, so it is never on for ordinary routing.
    func start(selftest: Bool) {
        guard !isBusy else { return }
        guard let source = selectedSourceUID, let destination = selectedDestinationUID else {
            lastError = loc("Pick an input and an output first.")
            return
        }
        // Not merely a different UID. A wireless headset presents as two
        // separate CoreAudio devices — the Razer Barracuda is
        // "44-…-69:input" and "44-…-69:output", same name, same model — and
        // routing one to the other is routing a headset into itself. It passes
        // every UID comparison and then fails deep inside the aggregate with
        // "output channel 1 is not part of the aggregate", which is true and
        // tells nobody anything.
        guard !isSamePhysicalDevice(source, destination) else {
            lastError = loc("The input and the output cannot be the same device.")
            return
        }
        guard source != destination else {
            lastError = loc("The input and the output cannot be the same device.")
            return
        }
        // Only when something is going to be tapped. Enumerating every audio
        // process on the machine costs 27 ms warm and 118 cold, and it was
        // being paid on every start — including the ones with nothing captured
        // at all, which is most of them, and including every restart caused by
        // a setting changing. It buys the process identifiers for the
        // applications about to be tapped, and if there are none it buys
        // nothing.
        if !capturedAppBundleIDs.isEmpty { refreshApps() }
        var routeList = routes
        var taps: [ProcessTap] = []

        // Application audio joins as extra source channels on the same
        // aggregate, so a tapped app is addressable exactly like a microphone.
        // One tap per application rather than one tap for all of them.
        //
        // A single stereo mixdown of every captured process is cheaper, and it
        // was what shipped — but it makes Discord and Spotify the same source,
        // which means they cannot be given different volumes, different roles
        // or different treatment when somebody talks. Balancing a voice call
        // against background music is the whole reason anybody captures two
        // applications at once, and it was the one thing the single tap could
        // not express.
        let capturedApps = availableApps.filter {
            capturedAppBundleIDs.contains($0.bundleID) && !$0.processIDs.isEmpty
        }
        tapOwners = [:]
        if !capturedApps.isEmpty {
            let destinationChannels = min(2, selectedDestination?.outputChannels ?? 0)
            var failed: [String] = []
            for app in capturedApps {
                guard
                    let tap = try? ProcessTap(
                        processIDs: app.processIDs, muteBehavior: tapMuteBehavior)
                else {
                    failed.append(app.name)
                    continue
                }
                taps.append(tap)
                tapOwners[tap.uid] = app.bundleID
                let tapChannels = Int(tap.format?.mChannelsPerFrame ?? 2)
                for channel in 0..<min(destinationChannels, tapChannels) {
                    routeList.append(
                        Route(
                            source: ChannelRef(deviceUID: tap.uid, channel: channel),
                            destination: ChannelRef(
                                deviceUID: destination, channel: channel),
                            // Only application audio gets out of the way. The
                            // microphone never does.
                            isDuckable: true))
                }
            }
            if !failed.isEmpty {
                lastError = String(
                    format: loc("%@ could not be captured."),
                    failed.joined(separator: ", "))
            }
        }

        // Monitoring last, so its routes sit at the end and their indices are
        // stable regardless of how many applications are being captured.
        // A second mix, not a monitor for the microphone alone.
        //
        // Every tool people praise for this — Wave Link, RØDE Connect,
        // VoiceMeeter — is praised for the same thing: two independent mixes,
        // one for what the far end hears and one for what you hear, with a
        // separate level per source on each. Music loud in your ears and quiet
        // on the stream is the case, and it cannot be expressed with one set of
        // faders however many of them there are.
        //
        // The monitor used to carry the microphone and nothing else, which is a
        // sidetone rather than a mix.
        monitorRouteIndices = [:]
        if let monitorUID = monitorDeviceUID,
            let monitor = outputDevices.first(where: { $0.uid == monitorUID })
        {
            let monitorChannels = min(2, monitor.outputChannels)
            // Every source already in the main mix, each at its own send.
            // Grouped by source so a stereo source keeps its sides.
            var bySource: [String: [Route]] = [:]
            var order: [String] = []
            for route in routeList {
                let uid = route.source.deviceUID
                if bySource[uid] == nil { order.append(uid) }
                bySource[uid, default: []].append(route)
            }

            for uid in order {
                let level = monitorSendDecibels(forSource: uid)
                guard level > Self.minimumDecibels else { continue }
                let gain = Self.gain(fromDecibels: level)
                let members = bySource[uid] ?? []
                var indices: [Int] = []
                for channel in 0..<monitorChannels {
                    // A mono source feeds both ears; a stereo one keeps its
                    // sides.
                    let taken = members[min(channel, members.count - 1)]
                    indices.append(routeList.count)
                    routeList.append(
                        Route(
                            source: taken.source,
                            destination: ChannelRef(
                                deviceUID: monitorUID, channel: channel),
                            gain: gain,
                            // Application audio ducks on the monitor too, or
                            // talking over music sounds different in your ears
                            // from how it sounds to everybody else.
                            isDuckable: taken.isDuckable))
                }
                monitorRouteIndices[uid] = indices
            }
        }

        guard !routeList.isEmpty else {
            lastError = loc("Those two devices share no usable channels.")
            return
        }

        clockLockFailed = false
        isBusy = true

        let engine = engine
        let effects = Array(enabledEffects)
        let pluginList = enabledPlugins
        let isolation =
            enabledEffects.contains(.voiceIsolation)
            ? VoiceIsolationSettings(mixPercent: voiceIsolationMix) : nil
        let rate = preferredSampleRate
        let buffer = bufferFrames
        let handle = TapHandle(taps: taps)
        // The far end is whatever the user chose to mix in. If they picked
        // nothing, every application currently making noise is used instead:
        // the point of the reference is to know what came out of the speaker,
        // and asking someone to name that twice would be asking them to do the
        // app's job.
        // The exclusion reaches this too. A reference tap only listens — it
        // does not redirect anything — but somebody who said "never touch
        // Logic" did not mean "except when guessing what the speakers are
        // playing", and the difference is not one they should have to know.
        let echo = echoSettings(
            fallbackProcessIDs:
                availableApps
                .filter { $0.isPlaying && !excludedAppBundleIDs.contains($0.bundleID) }
                .flatMap(\.processIDs))
        let monitor = monitorDeviceUID
        let trim = outputLatencyFrames
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
                    monitorDeviceUID: monitor,
                    effects: effects,
                    plugins: pluginList,
                    preferredSampleRate: rate,
                    bufferFrames: buffer,
                    voiceIsolation: isolation,
                    echoCancellation: echo,
                    outputLatencyTrim: trim,
                    selftest: selftest)
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
                // The engine holds these across a restart, but the model is the
                // one that knows what the user set, so it re-asserts them.
                self.engine.setInputGain(Self.gain(fromDecibels: self.inputDecibels))
                self.engine.setInputMuted(self.isInputMuted)
                self.engine.setOutputGain(Self.gain(fromDecibels: self.outputDecibels))
                self.engine.setOutputMuted(self.isOutputMuted)
                self.applyEffectValues()
                self.activeRoutes = routes
                self.routeGains = routes.map(\.gain)
                self.routeMutes = routes.map(\.isMuted)
                // The analysers are built per run, because the K-weighting
                // coefficients and the FFT bin mapping both depend on the rate
                // the aggregate settled on.
                self.startAnalysis(sampleRate: self.engine.pathQuality?.sampleRate ?? 48000)
                // After the graph exists, not before: the correction names an
                // output buffer, and there are no buffers until the aggregate
                // is built.
                self.applyHeadphoneCorrection()
                self.startPolling()
            }
        }
    }

    func stop() {
        wasInterruptedByDeviceLoss = false
        stop(then: nil)
    }

    /// - Parameter completion: Runs on the main actor once the engine is fully
    ///   down and `isBusy` has been cleared, so a caller can start again.
    func stop(then completion: (@MainActor () -> Void)? = nil) {
        guard !isBusy else { return }
        isBusy = true
        let engine = engine
        engineQueue.async {
            engine.stop()
            Task { @MainActor in
                self.isBusy = false
                self.finishStop()
                completion?()
            }
        }
    }

    private func finishStop() {
        isRunning = false
        // The engine tore the recorder down with the route, so the flag has to
        // follow or the button would claim a recording is still running against
        // a file nothing is writing to.
        if isRecording {
            // Same ordering trap as above, one step removed: by the time this
            // runs the engine has already stopped and the recorder is gone, so
            // the last polled value is the honest one to keep.
            isRecording = false
        }
        stopPolling()
        stopAnalysis()
        // Transcription goes down with the route it was listening to, but the
        // transcript stays: it is what somebody was there for, and losing it
        // because a device changed underneath would be the worst moment to.
        if isTranscribing { stopTranscribing() }
        levels = []
        peakHolds = []
        clipped = []
        activeRoutes = []
        routeGains = []
        routeMutes = []
        pathQuality = nil
        isClockLocked = false
    }

    func toggle() { isRunning ? stop() : start() }

    /// Carries out something another program asked for.
    ///
    /// - Returns: What happened, in a sentence, or nil when the command named
    ///   something this application does not have. The caller says it out loud
    ///   rather than swallowing it: a scene renamed since somebody wired a
    ///   button to it should not fail silently.
    @discardableResult
    func perform(_ command: RemoteCommand) -> String? {
        switch command {
        case .routing(let wanted):
            let target = wanted ?? !isRunning
            if target != isRunning { target ? start() : stop() }
            return target ? loc("Routing started.") : loc("Routing stopped.")
        case .mute(let wanted):
            isInputMuted = wanted ?? !isInputMuted
            return isInputMuted ? loc("Microphone muted.") : loc("Microphone unmuted.")
        case .record(let wanted):
            let target = wanted ?? !isRecording
            if target != isRecording { toggleRecording() }
            return isRecording ? loc("Recording.") : loc("Recording stopped.")
        case .transcribe(let wanted):
            let target = wanted ?? !isTranscribing
            if target, !isTranscribing {
                startTranscribing()
            } else if !target, isTranscribing {
                stopTranscribing()
            }
            return isTranscribing ? loc("Transcribing.") : loc("Transcription stopped.")
        case .config(let name):
            guard
                let configuration = quickConfigs.first(where: {
                    $0.name.compare(name, options: .caseInsensitive) == .orderedSame
                })
            else { return nil }
            let outcome = apply(configuration)
            return outcome.isComplete
                ? configuration.name
                : configuration.name + " — " + loc("missing") + " "
                    + describeMissing(outcome.missing)
        case .preset(let name):
            // Matched without case, because a URL somebody typed will not have
            // the capitals right and refusing over that is pedantry.
            guard
                let preset = allPresets.first(where: {
                    loc($0.name).compare(name, options: .caseInsensitive) == .orderedSame
                        || $0.name.compare(name, options: .caseInsensitive) == .orderedSame
                })
            else { return nil }
            apply(preset)
            return loc(preset.name)
        }
    }

    /// Tears everything down synchronously.
    ///
    /// Called while the application is quitting, so it cannot hop to a queue and
    /// hope to be finished — the process may be gone before the closure runs.
    /// The 17 ms this blocks for is the price of not leaving someone's hardware
    /// reconfigured.
    func shutDown() {
        hotkeys.tearDown()
        midiControl.tearDown()
        stopPolling()
        stopAnalysis()
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
    /// Set while a preset is being applied, so half a dozen property writes
    /// produce one restart instead of one each.
    ///
    /// Applying a preset moved the isolation flag, the channel mode and the
    /// sample rate, and each of those restarted the route on its own — three
    /// teardowns and three rebuilds for one click, with the audio dropping at
    /// every one.
    private var isApplyingPreset = false

    /// Runs `changes` as one edit: nothing restarts until they are all in.
    func batched(_ changes: () -> Void) {
        guard !isApplyingPreset else {
            changes()
            return
        }
        isApplyingPreset = true
        changes()
        isApplyingPreset = false
        persist()
        restartIfRunning()
    }

    /// Rebuilds triggered since launch. Only for the flow check, which asserts
    /// that one preset costs one rebuild — the alternative is a race, not
    /// merely waste: back-to-back restarts hit `stop`'s busy guard and are
    /// dropped, so whether the final settings reach the engine depends on how
    /// fast the engine queue happens to be.
    private(set) var restartCount = 0

    private func restartIfRunning() {
        guard !isApplyingPreset else { return }
        guard isRunning else { return }
        restartCount += 1
        // stop() is asynchronous and holds `isBusy` until the engine queue has
        // finished, so calling start() straight after it hits the busy guard and
        // the route never comes back. Chain them instead.
        stop {
            self.start()
        }
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

    /// What the poll cost and how much of it nobody needed.
    ///
    /// Kept out of observation on purpose: a counter of invalidations that
    /// itself invalidated every view would be a fine joke and a poor
    /// measurement.
    struct PollCost: Sendable {
        var polls = 0
        /// Wall-clock seconds spent inside `poll()`.
        var seconds = 0.0
        /// Observable properties the poll assigned to.
        var writes = 0
        /// How many of those assignments were the value already there.
        var unchanged = 0
    }

    @ObservationIgnored private(set) var pollCost = PollCost()

    /// Seconds spent in each part of the poll, while somebody is asking.
    ///
    /// Off by default and switched on by the flow check around its own
    /// measurement. Left permanently on it would be eleven string hashes a poll
    /// against a budget of about a hundred microseconds, which is a
    /// measurement large enough to be part of what it measures.
    @ObservationIgnored var measuresPollBreakdown = false
    @ObservationIgnored private(set) var pollBreakdown: [String: Double] = [:]

    func resetPollCost() {
        pollCost = PollCost()
        pollBreakdown = [:]
    }

    /// How many polls apart the path verdict is re-read.
    ///
    /// `engine.pathQuality` is not a stored value: answering it asks the HAL
    /// which sub-devices are being drift-corrected, whether the destination
    /// attenuates, what the buffer size is and what the sample rate is — half a
    /// dozen synchronous round trips to `coreaudiod`. Measured at **1478 µs**,
    /// which at twenty hertz was 2.96% of one core spent re-deriving a verdict
    /// that only changes when somebody changes a device.
    ///
    /// Ten polls is twice a second. Nothing that can move it happens faster
    /// than a person: every one of its inputs is on the far side of a route
    /// rebuild, which is seconds of device work. It is also re-read
    /// unconditionally whenever there is no verdict yet, so a route coming up
    /// reports immediately rather than up to half a second later — that
    /// mattered, because "say when the path is no longer clean" is a promise
    /// this application makes and a stale pill would be breaking it.
    private static let pathQualityEveryNPolls = 10

    @ObservationIgnored private var pollsSincePathQuality = 0

    /// Assigns only when the value actually moved.
    ///
    /// Every stored property of an `@Observable` publishes on *assignment*, not
    /// on change. `pathQuality = engine.pathQuality` therefore invalidates every
    /// view that ever read it, twenty times a second, whether or not the verdict
    /// has moved — and the verdict moves when somebody switches a device.
    /// Measured on an idle running route with the window open, seven of the nine
    /// properties this poll writes never changed at all, and the two that did
    /// were the meters.
    ///
    /// The comparison is not free, but it is a float or a small enum against a
    /// SwiftUI body re-evaluation, and it is not close.
    private func publish<Value: Equatable>(
        _ value: Value, to keyPath: ReferenceWritableKeyPath<RouterModel, Value>
    ) {
        pollCost.writes += 1
        guard self[keyPath: keyPath] != value else {
            pollCost.unchanged += 1
            return
        }
        self[keyPath: keyPath] = value
    }

    private func poll() {
        guard isRunning else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            pollCost.polls += 1
            pollCost.seconds +=
                Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        }
        func lap(_ name: String, _ body: () -> Void) {
            guard measuresPollBreakdown else { return body() }
            let entered = DispatchTime.now().uptimeNanoseconds
            body()
            pollBreakdown[name, default: 0] +=
                Double(DispatchTime.now().uptimeNanoseconds - entered) / 1e9
        }
        lap("routePeaks") { publish(engine.routePeaks, to: \.levels) }
        lap("refreshPeaks") { refreshPeaks(levels) }
        // Twice a second rather than twenty times, and at once when there is no
        // verdict yet. See `pathQualityEveryNPolls`.
        pollsSincePathQuality += 1
        if pathQuality == nil || pollsSincePathQuality >= Self.pathQualityEveryNPolls {
            pollsSincePathQuality = 0
            lap("pathQuality") { publish(engine.pathQuality, to: \.pathQuality) }
        }
        lap("isClockLocked") { publish(engine.isClockLocked, to: \.isClockLocked) }
        lap("rateRatio") { publish(engine.measuredRateRatio, to: \.measuredRateRatio) }
        lap("recordingState") { refreshRecordingState() }
        lap("outputPeak") { publish(engine.outputPeak, to: \.outputPeak) }
        lap("failedPlugins") { publish(engine.failedPlugins, to: \.failedPlugins) }
        lap("clipped") { publish(engine.outputClippedSamples, to: \.outputClippedSamples) }
        // Drained every poll whether or not the analysis panel is open. The ring
        // is finite, so a consumer that only ran while a view was visible would
        // hand the loudness meter a stream with holes in it and report an
        // integrated figure for audio it never saw.
        lap("analysisNeeds") { refreshAnalysisNeeds() }
        lap("analyser") {
            if let analyser, !analyser.isIdle {
                analyser.drain(from: engine)
                analysis = analyser.reading()
            }
        }
        if isTranscribing { pumpTranscription() }
        lap("nowPlaying") { if isSingingVisible { refreshNowPlaying() } }
        lap("gainReduction") { refreshGainReduction() }
        lap("ducking") { refreshDucking() }
        if isAutoLevelling { stepAutoLevel() }
        // The ring follows the loudest route, which is what a single ring can
        // honestly represent when several are running.
        lap("lighting") { lighting.update(level: levels.max() ?? 0, isMuted: isInputMuted) }
    }

    // MARK: Transcription

    /// True while every source is being written down.
    private(set) var isTranscribing = false
    /// Everything said so far, from every source, in the order it was said.
    private(set) var transcript: [Transcriber.Line] = []
    /// Set when transcription could not start, in words somebody can act on.
    private(set) var transcriptionError: String?

    /// Nil when this system can transcribe, otherwise why it cannot.
    ///
    /// The interface shows the control either way — a feature that vanishes on
    /// an older system is one nobody can find out about — and puts this
    /// underneath it when it is there.
    var transcriptionUnavailableReason: String? {
        Transcriber.unsupportedReason.map(Self.describe)
    }

    @ObservationIgnored private var transcribers: [Transcriber] = []
    /// Reused across polls. Two seconds at 48 kHz, which is more than the ring
    /// behind it holds, so a drain is never cut short by this buffer.
    @ObservationIgnored private var transcriptScratch = [Float](repeating: 0, count: 96_000)
    @ObservationIgnored private var transcriptRate: Double = 48000

    /// Starts writing down what every source says, each under its own name.
    ///
    /// One transcriber per source is the whole trick. Nothing here works out
    /// who is speaking, because nothing ever mixed them together — the
    /// microphone is one tap and each captured application is another, so the
    /// name on a line is the wiring rather than a guess that is sometimes
    /// wrong.
    func startTranscribing() {
        guard !isTranscribing else { return }
        guard isRunning else {
            transcriptionError = loc("Start routing before transcribing.")
            return
        }
        if let reason = Transcriber.unsupportedReason {
            transcriptionError = Self.describe(reason)
            return
        }

        let groups = sourceGroups
        let first = groups.compactMap(\.routes.first)
        guard !first.isEmpty else {
            transcriptionError = loc("Nothing is routed to transcribe.")
            return
        }
        let opened = engine.startTranscriptTaps(routes: first)
        guard opened > 0 else {
            transcriptionError = loc("Could not listen to any source.")
            return
        }

        transcriptRate = engine.pathQuality?.sampleRate ?? 48000
        transcribers = groups.prefix(opened).map { group in
            Transcriber(speaker: representative(of: group).map(routeTitle) ?? loc("Source"))
        }
        isTranscribing = true
        transcriptionError = nil

        // Started together rather than one at a time: the first model load
        // fetches assets, and serialising that would leave the second source
        // unheard for as long as the first one took.
        let starting = transcribers
        let now = Date().timeIntervalSince1970
        Task { @MainActor in
            for transcriber in starting {
                do {
                    try await transcriber.start(now: now)
                } catch {
                    self.transcriptionError = Self.describe(error)
                    self.stopTranscribing()
                    return
                }
            }
        }
    }

    func stopTranscribing() {
        guard isTranscribing else { return }
        isTranscribing = false
        engine.stopTranscriptTaps()
        let finishing = transcribers
        transcribers = []
        // Finalised rather than dropped: the model is holding the end of the
        // last sentence, and a transcript that stops mid-word because somebody
        // pressed a button is not what they asked for.
        Task { @MainActor in
            for transcriber in finishing { await transcriber.stop() }
            await self.collectTranscript(from: finishing)
        }
    }

    /// Moves audio from the rings to the models, and lines back.
    private func pumpTranscription() {
        let rate = transcriptRate
        for (slot, transcriber) in transcribers.enumerated() {
            let taken = transcriptScratch.withUnsafeMutableBufferPointer { buffer in
                engine.drainTranscript(
                    slot, into: buffer.baseAddress!, capacity: buffer.count)
            }
            guard taken > 0 else { continue }
            transcriber.add(Array(transcriptScratch[0..<taken]), sampleRate: rate)
        }
        let running = transcribers
        Task { @MainActor in await self.collectTranscript(from: running) }
    }

    private func collectTranscript(from transcribers: [Transcriber]) async {
        var merged: [Transcriber.Line] = []
        for transcriber in transcribers { merged += await transcriber.lines }
        // Sorted across sources, which is the point of doing it here rather
        // than per transcriber: two people talking is one conversation, and a
        // transcript that lists one person's half and then the other's is not
        // a record of it.
        merged.sort { $0.start < $1.start }
        if merged != transcript { transcript = merged }
    }

    /// The transcript as somebody would read it, attributed and timestamped.
    var transcriptText: String {
        transcript.map { line in
            String(
                format: "[%02d:%02d] %@: %@", Int(line.start) / 60, Int(line.start) % 60,
                line.speaker, line.text)
        }.joined(separator: "\n")
    }

    /// Writes the transcript beside the recordings.
    @discardableResult
    func saveTranscript() -> URL? {
        guard !transcript.isEmpty else { return nil }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let url = recordingDirectory.appendingPathComponent(
            "YunAudio \(stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")).txt"
        )
        do {
            try transcriptText.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            transcriptionError = String(describing: error)
            return nil
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let unavailable = error as? Transcriber.Unavailable else {
            return String(describing: error)
        }
        return describe(unavailable)
    }

    private static func describe(_ unavailable: Transcriber.Unavailable) -> String {
        switch unavailable {
        case .needsNewerSystem: loc("Live transcription needs macOS 27.")
        case .noModel: loc("No transcription model is installed.")
        case .unsupportedLanguage(let identifier): loc("No model for") + " \(identifier)"
        case .failed(let reason): reason
        }
    }

    // MARK: Analysis

    /// Loudness and spectrum, computed off the routed signal.
    private(set) var analysis: SignalAnalyser.Reading = .silent
    @ObservationIgnored private var analyser: SignalAnalyser?

    /// Set by the panel that draws the spectrum, so a closed panel costs nothing
    /// beyond the drain the meters need anyway.
    var isAnalysisVisible = false {
        didSet {
            guard isAnalysisVisible, !oldValue else { return }
            // Only when there is something to read from. The fallback used to
            // be `?? .silent`, which meant opening the window while nothing was
            // running replaced whatever was on screen with dashes — and wiped
            // the fixture the design captures depend on, so the analysis card
            // rendered empty in every one of them.
            guard let analyser else { return }
            analysis = analyser.reading()
        }
    }

    /// The platform the loudness readout is compared against.
    var loudnessTarget: LoudnessTarget = .discord {
        didSet {
            guard oldValue != loudnessTarget else { return }
            persist()
        }
    }

    /// How far the session sits from the chosen target, or nil while there is
    /// not yet enough material for the integrated figure to mean anything.
    ///
    /// Ten seconds is the threshold because the relative gate needs a mean to
    /// work against: before that the number swings by several units and would
    /// be read as a measurement.
    var loudnessOffset: Double? {
        guard analysis.duration >= 10, analysis.integrated.isFinite else { return nil }
        return analysis.integrated - loudnessTarget.lufs
    }

    // MARK: Calibration

    /// Balancing several sources against each other from one short recording.
    ///
    /// Everybody does this by ear and nobody does it well: you cannot hear your
    /// own mix the way the far end does, and two sources are never loud at the
    /// same moment, so there is nothing to compare against. Every tool in this
    /// category leaves it as two faders.
    ///
    /// So it is a measurement instead. Press it, everybody speaks in turn for
    /// ten seconds, and each source is measured only while it was actually
    /// producing something — otherwise whoever spoke least would measure
    /// quietest and be handed the most gain.
    enum CalibrationPhase: Equatable, Sendable {
        case idle
        /// A moment to get ready before anything counts.
        case countdown(Int)
        case listening
        /// Finished, with something to apply.
        case proposing
        case failed(String)
    }

    private(set) var calibrationPhase: CalibrationPhase = .idle
    /// Seconds left in whichever timed phase is running.
    private(set) var calibrationRemaining: Double = 0
    /// What it wants to change, in the order the mixer shows the routes.
    private(set) var calibrationProposals: [LevelCalibration.Proposal] = []
    /// Live gated seconds per route while listening, so somebody can see
    /// whether they are being heard before the ten seconds are up.
    private(set) var calibrationHeard: [Double] = []

    /// How long each phase lasts.
    static let calibrationCountdown = 3
    static let calibrationSeconds: Double = 10

    /// What each source is for. Keyed by the source's device or bundle
    /// identifier so it survives a rebuild.
    var sourceRoles: [String: LevelCalibration.Role] = [:] {
        didSet { if oldValue != sourceRoles { persist() } }
    }

    /// The role a route's source plays, defaulting by what it is.
    ///
    /// A microphone is a voice. An application could be either — Discord is a
    /// voice and Spotify is not — so the bundle identifier decides, and the
    /// user can override it.
    func role(of route: Route) -> LevelCalibration.Role {
        if route.source.deviceUID == selectedSourceUID {
            return sourceRoles[route.source.deviceUID] ?? .voice
        }
        guard let bundleID = tapOwners[route.source.deviceUID] else { return .voice }
        return sourceRoles[bundleID] ?? LevelCalibration.Role.default(forBundleID: bundleID)
    }

    /// Only sources that can be either are worth offering a choice for. The
    /// microphone is a person by definition.
    func canChangeRole(of route: Route) -> Bool {
        route.source.deviceUID != selectedSourceUID && tapOwners[route.source.deviceUID] != nil
    }

    func toggleRole(of route: Route) {
        guard let bundleID = tapOwners[route.source.deviceUID] else { return }
        sourceRoles[bundleID] = role(of: route) == .voice ? .background : .voice
    }

    var isCalibrating: Bool {
        switch calibrationPhase {
        case .idle, .failed, .proposing: false
        case .countdown, .listening: true
        }
    }

    /// Only worth offering when there is something to balance.
    var canCalibrate: Bool { isRunning && !isBusy && activeRoutes.count >= 1 }

    @ObservationIgnored private var calibrationTimer: Timer?

    func startCalibration() {
        guard canCalibrate, !isCalibrating else { return }
        calibrationProposals = []
        calibrationGroups = []
        calibrationHeard = Array(repeating: 0, count: sourceGroups.count)
        calibrationPhase = .countdown(Self.calibrationCountdown)
        calibrationRemaining = Double(Self.calibrationCountdown)
        scheduleCalibrationTick()
    }

    func cancelCalibration() {
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        engine.endCalibration()
        calibrationPhase = .idle
        calibrationRemaining = 0
        calibrationProposals = []
        calibrationGroups = []
    }

    private func scheduleCalibrationTick() {
        calibrationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.calibrationTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        calibrationTimer = timer
    }

    private func calibrationTick() {
        calibrationRemaining = max(0, calibrationRemaining - 0.1)

        switch calibrationPhase {
        case .countdown:
            let left = Int(ceil(calibrationRemaining))
            if calibrationRemaining <= 0 {
                calibrationPhase = .listening
                calibrationRemaining = Self.calibrationSeconds
                engine.beginCalibration()
            } else {
                calibrationPhase = .countdown(max(1, left))
            }
        case .listening:
            let rate = pathQuality?.sampleRate ?? 48000
            let seconds = engine.calibrationLevels(sampleRate: rate).map(\.seconds)
            calibrationHeard = sourceGroups.map { group in
                group.routes.compactMap { $0 < seconds.count ? seconds[$0] : nil }.max() ?? 0
            }
            if calibrationRemaining <= 0 { finishCalibration() }
        default:
            calibrationTimer?.invalidate()
            calibrationTimer = nil
        }
    }

    private func finishCalibration() {
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        engine.endCalibration()

        let rate = pathQuality?.sampleRate ?? 48000
        let levels = engine.calibrationLevels(sampleRate: rate)
        // Measured per source, not per channel.
        //
        // A stereo source is two routes, and proposing a gain for each would
        // put the two sides at different levels — a balance change nobody asked
        // for, and one that pulls the image apart. The group's level is its
        // loudest channel and its seconds are the longest, because a source was
        // heard if any of its channels heard something.
        let groups = sourceGroups
        let measurements = groups.enumerated().compactMap {
            index, group -> LevelCalibration.Measurement? in
            guard let route = representative(of: group) else { return nil }
            let members = group.routes.filter { $0 < levels.count }
            guard !members.isEmpty else { return nil }
            let decibels = members.map { levels[$0].decibels }.max() ?? -.infinity
            let seconds = members.map { levels[$0].seconds }.max() ?? 0
            return LevelCalibration.Measurement(
                id: index,
                role: role(of: route),
                decibels: decibels,
                seconds: seconds,
                currentGain: Double(faderDecibels(of: group)))
        }
        calibrationGroups = groups

        if let problem = LevelCalibration.problem(with: measurements) {
            switch problem {
            case .nothingHeard:
                calibrationPhase = .failed(
                    loc("Nothing was loud enough to measure. Try again and speak up."))
                return
            case .silentSources(let ids):
                let names = ids.compactMap { id -> String? in
                    guard id < groups.count,
                        let route = representative(of: groups[id])
                    else { return nil }
                    return routeTitle(route)
                }
                // Not fatal: the sources that did produce something can still
                // be balanced against each other, and saying which one stayed
                // silent is more useful than refusing.
                calibrationProposals = LevelCalibration.propose(from: measurements)
                calibrationPhase =
                    calibrationProposals.isEmpty
                    ? .failed(
                        String(
                            format: loc(
                                "%@ produced nothing, and the rest are already balanced."),
                            names.joined(separator: ", ")))
                    : .proposing
                return
            }
        }

        calibrationProposals = LevelCalibration.propose(from: measurements)
        calibrationPhase =
            calibrationProposals.isEmpty
            ? .failed(loc("Everything is already balanced. Nothing to change."))
            : .proposing
    }

    /// The groups the last proposal was computed against, so its ids still
    /// mean something if the route set changes underneath it.
    private(set) var calibrationGroups: [SourceGroup] = []

    /// Applies what it worked out. Every channel of a source moves together.
    func applyCalibration() {
        for proposal in calibrationProposals {
            guard proposal.id < calibrationGroups.count else { continue }
            setFaderDecibels(Float(proposal.gain), for: calibrationGroups[proposal.id])
        }
        calibrationProposals = []
        calibrationGroups = []
        calibrationPhase = .idle
    }

    /// A short name for a route, for the proposal list.
    func routeTitle(_ route: Route) -> String {
        if route.source.deviceUID == selectedSourceUID {
            return selectedSource?.name ?? loc("Microphone")
        }
        if let application = application(of: route) { return application.name }
        return "\(loc("Ch")) \(route.source.channel + 1)"
    }

    // MARK: Ducking

    /// Application audio steps out of the way while somebody is talking.
    ///
    /// Every sidechain ducker works off an envelope, and an envelope cannot
    /// tell a sentence from a cough, a chair or a keyboard — all of which pull
    /// the music down for no reason. The classifier can tell them apart but
    /// reports twice a second, far too slow to catch the front of a word. So
    /// each is used for what it is good at: the envelope decides *when*,
    /// instantly, on the IO thread; the model decides *whether*, over the last
    /// few seconds.
    ///
    /// Deliberately never applied to the microphone. Ducking is the music
    /// getting out of the way of a voice; a voice that ducked itself would be a
    /// gate with extra steps, and it is exactly how this feature would end up
    /// cutting the beginning of words.
    var isDucking = false {
        didSet {
            guard oldValue != isDucking else { return }
            engine.setDucking(enabled: isDucking, depth: Self.gain(fromDecibels: duckDecibels))
            persist()
        }
    }

    /// How far application audio drops while somebody is talking.
    var duckDecibels: Float = -14 {
        didSet {
            guard oldValue != duckDecibels else { return }
            engine.setDucking(enabled: isDucking, depth: Self.gain(fromDecibels: duckDecibels))
            persist()
        }
    }

    /// The duck depth as a 0...1 travel, from silent to no attenuation at all.
    var duckFraction: Float {
        get { max(0, min(1, (duckDecibels + 40) / 40)) }
        set { duckDecibels = -40 + max(0, min(1, newValue)) * 40 }
    }

    /// How long the classifier's verdict is trusted for after it last said
    /// speech.
    ///
    /// Speech is not continuous — there are gaps inside every sentence longer
    /// than the model's own window — so a verdict that expired the instant it
    /// stopped saying "speech" would let the music surge back between words.
    private static let speechHold: TimeInterval = 2.5
    @ObservationIgnored private var lastSpeechAt: Date?

    /// True while the model's verdict still counts.
    var isSpeechRecent: Bool {
        guard let lastSpeechAt else { return false }
        return Date().timeIntervalSince(lastSpeechAt) < Self.speechHold
    }

    private func refreshDucking() {
        guard isDucking else { return }
        if analyser?.classifier?.hearsSpeech == true { lastSpeechAt = Date() }
        engine.setDuckingAllowed(isSpeechRecent)
    }

    // MARK: Automatic levelling

    /// Holds the microphone at the chosen platform's loudness, by itself.
    ///
    /// What makes this different from the automatic gain control everybody
    /// turns off is what it measures and when it acts: loudness to the
    /// broadcast standard rather than an envelope, and only while Apple's
    /// on-device model says it is hearing speech. A conventional AGC has no way
    /// to tell a voice from a fan, so it spends every pause winding the gain up
    /// into the room noise.
    var isAutoLevelling = false {
        didSet {
            guard oldValue != isAutoLevelling else { return }
            if isAutoLevelling {
                autoLevel.reset()
                autoLevelBase = inputDecibels
                autoLevelTick = Date()
                autoLevelOffset = 0
            }
            persist()
        }
    }

    @ObservationIgnored private var autoLevel = AutoLevel()
    /// The trim as the user left it. The loop works relative to this rather
    /// than absolutely, so switching it off leaves them where they started.
    @ObservationIgnored private var autoLevelBase: Float = 0
    @ObservationIgnored private var autoLevelTick = Date()
    /// True while the loop is driving the trim, so the trim's own persistence
    /// does not write to disk twenty times a second.
    @ObservationIgnored private var isAutoAdjusting = false

    /// How far the loop has moved the trim, in decibels.
    private(set) var autoLevelOffset: Double = 0
    /// True when it is holding still because there is nothing to act on.
    var autoLevelIsWaiting: Bool { autoLevel.isWaiting }
    /// True when it has run out of range and the setup needs a human.
    var autoLevelIsAtLimit: Bool { autoLevel.isAtLimit }
    /// True when the peak, not the loudness, is what is stopping it.
    var autoLevelIsHeldByHeadroom: Bool { autoLevel.isHeldByHeadroom }

    /// What the on-device model hears right now.
    var heardVerdict: SoundClassifier.Verdict { analysis.verdict }
    var heardConfidence: Double { analysis.verdictConfidence }

    private func stepAutoLevel() {
        let now = Date()
        // Clamped: the first tick after switching it on, or after the app was
        // suspended, would otherwise be a single step of many decibels — the
        // slew limit is per second and would faithfully allow it.
        let elapsed = min(0.5, max(0, now.timeIntervalSince(autoLevelTick)))
        autoLevelTick = now

        // The reading comes off the bus after the master, so the master is
        // taken back out before the loop sees it. Without that, pulling the
        // master down makes the loop push the microphone up to compensate and
        // the master quietly stops doing anything.
        let master = isOutputMuted ? Double.infinity : Double(outputDecibels)
        let preMaster = analysis.shortTerm - master

        // How much more gain the peak has room for. Measured after every gain
        // stage, so it already includes whatever the loop has added so far;
        // one decibel of headroom is left rather than aiming at exactly full
        // scale, because the peak here is a sample peak and the true peak
        // between samples is always a little higher.
        let headroom = outputPeakDecibels.isFinite ? -1 - outputPeakDecibels : .infinity
        let ceiling = autoLevelOffset + headroom

        let offset = autoLevel.update(
            loudness: preMaster,
            target: loudnessTarget.lufs,
            hearsSpeech: analyser?.classifier?.hearsSpeech ?? false,
            elapsed: elapsed,
            ceiling: ceiling)
        autoLevelOffset = offset

        let wanted = autoLevelBase + Float(offset)
        guard abs(wanted - inputDecibels) > 0.01 else { return }
        isAutoAdjusting = true
        inputDecibels = wanted
        isAutoAdjusting = false
    }

    /// Starts the integrated measurement over.
    func resetLoudness() {
        analyser?.reset()
        analysis = .silent
    }

    /// Declares what the analysers should actually be computing.
    ///
    /// Nothing is built until something asks for it, and everything is released
    /// when the last thing that wanted it goes away. With the panel closed and
    /// levelling off this leaves no FFT, no sound model and no per-cycle fold
    /// on the IO thread — a router forwarding audio between two devices should
    /// not be holding a neural network open in case somebody looks.
    private func refreshAnalysisNeeds() {
        var wanted: SignalAnalyser.Needs = []
        if isAnalysisVisible {
            wanted.formUnion([.loudness, .spectrum, .classification, .pitch])
        }
        // Singing needs the pitch and nothing else — no FFT, no sound model.
        // The lazy needs are the reason a lyrics panel does not cost what the
        // analysis panel costs.
        // Singing needs the pitch, and the spectrum for the key of what is
        // playing — no sound model, which is the expensive one.
        if isSingingVisible { wanted.formUnion([.pitch, .spectrum]) }
        if isAutoLevelling { wanted.formUnion([.loudness, .classification]) }
        if isDucking { wanted.formUnion([.classification]) }

        guard wanted != analysisNeeds else { return }
        analysisNeeds = wanted
        analyser?.require(wanted)
        engine.setAnalysisEnabled(!wanted.isEmpty)
        if wanted.isEmpty { analysis = .silent }
    }

    @ObservationIgnored private var analysisNeeds: SignalAnalyser.Needs = []

    /// Raw frames off the analysis tap, for diagnostics that want the signal
    /// rather than a summary of it.
    func drainAnalysisForDiagnostics(
        into destination: UnsafeMutablePointer<Float>, capacity: Int
    ) -> Int {
        engine.drainAnalysis(into: destination, capacity: capacity)
    }

    /// True when no analysis is being computed at all.
    var analysisIsIdle: Bool { analyser?.isIdle ?? true }

    private func startAnalysis(sampleRate: Double) {
        analyser = SignalAnalyser(sampleRate: sampleRate)
        analysis = .silent
        // Whatever was already switched on has to be re-declared against the
        // new analyser, or turning routing off and on again would silently stop
        // the levelling.
        analysisNeeds = []
        refreshAnalysisNeeds()
    }

    private func stopAnalysis() {
        analyser = nil
        analysis = .silent
        analysisNeeds = []
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

    /// Whether the allocator hook is installed.
    ///
    /// Off by default, and it used to be on from launch so the diagnostics page
    /// could show a real number. That was the wrong trade by a long way: the
    /// hook is process-wide and has no way to be installed selectively, so
    /// every allocation in SwiftUI, AppKit and CoreAudio was paying for a page
    /// almost nobody opens. It is a measurement to switch on.
    var watchesIOAllocations = false {
        didSet {
            guard oldValue != watchesIOAllocations else { return }
            if watchesIOAllocations {
                RoutingEngine.enableAllocationTripwire()
            } else {
                RoutingEngine.disableAllocationTripwire()
            }
        }
    }

    /// True in an unoptimised build, where the count is Swift's own checking
    /// machinery rather than anything about the code that ships.
    var isDebugBuild: Bool { RoutingEngine.isDebugBuild }

    // MARK: Integrity check

    private(set) var isCheckingIntegrity = false
    /// Fraction of the capture buffer filled, for the progress bar.
    private(set) var integrityProgress: Double = 0
    /// What the last comparison found, or nil if none has run.
    private(set) var integrityResult: SelftestResult?
    private(set) var integrityError: String?

    /// Only a loopback destination can answer the question: the check writes a
    /// known sequence to the output and reads it back off the same device's
    /// input, so a destination with no input has nothing to read back.
    var canCheckIntegrity: Bool {
        guard let destination = selectedDestination else { return false }
        return destination.inputChannels > 0 && !isCheckingIntegrity
    }

    /// Sends a known pseudorandom sequence through the whole path and compares
    /// every sample that comes back.
    ///
    /// This is the project's central claim, and until now it could only be made
    /// from a terminal. Somebody who installs the app had no way to find out
    /// whether their own path is bit-exact — which is the one thing nothing
    /// else in this category will tell them.
    func checkIntegrity() {
        guard canCheckIntegrity, !isBusy else { return }
        integrityResult = nil
        integrityError = nil
        integrityProgress = 0
        isCheckingIntegrity = true

        // The check needs its own start: the sequence generator and the capture
        // buffer are installed when the graph is built, so they cannot be added
        // to a route that is already running.
        let wasRunning = isRunning
        let begin: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.start(selftest: true)
            Task { @MainActor in await self.pollIntegrity(restoreRunning: wasRunning) }
        }
        if wasRunning { stop(then: begin) } else { begin() }
    }

    private func pollIntegrity(restoreRunning: Bool) async {
        // Long enough to fill the capture buffer at 48 kHz, with headroom for
        // the route to come up first.
        for _ in 0..<160 {
            try? await Task.sleep(for: .milliseconds(100))
            integrityProgress = engine.selftestProgress
            if integrityProgress >= 1 { break }
        }
        integrityResult = engine.evaluateSelftest()
        if integrityResult == nil {
            // Two different failures, and telling them apart is the difference
            // between a message somebody can act on and one they cannot. The
            // check reads its sequence back off the destination's input; a
            // destination with no input — speakers, a headset, a display — can
            // never return anything, and saying "could not be set up" invites
            // somebody to go looking for a fault that is not there.
            integrityError =
                integrityProgress <= 0
                ? loc(
                    "This output has no input to read the sequence back from, so there is nothing to grade. Route to a loopback device to run the check."
                )
                : loc("The check could not be set up on this path.")
        }
        isCheckingIntegrity = false

        // Put the route back the way it was found rather than leaving the
        // check's own graph running: it overwrites a destination channel with
        // the test sequence, which is not something to leave in a call.
        stop(then: { [weak self] in
            guard let self, restoreRunning else { return }
            self.start()
        })
    }

    /// Which of the two looks the whole application wears.
    ///
    /// Stored here and mirrored onto the shared theme rather than read straight
    /// off it: the menu bar panel is hosted outside this model's view tree, so
    /// the theme is what that panel follows, while this is what the preferences
    /// window binds to.
    var style: YunStyle = .flat {
        didSet {
            guard oldValue != style else { return }
            YunTheme.shared.style = style
            persist()
        }
    }

    /// IO cycles completed. Only used by the flow check, which needs to know
    /// whether audio survived a change rather than merely whether the model
    /// still says it is running.
    var cycleCountForDiagnostics: UInt64 { engine.cycleCount }

    /// Loudest route, for the menu bar icon and the signal path graphic.
    var peakLevel: Float { levels.max() ?? 0 }
}
