import AppKit
import CoreAudio
import Foundation
import Observation
import YunAudioControl
import YunAudioEngine
import YunAudioHAL
import YunAudioOBS
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
final class RouterModel: ScriptTarget {
    // MARK: Devices

    private(set) var inputDevices: [AudioDevice] = []
    private(set) var outputDevices: [AudioDevice] = []

    /// Inputs automation may open without waking another personal device.
    ///
    /// Continuity Capture remains in `inputDevices` so a person can choose it
    /// deliberately. It is absent here so launch defaults, recovery and
    /// verification cannot turn a nearby phone into a microphone.
    var automaticallySelectableInputDevices: [AudioDevice] {
        inputDevices.filter { !$0.transport.requiresExplicitInputSelection }
    }

    /// Whether the remembered route contains an input that must not auto-start.
    private var routeRequiresExplicitInputSelection: Bool {
        activeSourceUIDs.contains { uid in
            inputDevices.first(where: { $0.uid == uid })?.transport
                .requiresExplicitInputSelection == true
        }
    }

    /// Verification is unattended and must neither open saved hardware nor
    /// rewrite the person's saved route while it drives a temporary one.
    private static let isVerificationProcess: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["YUNAUDIO_FLOWCHECK"] != nil
            || environment["YUNAUDIO_SCREENSHOT"] != nil
            || environment["YUNAUDIO_RENDER"] != nil
            || environment["YUNAUDIO_ICON"] != nil
    }()

    /// The user's real input choices while a verification route is temporary.
    @ObservationIgnored private var verificationSourceUID: String?
    @ObservationIgnored private var verificationAdditionalSourceUIDs: [String]?

    /// Moves verification away from inputs that wake a nearby phone or tablet.
    ///
    /// The ordinary picker remains untouched. Automated runs have no person at
    /// the point of capture to consent to Continuity Capture, so they either use
    /// a local input or decline to open audio at all.
    @discardableResult
    func prepareForAutomatedAudioUse() -> Bool {
        if Self.isVerificationProcess, verificationAdditionalSourceUIDs == nil {
            verificationSourceUID = selectedSourceUID
            verificationAdditionalSourceUIDs = additionalSourceUIDs
        }
        additionalSourceUIDs.removeAll { uid in
            inputDevices.first(where: { $0.uid == uid })?.transport
                .requiresExplicitInputSelection == true
        }
        if selectedSource?.transport.requiresExplicitInputSelection == true {
            selectedSourceUID =
                automaticallySelectableInputDevices.first { !$0.transport.isVirtual }?.uid
                ?? automaticallySelectableInputDevices.first?.uid
        }
        return selectedSource != nil && !routeRequiresExplicitInputSelection
    }

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
            // What was chosen for *this* device, and only otherwise the
            // default worked out from its topology.
            if !restoreChannelChoice() { applyChannelDefaults() }
            // The gain and the monitor belong to whichever microphone this now
            // is, and a stale reading would put the last device's slider under
            // the new device's name until the next poll.
            pendingHardwareGain = nil
            pendingHardwareMonitor = nil
            refreshDeviceControls()
            persist()
            rerouteAfterDeviceChange()
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
            refreshDeviceControls()
            persist()
            rerouteAfterDeviceChange()
        }
    }

    // MARK: More than one of each

    /// Further hardware inputs, mixed in alongside the one above.
    ///
    /// Kept beside the primary rather than folded into a list with it because
    /// the aggregate has a clock master and that is what `selectedSourceUID`
    /// is: every other member is drift corrected against it. Presenting them
    /// as equals in the model would be presenting them as equals in the
    /// interface, and they are not — which of them the route is clocked from
    /// decides which one cannot be resampled.
    ///
    /// Until this existed a second microphone could only be had by making an
    /// aggregate device in Audio MIDI Setup and routing that, which loses the
    /// per-source fader, the per-source mute and the role, because to this
    /// application the whole aggregate was one source.
    private(set) var additionalSourceUIDs: [String] = []

    /// Further outputs, each receiving the same mix as the main one.
    ///
    /// The same mix, deliberately. A bus with sends of its own is the monitor,
    /// and there is exactly one of those; these are copies — speakers and a
    /// recorder and a stream device all carrying the send. Somebody who wants
    /// a third *independent* mix is asking for something this does not claim
    /// to do, and quietly giving them a copy under that name would be worse
    /// than not offering it.
    private(set) var additionalDestinationUIDs: [String] = []

    /// Every input in the route, the clock master first.
    var activeSourceUIDs: [String] {
        (selectedSourceUID.map { [$0] } ?? []) + additionalSourceUIDs
    }

    /// Every output the send is written to, the primary first.
    var activeDestinationUIDs: [String] {
        (selectedDestinationUID.map { [$0] } ?? []) + additionalDestinationUIDs
    }

    /// Inputs that could still be added: present, with channels, and not
    /// already an end of the route.
    ///
    /// The physical-device test is the same one `start()` applies to the main
    /// pair, for the same reason: a headset presents as two CoreAudio devices
    /// with one name, and adding its input while its output carries the mix is
    /// routing it into itself. Offering the choice and then refusing it at
    /// start is worse than not offering it.
    var addableSourceDevices: [AudioDevice] {
        inputDevices.filter { device in
            device.inputChannels > 0
                && !activeSourceUIDs.contains(device.uid)
                && !activeDestinationUIDs.contains { isSamePhysicalDevice($0, device.uid) }
                && !(monitorDeviceUID.map { isSamePhysicalDevice($0, device.uid) } ?? false)
        }
    }

    /// And outputs, on the same terms.
    var addableDestinationDevices: [AudioDevice] {
        outputDevices.filter { device in
            device.outputChannels > 0
                && !activeDestinationUIDs.contains(device.uid)
                && device.uid != monitorDeviceUID
                && !activeSourceUIDs.contains { isSamePhysicalDevice($0, device.uid) }
        }
    }

    /// Chooses how one of the extra inputs is taken.
    ///
    /// The primary source has two visible controls for this; the extras share
    /// the same per-device memory through one call, because a second full set
    /// of controls per input is how a mixer with four inputs becomes a window
    /// nobody can read.
    func setChannelChoice(
        mode: SourceChannelMode, channel: Int, forSourceUID uid: String
    ) {
        guard uid != selectedSourceUID else {
            channelMode = mode
            if mode == .mono { monoChannel = channel }
            return
        }
        let stored = mode == .stereo ? "stereo" : "mono:\(channel)"
        guard sourceChannelChoices[uid] != stored else { return }
        sourceChannelChoices[uid] = stored
        persist()
        // Only the channel map moves, so this can be swapped in silently — the
        // same treatment the primary source's own picker gets.
        if !reconfigureIfPossible() { restartIfRunning() }
    }

    func addSource(_ uid: String) {
        guard !activeSourceUIDs.contains(uid) else { return }
        // A new choice is a new question, so the last refusal stops being an
        // answer to it — the same rule the monitor picker follows.
        droppedExtraInputNames = []
        droppedExtraOutputNames = []
        // No primary yet means this is the primary. Adding a second input to a
        // route with no first one would leave the clock master unset and the
        // start refused, with the interface showing an input that is there.
        guard selectedSourceUID != nil else {
            selectedSourceUID = uid
            return
        }
        additionalSourceUIDs.append(uid)
        persist()
        rerouteAfterDeviceChange()
    }

    func removeSource(_ uid: String) {
        // Removing the clock master promotes the first of the others rather
        // than emptying the route: somebody taking away one of two microphones
        // meant to keep the other, and which of them the aggregate happened to
        // be clocked from is not a distinction they were asked to make.
        if uid == selectedSourceUID {
            guard !additionalSourceUIDs.isEmpty else { return }
            let promoted = additionalSourceUIDs.removeFirst()
            substituting { selectedSourceUID = promoted }
            persist()
            rerouteAfterDeviceChange()
            return
        }
        guard let index = additionalSourceUIDs.firstIndex(of: uid) else { return }
        additionalSourceUIDs.remove(at: index)
        persist()
        rerouteAfterDeviceChange()
    }

    func addDestination(_ uid: String) {
        guard !activeDestinationUIDs.contains(uid) else { return }
        droppedExtraInputNames = []
        droppedExtraOutputNames = []
        guard selectedDestinationUID != nil else {
            selectedDestinationUID = uid
            return
        }
        additionalDestinationUIDs.append(uid)
        persist()
        rerouteAfterDeviceChange()
    }

    func removeDestination(_ uid: String) {
        if uid == selectedDestinationUID {
            guard !additionalDestinationUIDs.isEmpty else { return }
            let promoted = additionalDestinationUIDs.removeFirst()
            substituting { selectedDestinationUID = promoted }
            persist()
            rerouteAfterDeviceChange()
            return
        }
        guard let index = additionalDestinationUIDs.firstIndex(of: uid) else { return }
        additionalDestinationUIDs.remove(at: index)
        persist()
        rerouteAfterDeviceChange()
    }

    /// Drops anything additional that has become an end of the main route or
    /// has gone away.
    ///
    /// Called after the device list changes and after either primary moves.
    /// Without it, choosing as the main output a device that was already an
    /// extra one leaves it in both lists — which the engine deduplicates, so
    /// nothing breaks audibly and the interface shows the same speakers twice
    /// for as long as anybody leaves it.
    private func pruneAdditionalDevices() {
        let inputs = Set(inputDevices.map(\.uid))
        let outputs = Set(outputDevices.map(\.uid))
        let sources = additionalSourceUIDs.filter {
            $0 != selectedSourceUID && $0 != selectedDestinationUID && inputs.contains($0)
        }
        let destinations = additionalDestinationUIDs.filter {
            $0 != selectedDestinationUID && $0 != selectedSourceUID && $0 != monitorDeviceUID
                && outputs.contains($0)
        }
        guard sources != additionalSourceUIDs || destinations != additionalDestinationUIDs
        else { return }
        additionalSourceUIDs = sources
        additionalDestinationUIDs = destinations
        persist()
    }

    // MARK: Per-bus processing

    /// Corrections found on disk, by name.
    ///
    /// Documents rather than a bundled database. Every headphone has a
    /// frequency response that is wrong in a way somebody has already measured,
    /// and AutoEq publishes the correction for thousands of them as a
    /// `ParametricEQ.txt` — the file people already download for their model.
    /// Shipping a copy of all of them would be a licensing problem, an update
    /// problem, and worse than the file for somebody's exact unit.
    private(set) var headphoneProfiles: [ParametricEQ] = []

    /// Ten slider positions per bus, in decibels, at the band centres in
    /// `ParametricEQ`, keyed by the bus's output device UID.
    ///
    /// Per bus rather than one for the whole router, which is the point of the
    /// exercise: the stream mix and the headphone mix are two different
    /// audiences, and shaping one for the other is the thing every review of
    /// VoiceMeeter singles out as what it gets right.
    ///
    /// Keyed by device UID rather than by the bus letter, because the letters
    /// are positional — turning the monitor off promotes B to A — and a tone
    /// dialled in for a pair of headphones must not migrate to the send.
    private(set) var busGraphicEQ: [String: [Float]] = [:]

    /// The headphone correction chosen for each bus, by file name.
    private(set) var busHeadphoneProfiles: [String: String] = [:]

    /// Value-semantic input to an off-main correction build.
    ///
    /// The collections are copy-on-write snapshots. Slider events therefore
    /// retain their moment cheaply while the latest-value applier decides which
    /// moment is actually worth turning into biquad coefficients.
    struct CorrectionSnapshot: Sendable {
        let busIDs: [String]
        let graphic: [String: [Float]]
        let profileNames: [String: String]
        let profiles: [ParametricEQ]
    }

    /// The tone control for one bus, ten bands, flat when it has never been set.
    func graphicEQ(forBus id: String) -> [Float] {
        let bands = busGraphicEQ[id] ?? []
        return bands.count == 10 ? bands : [Float](repeating: 0, count: 10)
    }

    func graphicEQIsFlat(forBus id: String) -> Bool {
        graphicEQ(forBus: id).allSatisfy { abs($0) < 0.05 }
    }

    func setGraphicBand(_ decibels: Float, at index: Int, forBus id: String) {
        var bands = graphicEQ(forBus: id)
        guard bands.indices.contains(index) else { return }
        let clamped = max(
            ParametricEQ.graphicRange.lowerBound,
            min(ParametricEQ.graphicRange.upperBound, decibels))
        guard abs(bands[index] - clamped) > 0.001 else { return }
        bands[index] = clamped
        busGraphicEQ[id] = bands
        persist()
        scheduleCorrections()
    }

    func resetGraphicEQ(forBus id: String) {
        guard !graphicEQIsFlat(forBus: id) else { return }
        busGraphicEQ[id] = [Float](repeating: 0, count: 10)
        persist()
        scheduleCorrections()
    }

    func headphoneProfileName(forBus id: String) -> String? { busHeadphoneProfiles[id] }

    func headphoneProfile(forBus id: String) -> ParametricEQ? {
        headphoneProfiles.first { $0.name == busHeadphoneProfiles[id] }
    }

    func setHeadphoneProfileName(_ name: String?, forBus id: String) {
        guard busHeadphoneProfiles[id] != name else { return }
        busHeadphoneProfiles[id] = name
        persist()
        scheduleCorrections()
    }

    /// What is actually run on one bus: its correction, its tone control, or
    /// both cascaded.
    ///
    /// A correction undoes a fault somebody measured in the hardware and the
    /// tone control is taste, so neither replaces the other. Cascaded biquads
    /// compose by concatenation, so running both costs only its own sections.
    func curve(forBus id: String) -> ParametricEQ? {
        var curves: [ParametricEQ] = []
        if let profile = headphoneProfile(forBus: id) { curves.append(profile) }
        if !graphicEQIsFlat(forBus: id) {
            curves.append(ParametricEQ.graphic(graphicEQ(forBus: id)))
        }
        return ParametricEQ.combined(curves, name: loc("Output"))
    }

    /// Every bus that has something to run, by output device UID.
    var busCurves: [String: ParametricEQ] {
        var result: [String: ParametricEQ] = [:]
        for bus in buses {
            if let curve = curve(forBus: bus.id) { result[bus.id] = curve }
        }
        return result
    }

    // MARK: The primary bus, by its old names

    /// The bus a correction ran on before buses had their own.
    ///
    /// The monitor when there is one, because that is the headphone path by
    /// definition. Otherwise the destination — somebody routing straight to
    /// their headphones with no separate monitor is still wearing them. The
    /// device tab's two cards edit this one, so the shortcut somebody already
    /// knows keeps working and a saved file keeps meaning what it meant.
    var correctedOutputUID: String? { monitorDeviceUID ?? selectedDestinationUID }

    /// Which one is in use on the primary bus, by name, or nil for none.
    var headphoneProfileName: String? {
        get { correctedOutputUID.flatMap { busHeadphoneProfiles[$0] } }
        set {
            guard let bus = correctedOutputUID else { return }
            setHeadphoneProfileName(newValue, forBus: bus)
        }
    }

    var headphoneProfile: ParametricEQ? {
        correctedOutputUID.flatMap { headphoneProfile(forBus: $0) }
    }

    var graphicEQ: [Float] {
        correctedOutputUID.map { graphicEQ(forBus: $0) }
            ?? [Float](repeating: 0, count: 10)
    }

    var graphicEQIsFlat: Bool { graphicEQ.allSatisfy { abs($0) < 0.05 } }

    func setGraphicBand(_ decibels: Float, at index: Int) {
        guard let bus = correctedOutputUID else { return }
        setGraphicBand(decibels, at: index, forBus: bus)
    }

    func resetGraphicEQ() {
        guard let bus = correctedOutputUID else { return }
        resetGraphicEQ(forBus: bus)
    }

    /// What the primary bus runs.
    var headphoneCurve: ParametricEQ? { correctedOutputUID.flatMap { curve(forBus: $0) } }

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
        // not silently keep running from memory. Every bus, not only the one
        // the device tab shows: a file deleted while the send was using it
        // would otherwise keep running off a copy nothing can reach.
        let available = Set(headphoneProfiles.map(\.name))
        let stale = busHeadphoneProfiles.filter { !available.contains($0.value) }
        if !stale.isEmpty {
            for id in stale.keys { busHeadphoneProfiles[id] = nil }
            persist()
            scheduleCorrections()
        }
    }

    /// True when a correction is chosen somewhere and is not reaching anything.
    var headphoneCorrectionIsIdle: Bool {
        !busCurves.isEmpty && !isRunning
    }

    /// Publishes every bus's curve at once.
    ///
    /// The whole set rather than the one that changed, because a bus that has
    /// just lost its curve has to stop running the old one and only a whole
    /// set can say so. Reinstalling an unchanged curve costs nothing: the
    /// engine leaves a slot's filter history alone when its coefficients did
    /// not move, so adjusting one bus does not click the other.
    ///
    /// - Returns: How many curves reached an output, which is not always how
    ///   many were asked for — a bus whose device has gone is dropped.
    /// Recorded as applied, because the defect this replaced was a route edit
    /// silently dropping the curves: the comment in `updateRoutes` said the
    /// model reinstalls them afterwards and the model never did. What is
    /// tracked is what actually reached the graph, so a check can ask.
    @discardableResult
    func applyCorrections() -> Int {
        correctionApplier.flush(correctionSnapshot)
    }

    /// One cheap COW snapshot per gesture event. Curves and coefficients are
    /// built only for values the latest-value applier does not coalesce away.
    private var correctionSnapshot: CorrectionSnapshot {
        CorrectionSnapshot(
            busIDs: buses.map(\.id),
            graphic: busGraphicEQ,
            profileNames: busHeadphoneProfiles,
            profiles: headphoneProfiles)
    }

    nonisolated static func correctionCurves(
        from snapshot: CorrectionSnapshot
    ) -> [String: ParametricEQ] {
        let profiles = Dictionary(
            snapshot.profiles.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
        var result: [String: ParametricEQ] = [:]
        result.reserveCapacity(snapshot.busIDs.count)
        for id in snapshot.busIDs {
            var curves: [ParametricEQ] = []
            if let name = snapshot.profileNames[id], let profile = profiles[name] {
                curves.append(profile)
            }
            if let bands = snapshot.graphic[id], bands.count == 10,
                bands.contains(where: { abs($0) >= 0.05 })
            {
                curves.append(.graphic(bands))
            }
            if let curve = ParametricEQ.combined(curves, name: "Output") {
                result[id] = curve
            }
        }
        return result
    }

    private func scheduleCorrections() {
        correctionApplier.submit(correctionSnapshot)
    }

    private func publishCorrectionCount(_ reached: Int) {
        if reached > 0 {
            appliedToGraph.insert(.headphoneCorrection)
        } else {
            // Nothing reached an output, which is the ordinary case of a
            // profile left selected after the headphones were unplugged.
            appliedToGraph.remove(.headphoneCorrection)
        }
    }

    /// Reads per-bus processing out of a saved file, old shape or new.
    ///
    /// A file written before buses had their own carries one tone control and
    /// one correction for the whole router. Those ran on the monitor when there
    /// was one and on the destination otherwise, so that is the bus they become
    /// — folding them onto anything else would silently move somebody's
    /// headphone correction onto the mix the far end hears, which is the exact
    /// mistake the per-output rule exists to prevent.
    ///
    /// A per-bus entry always wins over the flat one: both are written on every
    /// save so that an older build can still open the file, and the flat pair
    /// is the lossy copy.
    static func busProcessing(
        from saved: Preferences
    ) -> (graphic: [String: [Float]], profiles: [String: String]) {
        // A malformed band list is dropped rather than padded: ten sliders is
        // what the interface draws, and anything else came from a file that
        // was edited by hand.
        var graphic = (saved.busGraphicEQ ?? [:]).filter { $0.value.count == 10 }
        var profiles = saved.busHeadphoneProfiles ?? [:]
        guard let previous = saved.monitorDeviceUID ?? saved.destinationDeviceUID else {
            return (graphic, profiles)
        }
        if graphic[previous] == nil, let bands = saved.graphicEQ, bands.count == 10,
            bands.contains(where: { abs($0) > 0.05 })
        {
            graphic[previous] = bands
        }
        if profiles[previous] == nil, let name = saved.headphoneProfileName {
            profiles[previous] = name
        }
        return (graphic, profiles)
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
    @ObservationIgnored private var outputDelaysNeedCommit = false

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
        selectedDestination != nil && !destinationHasVolumeControl
    }

    // MARK: What the devices themselves publish

    /// The three answers a window body used to ask `coreaudiod` for directly.
    ///
    /// Measured from a real window body on this machine: `hardwareGain` 431 µs,
    /// `hasHardwareMonitoring` 416 µs, `volumeKeysAreDead` 188 µs — **a
    /// millisecond of synchronous round trips to the audio server per
    /// evaluation**, and a body is evaluated on every hover, every drag frame
    /// and every step of a resize. That millisecond is not this process's to
    /// spend: `coreaudiod` is the one process every other application's audio is
    /// also waiting on, so a view body doing this is one way a menu bar
    /// application makes a whole machine feel slow.
    ///
    /// Kept rather than asked for, on the same reasoning as
    /// `destinationLatencyFrames`. Not cached and forgotten, though: these
    /// belong to the device rather than to us and Audio MIDI Setup can move
    /// them, so they are re-read beside the path verdict — twice a second — and
    /// whenever the selection or the device list changes.
    private(set) var hardwareGainReading: AudioDevice.HardwareGain?
    private(set) var hardwareMonitorReading: AudioDevice.HardwareGain?
    /// True until something says otherwise, so a window drawn before the first
    /// read does not accuse the volume keys of being dead.
    private(set) var destinationHasVolumeControl = true

    /// True when a window that draws any of them is on screen.
    ///
    /// The menu bar panel reads none of these and the inspector reads all of
    /// them, so with the window shut this is a round trip to the audio server
    /// on behalf of nobody — and shut is how a menu bar application spends most
    /// of its life. Measured: refreshing them on every poll regardless put
    /// 166 µs on each one, which is more than the entire poll costs with
    /// nothing open.
    private var inspectorIsOnScreen: Bool {
        NSApp?.windows.contains { $0.isVisible && $0.title == "YunAudio" } ?? false
    }

    func refreshDeviceControls() {
        publish(
            selectedSource?.hardwareGain(scope: kAudioObjectPropertyScopeInput),
            to: \.hardwareGainReading)
        publish(selectedSource?.playThrough(), to: \.hardwareMonitorReading)
        publish(
            selectedDestination?.hasSettableVolume(scope: kAudioObjectPropertyScopeOutput)
                ?? true,
            to: \.destinationHasVolumeControl)
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
    var hasHardwareMonitoring: Bool { hardwareMonitorReading?.isSettable ?? false }

    /// Where that feedback level sits, 0 to 1.
    ///
    /// Read through a stored copy rather than off the device on every look, for
    /// the reason `hardwareMonitorReading` gives — and through the pending
    /// value while it is being dragged, so the thumb does not snap back to
    /// whatever the device rounded the last set to.
    var hardwareMonitorScalar: Float {
        get { pendingHardwareMonitor ?? hardwareMonitorReading?.scalar ?? 0 }
        set {
            pendingHardwareMonitor = newValue
            try? selectedSource?.setPlayThrough(scalar: max(0, min(1, newValue)))
        }
    }
    private var pendingHardwareMonitor: Float?

    var hardwareMonitorLabel: String {
        guard let level = hardwareMonitorReading else { return "—" }
        // Re-derived from the range against the value on the slider, like
        // `hardwareGainLabel`: the stored reading is up to half a second old
        // while somebody is dragging, and a readout that lags the thumb it sits
        // beside reads as a control that is not working.
        let scalar = hardwareMonitorScalar
        guard let range = level.decibelRange, range.upperBound > range.lowerBound else {
            return String(format: "%.0f%%", scalar * 100)
        }
        let value = range.lowerBound + scalar * (range.upperBound - range.lowerBound)
        guard value.isFinite else { return String(format: "%.0f%%", scalar * 100) }
        return String(format: "%+.1f dB", value)
    }

    // MARK: Singing

    /// What a music player is playing right now, when the panel is open.
    private(set) var nowPlaying: NowPlaying.Track?
    /// Why source-independent audio recognition could not answer.
    private(set) var musicRecognitionProblem: String?
    @ObservationIgnored private lazy var musicRecognition = MusicRecognition {
        [weak self] result in
        self?.receiveMusicRecognition(result)
    }
    @ObservationIgnored private var recognisedApplication: AudioApplication?
    @ObservationIgnored private var recognitionSourceUID: String?
    /// Lyrics for it, when a file was found.
    private(set) var lyrics: Lyrics?
    /// Words with no reliable timeline, used only when no timed copy exists.
    private(set) var plainLyrics: String?
    /// The source actually shown, so a fallback is visible rather than opaque.
    private(set) var lyricsSourceName: String?
    enum LyricsLookupStatus: Equatable {
        case idle
        case local
        case native
        case loading
        case online
        case notFound
        case failed
        case rateLimited
    }

    /// Where the words came from, or what the one lookup is doing.
    private(set) var lyricsLookupStatus: LyricsLookupStatus = .idle
    @ObservationIgnored private var lyricsLookupTask: Task<Void, Never>?
    /// Which line is being sung, and how far through it.
    private(set) var lyricLine: Int?
    private(set) var lyricProgress: Double = 0
    /// Where the song has got to, extrapolated between the once-a-second
    /// answers a player will give. See `TrackClock` for why it is not simply
    /// asked every poll.
    ///
    /// Computed rather than published, so that reading it exactly — which every
    /// clock a score is anchored on has to — does not invalidate a view twenty
    /// times a second for a timecode that shows whole seconds. `songSecond` is
    /// the published half.
    var songPosition: Double {
        trackClock.position(at: Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
    }
    /// The whole second the timecode shows, published only when it changes.
    private(set) var songSecond: Int = 0
    /// Seconds to pull the words earlier, positive meaning earlier.
    ///
    /// The `.lrc` format has an `[offset:]` tag for exactly this, and it is
    /// wrong as often as it is right: the file somebody downloaded was written
    /// against a different master, a different pressing, or a stream with a
    /// different silent lead-in. Everybody who has ever sung to a downloaded
    /// `.lrc` has wanted this control and the panel did not have one, so the
    /// only remedy was editing the file between verses.
    private(set) var lyricNudge: Double = 0
    /// Set while somebody is looking at the lyrics, so nothing is asked of the
    /// music players when nobody is.
    var isSingingVisible = false {
        didSet {
            guard oldValue != isSingingVisible else { return }
            refreshAnalysisNeeds()
            if isSingingVisible { refreshNowPlaying(); updateSinging() } else { clearSinging() }
        }
    }

    /// Moves the words against the recording, in tenths of a second.
    ///
    /// Bounded at two seconds either way: past that the file is for a different
    /// recording rather than out by a lead-in, and a control that can put the
    /// words a verse out is a control that loses somebody their place.
    func nudgeLyrics(by seconds: Double) {
        lyricNudge = max(-2, min(2, ((lyricNudge + seconds) * 10).rounded() / 10))
        followTheWords()
    }

    /// What key the backing track is in, once enough of it has been heard.
    private(set) var songKey: KeyDetector.Key?
    /// How far the song would have to move for this singer, in semitones.
    private(set) var suggestedShift: Int?

    /// The middle of the singer's measured range, or nil before they have sung.
    ///
    /// **From the singer's own tap, not from the analysis ring.** This and
    /// `heardNote` both used to read `analysis.pitchHertz`, and that ring is
    /// written from the *output bus* — every source mixed, after the master.
    /// With music playing, which is the one case this panel exists for, the
    /// dominant pitch on that bus is the backing track, so the panel reported
    /// the song as the singer's range and then built a transpose suggestion on
    /// top of it. Measured with the microphone silent and an F major
    /// progression captured onto the bus: the panel named a note throughout.
    ///
    /// Every source already has its own ring for the transcript and the score.
    /// This uses the same one, which is why the panel opens taps while it is
    /// merely being looked at rather than only while it is scoring.
    var comfortableMidi: Double? { singerTrack?.comfortableMidi }

    /// The pitch track of whoever is singing — the first source that is a real
    /// input rather than a captured application, since a captured application
    /// is the backing track by definition.
    private var singerTrack: SingerPitch? {
        for (index, track) in singerTracks.enumerated()
        where index < scoringIsBackingTrack.count && !scoringIsBackingTrack[index] {
            return track
        }
        return nil
    }

    /// Folds the current chroma into the key estimate.
    ///
    /// Accumulated rather than judged frame by frame: a single window of a song
    /// is a chord, and a chord is in several keys at once. A few seconds of
    /// them is a key.
    @ObservationIgnored private var chromaTotal = [Double](repeating: 0, count: 12)
    /// How many windows went into it, which is what decides whether the total
    /// is a key or merely the chord that happened to be playing when the panel
    /// opened. See `KeyDetector.leastWindowsForAKey`.
    @ObservationIgnored private(set) var chromaWindows = 0
    @ObservationIgnored private var pollsSinceChroma = 0

    /// Total spectral magnitude folded into the current key estimate.
    ///
    /// A positive value with twenty windows and no key means the profile match
    /// rejected the music; zero means the analyser was handed silence.
    var chromaEnergy: Double { chromaTotal.reduce(0, +) }

    var analysisStatistics: RoutingEngine.AnalysisStatistics {
        engine.analysisStatistics
    }

    /// How often the chroma is folded in, in polls of the twenty-a-second
    /// timer.
    ///
    /// Five times a second. The fold walks a thousand FFT bins and the interface
    /// wants a key about once a second, so doing it every poll would be paying
    /// four times over for an answer nobody reads that fast — but the sung
    /// pitch above it *is* taken every poll, because twenty of those is what
    /// makes a range rather than a note.
    private static let chromaEveryNPolls = 4

    private func updateSinging() {
        // One tracker per source, kept open while the panel is, so the note and
        // the range below are the voice rather than the mix.
        refreshSingerTracks()

        pollsSinceChroma += 1
        guard pollsSinceChroma >= Self.chromaEveryNPolls else { return }
        pollsSinceChroma = 0
        guard let chroma = analyser?.chroma(), chroma.count == 12 else { return }
        for index in 0..<12 { chromaTotal[index] += chroma[index] }
        chromaWindows += 1
        // Nothing is published until enough of the piece has gone in. The first
        // fold used to be published, and it answered whichever chord was
        // sounding at the moment the panel opened — B♭ for a song in F, at
        // 100% confidence, with a transpose suggestion built on top of it.
        guard let key = KeyDetector.key(from: chromaTotal, windows: chromaWindows) else {
            return
        }
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

    /// The note the singer is hearing themselves make, or nil when there is no
    /// pitch to find on their own microphone.
    ///
    /// The singer's tap rather than the mix — see `comfortableMidi`. The
    /// difference is the whole panel: on the mix this line reads the backing
    /// track and reads it confidently.
    var heardNote: String? { PitchTracker.noteName(singerHertz) }

    /// What the singer's own microphone is at, in hertz. Zero when nobody is
    /// singing, or when routing is not up and there is no tap to ask.
    var singerHertz: Float { singerTrack?.hertz ?? 0 }

    private func clearSinging() {
        cancelLyricsLookup()
        musicRecognition.reset()
        recognisedApplication = nil
        recognitionSourceUID = nil
        musicRecognitionProblem = nil
        isScoringSinging = false
        songKey = nil
        suggestedShift = nil
        chromaTotal = [Double](repeating: 0, count: 12)
        chromaWindows = 0
        pollsSinceChroma = 0
        nowPlaying = nil
        nowPlayingFailure = nil
        lyrics = nil
        plainLyrics = nil
        lyricsSourceName = nil
        melody = nil
        lyricLine = nil
        lyricProgress = 0
        songSecond = 0
        lyricNudge = 0
        isHandRun = false
        trackClock.stop()
        pollsSinceNowPlaying = Self.nowPlayingEveryNPolls
        releaseSingerTracks()
    }

    // MARK: Scoring, and duets

    /// The tune for what is playing, when a `.mid` was found beside the `.lrc`.
    private(set) var melody: MidiMelody?

    /// One singer, their own microphone, their own score.
    struct Singer: Identifiable, Equatable {
        /// The device the voice came in on, which is what makes two of these
        /// two of them rather than one averaged.
        let uid: String
        let name: String
        let hertz: Float
        let score: KaraokeScore
        var id: String { uid }
        var note: String? { PitchTracker.noteName(hertz) }
    }

    /// One entry per source being listened to, in the order the sources appear.
    private(set) var singers: [Singer] = []
    /// Set when scoring could not start, in words somebody can act on.
    private(set) var singingError: String?

    /// Scores everybody singing, each on their own microphone.
    ///
    /// A duet is structurally free here and it is worth saying why, because it
    /// is the whole argument for how this application is wired. Every other
    /// product that scores two singers has to work out which of them is
    /// singing, from the sound, and is sometimes wrong. Here the two were never
    /// mixed: each microphone is its own route with its own ring, so the name
    /// on a score is the wiring. What had to be built was one pitch tracker per
    /// source — the existing one runs on the mixed analysis tap, and a score
    /// off that would be the two of them averaged.
    var isScoringSinging = false {
        didSet {
            guard oldValue != isScoringSinging else { return }
            if isScoringSinging { startScoring() } else { stopScoring() }
        }
    }

    @ObservationIgnored private var singerTracks: [SingerPitch] = []
    @ObservationIgnored private var scoringNames: [String] = []
    @ObservationIgnored private var scoringUIDs: [String] = []
    @ObservationIgnored private var scoringApplicationIDs: [String?] = []
    /// Which of them is a captured application rather than somebody's
    /// microphone. A captured application is the backing track by definition,
    /// so it is not who "you are singing" is about.
    @ObservationIgnored private var scoringIsBackingTrack: [Bool] = []
    /// The melody sampled once, rather than on every poll: it is seven thousand
    /// samples for a five-minute song and it does not change while it plays.
    @ObservationIgnored private var scoringReference: [PitchSample] = []
    @ObservationIgnored private var pollsSinceScore = 0
    private struct CapturedScoringReference {
        let samples: [PitchSample]
        let step: Double
    }

    /// True when the score is against an exact MIDI tune rather than the
    /// detected-key fallback used by ordinary streaming tracks.
    var hasExactScoringReference: Bool { !scoringReference.isEmpty }

    enum ScoringReferenceMode: Equatable {
        case waiting
        case midi
        case capturedPlayer
        case key
    }

    /// What the number currently compares the microphones with.
    ///
    /// Published only when the four-times-a-second score is rebuilt. Deriving
    /// it from the growing pitch histories inside SwiftUI would make a redraw
    /// walk the whole song.
    private(set) var scoringReferenceMode: ScoringReferenceMode = .waiting

    /// How often a score is recomputed, in polls of the twenty-a-second timer.
    ///
    /// Four times a second. The comparison is over every reference sample of
    /// the whole song and a score that moves faster than somebody can read it
    /// is not more informative — but the note being sung is taken every poll,
    /// because that one is a tuner and has to feel immediate.
    private static let scoreEveryNPolls = 5

    /// How far the player's own position may be from where the tapped audio
    /// says the song has reached before it counts as a seek.
    ///
    /// Somebody restarting the song to have another go is the ordinary case,
    /// not an edge one, and the sung samples are timestamped from where the
    /// song was when scoring started. Two seconds is far more than the drift
    /// between an Apple event and a frame count, and far less than any seek
    /// somebody makes on purpose.
    private static let seekToleranceSeconds: Double = 2

    /// Opens a tap and a pitch tracker per source, or leaves the ones that are
    /// already right alone.
    ///
    /// Called from the poll while the panel is open rather than only when
    /// scoring starts, because "the note you are singing" and "how far to move
    /// the song for you" are about the singer and the only place the singer
    /// exists on their own is their own ring. Rebuilt only when the set of
    /// sources actually changes: rebuilding on every poll would throw away the
    /// performance twenty times a second.
    ///
    /// - Returns: True when there is at least one tracker to read.
    @discardableResult
    private func refreshSingerTracks() -> Bool {
        guard isSingingVisible || isScoringSinging, isRunning else { return false }
        let opened = openSourceTaps()
        guard opened > 0 else { return false }
        let groups = Array(sourceGroups.prefix(opened))
        guard groups.map(\.uid) != scoringUIDs || singerTracks.count != groups.count else {
            return !singerTracks.isEmpty
        }
        scoringUIDs = groups.map(\.uid)
        scoringNames = groups.map {
            representative(of: $0).map(routeTitle) ?? loc("Source")
        }
        scoringIsBackingTrack = groups.map {
            representative(of: $0).flatMap(application(of:)) != nil
        }
        scoringApplicationIDs = groups.map {
            representative(of: $0).flatMap(application(of:))?.bundleID
        }
        singerTracks = groups.compactMap { _ in SingerPitch(sampleRate: transcriptRate) }
        for track in singerTracks {
            track.keepsHistory = isScoringSinging
            track.reset(at: songPosition)
        }
        return !singerTracks.isEmpty
    }

    private func releaseSingerTracks() {
        singerTracks = []
        scoringUIDs = []
        scoringNames = []
        scoringIsBackingTrack = []
        scoringApplicationIDs = []
        closeSourceTapsIfIdle()
    }

    private func startScoring() {
        guard isRunning else {
            singingError = loc("Start routing before it can score you.")
            // Assigning inside an observer does not run the observer again, so
            // this cannot recurse.
            isScoringSinging = false
            return
        }
        guard refreshSingerTracks() else {
            singingError = loc("Could not listen to any source.")
            isScoringSinging = false
            return
        }
        restartScore()
        singingError = nil
        pollsSinceScore = Self.scoreEveryNPolls
        refreshSingers()
    }

    /// Puts every singer back at the start of their attempt.
    ///
    /// A karaoke machine's other button. The clock a score is measured on is
    /// the song's, and the whole of somebody's first verse being counted
    /// against them because they started the song late is the ordinary way a
    /// score becomes meaningless — and toggling the switch was the only remedy,
    /// which also loses the tune, the taps and the words.
    func restartScore() {
        for track in singerTracks {
            track.keepsHistory = true
            track.reset(at: songPosition)
        }
        rebuildScoringReference()
        scoringReferenceMode = scoringReference.isEmpty ? .waiting : .midi
        singers = []
        pollsSinceScore = Self.scoreEveryNPolls
    }

    private func stopScoring() {
        scoringReference = []
        scoringReferenceMode = .waiting
        singers = []
        singingError = nil
        // The trackers stay open while the panel is: the note at the top of it
        // is live whether or not anybody asked for a score.
        for track in singerTracks {
            track.keepsHistory = false
            track.reset(at: songPosition)
        }
        if !isSingingVisible { releaseSingerTracks() }
    }

    private func rebuildScoringReference() {
        scoringReference = melody?.samples(every: KaraokeScore.referenceInterval) ?? []
    }

    /// Recomputes what the interface shows for each singer.
    private func refreshSingers() {
        guard !singerTracks.isEmpty else {
            if !singers.isEmpty { singers = [] }
            return
        }
        pollsSinceScore += 1
        let expectedSingerCount = singerTracks.indices.reduce(into: 0) { count, index in
            if index >= scoringIsBackingTrack.count || !scoringIsBackingTrack[index] {
                count += 1
            }
        }
        let rescore =
            pollsSinceScore >= Self.scoreEveryNPolls || singers.count != expectedSingerCount
        if rescore { pollsSinceScore = 0 }

        // An `.lrc` offset says the words are late against the recording, so a
        // line the file stamps at 30 s is sung at 30 s minus the offset — and
        // the melody file is on the recording's clock, not the words'.
        let shift = lyrics?.offset ?? 0
        // Lyrics do not change between tuner refreshes. Building the whole
        // shifted list at 20 Hz made the four-Hz score cadence mostly cosmetic
        // on a song with hundreds of lines.
        let lines =
            rescore
            ? (lyrics?.lines ?? []).map {
                Lyrics.Line(time: $0.time - shift, text: $0.text)
            }
            : []

        let previous = Dictionary(uniqueKeysWithValues: singers.map { ($0.uid, $0) })
        let capturedReference =
            rescore && scoringReference.isEmpty
            ? automaticCapturedReference(lines: lines)
            : nil
        if rescore {
            if !scoringReference.isEmpty {
                scoringReferenceMode = .midi
            } else if capturedReference != nil {
                scoringReferenceMode = .capturedPlayer
            } else if songKey != nil {
                scoringReferenceMode = .key
            } else {
                scoringReferenceMode = .waiting
            }
        }
        var updated: [Singer] = []
        for (index, track) in singerTracks.enumerated() {
            // Captured applications are the accompaniment. Showing Spotify or
            // QQ Music as a singer gave the original recording its own score
            // row and made a silent microphone look successful.
            guard index >= scoringIsBackingTrack.count || !scoringIsBackingTrack[index]
            else { continue }
            let uid = index < scoringUIDs.count ? scoringUIDs[index] : "\(index)"
            let score: KaraokeScore
            if !rescore, let held = previous[uid] {
                score = held.score
            } else {
                score = scoreForTrack(
                    track, lines: lines, capturedReference: capturedReference)
            }
            let hertz = Self.singerDisplayHertz(
                measured: track.hertz,
                previous: previous[uid],
                rescore: rescore)
            updated.append(
                Singer(
                    uid: uid,
                    name: index < scoringNames.count ? scoringNames[index] : loc("Source"),
                    hertz: hertz, score: score))
        }
        if updated != singers { singers = updated }
    }

    /// Keeps raw tuner jitter from becoming view state.
    ///
    /// The row displays a note name, not hertz. While the measured value stays
    /// on that note, publishing every small autocorrelation wobble invalidates
    /// the singing panel at 20 Hz without changing one pixel. A score refresh
    /// still takes the exact current value at 4 Hz, and crossing a semitone is
    /// published immediately.
    static func singerDisplayHertz(
        measured: Float,
        previous: Singer?,
        rescore: Bool
    ) -> Float {
        guard !rescore, let previous,
            PitchTracker.noteName(previous.hertz) == PitchTracker.noteName(measured)
        else { return measured }
        return previous.hertz
    }

    /// A source's raw scoring result for verification, including accompaniment.
    ///
    /// Captured players are intentionally absent from `singers`, which is the
    /// interface list. The end-to-end check still needs to feed a known note
    /// through a real process tap and measure the number without turning that
    /// backing track into a person on screen.
    func scoringSource(uid: String) -> Singer? {
        guard let index = scoringUIDs.firstIndex(of: uid), index < singerTracks.count else {
            return nil
        }
        let shift = lyrics?.offset ?? 0
        let lines = (lyrics?.lines ?? []).map {
            Lyrics.Line(time: $0.time - shift, text: $0.text)
        }
        let reference =
            scoringReference.isEmpty ? automaticCapturedReference(lines: lines) : nil
        let score = scoreForTrack(
            singerTracks[index], lines: lines, capturedReference: reference)
        return Singer(
            uid: uid, name: index < scoringNames.count ? scoringNames[index] : loc("Source"),
            hertz: singerTracks[index].hertz, score: score)
    }

    private func scoreForTrack(
        _ track: SingerPitch, lines: [Lyrics.Line],
        capturedReference: CapturedScoringReference? = nil
    ) -> KaraokeScore {
        if !scoringReference.isEmpty {
            return KaraokeScore.scoreChronological(
                sung: track.samples, sungStep: track.sampleInterval,
                reference: scoringReference,
                referenceStep: KaraokeScore.referenceInterval,
                lyrics: lines, through: track.elapsed)
        }
        if let capturedReference {
            return KaraokeScore.scoreChronological(
                sung: track.samples, sungStep: track.sampleInterval,
                reference: capturedReference.samples,
                referenceStep: capturedReference.step,
                lyrics: lines, through: track.elapsed)
        }
        guard let songKey else { return .none }
        return KaraokeScore.keyScoreChronological(
            sung: track.samples, sungStep: track.sampleInterval,
            key: songKey, lyrics: lines,
            through: track.elapsed)
    }

    /// Uses the player already captured into the route as an automatic
    /// reference when it contains the original vocal.
    ///
    /// An accompaniment-only track has harmony and rhythm but no answer to
    /// "which note should the singer sing". Calling its dominant instrument an
    /// exact melody would manufacture a confident bad score, so those tracks
    /// deliberately fall through to the key-and-timing mode.
    private func automaticCapturedReference(
        lines: [Lyrics.Line]
    ) -> CapturedScoringReference? {
        guard !lines.isEmpty,
            let track = nowPlaying,
            !OnlineLyrics.isBackingTitle(track.title),
            let expectedApplication =
                recognisedApplication?.bundleID
                ?? [
                    "Music": "com.apple.Music",
                    "Spotify": "com.spotify.client",
                ][track.application],
            let index = scoringIsBackingTrack.indices.first(where: {
                scoringIsBackingTrack[$0] && $0 < singerTracks.count
                    && $0 < scoringApplicationIDs.count
                    && scoringApplicationIDs[$0] == expectedApplication
            })
        else { return nil }
        let reference = KaraokeScore.capturedReference(
            singerTracks[index].samples, lyrics: lines,
            through: singerTracks[index].elapsed)
        let step = singerTracks[index].sampleInterval
        guard Double(reference.count) * step >= KaraokeScore.leastSeconds
        else { return nil }
        return CapturedScoringReference(samples: reference, step: step)
    }

    /// Puts every singer's clock back where the player says the song is.
    ///
    /// Only when the two have genuinely parted company. Re-anchoring on every
    /// poll would hand the score whatever jitter an Apple event round trip
    /// happened to have.
    private func reanchorIfSeeked(to seconds: Double) {
        guard isScoringSinging, trackClock.isPlaying, let first = singerTracks.first else {
            return
        }
        guard abs(seconds - first.elapsed) > Self.seekToleranceSeconds else { return }
        for singer in singerTracks { singer.reset(at: seconds) }
        singers = []
    }

    /// Where lyrics are read from.
    static var lyricsDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YunAudio/Lyrics", isDirectory: true)
    }

    /// Where the song has got to, and what it is, and which words go with it.
    ///
    /// The player is asked about once a second and the moments in between are
    /// arithmetic — see `TrackClock`. The old shape asked on every poll, which
    /// measured 61.4 ms of Apple events against a 50 ms poll period, so the
    /// panel spent more than the whole of the main thread finding out something
    /// that advances at one second per second. Whatever the animation said, the
    /// highlight could not sweep, because nothing had time to draw it.
    func refreshNowPlaying() {
        guard isSingingVisible else { return }
        if !isHandRun {
            // Counted rather than conditioned on there being an answer yet. A
            // running player with nothing loaded answers nil every time, and
            // "ask again until it says something" would be the old cost back
            // for the one case nobody can act on.
            pollsSinceNowPlaying += 1
            if pollsSinceNowPlaying >= Self.nowPlayingEveryNPolls {
                pollsSinceNowPlaying = 0
                askThePlayer()
            }
        }
        followTheWords()
    }

    // MARK: Words with no player to ask

    /// True while the words came from a file somebody chose and the clock is
    /// being run by hand rather than by a player.
    ///
    /// Music and Spotify have scripting dictionaries. A browser, a hardware
    /// player, a file on the desktop and a karaoke machine plugged into the
    /// line input have none, and to all of them the panel used to say "Play
    /// something in Music or Spotify" and offer nothing else — which is most of
    /// the ways anybody actually plays a backing track. Choosing the words and
    /// starting them when the music starts is what a karaoke machine has always
    /// done, and it makes the whole path — words, tune, clock, score —
    /// exercisable without a music service being in any particular state.
    private(set) var isHandRun = false

    /// Whether hand-run words are moving.
    var isRunningWords: Bool { isHandRun && trackClock.isPlaying }

    /// Takes an `.lrc` chosen by hand, with the tune beside it if there is one.
    ///
    /// - Returns: False when nothing in the file carried a timestamp, which is
    ///   the honest answer for a page of words with no timing.
    @discardableResult
    func openWords(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let parsed = Lyrics.parse(text)
        else { return false }
        cancelLyricsLookup()
        isHandRun = true
        lyrics = parsed
        plainLyrics = nil
        lyricsSourceName = loc("Local file")
        lyricsLookupStatus = .local
        melody =
            ["mid", "midi"]
            .lazy
            .map { url.deletingPathExtension().appendingPathExtension($0) }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap(MidiMelody.parse)
            .first
        // Where the words run out. The last line is given the four seconds
        // `Lyrics.progress(at:)` gives it, and the tune wins when it is longer
        // — a hand-run clock with nothing to stop it would sweep on past the
        // end of a song that had already finished.
        let ends = max(
            melody?.duration ?? 0, (parsed.lines.last?.time ?? 0) - parsed.offset + 4)
        nowPlaying = NowPlaying.Track(
            application: loc("By hand"),
            title: parsed.title ?? url.deletingPathExtension().lastPathComponent,
            artist: parsed.artist ?? "", album: parsed.album ?? "",
            position: 0, duration: ends, isPlaying: false)
        trackClock.stop()
        trackClock.duration = ends
        lyricLine = nil
        lyricProgress = 0
        songSecond = 0
        if isScoringSinging { rebuildScoringReference() }
        return true
    }

    /// Starts the hand-run words from a moment on the song's clock.
    ///
    /// The same instant re-anchors every singer, because the score and the
    /// words have to be measured against the same zero or the per-line
    /// breakdown belongs to different lines than the ones it names.
    func runWords(from seconds: Double = 0) {
        guard isHandRun else { return }
        trackClock.adopt(
            seconds, isPlaying: true,
            trueAt: Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
        if var track = nowPlaying, !track.isPlaying {
            track.isPlaying = true
            nowPlaying = track
        }
        if isScoringSinging { restartScore() }
        followTheWords()
    }

    /// Stops them where they are.
    func stopWords() {
        guard isHandRun else { return }
        let held = songPosition
        trackClock.adopt(
            held, isPlaying: false,
            trueAt: Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
        if var track = nowPlaying, track.isPlaying {
            track.isPlaying = false
            nowPlaying = track
        }
    }

    /// Hands the panel back to whatever a player says.
    func closeWords() {
        guard isHandRun else { return }
        cancelLyricsLookup()
        isHandRun = false
        trackClock.stop()
        nowPlaying = nil
        nowPlayingFailure = nil
        lyrics = nil
        plainLyrics = nil
        lyricsSourceName = nil
        melody = nil
        lyricLine = nil
        lyricProgress = 0
        songSecond = 0
        lyricsLookupStatus = .idle
        pollsSinceNowPlaying = Self.nowPlayingEveryNPolls
    }

    /// How many polls apart a player is asked where it is.
    ///
    /// Twenty, which is once a second. The cheap read is 20.7 ms at the median
    /// on this machine, so this is 2.1% of the main thread against the 123% the
    /// full read on every poll cost. A second is also about as long as anybody
    /// can hold a seek or a pause against the interface without noticing, and
    /// the correction when one happens is measured rather than assumed —
    /// `trackClock.lastCorrection`.
    private static let nowPlayingEveryNPolls = 20

    @ObservationIgnored private var trackClock = TrackClock()
    /// Starts at the interval so that opening the panel asks at once rather
    /// than showing an empty header for a second.
    @ObservationIgnored private var pollsSinceNowPlaying = RouterModel.nowPlayingEveryNPolls
    /// Which player answered last, so the cheap read asks that one first rather
    /// than paying a round trip per installed player.
    @ObservationIgnored private var lastPlayer: String?

    /// How far the freewheeling clock had strayed when the player last spoke,
    /// in seconds. The only honest check on extrapolating at all.
    var lyricClockCorrection: Double { trackClock.lastCorrection }

    /// Asks the player where it is, without the interface waiting for it.
    ///
    /// This was a synchronous Apple event on the main actor: 20.7 ms for the
    /// position and 61.4 for the metadata, all of it spent inside the player's
    /// own main thread. Twice a second that is a frame gone twice a second for
    /// as long as the panel is open, and the previous version of this asked on
    /// every poll, which was 1.24 seconds of work per second of wall clock.
    ///
    /// One question at a time. A player that is slow to answer must not have a
    /// second put to it before it has answered the first, or a stall turns into
    /// a queue that never drains.
    private func askThePlayer() {
        // Once captured audio has identified a source, its acoustic timecode
        // is authoritative. Asking Music or Spotify as well could let a paused
        // track in either application overwrite the QQ Music or NetEase song
        // that is actually on the bus.
        guard recognisedApplication == nil, !isAskingThePlayer else { return }
        isAskingThePlayer = true
        NowPlaying.positionAsynchronously(
            preferring: lastPlayer, knownIdentity: nowPlaying?.identity
        ) { [weak self] position, track, failure, middle in
            self?.isAskingThePlayer = false
            self?.receivePosition(
                position, track: track, failure: failure, trueAt: middle)
        }
    }

    /// True while an ask is in flight.
    @ObservationIgnored private var isAskingThePlayer = false

    /// What the player said, applied on the main actor.
    private func receivePosition(
        _ position: NowPlaying.Position?, track: NowPlaying.Track?,
        failure: NowPlaying.QueryFailure?, trueAt middle: Double
    ) {
        // An answer to a question that stopped mattering while it was in the
        // air. The poll only asks when a player is the authority, but the ask
        // now happens on another thread and takes about twenty milliseconds, so
        // somebody who opens the panel and chooses an `.lrc` in that window
        // gets the player's reply landing on top of their file: the words, the
        // tune and the clock all replaced by whatever Spotify happens to be
        // paused at.
        //
        // Measured: the hand-run clock read 75.15 s of a nine-second file and
        // never moved, because the position adopted was a paused player's and a
        // paused clock does not advance. Twelve assertions in the flow check
        // say so, and every one of them had been passing before — the
        // synchronous version had no window for a late answer to arrive in.
        guard !isHandRun else { return }
        if let failure {
            nowPlayingFailure = failure
            // A player that did not answer must not be hammered once a second.
            // Timeout gets another chance in ten seconds; a denied Automation
            // request waits a minute, because only a setting change can alter
            // that answer.
            switch failure {
            case .denied:
                pollsSinceNowPlaying = -1180
            case .timedOut, .failed:
                pollsSinceNowPlaying = -180
            }
            trackClock.stop()
            return
        }
        nowPlayingFailure = nil
        guard let position else {
            lastPlayer = nil
            trackClock.stop()
            if nowPlaying != nil { nowPlaying = nil }
            if lyrics != nil { lyrics = nil }
            if plainLyrics != nil { plainLyrics = nil }
            if lyricsSourceName != nil { lyricsSourceName = nil }
            if melody != nil { melody = nil }
            return
        }
        lastPlayer = position.application
        // Fetched on the other thread only when the song had actually changed,
        // so arriving with one here *is* the change.
        if let track { adopt(track) }
        if var current = nowPlaying, current.isPlaying != position.isPlaying {
            current.isPlaying = position.isPlaying
            nowPlaying = current
        }
        trackClock.duration = nowPlaying?.duration ?? 0
        trackClock.adopt(position.seconds, isPlaying: position.isPlaying, trueAt: middle)
        reanchorIfSeeked(to: position.seconds)
    }

    private(set) var nowPlayingFailure: NowPlaying.QueryFailure?

    private func receiveMusicRecognition(
        _ result: Result<MusicRecognition.Match, MusicRecognition.Failure>
    ) {
        guard isSingingVisible, !isHandRun, let application = recognisedApplication else {
            return
        }
        switch result {
        case .failure(.catalogueAccessNotEnabled):
            musicRecognitionProblem = loc(
                "This build is not signed for the Shazam catalogue. Enable ShazamKit for the App ID to identify players without scripting support."
            )
        case let .failure(.failed(reason)):
            musicRecognitionProblem = String(
                format: loc("Music recognition is unavailable: %@"), reason)
        case let .success(match):
            musicRecognitionProblem = nil
            nowPlayingFailure = nil
            let track = NowPlaying.Track(
                application: application.name, title: match.title,
                artist: match.artist, album: match.album,
                position: match.position, duration: match.duration,
                isPlaying: true, identity: match.identity)
            if nowPlaying?.identity != match.identity {
                adopt(track)
            } else {
                nowPlaying = track
            }
            let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            trackClock.duration = match.duration
            trackClock.adopt(match.position, isPlaying: true, trueAt: now)
            reanchorIfSeeked(to: match.position)
            followTheWords()
        }
    }

    var nowPlayingProblem: String? {
        guard let failure = nowPlayingFailure else { return nil }
        switch failure {
        case let .timedOut(application):
            return String(
                format: loc("%@ did not answer YunAudio. Playback audio is still available."),
                application)
        case let .denied(application):
            return String(
                format: loc("Allow YunAudio to control %@ in Automation settings."),
                application)
        case let .failed(application, code):
            return String(
                format: loc("%@ could not be read (Apple Event %d)."), application, code)
        }
    }

    /// Takes a new song, with the words and the tune that go with it.
    private func adopt(_ track: NowPlaying.Track?) {
        cancelLyricsLookup()
        nowPlaying = track
        lyrics = track.flatMap(Self.findLyrics)
        let localPlain = track.flatMap(Self.findPlainLyrics)
        plainLyrics =
            lyrics == nil
            ? localPlain ?? track?.nativeLyrics
            : nil
        lyricsSourceName =
            lyrics != nil || localPlain != nil
            ? loc("Local file")
            : track?.nativeLyrics == nil ? nil : loc("Music")
        melody = track.flatMap(Self.findMelody)
        if let track {
            if lyrics != nil {
                lyricsLookupStatus = .local
            } else {
                lyricsLookupStatus = plainLyrics == nil ? .loading : .native
                startLyricsLookup(for: track)
            }
        } else {
            lyricsLookupStatus = .idle
        }
        if isScoringSinging { rebuildScoringReference() }
    }

    /// Tries the public synchronised-lyrics index once for a new song.
    ///
    /// This never runs from `refreshNowPlaying`: that method is called twenty
    /// times a second. `adopt` only runs when the player's track identity
    /// changes, so one song is one request and one cache file.
    private func startLyricsLookup(for track: NowPlaying.Track) {
        let query = OnlineLyrics.Query(
            title: track.title, artist: track.artist, album: track.album,
            duration: track.duration)
        let identity = Self.lyricsIdentity(for: track)
        if plainLyrics == nil { lyricsLookupStatus = .loading }
        lyricsLookupTask = Task { [weak self] in
            do {
                // OnlineLyrics is nonisolated, so its network and decoding work
                // runs on the generic executor. Keeping it as this task's child
                // also means changing songs cancels all four provider requests;
                // Task.detached left them running after their answer was stale.
                let match = try await OnlineLyrics.live.fetch(query)
                try Task.checkCancellation()
                guard let self,
                    let current = self.nowPlaying,
                    Self.lyricsIdentity(for: current) == identity
                else { return }
                guard let match else {
                    self.lyricsLookupStatus =
                        self.plainLyrics == nil ? .notFound : self.lyricsLookupStatus
                    return
                }
                if let parsed = match.parsed {
                    self.lyrics = parsed
                    self.plainLyrics = nil
                } else if let plain = match.plain {
                    self.plainLyrics = plain
                } else {
                    self.lyricsLookupStatus =
                        self.plainLyrics == nil ? .notFound : self.lyricsLookupStatus
                    return
                }
                self.lyricsSourceName = Self.lyricsSourceName(for: match.source)
                self.lyricsLookupStatus = .online
                self.followTheWords()
                if self.isScoringSinging { self.rebuildScoringReference() }

                guard let directory = Self.lyricsDirectory else { return }
                guard let text = match.cacheText else { return }
                let url = OnlineLyrics.cacheURL(
                    for: query, source: match.source,
                    extension: match.cacheExtension, in: directory)
                await Task.detached(priority: .utility) {
                    try? FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                }.value
            } catch is CancellationError {
                return
            } catch OnlineLyrics.Failure.rateLimited {
                guard let self,
                    self.nowPlaying.map(Self.lyricsIdentity(for:)) == identity
                else { return }
                if self.lyrics == nil, self.plainLyrics == nil {
                    self.lyricsLookupStatus = .rateLimited
                }
            } catch {
                guard let self,
                    self.nowPlaying.map(Self.lyricsIdentity(for:)) == identity
                else { return }
                if self.lyrics == nil, self.plainLyrics == nil {
                    self.lyricsLookupStatus = .failed
                }
            }
        }
    }

    private static func lyricsIdentity(for track: NowPlaying.Track) -> String {
        track.identity.isEmpty
            ? "\(track.searchKey)\u{1F}\(Int(track.duration.rounded()))"
            : track.identity
    }

    private static func lyricsSourceName(for source: OnlineLyrics.Source) -> String {
        switch source {
        case .lrclib: source.rawValue
        case .qqMusic: loc("QQ Music")
        case .netEase: loc("NetEase Cloud Music")
        case .lyricsOvh: source.rawValue
        }
    }

    private func cancelLyricsLookup() {
        lyricsLookupTask?.cancel()
        lyricsLookupTask = nil
    }

    func retryLyricsLookup() {
        guard let track = nowPlaying, lyrics == nil, !isHandRun else { return }
        cancelLyricsLookup()
        startLyricsLookup(for: track)
    }

    /// Moves the highlight to wherever the clock now says the song is.
    ///
    /// Every poll, and costing nothing: this is the half that had to be
    /// separated from the asking for the sweep to be able to move at all.
    private func followTheWords() {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let position = trackClock.position(at: now)
        // Published only when the second it displays changes. The timecode is
        // whole seconds, so republishing it twenty times a second would
        // invalidate the whole panel for a string that is the same string.
        if Int(position) != songSecond { songSecond = Int(position) }
        guard let lyrics else {
            if lyricLine != nil { lyricLine = nil }
            if lyricProgress != 0 { lyricProgress = 0 }
            return
        }
        let heard = position + lyricNudge
        let index = lyrics.index(at: heard)
        if lyricLine != index { lyricLine = index }
        let progress = lyrics.progress(at: heard)
        if lyricProgress != progress { lyricProgress = progress }
    }

    /// Finds an `.lrc` for a track by name.
    static func findLyrics(for track: NowPlaying.Track) -> Lyrics? {
        guard let url = bestFile(for: track, extensions: ["lrc"]),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return Lyrics.parse(text)
    }

    /// Finds locally cached or user-supplied words with no timing.
    static func findPlainLyrics(for track: NowPlaying.Track) -> String? {
        guard let url = bestFile(for: track, extensions: ["txt"]),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// Finds the tune, which lives beside the words under the same name.
    ///
    /// Beside rather than inside: an `.lrc` has nowhere to put a pitch, and
    /// inventing an extension to the format would mean nobody's existing files
    /// worked. A karaoke MIDI is older than the `.lrc` and people already have
    /// them.
    static func findMelody(for track: NowPlaying.Track) -> MidiMelody? {
        guard let url = bestFile(for: track, extensions: ["mid", "midi"]),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return MidiMelody.parse(data)
    }

    /// Picks the file in the lyrics folder that best matches a track.
    ///
    /// Matched loosely on purpose. A file somebody downloaded is called
    /// whatever the person who made it called it — "Artist - Title.lrc",
    /// "Title.lrc", with or without accents — and refusing to find it because
    /// of a hyphen would make the feature useless in exactly the case it exists
    /// for.
    ///
    /// - Parameters:
    ///   - track: What is playing.
    ///   - extensions: Which suffixes count, without the dot.
    /// - Returns: The best match, or nil when nothing in the folder looks like
    ///   this song.
    static func bestFile(for track: NowPlaying.Track, extensions: [String]) -> URL? {
        guard let directory = lyricsDirectory,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        let wanted = normalised(track.searchKey)
        let title = normalised(track.title)

        let candidates = names.filter { name in
            extensions.contains { name.lowercased().hasSuffix("." + $0) }
        }
        // Both names present is a better match than the title alone, so it is
        // preferred rather than taking whatever the directory listed first.
        let best =
            candidates.first { normalised($0).contains(wanted) }
            ?? candidates.first {
                let file = normalised($0)
                return file.contains(title) && file.contains(normalised(track.artist))
            }
            ?? candidates.first { normalised($0).contains(title) }
        return best.map { directory.appendingPathComponent($0) }
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
        guard updateOutputDelay(milliseconds, for: uid) else { return }
        commitOutputDelays()
    }

    /// Updates the continuous alignment control without rebuilding its
    /// aggregate for every pointer event. The final value is committed when
    /// the drag ends.
    func previewOutputDelay(_ milliseconds: Double, for uid: String) {
        if updateOutputDelay(milliseconds, for: uid) {
            outputDelaysNeedCommit = true
        }
    }

    func commitOutputDelays() {
        guard outputDelaysNeedCommit else { return }
        outputDelaysNeedCommit = false
        persist()
        // The delay is a property of the aggregate, decided when it is built,
        // so it cannot be swapped in the way a fader can.
        restartIfRunning()
    }

    @discardableResult
    private func updateOutputDelay(_ milliseconds: Double, for uid: String) -> Bool {
        let clamped = max(0, min(Self.maximumOutputDelay, milliseconds))
        guard outputDelays[uid] != clamped else { return false }
        if clamped == 0 { outputDelays[uid] = nil } else { outputDelays[uid] = clamped }
        outputDelaysNeedCommit = true
        return true
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
            rememberChannelChoice()
            persist()
            // Only the channel map moves, so this can be swapped in silently.
            if !reconfigureIfPossible() { restartIfRunning() }
        }
    }
    /// Which source channel a mono route takes, zero-based.
    var monoChannel: Int = 0 {
        didSet {
            guard oldValue != monoChannel else { return }
            rememberChannelChoice()
            persist()
            if !reconfigureIfPossible() { restartIfRunning() }
        }
    }

    /// Which channel of each source somebody chose, by device UID.
    ///
    /// Kept per device because it is a fact about that device. Without it,
    /// `applyChannelDefaults()` ran on every source change and put the choice
    /// back to the default — so deliberately picking the Seiren V3 Pro's third
    /// tap, the one past its expander, switching to another microphone and
    /// switching back returned silently to the first. The interface said
    /// nothing, and the signal is a plausible-sounding version of the right
    /// one, which is the worst way for this to be wrong.
    ///
    /// Stored as "stereo" or "mono:2" rather than as two maps: the preferences
    /// file is meant to be readable by somebody opening it, and one line per
    /// device says more than two halves of a decision in different places.
    var sourceChannelChoices: [String: String] = [:]

    private func rememberChannelChoice() {
        // Not while the model is being put back together or driven by a preset:
        // those are the application choosing, and only a person's choice is
        // worth remembering against their device.
        guard !isRestoring, !isApplyingPreset, !isAutoAdjusting,
            let uid = selectedSourceUID
        else { return }
        sourceChannelChoices[uid] =
            channelMode == .stereo ? "stereo" : "mono:\(monoChannel)"
    }

    /// Puts back what was chosen for this device, if anything ever was.
    ///
    /// - Returns: False when this device has never been set by hand, so the
    ///   caller falls back to working the default out from its topology.
    private func restoreChannelChoice() -> Bool {
        guard let uid = selectedSourceUID, let stored = sourceChannelChoices[uid] else {
            return false
        }
        if stored == "stereo" {
            channelMode = .stereo
            return true
        }
        guard stored.hasPrefix("mono:"), let channel = Int(stored.dropFirst(5)) else {
            return false
        }
        // Checked against the device as it is now: a profile somebody saved
        // when the interface had eight inputs must not select channel six on a
        // microphone that has one.
        guard channel < (selectedSource?.inputChannels ?? 0) else { return false }
        channelMode = .mono
        monoChannel = channel
        return true
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
            let preset = voicePreset
            applyLiveControl { engine in
                engine.setEffectParameter("cents", of: .pitch, to: preset.cents)
                engine.setEffectParameter("shift", of: .formant, to: preset.formantPercent)
            }
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
    /// Swapped live like the built-in stages rather than restarting the route.
    /// A third-party unit goes into the same chain the built-in ones do, so
    /// there was never a reason for adding one to cost seconds of silence when
    /// switching on a compressor does not.
    var enabledPlugins: [AudioUnitPlugin] = [] {
        didSet {
            guard oldValue != enabledPlugins else { return }
            pluginParameterCache = [:]
            persist()
            if !swapChainIfPossible() { restartIfRunning() }
        }
    }

    /// Ones that were asked for and would not load, with why.
    private(set) var failedPlugins: [AudioUnitLoadFailure] = []
    @ObservationIgnored private var pluginParameterCache: [String: [EffectParameter]] = [:]

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
        if let cached = pluginParameterCache[plugin.id] { return cached }
        guard let parameters = engine.pluginParametersIfAvailable(plugin.id) else {
            return []
        }
        pluginParameterCache[plugin.id] = parameters
        return parameters
    }

    func setPluginValue(
        _ value: Float, of parameter: EffectParameter, in plugin: AudioUnitPlugin
    ) {
        pluginValues["\(plugin.id).\(parameter.id)"] = value
        let parameterID = parameter.id
        let pluginID = plugin.id
        applyLiveControl {
            $0.setPluginParameter(parameterID, ofPlugin: pluginID, to: value)
        }
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
    /// How much of the isolated signal to use, 0…100.
    ///
    /// Written straight into whatever is rendering rather than restarting the
    /// route. An Audio Unit parameter write is realtime-safe, so dragging this
    /// slider used to tear the graph down and build it again for every value
    /// the drag passed through — seconds of silence to move a knob, on the one
    /// control somebody would want to move *while listening* to decide where it
    /// belongs.
    var voiceIsolationMix: Float = 100 {
        didSet {
            guard oldValue != voiceIsolationMix else { return }
            persist()
            let mix = voiceIsolationMix
            applyLiveControl {
                $0.setEffectParameter("mix", of: .voiceIsolation, to: mix)
            }
        }
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
    /// says — something making noise is worth being able to point at. A process
    /// holding the microphone counts as audible for this purpose: it is making
    /// no noise and it is the most consequential thing on the list.
    private var offeredApps: [AudioApplication] {
        availableApps.filter { !$0.isBackground || $0.isPlaying || $0.isRecording }
    }

    // MARK: A headset that has dropped to call quality

    /// An output that is a Bluetooth headset currently reduced to telephone
    /// quality, if there is one.
    ///
    /// The oldest complaint about audio on this platform, and the part of it
    /// nobody is ever told: classic Bluetooth carries either good sound in one
    /// direction (A2DP) or poor sound in both (HFP), and the radio switches the
    /// moment anything opens the microphone. So the music turns into a
    /// telephone call and the cause is in a different application entirely.
    ///
    /// There is nothing to set. The macOS 27 SDK was searched: CoreAudio
    /// publishes no profile or codec property, and the one switch that would do
    /// it — `AVAudioSessionCategoryOptionBluetoothHighQualityRecording` — is
    /// marked `API_AVAILABLE(ios(26.0))` and `API_UNAVAILABLE(macos)`.
    ///
    /// What can be done is to say so, name what did it, and offer the way out:
    /// leave the headset as an output and take the microphone from somewhere
    /// else. That is what this application is for, which is why the remedy is
    /// one line of interface rather than a feature.
    private(set) var headsetInCallQuality: AudioDevice?

    /// Reads the live sample rate off likely outputs first, then the rest.
    ///
    /// Synchronous HAL work, so callers run it on `engineQueue` except for the
    /// one initial device enumeration. Keeping it out of the computed property
    /// stops every recording-pill redraw from asking CoreAudio the same
    /// question at 20 Hz.
    nonisolated static func headsetInCallQuality(
        outputDevices: [AudioDevice],
        preferredUIDs: [String]
    ) -> AudioDevice? {
        let preferred = preferredUIDs.compactMap { uid in
            outputDevices.first { $0.uid == uid }
        }
        // A headset somebody is listening on but not routing to still matters,
        // which is why the rest remain a fallback.
        return preferred.first(where: { $0.hasFallenToCallQuality })
            ?? outputDevices.first(where: { $0.hasFallenToCallQuality })
    }

    /// Which applications currently have an input open, most interesting first.
    ///
    /// Ours is left out when it is the router itself: telling somebody that
    /// YunAudio has the microphone open, in YunAudio, is not news.
    var applicationsHoldingTheMicrophone: [AudioApplication] {
        availableApps.filter {
            $0.isRecording && $0.bundleID != Bundle.main.bundleIdentifier
        }
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
    /// Gated rather than unconditional because the background half is not
    /// free: 12 to 27 ms warm on this machine and 118 ms cold. Moving it off
    /// MainActor prevents a dropped frame; not asking for the same answer on
    /// every redraw prevents needless work elsewhere.
    ///
    /// - Parameter seconds: How stale the list may be before it is re-read.
    func refreshAppsIfStale(olderThan seconds: TimeInterval = 3) {
        if let refreshed = appsRefreshedAt, Date().timeIntervalSince(refreshed) < seconds {
            return
        }
        // Two copies of AppSourceList can appear at once. Their `.task`
        // modifiers are freshness requests, not two reasons to enumerate the
        // same HAL process list back to back.
        guard !appRefreshInFlight else { return }
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
            applyInputGain()
            persist()
            // Somebody moving this by hand is restating where the loop should
            // work from. Without that, the base was captured once — when
            // automatic levelling was switched on — and every later drag was
            // overwritten on the next tick: in a quiet room the offset is zero,
            // so the trim sprang straight back to where it had been, and the
            // control simply did not work while the feature was on.
            //
            // Rebased so the total stays where it was put. Setting the base to
            // the new value instead would make the trim jump by the offset the
            // moment the drag ended, which is the same defect wearing a hat.
            if isAutoLevelling, !isAutoAdjusting {
                autoLevelBase = Self.autoLevelBase(
                    afterManual: inputDecibels, offset: autoLevelOffset)
            }
        }
    }
    var isInputMuted = false {
        didSet {
            guard oldValue != isInputMuted else { return }
            applyInputMute()
            persist()
            // Nothing to warn about once the microphone is live again.
            if !isInputMuted { isSpeakingWhileMuted = false }
            // A streamer who hits mute means everywhere. OBS's own mute for the
            // same source is a separate switch on a separate window, and the
            // failure it produces is the one nobody notices in time.
            let muted = isInputMuted
            Task { await obsLink.mirrorMute(muted) }
            fire(isInputMuted ? .muted : .unmuted)
        }
    }

    // MARK: Speaking while muted

    /// CoreAudio's own detector, watching the source device.
    ///
    /// Kept for the lifetime of a route rather than made on demand: switching
    /// detection on is a write to the device, and doing that per question would
    /// be writing to somebody's hardware twenty times a second.
    @ObservationIgnored private var voiceWatcher: VoiceActivityWatcher?

    /// True when the microphone is muted and somebody is talking into it.
    ///
    /// The most-asked-for small feature in every conferencing application, and
    /// here it costs two device properties: no model, no processor time on the
    /// audio path, no latency. The detector CoreAudio publishes has its own
    /// echo cancellation, so the speakers playing somebody else talking does
    /// not set it off, and — the part that makes the feature possible at all —
    /// it keeps working under a process mute, where anything reading the routed
    /// signal would see the silence the mute produces.
    private(set) var isSpeakingWhileMuted = false

    /// Whether the source device publishes the detector at all.
    ///
    /// Measured rather than assumed from the macOS version: on this machine
    /// every input device publishes it — but on the **input** scope, and asking
    /// on the global scope reports that not one of them does. An interface that
    /// showed an indicator which could never light would be worse than one that
    /// says the device cannot do it.
    var canDetectVoiceActivity: Bool {
        guard let source = selectedSource else { return false }
        return VoiceActivityWatcher.isAvailable(on: source.id)
    }

    /// True while the detector this route built is actually running.
    ///
    /// `VoiceActivityWatcher` reports this and nothing in the application asked
    /// — which is the one question that decides whether "not speaking" means
    /// anything. Its initialiser returns a live object even when the write that
    /// switches detection on failed, and then the state reads 0 for ever,
    /// `isSpeakingWhileMuted` never becomes true, and the "muted, but talking"
    /// pill cannot appear, with nothing anywhere saying the detector is not
    /// running. Asked of the watcher rather than of the device, because it is
    /// the watcher's own claim that is being checked.
    var isDetectingVoiceActivity: Bool { voiceWatcher?.isObserving ?? false }

    private func startVoiceActivity() {
        guard voiceWatcher == nil, let source = selectedSource else { return }
        voiceWatcher = VoiceActivityWatcher(device: source.id) { [weak self] speaking in
            Task { @MainActor in
                guard let self else { return }
                // Only ever a warning about a mute. Publishing "somebody is
                // talking" while unmuted would be a meter, and there is a real
                // one two rows up that measures the signal rather than asking
                // the system about it.
                let wanted = speaking && self.isInputMuted
                let changed = wanted != self.isSpeakingWhileMuted
                self.isSpeakingWhileMuted = wanted
                // Only on the edge. A script told once a second that somebody
                // is still talking cannot tell that from somebody starting.
                if changed, wanted { self.fire(.speakingWhileMuted) }
            }
        }
    }

    private func stopVoiceActivity() {
        voiceWatcher = nil
        isSpeakingWhileMuted = false
    }
    var outputDecibels: Float = 0 {
        didSet {
            guard oldValue != outputDecibels else { return }
            applyOutputGain()
            persist()
        }
    }
    var isOutputMuted = false {
        didSet {
            guard oldValue != isOutputMuted else { return }
            applyOutputMute()
            persist()
        }
    }

    /// The four level settings, each in one place.
    ///
    /// Written once rather than at each call site because they are set from two
    /// of them — the control being moved, and a freshly built graph being
    /// caught up — and a push that is recorded in one place and not the other
    /// is exactly the bookkeeping this is here to make impossible.
    private func applyInputGain() {
        let gain = Self.gain(fromDecibels: inputDecibels)
        applyLiveControl { $0.setInputGain(gain) }
        appliedToGraph.insert(.inputGain)
    }

    private func applyInputMute() {
        let muted = isInputMuted
        applyLiveControl { $0.setInputMuted(muted) }
        appliedToGraph.insert(.inputMute)
    }

    private func applyOutputGain() {
        let gain = Self.gain(fromDecibels: outputDecibels)
        applyLiveControl { $0.setOutputGain(gain) }
        appliedToGraph.insert(.outputGain)
    }

    private func applyOutputMute() {
        let muted = isOutputMuted
        applyLiveControl { $0.setOutputMuted(muted) }
        appliedToGraph.insert(.outputMute)
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
            refreshHeadsetQualityAsynchronously()
            // A monitor the engine itself gave up on is already out of a route
            // that is running. Restarting would take a working mix down to
            // arrive exactly where it already is — and the start it would run
            // is the one that has just been proved to work.
            guard !isDroppingMonitor else { return }
            // A new choice is a new question, so the last refusal stops being
            // an answer to it.
            droppedMonitorName = nil
            droppedMonitorReason = nil
            restartIfRunning()
        }
    }

    /// The monitor output the engine could not bring up, by name, or nil when
    /// monitoring is doing what it was asked to.
    ///
    /// Kept beside `lastError` rather than only inside it: an error is the last
    /// thing that went wrong anywhere and is cleared by the next thing that goes
    /// right, whereas a monitor that was dropped stays dropped. A picker that
    /// has quietly gone back to "Off" with nothing to explain it is precisely
    /// the silent disappearance this project keeps finding in other forms.
    private(set) var droppedMonitorName: String?
    /// What the engine said when it refused, verbatim. Technical on purpose —
    /// the failed plugins are reported the same way, because the status is the
    /// only part the device's own author can act on.
    private(set) var droppedMonitorReason: String?

    /// Set while the monitor is being cleared on the engine's behalf rather than
    /// on the user's, so the picker's `didSet` does not order a restart of a
    /// route that has just come up.
    @ObservationIgnored private var isDroppingMonitor = false

    /// Takes a monitor the engine gave up on out of the interface, and says
    /// which one it was and what it said.
    private func monitorWasDropped(_ dropped: RoutingEngine.DroppedMonitor) {
        // The name while it is still in the list; the remembered one after that.
        // "PG32UCDM would not start" is a sentence somebody can act on and
        // "AppleGFXHDAEngineOutputDP:…" is not.
        let name =
            outputDevices.first(where: { $0.uid == dropped.uid })?.name
            ?? deviceNames[dropped.uid] ?? dropped.uid
        droppedMonitorName = name
        droppedMonitorReason = dropped.reason
        isDroppingMonitor = true
        monitorDeviceUID = nil
        isDroppingMonitor = false
        // Faders are positions in the engine's route list and that list is now
        // shorter than the one this model handed over. Re-read rather than
        // adjusted here: the engine is the only thing that knows what it built.
        let installed = engine.currentRoutes
        if installed != activeRoutes {
            activeRoutes = installed
            routeGains = installed.map(\.gain)
            routeMutes = installed.map(\.isMuted)
        }
        remapMonitorRoutes()
        lastError = String(
            format: loc("%@ would not start as a monitor; the mix is carrying on without it."),
            name)
    }

    /// Extra inputs and outputs the engine gave up on, by name.
    ///
    /// The same argument as `droppedMonitorName`: an extra device that will not
    /// join must not cost somebody the route, and must not vanish from the
    /// interface with nothing said either. Held rather than only put in
    /// `lastError`, because the error is cleared by the next thing that goes
    /// right and a device that was dropped stays dropped.
    /// Split by end rather than kept as one list, so the notice can appear
    /// beside the picker somebody is actually looking at. A message about a
    /// microphone under the output list is a message nobody reads.
    private(set) var droppedExtraInputNames: [String] = []
    private(set) var droppedExtraOutputNames: [String] = []

    /// Takes the extras the engine could not bring up out of the interface, and
    /// names them.
    private func extrasWereDropped(_ dropped: [RoutingEngine.DroppedMonitor]) {
        guard !dropped.isEmpty else { return }
        let gone = Set(dropped.map(\.uid))
        // Read before the removals below, or every dropped device looks like
        // neither an input nor an output.
        droppedExtraInputNames =
            additionalSourceUIDs.filter { gone.contains($0) }.map { deviceName($0) ?? $0 }
        droppedExtraOutputNames =
            additionalDestinationUIDs.filter { gone.contains($0) }.map { deviceName($0) ?? $0 }
        let names = droppedExtraInputNames + droppedExtraOutputNames
        additionalSourceUIDs.removeAll { gone.contains($0) }
        additionalDestinationUIDs.removeAll { gone.contains($0) }
        persist()
        // Same reason as the monitor: the engine built a shorter route list
        // than this model handed it, and only the engine knows what it built.
        let installed = engine.currentRoutes
        if installed != activeRoutes {
            activeRoutes = installed
            routeGains = installed.map(\.gain)
            routeMutes = installed.map(\.isMuted)
        }
        remapMonitorRoutes()
        lastError = String(
            format: loc("%@ would not join the route; the mix is carrying on without it."),
            names.joined(separator: ", "))
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
        applyLiveControl { engine in
            for index in indices { engine.setGain(gain, forRouteAt: index) }
        }
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
        return (bufferFrames + Double(monitorLatencyFrames)) / rate * 1000
    }

    /// The monitor's reported latency and safety offset, read off MainActor.
    private(set) var monitorLatencyFrames = 0

    private func applyMonitorGain() {
        // The microphone's own send follows the monitor level unless somebody
        // has moved it themselves.
        guard let uid = selectedSourceUID, monitorSends[uid] == nil,
            let indices = monitorRouteIndices[uid]
        else { return }
        let gain = Self.gain(fromDecibels: monitorDecibels)
        applyLiveControl { engine in
            for index in indices { engine.setGain(gain, forRouteAt: index) }
        }
    }

    /// Below this the fader reads as −∞ and the gain is exactly zero, so the
    /// bottom of the travel is silence rather than something very quiet.
    nonisolated static let minimumDecibels: Float = -40

    nonisolated static func gain(fromDecibels decibels: Float) -> Float {
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
    var hardwareGain: AudioDevice.HardwareGain? { hardwareGainReading }

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

    /// What the canceller is doing, or nil when it is not in the path.
    var echoStatus: EchoCancellationStatus? { engine.echoCancellationStatus }

    /// Why the canceller is not in the path, when it was asked for.
    ///
    /// The engine has recorded this since it was written and only the
    /// command-line harness ever asked. Somebody who switched echo
    /// cancellation on in the menu bar, and got none, was told nothing at all.
    var echoCancellationMessage: String? {
        guard cancelsEcho, isRunning, let reason = engine.lastEchoCancellationError
        else { return nil }
        return Self.echoMessage(reason)
    }

    /// Split out for the reason `isolationMessage` is: the failure cannot be
    /// produced on demand, and the mapping is the testable part of it.
    static func echoMessage(_ reason: String) -> String {
        switch reason {
        case RoutingEngine.EchoFailure.notBuilt:
            loc("The echo canceller could not be built.")
        case RoutingEngine.EchoFailure.wouldNotStart:
            loc("The echo canceller would not start.")
        default: reason
        }
    }

    // MARK: Recording

    /// Container to write. WAV keeps a bit-exact path bit-exact on disk; AAC is
    /// a quarter the size and a lossy copy of the thing this project spends
    /// most of its effort keeping intact.
    ///
    /// Persisted, unlike `recordsStems` beside it, which it was not: the picker
    /// in the recording panel wrote here, the engine read it, presets carried
    /// it — and every launch put it back to WAV. Somebody choosing AAC to save
    /// disk got WAV files the next morning with nothing to say why.
    var recordingFormat: Recorder.Format = .wav {
        didSet { if oldValue != recordingFormat { persist() } }
    }

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
        let paused = isRecordingPaused
        applyLiveControl { $0.setRecordingPaused(paused) }
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
            // `recordStart` and `recordStop` were declared in `ScriptHost.Event`
            // and raised by nothing, which is worse than absent: the event names
            // are listed in the scripting help, and `installEvents` refuses an
            // unknown name precisely so that a typo cannot become a handler that
            // never fires. So `yun.on('recordStop', …)` was accepted, listed and
            // never called — the one failure that guard exists to prevent.
            fire(
                .recordingStopped,
                ["file": recordingURL?.path ?? "", "seconds": recordingSeconds])
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
            fire(.recordingStarted, ["file": recordingURL?.path ?? ""])
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
        // growing minutes ago — which is what it did, because the writer
        // failing does not release the recorder and `isRecording` therefore
        // stayed true. The reason is asked for first now, and it is the
        // system's own sentence about what went wrong rather than this
        // application's guess at it.
        if let reason = engine.recordingError {
            engine.stopRecording()
            isRecording = false
            lastError = String(format: loc("Recording stopped: %@"), reason)
        } else if !engine.isRecording {
            isRecording = false
            lastError = loc("Recording stopped: the file could not be written.")
        }
    }

    /// Populates the model with representative state for the offscreen design
    /// captures. Not called by the running app.
    func prepareForRendering() {
        refreshAppsForVerification()
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
        // Two singers, because two is what the duet has to be checked at: one
        // score is one colour and proves nothing about whether the second is
        // legible beside it in either appearance. The switch above them stays
        // off, because it is wired to real taps and this model has none — so
        // the capture shows the control at rest and the rows it produces at
        // once, which is what a design check wants to look at.
        singers = [
            Singer(
                uid: "preview-one", name: loc("Microphone"), hertz: 220,
                score: Self.previewScore(percentage: 78, error: -0.31)),
            Singer(
                uid: "preview-two", name: loc("Source"), hertz: 330,
                score: Self.previewScore(percentage: 54, error: 0.42)),
        ]

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

    /// A score with nothing behind it, for the design captures only.
    private static func previewScore(percentage: Double, error: Double) -> KaraokeScore {
        KaraokeScore(
            percentage: percentage, onPitchSeconds: 84 * percentage / 100,
            nearPitchSeconds: 6, silentSeconds: 12, referenceSeconds: 96, sungSeconds: 88,
            meanErrorSemitones: error, lines: [])
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
    ///
    /// Answered once and remembered. The answer is two binaries read off disk
    /// and hashed — 128 µs with a driver bundled beside the app, 23 µs without
    /// — and the window's body asked for it on every redraw, which is twenty
    /// times a second while a route is up. Nothing can change it except this
    /// application installing a driver, which is the one place it is recomputed.
    private(set) var driverIsOutOfDate = DriverInstaller.installedIsOutOfDate

    func installDriver() {
        isInstallingDriver = true
        driverMessage = nil
        let outcome = DriverInstaller.install()
        isInstallingDriver = false
        // The one thing that can change the answer, so the one place it is
        // asked again.
        driverIsOutOfDate = DriverInstaller.installedIsOutOfDate
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

    /// Takes the driver back off.
    ///
    /// It existed and nothing called it. The application offered to install a
    /// driver and gave no way at all to remove one — which is worse than the
    /// other way round, because an installation somebody cannot undo is a
    /// change to a machine they have to look up how to reverse. The command was
    /// in the README and nowhere in the interface.
    ///
    /// Routing is stopped first, deliberately. Removing the plug-in restarts
    /// `coreaudiod`, and a route running through the device that is about to
    /// stop existing is an aggregate whose member disappears underneath it.
    func removeDriver() {
        if isRunning { stop() }
        isInstallingDriver = true
        driverMessage = nil
        let outcome = DriverInstaller.uninstall()
        isInstallingDriver = false
        driverIsOutOfDate = DriverInstaller.installedIsOutOfDate
        switch outcome {
        case .removed:
            driverMessage = nil
            // The device goes with it, so anything pointing at it has to be let
            // go rather than left as a UID that resolves to nothing.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.refreshDevices()
                if self.selectedDestinationUID == ClockAnchorPublisher.driverDeviceUID {
                    self.selectedDestinationUID = nil
                    self.selectDefaults()
                }
            }
        case let .failed(reason):
            driverMessage = reason
        case .installed, .cancelled:
            driverMessage = nil
        }
    }

    /// Refreshes the application list without putting CoreAudio on MainActor.
    ///
    /// The AppKit snapshot is value-only and measured at about 1.23 ms. The HAL
    /// process enumeration behind `grouped` is 12–27 ms warm and 118 ms cold,
    /// which is a dropped frame before the list has drawn its first row.
    func refreshApps() {
        if appRefreshInFlight {
            // A person pressing Refresh should not be ignored, but neither
            // should ten presses queue ten identical HAL enumerations.
            appRefreshPending = true
            return
        }
        appRefreshInFlight = true
        let workspace = AudioApplications.workspaceSnapshot()
        let keeping = capturedAppBundleIDs
        let revision = appListRevision
        engineQueue.async {
            let applications =
                (try? AudioApplications.grouped(keeping: keeping, workspace: workspace)) ?? []
            Task { @MainActor in
                // A route start can publish a newer enumeration while this
                // request is crossing back to MainActor. The old list must not
                // win merely because its unstructured task ran second.
                if self.appListRevision == revision {
                    self.appListRevision &+= 1
                    self.availableApps = applications
                    self.appsRefreshedAt = Date()
                    self.refreshHeadsetQualityAsynchronously()
                }
                self.appRefreshInFlight = false

                // A selection changed while HAL was answering, or a manual
                // refresh arrived. One latest rerun is enough for both.
                if self.capturedAppBundleIDs != keeping { self.appRefreshPending = true }
                guard self.appRefreshPending else { return }
                self.appRefreshPending = false
                self.refreshApps()
            }
        }
    }

    @ObservationIgnored private var appRefreshInFlight = false
    @ObservationIgnored private var appRefreshPending = false
    @ObservationIgnored private var appListRevision = 0

    /// The deterministic, blocking form used only by rendering and flow checks.
    ///
    /// Their next assertion has to see the completed list. Production controls
    /// call `refreshApps()` above and never pay for HAL on the main actor.
    func refreshAppsForVerification() {
        // Anything already captured is listed whether or not it happens to be
        // audible at this instant. A process with no bundle identifier is listed
        // only while the HAL says it is running output, and that property blinks
        // — see the note in `AudioApplications.group`. `start` calls this and
        // then resolves the captured identifiers against what came back, so a
        // blink at that moment meant no tap, no route, and nothing said about
        // it. Measured with the flow check's own player, one argument apart:
        // without this, two routes and "resolved to no running process"; with
        // it, four routes and the key it was built in.
        appListRevision &+= 1
        availableApps = (try? AudioApplications.grouped(keeping: capturedAppBundleIDs)) ?? []
        appsRefreshedAt = Date()
        refreshHeadsetQualityAsynchronously()
    }

    private func refreshHeadsetQualityAsynchronously() {
        let outputs = outputDevices
        let preferred = [selectedDestinationUID, monitorDeviceUID].compactMap { $0 }
        let monitor = monitorDeviceUID.flatMap { uid in
            outputs.first(where: { $0.uid == uid })
        }
        engineQueue.async {
            let headset = Self.headsetInCallQuality(
                outputDevices: outputs,
                preferredUIDs: preferred)
            let latency =
                monitor?.latencyFrames(scope: kAudioObjectPropertyScopeOutput) ?? 0
            Task { @MainActor in
                self.publish(headset, to: \.headsetInCallQuality)
                self.publish(latency, to: \.monitorLatencyFrames)
            }
        }
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

    /// Captured identifiers that the last start resolved to no running process.
    ///
    /// Not an error — an application ticked weeks ago and not running today is
    /// the ordinary case — but until now it was not anything at all. A capture
    /// that resolves to nothing builds no tap, and a mix with no tap in it looks
    /// exactly like a mix whose tap is silent, which is how an afternoon went
    /// into the analysers before anybody established that no music had been put
    /// on the bus.
    @ObservationIgnored private(set) var unresolvedCaptures: [String] = []

    /// Captured applications whose tap CoreAudio refused at the last start.
    ///
    /// The other half of the same question. `lastError` says this too, once,
    /// and then the next thing to go wrong writes over it — so the fact that a
    /// capture was refused survives here for anything asking afterwards.
    @ObservationIgnored private(set) var refusedCaptures: [String] = []

    /// How many channels of a tap to route into the destination.
    ///
    /// A tap that publishes no format is taken as stereo. So is one that
    /// publishes a format carrying zero channels, which is a *different* thing
    /// and `?? 2` did not cover: it only sees the absent case, so a present
    /// zero would have built no routes at all and said nothing about it —
    /// indistinguishable from a tap that is merely quiet. The same trap as the
    /// `?? 48000` guarding the reported sample rate a few hundred lines down,
    /// and worth closing for the same reason rather than because it has been
    /// seen: a mix silently missing a source is what this whole area cost.
    ///
    /// - Parameters:
    ///   - published: What the tap says it carries, if it says anything.
    ///   - destination: Channels the destination has room for.
    /// - Returns: How many channels to build routes for.
    nonisolated static func channelsToRoute(published: UInt32?, destination: Int) -> Int {
        let carried = Int(published ?? 0)
        return min(destination, carried > 0 ? carried : 2)
    }

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
        applyLiveControl { $0.clearOutputClipping() }
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
            if current[index] >= Self.clipThreshold, !clipped[index] {
                clipped[index] = true
            }
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
            rebuiltRoutes()
        }
    }

    /// Called after the engine has published a graph built by `updateRoutes`.
    ///
    /// That path carries the gains, the mutes, the recording rings and the
    /// ducking across, and does not carry the output correction — the engine
    /// says so in as many words, and says the model puts it back. Nothing did:
    /// dragging one cable in the patchbay, or switching between mono and
    /// stereo, silently took somebody's headphone correction and tone control
    /// out of the path, with the interface still showing both.
    private func rebuiltRoutes() {
        remapMonitorRoutes()
        appliedToGraph.remove(.headphoneCorrection)
        applyCorrections()
    }

    /// Rebuilds the source-to-monitor-route map from the routes that are
    /// actually running.
    ///
    /// Route indices are positions in a list, and a patchbay edit moves them:
    /// pulling one cable from the main mix shifts every monitor route down by
    /// one. The map was built once, in `start`, and never rebuilt — so after an
    /// edit the monitor faders drove whichever route had inherited the old
    /// index, which on a two-bus setup is somebody's send to the far end.
    private func remapMonitorRoutes() {
        guard let uid = monitorDeviceUID else {
            monitorRouteIndices = [:]
            return
        }
        var map: [String: [Int]] = [:]
        for (index, route) in activeRoutes.enumerated()
        where route.destination.deviceUID == uid {
            map[route.source.deviceUID, default: []].append(index)
        }
        monitorRouteIndices = map
    }

    /// True when every remembered monitor route still points at a route into
    /// the monitor.
    ///
    /// The invariant behind every monitor fader. It is not visible from the
    /// interface — a send driving the wrong route changes a level somewhere
    /// else and nothing says so — so it is asserted instead.
    var monitorRoutesAreConsistent: Bool {
        guard let uid = monitorDeviceUID else { return monitorRouteIndices.isEmpty }
        return monitorRouteIndices.values.joined().allSatisfy { index in
            index < activeRoutes.count && activeRoutes[index].destination.deviceUID == uid
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
        let mutes = routeMutes.indices.map { (index: $0, muted: isSilenced($0)) }
        applyLiveControl { engine in
            for entry in mutes {
                engine.setMuted(entry.muted, forRouteAt: entry.index)
            }
        }
    }

    func setGain(_ gain: Float, forRouteAt index: Int) {
        guard index < routeGains.count else { return }
        routeGains[index] = gain
        applyLiveControl { $0.setGain(gain, forRouteAt: index) }
        persist()
    }

    /// A route's fader position in decibels.
    ///
    /// The output's own trim comes back off, so the fader shows what somebody
    /// set for that source rather than what the wire ends up carrying. Without
    /// it, turning a second pair of speakers down moved every fader on the
    /// strip and the two controls fought each other.
    func faderDecibels(forRouteAt index: Int) -> Float {
        guard index < routeGains.count else { return 0 }
        let gain = routeGains[index]
        guard gain > 0 else { return -40 }
        return 20 * log10(gain) - outputTrimDecibels(forRouteAt: index)
    }

    func setFaderDecibels(_ decibels: Float, forRouteAt index: Int) {
        setGain(
            yunGainMultiplier(decibels: decibels + outputTrimDecibels(forRouteAt: index)),
            forRouteAt: index)
    }

    // MARK: What each output is worth on its own

    /// A level per additional output, in decibels.
    ///
    /// The primary output has the master and the monitor has its own level;
    /// these are the outputs that had neither. Applied as a trim on top of each
    /// source's fader rather than as a stage of its own, because the engine's
    /// master is a single global gain over the whole mix and cannot say "this
    /// output quieter than that one" — the per-route gain is the only place
    /// where the difference between two outputs can be expressed at all.
    ///
    /// Keyed by device UID for the reason `busGraphicEQ` is: the bus letters
    /// are positional, and a level dialled in for a pair of speakers must not
    /// migrate to a recorder because a picker changed.
    private(set) var outputTrims: [String: Float] = [:]

    func outputTrim(of uid: String) -> Float { outputTrims[uid] ?? 0 }

    /// Twelve decibels up is as much as a trim should be able to add before it
    /// is doing the master's job; the bottom of the travel is silence.
    static let maximumOutputTrim: Float = 12

    func setOutputTrim(_ decibels: Float, for uid: String) {
        let clamped = max(Self.minimumDecibels, min(Self.maximumOutputTrim, decibels))
        guard outputTrim(of: uid) != clamped else { return }
        // The fader positions as they read now, taken before the trim moves.
        // Re-applied afterwards, they keep the balance somebody set between
        // the sources while the whole output moves together.
        let indices = activeRoutes.indices.filter {
            activeRoutes[$0].destination.deviceUID == uid
        }
        let positions = indices.map { faderDecibels(forRouteAt: $0) }
        if clamped == 0 { outputTrims[uid] = nil } else { outputTrims[uid] = clamped }
        persist()
        for (index, position) in zip(indices, positions) {
            setFaderDecibels(position, forRouteAt: index)
        }
    }

    private func outputTrimDecibels(forRouteAt index: Int) -> Float {
        guard index < activeRoutes.count else { return 0 }
        return outputTrim(of: activeRoutes[index].destination.deviceUID)
    }

    /// Puts the trims back on a route that has just been built.
    ///
    /// The engine builds every route at the gain the model handed it, which is
    /// the fader and not the fader plus the trim — so without this a restart
    /// silently put every trimmed output back to unity, and the slider went on
    /// showing the value nobody was hearing.
    private func applyOutputTrims() {
        guard !outputTrims.isEmpty else { return }
        for index in activeRoutes.indices where index < routeGains.count {
            let trim = outputTrimDecibels(forRouteAt: index)
            guard trim != 0 else { continue }
            setGain(routeGains[index] * Self.gain(fromDecibels: trim), forRouteAt: index)
        }
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

    /// Builds the logical sources for a route list, in first-seen order.
    ///
    /// Kept pure so the grouping arithmetic can be asserted independently of
    /// the model and so the cache below cannot become a second implementation.
    nonisolated static func groupRoutes(_ routes: [Route]) -> [SourceGroup] {
        var order: [String] = []
        var members: [String: [Int]] = [:]
        for (index, route) in routes.enumerated() {
            let uid = route.source.deviceUID
            if members[uid] == nil { order.append(uid) }
            members[uid, default: []].append(index)
        }
        return order.map { SourceGroup(uid: $0, routes: members[$0] ?? []) }
    }

    /// Routes grouped by source, rebuilt only when the route list changes.
    ///
    /// KTV, transcription, MIDI and two visible mixers ask for this repeatedly;
    /// while singing, the recognition path alone can ask twice per 20 Hz poll.
    /// The route list changes on graph publication, not on a meter tick, so
    /// rebuilding a dictionary and several arrays at every read was pure churn.
    ///
    /// Touching `activeRoutes` preserves the Observation dependency for views
    /// while returning the COW cache itself does not allocate.
    var sourceGroups: [SourceGroup] {
        _ = activeRoutes
        return groupedActiveRoutes
    }

    @ObservationIgnored private var groupedActiveRoutes: [SourceGroup] = []

    /// The first route of a group, which is what every per-route accessor is
    /// keyed on.
    func representative(of group: SourceGroup) -> Route? {
        guard let first = group.routes.first, first < activeRoutes.count else { return nil }
        return activeRoutes[first]
    }

    struct SourceMeter: Sendable, Equatable {
        let level: Float
        let peakHold: Float
        let isClipped: Bool
    }

    /// Reduces a logical source's channels in one allocation-free pass.
    ///
    /// RouteStrip draws all three values together. It used to ask for each one
    /// separately, and the level and hold accessors each built a temporary
    /// `compactMap` array: four sources at twenty hertz made 160 short-lived
    /// arrays a second for two maxima over lists usually two elements long.
    nonisolated static func sourceMeter(
        routeIndices: [Int],
        levels: [Float],
        peakHolds: [Float],
        clipped: [Bool]
    ) -> SourceMeter {
        var level: Float = 0
        var peakHold: Float = 0
        var isClipped = false
        var routeIndex = 0
        while routeIndex < routeIndices.count {
            let index = routeIndices[routeIndex]
            if index >= 0, index < levels.count { level = max(level, levels[index]) }
            if index >= 0, index < peakHolds.count {
                peakHold = max(peakHold, peakHolds[index])
            }
            if index >= 0, index < clipped.count {
                isClipped = isClipped || clipped[index]
            }
            routeIndex += 1
        }
        return SourceMeter(level: level, peakHold: peakHold, isClipped: isClipped)
    }

    func meter(of group: SourceGroup) -> SourceMeter {
        Self.sourceMeter(
            routeIndices: group.routes,
            levels: levels,
            peakHolds: peakHolds,
            clipped: clipped)
    }

    func isClipped(_ group: SourceGroup) -> Bool {
        var routeIndex = 0
        while routeIndex < group.routes.count {
            let index = group.routes[routeIndex]
            if index >= 0, index < clipped.count, clipped[index] { return true }
            routeIndex += 1
        }
        return false
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
        setSourceLevel(decibels, for: group.uid)
    }

    // MARK: What each source is worth, whether or not it is running

    /// Each source's fader position, in decibels, by source UID.
    ///
    /// Written down for two reasons, both of which were defects. A fader lived
    /// only as the gain of a route the engine had built, so it went back to
    /// unity on every restart of the application and nothing said it had — and
    /// while the route is down there are no routes at all, so a device's own
    /// level had nowhere to be shown next to the device.
    ///
    /// Keyed by source UID rather than by route index because that is what it
    /// is a fact about: the indices are positional and change whenever an
    /// output is added, a capture appears, or the monitor comes and goes.
    private(set) var sourceLevels: [String: Float] = [:]

    func sourceLevel(of uid: String) -> Float { sourceLevels[uid] ?? 0 }

    func setSourceLevel(_ decibels: Float, for uid: String) {
        let clamped = max(Self.minimumDecibels, min(Self.maximumOutputTrim, decibels))
        if clamped == 0 { sourceLevels[uid] = nil } else { sourceLevels[uid] = clamped }
        persist()
        // Only the main mix. The monitor's routes are governed by that source's
        // own send, and moving both from one control is what the second mix
        // exists not to do.
        let monitored = Set(monitorRouteIndices[uid] ?? [])
        for index in activeRoutes.indices
        where activeRoutes[index].source.deviceUID == uid && !monitored.contains(index) {
            setFaderDecibels(clamped, forRouteAt: index)
        }
    }

    /// Puts the levels back on routes the engine has just built, for the reason
    /// `applyOutputTrims` does.
    private func applySourceLevels() {
        guard !sourceLevels.isEmpty else { return }
        for (uid, decibels) in sourceLevels {
            let monitored = Set(monitorRouteIndices[uid] ?? [])
            for index in activeRoutes.indices
            where activeRoutes[index].source.deviceUID == uid && !monitored.contains(index) {
                setFaderDecibels(decibels, forRouteAt: index)
            }
        }
    }

    /// What a source is called in the mixer: its name, and how many channels
    /// it carries when that is worth saying.
    func sourceLabel(for group: SourceGroup) -> String {
        guard let route = representative(of: group) else { return "" }
        let name = routeTitle(route)
        // Distinct source channels, not routes. With a second output in the
        // path every source has twice the routes and carries exactly as many
        // channels as before, so counting wires said a mono microphone was
        // "2ch" the moment somebody added speakers.
        let channels = Set(
            group.routes.compactMap {
                $0 < activeRoutes.count ? activeRoutes[$0].source.channel : nil
            })
        guard channels.count > 1 else { return name }
        return "\(name)  \(channels.count)ch"
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
        applyLiveControl { $0.setMuted(muted, forRouteAt: index) }
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
                // A chain swap holds the queue for as long as it takes to build
                // the Audio Units, which is long enough for somebody to press
                // Stop into it and be refused.
                if self.honourPendingStop() { return }
                guard swapped else {
                    self.restartIfRunning()
                    return
                }
                self.failedPlugins = engine.failedPlugins
                // A freshly built chain comes up at each stage's own defaults,
                // so the stored knob positions have to be pushed back — the
                // same reason a restart does it.
                self.appliedToGraph.remove(.effectValues)
                self.applyEffectValues()
            }
        }
        return true
    }

    /// The stages actually rendering. Not the same as `enabledEffects`: one
    /// that will not instantiate is dropped, and until recently a single
    /// enabled stage built no chain at all.
    @ObservationIgnored private var activeEffectStageCache: [EffectKind] = []

    var activeEffectStages: [EffectKind] {
        if let current = engine.activeEffectStagesIfAvailable {
            activeEffectStageCache = current
        }
        return activeEffectStageCache
    }

    /// How much each dynamics stage is pulling the signal down, in decibels.
    ///
    /// A compressor with its threshold set wrong is completely silent about it:
    /// it sounds like a compressor doing nothing, which is what it is. The only
    /// way to tell is to watch the reduction, which is why every compressor
    /// ever shipped has this meter and why two knobs without one are guesswork.
    private(set) var gainReduction: [EffectKind: Float] = [:]

    /// The stages that can report how much they are pulling the signal down.
    ///
    /// Named rather than repeated, because the interface needs the same answer:
    /// a meter for a stage that will never publish one is a view that redraws
    /// with the poll and draws nothing, eleven times over.
    static let meteredStages: Set<EffectKind> = [.compressor, .gate]

    private func refreshGainReduction() {
        for kind in Self.meteredStages where enabledEffects.contains(kind) {
            guard let value = engine.gainReduction(of: kind) else { continue }
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
        let parameterID = parameter.id
        applyLiveControl {
            $0.setEffectParameter(parameterID, of: kind, to: value)
        }
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
        appliedToGraph.insert(.effectValues)
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

    /// What the chain costs, and what the paths that skipped it are held back
    /// by to meet it. The two are the same number or something is adrift.
    var chainAlignment: (chain: Int, applied: Int) {
        (engine.effectLatencyFrames, engine.alignmentFrames)
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
        return (Double(quality.bufferFrames) + Double(destinationLatencyFrames))
            / quality.sampleRate * 1000 + addedLatencyMilliseconds
    }

    /// The destination's own reported latency and safety offset, in frames.
    ///
    /// Read from the HAL and kept, rather than asked for wherever it is wanted.
    /// The status bar quotes the whole path latency and is redrawn by the
    /// meters, so this was a synchronous round trip to `coreaudiod` twenty
    /// times a second — measured at 129 µs, which is more than the entire poll
    /// costs. It is re-read beside the path verdict, on the same reasoning:
    /// every input to it is on the far side of a route rebuild.
    private(set) var destinationLatencyFrames = 0

    /// Latency the isolation stage adds, in milliseconds.
    var voiceIsolationLatencyMilliseconds: Double {
        let rate = pathQuality?.sampleRate ?? 48000
        guard rate > 0 else { return 0 }
        return Double(engine.voiceIsolationLatencyFrames) / rate * 1000
    }

    // MARK: Runtime

    private(set) var isRunning = false
    private(set) var lastError: String?

    /// What to say when voice isolation was asked for and did not attach.
    ///
    /// A function rather than three lines at the call site so that it can be
    /// asserted: the case that matters is the one nobody can produce on demand,
    /// and the mapping is the only part of it that is testable at all. An
    /// unrecognised reason is passed through rather than swallowed — the
    /// engine's own words in front of somebody is worse than a translation and
    /// far better than silence, which is what there was.
    static func isolationMessage(_ reason: String) -> String {
        let explained =
            switch reason {
            case RoutingEngine.IsolationFailure.unitNotInstantiated:
                loc("this system does not offer it")
            case RoutingEngine.IsolationFailure.chainNotBuilt:
                loc("the processing chain could not be built")
            default: reason
            }
        return String(format: loc("Voice isolation is not running: %@."), explained)
    }
    private(set) var levels: [Float] = []
    private(set) var pathQuality: PathQuality?
    /// A HAL-backed verdict read already queued on the engine serial queue.
    ///
    /// The read costs about three milliseconds and used to run synchronously
    /// on the main actor every half second. Keeping one request in flight
    /// preserves the same update cadence without stacking work when
    /// `coreaudiod` is slow.
    @ObservationIgnored private var pathQualityReadInFlight = false
    private(set) var isClockLocked = false
    private(set) var measuredRateRatio: Double = 1
    private(set) var clockLockFailed = false
    /// The routes actually running, including any built from application taps.
    private(set) var activeRoutes: [Route] = [] {
        didSet { groupedActiveRoutes = Self.groupRoutes(activeRoutes) }
    }

    /// Whether the running route has taken the driver's clock. Not
    /// `isClockLocked`, which is whether the anchor has converged yet.
    var holdsClockLock: Bool { engine.holdsClockLock }

    /// Provokes the clock-lock recovery, for the flow check.
    ///
    /// Only that: the recovery happens when the driver misses an anchor
    /// deadline, and nothing in this application can arrange for it. What it
    /// leaves behind was wrong for as long as it could not be asked for — the
    /// route came back with no processing chain at all — so it is worth being
    /// able to ask.
    ///
    /// Off the main actor, like the real thing: the recovery is a full teardown
    /// and rebuild, which takes seconds, and it happens behind the model's back
    /// rather than through `isBusy`. Running it inline would block the interface
    /// for the length of it and would also stop being a fair imitation.
    ///
    /// - Returns: False when this route is not clock-locked, so the caller can
    ///   report that nothing was exercised rather than that something passed.
    @discardableResult
    func forceClockLockRecovery() async -> Bool {
        let engine = engine
        return await withCheckedContinuation { continuation in
            engineQueue.async {
                continuation.resume(returning: engine.forceClockLockRecovery())
            }
        }
    }

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
    /// Builds and installs only the newest output curve in a slider burst.
    ///
    /// Lazy because its completion publishes back into this model, which does
    /// not exist to capture during stored-property initialisation.
    @ObservationIgnored private lazy var correctionApplier = LatestValueApplier<
        CorrectionSnapshot, Int
    >(
        queue: engineQueue,
        apply: { [engine] snapshot in
            engine.setCorrections(Self.correctionCurves(from: snapshot))
        },
        publish: { [weak self] reached in
            self?.publishCorrectionCount(reached)
        })

    /// Applies a control immediately unless an engine rebuild already owns the
    /// state lock.
    ///
    /// Faders and mutes travel through the realtime command queue, but reaching
    /// that queue still takes the engine's state lock because a graph swap can
    /// replace and free it. Calling those methods on the main actor while
    /// `start` or `updateEffects` held the lock therefore froze every control
    /// for the whole CoreAudio or Audio Unit operation. Queueing behind the
    /// rebuild preserves the order and the model's latest value without making
    /// the interface wait for it.
    private func applyLiveControl(
        _ work: @escaping @Sendable (RoutingEngine) -> Void
    ) {
        let engine = engine
        if isBusy {
            engineQueue.async { work(engine) }
        } else {
            work(engine)
        }
    }

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

    /// What each input channel of *a given device* carries.
    ///
    /// Keyed on the device, because the labels are a fact about that device and
    /// nothing else. The patchbay drew a row per source and labelled every one
    /// of them with the *selected* device's names — so with a Seiren V3 Pro
    /// chosen, a second microphone's channels, and the channels of any captured
    /// application, were all labelled "Processed", "Dry" and "Post-expander".
    /// Names belonging to a device the row has nothing to do with, on a control
    /// whose entire job is saying which signal is which.
    func channelNames(ofDeviceUID uid: String) -> [DeviceChannelNames.Channel]? {
        guard let device = inputDevices.first(where: { $0.uid == uid }) else { return nil }
        return DeviceChannelNames.channels(
            modelUID: device.modelUID, name: device.name,
            scope: kAudioObjectPropertyScopeInput)
    }

    /// Label for one channel of a named device.
    ///
    /// A captured application has no entry in `inputDevices` at all, so it falls
    /// through to the plain number — which is right: an application's audio has
    /// no capsule topology to describe.
    func channelLabel(_ channel: Int, ofDeviceUID uid: String) -> String {
        if let names = channelNames(ofDeviceUID: uid), channel < names.count {
            return loc(names[channel].name)
        }
        return "\(loc("Ch")) \(channel + 1)"
    }

    /// Label for one channel of the selected source. Kept for the places that
    /// are showing that device and nothing else — the device card, and the
    /// menu bar panel's channel picker.
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
        // After `restore`, so loading the file does not immediately write it
        // back — and `restore` is guarded anyway, which is belt and braces on
        // the one path where a setting arriving from disk looked like a change.
        obsLink.persist = { [weak self] in self?.persist() }

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

        if !Self.isVerificationProcess, autoStart,
            selectedSource != nil, selectedDestination != nil,
            !routeRequiresExplicitInputSelection
        {
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
        // Listed because this page is where somebody looks for it, and because
        // the shortcut is new: settings used to be reachable only from the menu
        // bar item's right-click menu, so ⌘, — the combination macOS teaches
        // everybody to try first — did nothing in the application's own window.
        entries.append((loc("Settings"), "⌘,", false))
        for (index, preset) in RoutePreset.builtIn.enumerated() {
            entries.append((preset.name, "⌘\(index + 1)", false))
        }
        return entries
    }

    // MARK: MIDI

    /// Physical faders and pads. Everything it does lives in `MIDIControl.swift`;
    /// what is here is the ownership and the two lines of persistence.
    let midiControl = MIDIController()

    // MARK: OBS

    /// The link to OBS. Everything it does lives in `OBSLink.swift`; what is
    /// here is the ownership, the persistence, and the one number worth sending.
    let obsLink = OBSLink()

    /// The sync offset OBS would need, in milliseconds, for its own captures to
    /// line up with what this application produces.
    ///
    /// Negative, and the magnitude is the effect chain's latency. Computable
    /// with nothing connected, which is why it is here rather than inside
    /// `OBSLink`: it is a fact about this application, and the interface should
    /// show it whether or not anybody is streaming.
    var obsSyncOffsetMilliseconds: Double {
        OBSSyncOffset.forProcessingLatency(
            frames: engine.effectLatencyFrames,
            sampleRate: pathQuality?.sampleRate ?? preferredSampleRate)
    }

    /// Tells OBS what the chain costs now. Does nothing when nothing is linked.
    func pushOBSSyncOffset() {
        let frames = engine.effectLatencyFrames
        let rate = pathQuality?.sampleRate ?? preferredSampleRate
        Task { await obsLink.pushSyncOffset(latencyFrames: frames, sampleRate: rate) }
    }

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
        let processing = Self.busProcessing(from: saved)
        busGraphicEQ = processing.graphic
        busHeadphoneProfiles = processing.profiles
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
        recordingFormat =
            saved.recordingFormat.flatMap(Recorder.Format.init(rawValue:)) ?? .wav
        monitorSends = saved.monitorSends ?? [:]
        tapMuteBehavior =
            saved.tapMuteBehavior.flatMap(TapMuteBehavior.init(storageKey:)) ?? .unmuted
        // Only restored when the device is actually present: a monitor pointing
        // at headphones that are not plugged in would fail the whole start.
        if let uid = saved.monitorDeviceUID,
            outputDevices.contains(where: { $0.uid == uid })
        {
            monitorDeviceUID = uid
        }
        style = saved.style.flatMap(YunStyle.init(rawValue:)) ?? .flat
        YunTheme.shared.style = style
        // Through `style(named:)` so a preferences file naming an icon style
        // that no longer exists restores the default rather than nothing.
        iconStyle = YunIconBadge.style(named: saved.iconStyle).name
        applyIconStyle()
        voiceIsolationEnabled = enabledEffects.contains(.voiceIsolation)
        voiceIsolationMix = saved.voiceIsolationMix
        // The property's own `didSet` reloads and persists, and `isRestoring`
        // stops the persist but not the reload — so it is loaded explicitly
        // below, once the rest of the model is in place. A handler that fired
        // during a restore would be looking at half an arrangement.
        residentScript = saved.residentScript ?? ""
        sourceChannelChoices = saved.sourceChannelChoices ?? [:]
        // Before the primaries are set, so that `pruneAdditionalDevices` on the
        // first device refresh sees the whole route and not a half of it.
        outputTrims = saved.outputTrims ?? [:]
        sourceLevels = saved.sourceLevels ?? [:]
        additionalSourceUIDs = saved.additionalSourceUIDs ?? []
        additionalDestinationUIDs = saved.additionalDestinationUIDs ?? []
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
        obsLink.host = saved.obsHost ?? "127.0.0.1"
        obsLink.port = saved.obsPort ?? OBSConnection.defaultPort
        obsLink.inputName = saved.obsInputName ?? ""
        obsLink.mirrorsMute = saved.obsMirrorsMute ?? false

        selectDefaults()
        reloadResidentScript()
    }

    private func persist() {
        guard !isRestoring, !isApplyingPreset, !isAutoAdjusting else { return }
        PreferencesStore.save(
            PendingPreferencesSnapshot(
                Preferences(
                    sourceDeviceUID: verificationAdditionalSourceUIDs == nil
                        ? selectedSourceUID : verificationSourceUID,
                    destinationDeviceUID: selectedDestinationUID,
                    channelMode: channelMode.rawValue,
                    monoChannel: monoChannel,
                    bufferFrames: bufferFrames,
                    autoStart: autoStart,
                    voiceIsolationEnabled: voiceIsolationEnabled,
                    voiceIsolationMix: voiceIsolationMix,
                    preferredSampleRate: preferredSampleRate,
                    capturedAppBundleIDs: [],
                    excludedAppBundleIDs: [],
                    enabledEffects: [],
                    effectValues: effectValues,
                    cancelsEcho: cancelsEcho,
                    echoSpeakerUID: echoSpeakerUID,
                    style: style.rawValue,
                    iconStyle: iconStyle,
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
                    sourceRoles: [:],
                    isPushToTalkEnabled: isPushToTalkEnabled,
                    plugins: enabledPlugins,
                    pluginValues: pluginValues,
                    voicePreset: voicePreset.rawValue,
                    recordsStems: recordsStems,
                    recordingFormat: recordingFormat.rawValue,
                    monitorSends: monitorSends,
                    outputDelays: outputDelays,
                    // The two flat fields are still written so that a file this
                    // version saves can be opened by one that predates buses having
                    // their own: the primary bus is what that version would have
                    // run, which is the closest thing to the truth it can hold.
                    headphoneProfileName: headphoneProfileName,
                    graphicEQ: graphicEQ,
                    busGraphicEQ: busGraphicEQ,
                    busHeadphoneProfiles: busHeadphoneProfiles,
                    recentSourceUIDs: recentSourceUIDs,
                    recentDestinationUIDs: recentDestinationUIDs,
                    // Written on every save, not only when a binding changes: this
                    // rebuilds the whole file, so leaving it out would quietly
                    // erase somebody's controller the next time they moved a fader.
                    midiBindings: [:],
                    // Its `didSet` has called `persist()` since the day it was
                    // written, and `Preferences` had no field for it — so the one
                    // setting that decides whether a captured application is still
                    // audible was forgotten at every launch, silently, back to the
                    // default.
                    tapMuteBehavior: tapMuteBehavior.storageKey,
                    // The same omission as `tapMuteBehavior` above, on the field
                    // added directly after it: a `didSet` that persists, a
                    // `Preferences` field to persist into, and no line here joining
                    // them. The memberwise initialiser fills an optional it was not
                    // given with nil and `save` replaces the whole blob, so every
                    // save — including the one the script editor's own `didSet`
                    // triggers — wrote the script away as nothing.
                    residentScript: residentScript,
                    sourceChannelChoices: sourceChannelChoices,
                    additionalSourceUIDs: verificationAdditionalSourceUIDs
                        ?? additionalSourceUIDs,
                    additionalDestinationUIDs: additionalDestinationUIDs,
                    outputTrims: outputTrims,
                    sourceLevels: sourceLevels,
                    obsHost: obsLink.host,
                    obsPort: obsLink.port,
                    obsInputName: obsLink.inputName,
                    obsMirrorsMute: obsLink.mirrorsMute),
                capturedAppBundleIDs: capturedAppBundleIDs,
                excludedAppBundleIDs: excludedAppBundleIDs,
                enabledEffects: enabledEffects,
                sourceRoles: sourceRoles,
                midiBindings: midiControl.bindings))
    }

    // MARK: Devices

    func refreshDevices() {
        let all = (try? AudioDevices.all()) ?? []
        inputDevices = all.filter(\.hasInput)
        outputDevices = all.filter(\.hasOutput)
        for device in all { deviceNames[device.uid] = device.name }
        // An extra input or output that has been unplugged, or has since become
        // an end of the main route, is not one any more.
        pruneAdditionalDevices()
        // A new device list can mean a new selected device, and what that
        // device publishes is what the window draws.
        refreshDeviceControls()
        refreshHeadsetQualityAsynchronously()
    }

    func selectDefaults() {
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
                device.transport.isVirtual || device.transport.requiresExplicitInputSelection
                    ? nil : device
            }
            let automatic = automaticallySelectableInputDevices
            selectedSourceUID =
                realInput.map(\.uid)
                ?? automatic.first { $0.transport == .usb }?.uid
                ?? automatic.first { !$0.transport.isVirtual }?.uid
                ?? automatic.first?.uid
        }
        // Whatever the source ended up as, it must not also be the destination.
        // Two faces of one headset count as the same device here too, or the
        // default selection quietly picks a Bluetooth headset's microphone and
        // its own speakers and the route cannot be built at all.
        if let source = selectedSourceUID, let destination = selectedDestinationUID,
            isSamePhysicalDevice(source, destination)
        {
            selectedSourceUID =
                automaticallySelectableInputDevices.first {
                    !$0.transport.isVirtual && !isSamePhysicalDevice($0.uid, destination)
                }?.uid
                ?? automaticallySelectableInputDevices.first {
                    !isSamePhysicalDevice($0.uid, destination)
                }?.uid
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
        // Only when there is nothing saved to overwrite. Anybody who has run
        // this before has a channel choice on disk, and it wins.
        applyChannelDefaults(
            evenWhileRestoring: !PreferencesStore.hasStoredPreferences)
    }

    /// Picks a sensible channel mode for the selected source.
    ///
    /// An odd channel count is a strong hint that the device is not presenting
    /// a stereo pair — the Seiren V3 Pro reports three input channels where only
    /// the first carries the capsule, and routing 1→1, 2→2 would send silence
    /// down one side of every call.
    private func applyChannelDefaults(evenWhileRestoring: Bool = false) {
        // Restoring must not overwrite what the user chose last time — unless
        // there was no last time. `selectDefaults()` runs inside `restore()`,
        // which holds `isRestoring` for its whole body, so this was unreachable
        // from the one path that exists to choose sensible values on a first
        // launch: a fresh install got mono on channel 0 whatever the device
        // was, and a stereo interface routed one side of everything into
        // silence until somebody found the control.
        guard evenWhileRestoring || !isRestoring, let source = selectedSource else {
            return
        }
        let choice = Self.defaultChannelChoice(
            inputChannels: source.inputChannels, names: sourceChannelNames)
        channelMode = choice.mode
        monoChannel = choice.channel
    }

    /// The rule itself, with nothing around it.
    ///
    /// Pure so it can be asserted: which channel a device's topology points at
    /// is the sort of thing that is obviously right until somebody plugs in a
    /// four-channel interface.
    static func defaultChannelChoice(
        inputChannels: Int, names: [DeviceChannelNames.Channel]?
    ) -> (mode: SourceChannelMode, channel: Int) {
        // A device whose topology is known says which channel is the one
        // anybody wants, which is better than the first one by position: on the
        // Seiren the first is right, but that is luck rather than a rule.
        if let names, let preferred = names.firstIndex(where: \.isDefault) {
            return (.mono, preferred)
        }
        // An odd count is a strong hint the device is not presenting a stereo
        // pair, and routing 1→1, 2→2 across one would send silence down one
        // side of every call.
        let stereo = inputChannels % 2 == 0 && inputChannels >= 2
        return (stereo ? .stereo : .mono, 0)
    }

    /// True when routing stopped because hardware went away, rather than
    /// because anybody asked it to.
    ///
    /// A flag of its own, not `lastError != nil`. Using the error as the marker
    /// meant that any unrelated failure — a start that found no usable
    /// channels, a recording that could not be written — armed the resume, and
    /// then plugging in headphones started routing that nobody had asked for.
    private var wasInterruptedByDeviceLoss = false

    /// True when the route is down because a start would not come up, rather
    /// than because anybody asked for it.
    ///
    /// Deliberately not the same flag as the one above, and deliberately not
    /// `lastError != nil`. `wasInterruptedByDeviceLoss` arms the resume on
    /// *every* device change, which is right for a device that went away and
    /// wrong for a start that failed: a failing start fails again, and each
    /// attempt builds and tears down an aggregate — which itself publishes a
    /// device change, so the retry would feed itself.
    ///
    /// This one is read at exactly one place: the moment a device the route
    /// names is confirmed gone *and* a present one has been put in its place.
    /// That is the one event that gives any reason to think the start would go
    /// differently now, and it is the moment the router tells somebody it is
    /// carrying on with another device — which has to be true.
    @ObservationIgnored private var startFailed = false

    private func handleDeviceChange() {
        let before = Set((inputDevices + outputDevices).map(\.uid))
        refreshDevices()
        let after = Set((inputDevices + outputDevices).map(\.uid))
        // Named, because "something changed" is not something a script can act
        // on. Which device arrived is exactly the thing a rule like "when the
        // interface is plugged in, use it" needs.
        for uid in after.subtracting(before) {
            fire(.deviceAppeared, ["uid": uid, "name": deviceNames[uid] ?? uid])
        }
        for uid in before.subtracting(after) {
            fire(.deviceDisappeared, ["uid": uid, "name": deviceNames[uid] ?? uid])
        }

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

    /// What a device is called.
    ///
    /// The live lists first and the remembered names only as a fallback: the
    /// cache is deliberately outside observation, so a view that read it alone
    /// would not redraw when a device was renamed or replugged.
    func deviceName(_ uid: String) -> String? {
        inputDevices.first { $0.uid == uid }?.name
            ?? outputDevices.first { $0.uid == uid }?.name
            ?? deviceNames[uid]
    }

    /// The same, with the manufacturer's own prefix off where that leaves
    /// something to read. For rows that share their width with controls.
    func shortDeviceName(_ uid: String) -> String {
        let device =
            inputDevices.first { $0.uid == uid } ?? outputDevices.first { $0.uid == uid }
        return device?.shortName ?? deviceName(uid) ?? uid
    }

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
                for: lost, recent: recentSourceUIDs,
                available: automaticallySelectableInputDevices.map(\.uid))
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
        } else if !isRunning, !stillGone, !isBusy, wasInterruptedByDeviceLoss || startFailed {
            // Both ends are present again — the substitution above saw to that —
            // and yet the route is down. Either the rebuild the substitution
            // kicked off found the old device already gone, or the route had
            // never come up on that device in the first place; both leave a live
            // model pointing at a dead engine, and the message just set promises
            // the opposite.
            //
            // Nothing else will put it back. `restartIfRunning` restarts a
            // *running* route and there is none, and the resume at the top of
            // `handleDeviceChange` waits for a device change that may never
            // arrive — this is the last thing an unplug runs.
            //
            // Left armed when the queue is busy rather than started blindly: a
            // start would be refused there and the flag spent for nothing. The
            // resume above picks it up on the next notification instead, and
            // route work produces plenty of those.
            //
            // The "carrying on with another" message set above is left standing;
            // a start that succeeds clears it, exactly as on the ordinary
            // fall-back, and one that fails replaces it with something truer.
            wasInterruptedByDeviceLoss = false
            startFailed = false
            start()
        }
    }

    private func restoreDisplacedDevices() {
        if let wanted = displacedSourceUID,
            let device = inputDevices.first(where: { $0.uid == wanted }),
            !device.transport.requiresExplicitInputSelection
        {
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

    /// How one source's channels are taken.
    ///
    /// The primary source's answer is the two controls somebody can see; every
    /// other input answers from what was remembered against it, and otherwise
    /// from its own topology. There is deliberately no second pair of controls:
    /// `sourceChannelChoices` is already per device, so the extra inputs get
    /// the same memory the primary one has without a second place to store it.
    func channelChoice(forSourceUID uid: String) -> (mode: SourceChannelMode, channel: Int) {
        let inputChannels = inputDevices.first { $0.uid == uid }?.inputChannels ?? 0
        if uid == selectedSourceUID {
            return (channelMode, min(monoChannel, max(0, inputChannels - 1)))
        }
        if let stored = sourceChannelChoices[uid] {
            if stored == "stereo" { return (.stereo, 0) }
            if stored.hasPrefix("mono:"), let channel = Int(stored.dropFirst(5)),
                channel < inputChannels
            {
                return (.mono, channel)
            }
        }
        return Self.defaultChannelChoice(
            inputChannels: inputChannels, names: channelNames(ofDeviceUID: uid))
    }

    /// What to say when an application could not be tapped.
    ///
    /// Pure so it can be asserted, and so the sentence is written once: the
    /// name is what somebody recognises and the status is the only part they
    /// can look up or quote at anybody.
    nonisolated static func captureFailure(_ name: String, _ error: Error) -> String {
        "\(name) (\(String(describing: error)))"
    }

    /// Process objects the echo canceller may use as its far-end reference.
    nonisolated static func echoReferenceProcessIDs(
        in applications: [AudioApplication],
        excluding bundleIDs: Set<String>
    ) -> [AudioObjectID] {
        applications.filter {
            $0.isPlaying && !bundleIDs.contains($0.bundleID)
        }.flatMap(\.processIDs)
    }

    /// A destination reduced to the values application routing needs.
    private struct CaptureDestination: Sendable {
        let uid: String
        let outputChannels: Int
    }

    /// The monitor values frozen at the instant Start was pressed.
    private struct MonitorStartPlan: Sendable {
        let uid: String
        let outputChannels: Int
        let sends: [String: Float]
        let selectedSourceUID: String
        let defaultDecibels: Float
    }

    /// Everything built before the engine can start.
    ///
    /// This value never leaves `engineQueue`. In particular, its taps must not
    /// cross back to the main actor: their deinitializer synchronously destroys
    /// a CoreAudio object, so the thread that abandons a cancelled start is as
    /// important as the thread that creates it.
    private struct CapturePreparation {
        let applications: [AudioApplication]
        let refreshedApplications: Bool
        let routes: [Route]
        let taps: [ProcessTap]
        let owners: [String: String]
        let unresolved: [String]
        let refused: [String]
        let monitorRouteIndices: [String: [Int]]
    }

    /// Resolves applications, creates their taps and lays out both mixes.
    ///
    /// Synchronous deliberately: taps use before/after snapshots of CoreAudio's
    /// global tap list to recover a missing object identifier, so creating two
    /// in parallel would make each snapshot contain the other's object.
    nonisolated private static func prepareCapture(
        selected: Set<String>,
        currentApplications: [AudioApplication],
        workspace: AudioApplications.WorkspaceSnapshot,
        muteBehavior: TapMuteBehavior,
        destinations: [CaptureDestination],
        baseRoutes: [Route],
        monitor: MonitorStartPlan?
    ) -> CapturePreparation {
        let refreshed = !selected.isEmpty
        let applications =
            refreshed
            ? ((try? AudioApplications.grouped(keeping: selected, workspace: workspace)) ?? [])
            : currentApplications
        let captured = applications.filter {
            selected.contains($0.bundleID) && !$0.processIDs.isEmpty
        }
        let unresolved = selected.subtracting(captured.map(\.bundleID)).sorted()
        var routes = baseRoutes
        var taps: [ProcessTap] = []
        var owners: [String: String] = [:]
        var refused: [String] = []

        for application in captured {
            let tap: ProcessTap
            do {
                tap = try ProcessTap(
                    processIDs: application.processIDs,
                    muteBehavior: muteBehavior,
                    bundleIDs: [application.bundleID])
            } catch {
                refused.append(captureFailure(application.name, error))
                continue
            }
            taps.append(tap)
            owners[tap.uid] = application.bundleID
            for destination in destinations {
                let channels = channelsToRoute(
                    published: tap.format?.mChannelsPerFrame,
                    destination: min(2, destination.outputChannels))
                for channel in 0..<channels {
                    routes.append(
                        Route(
                            source: ChannelRef(deviceUID: tap.uid, channel: channel),
                            destination: ChannelRef(
                                deviceUID: destination.uid, channel: channel),
                            isDuckable: true))
                }
            }
        }

        var monitorIndices: [String: [Int]] = [:]
        if let monitor {
            let monitorChannels = min(2, monitor.outputChannels)
            var bySource: [String: [Route]] = [:]
            var order: [String] = []
            for route in routes {
                let uid = route.source.deviceUID
                if bySource[uid] == nil { order.append(uid) }
                guard
                    !(bySource[uid]?.contains { $0.source.channel == route.source.channel }
                        ?? false)
                else { continue }
                bySource[uid, default: []].append(route)
            }

            for uid in order {
                let decibels =
                    monitor.sends[uid]
                    ?? (uid == monitor.selectedSourceUID
                        ? monitor.defaultDecibels : minimumDecibels)
                guard decibels > minimumDecibels else { continue }
                let monitorGain = gain(fromDecibels: decibels)
                let members = (bySource[uid] ?? []).sorted {
                    $0.source.channel < $1.source.channel
                }
                guard !members.isEmpty else { continue }
                var indices: [Int] = []
                for channel in 0..<monitorChannels {
                    let taken = members[min(channel, members.count - 1)]
                    indices.append(routes.count)
                    routes.append(
                        Route(
                            source: taken.source,
                            destination: ChannelRef(
                                deviceUID: monitor.uid, channel: channel),
                            gain: monitorGain,
                            isDuckable: taken.isDuckable))
                }
                monitorIndices[uid] = indices
            }
        }

        return CapturePreparation(
            applications: applications,
            refreshedApplications: refreshed,
            routes: routes,
            taps: taps,
            owners: owners,
            unresolved: unresolved,
            refused: refused,
            monitorRouteIndices: monitorIndices)
    }

    /// Every input in the route wired to every output, before the taps and the
    /// monitor are added.
    ///
    /// Sources outermost so the clock master's routes come first: the effect
    /// chain reads `routes.first.source` to decide what it is processing, and a
    /// second microphone appearing ahead of the first would silently move the
    /// gate, the compressor and the isolator onto it.
    var routes: [Route] {
        let sources = activeSourceUIDs.compactMap { uid in
            inputDevices.first { $0.uid == uid }
        }
        let destinations = activeDestinationUIDs.compactMap { uid in
            outputDevices.first { $0.uid == uid }
        }
        return Self.routes(
            from: sources.map {
                let choice = channelChoice(forSourceUID: $0.uid)
                return SourceWiring(
                    uid: $0.uid, channels: $0.inputChannels,
                    mode: choice.mode, monoChannel: choice.channel)
            },
            to: destinations.map { ($0.uid, $0.outputChannels) })
    }

    /// One source, as the wiring rule needs to see it.
    nonisolated struct SourceWiring: Sendable, Hashable {
        var uid: String
        var channels: Int
        var mode: SourceChannelMode
        var monoChannel: Int
    }

    /// The wiring rule itself, with no devices around it.
    ///
    /// Pure so it can be asserted. Which wires exist between two inputs and two
    /// outputs is exactly the sort of thing that is obviously right until
    /// somebody adds a second of either, and the model above cannot be run
    /// without the machine's real hardware — so the rule that decides it is
    /// kept where a test can reach it, the same way `defaultChannelChoice` is.
    nonisolated static func routes(
        from sources: [SourceWiring], to destinations: [(uid: String, channels: Int)]
    ) -> [Route] {
        var list: [Route] = []
        for source in sources where source.channels > 0 {
            for destination in destinations {
                let destinationChannels = min(2, destination.channels)
                guard destinationChannels > 0 else { continue }
                switch source.mode {
                case .mono:
                    let channel = min(source.monoChannel, source.channels - 1)
                    for destinationChannel in 0..<destinationChannels {
                        list.append(
                            Route(
                                source: ChannelRef(deviceUID: source.uid, channel: channel),
                                destination: ChannelRef(
                                    deviceUID: destination.uid, channel: destinationChannel)))
                    }
                case .stereo:
                    for channel in 0..<min(destinationChannels, source.channels) {
                        list.append(
                            Route(
                                source: ChannelRef(deviceUID: source.uid, channel: channel),
                                destination: ChannelRef(
                                    deviceUID: destination.uid, channel: channel)))
                    }
                }
            }
        }
        return list
    }

    func start() { start(selftest: false) }

    /// - Parameter selftest: Installs the loopback integrity check alongside
    ///   the routes. It overwrites one destination channel with a known
    ///   sequence, so it is never on for ordinary routing.
    func start(selftest: Bool) {
        guard !isBusy else { return }
        // `prepareForAutomatedAudioUse()` chooses a local input before either
        // harness starts. This guard is the last line of defence for a future
        // test that forgets: failing that test is preferable to waking a phone.
        guard !(Self.isVerificationProcess && routeRequiresExplicitInputSelection) else {
            startFailed = true
            return
        }
        guard let source = selectedSourceUID, let destination = selectedDestinationUID else {
            startFailed = true
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
            startFailed = true
            lastError = loc("The input and the output cannot be the same device.")
            return
        }
        guard source != destination else {
            startFailed = true
            lastError = loc("The input and the output cannot be the same device.")
            return
        }
        beginStartOnEngineQueue(source: source, destination: destination, selftest: selftest)
        return ()
    }

    /// Starts without putting CoreAudio enumeration or tap lifetime on the main
    /// actor.
    private func beginStartOnEngineQueue(
        source: String,
        destination: String,
        selftest: Bool
    ) {
        // AppKit objects are reduced to values here. The HAL half of grouping
        // is the measured 27 ms warm / 118 ms cold part and runs below.
        let workspace = AudioApplications.workspaceSnapshot()
        let selectedApplications = capturedAppBundleIDs
        let knownApplications = availableApps
        let muteBehavior = tapMuteBehavior
        let destinations = activeDestinationUIDs.compactMap { uid in
            outputDevices.first(where: { $0.uid == uid }).map {
                CaptureDestination(uid: uid, outputChannels: $0.outputChannels)
            }
        }
        let baseRoutes = routes
        let monitorPlan = monitorDeviceUID.flatMap { uid in
            outputDevices.first(where: { $0.uid == uid }).map {
                MonitorStartPlan(
                    uid: uid,
                    outputChannels: $0.outputChannels,
                    sends: monitorSends,
                    selectedSourceUID: source,
                    defaultDecibels: monitorDecibels)
            }
        }
        let effects = Array(enabledEffects)
        let pluginList = enabledPlugins
        let isolation =
            enabledEffects.contains(.voiceIsolation)
            ? VoiceIsolationSettings(mixPercent: voiceIsolationMix) : nil
        let rate = preferredSampleRate
        let buffer = bufferFrames
        let monitorUID = monitorDeviceUID
        let extraSources = additionalSourceUIDs
        let extraDestinations = additionalDestinationUIDs
        let trim = outputLatencyFrames
        let echoIsEnabled = cancelsEcho
        let wantedEchoSpeaker = echoSpeakerUID
        let echoSpeakers = echoSpeakerOptions
        let excludedApplications = excludedAppBundleIDs
        let emptyRouteError =
            selectedSource == nil || selectedDestination == nil
            ? loc("A device in the route was unplugged.")
            : loc("Those two devices share no usable channels.")

        clockLockFailed = false
        tapOwners = [:]
        unresolvedCaptures = []
        refusedCaptures = []
        monitorRouteIndices = [:]
        isBusy = true
        isStarting = true
        let intent = StartIntent()
        currentStartIntent = intent
        let engine = engine

        engineQueue.async {
            let preparation = Self.prepareCapture(
                selected: selectedApplications,
                currentApplications: knownApplications,
                workspace: workspace,
                muteBehavior: muteBehavior,
                destinations: destinations,
                baseRoutes: baseRoutes,
                monitor: monitorPlan)
            guard !intent.isCancelled else {
                // `preparation` — and therefore every ProcessTap — dies on this
                // queue after the callback is enqueued, never on MainActor.
                Task { @MainActor in self.finishCancelledStart(intent) }
                return
            }
            guard !preparation.routes.isEmpty else {
                let report = StartReport(
                    applications: preparation.applications,
                    refreshedApplications: preparation.refreshedApplications,
                    owners: preparation.owners,
                    unresolved: preparation.unresolved,
                    refused: preparation.refused,
                    monitorRouteIndices: preparation.monitorRouteIndices,
                    failure: emptyRouteError,
                    quality: nil,
                    didStart: false)
                Task { @MainActor in self.finishStart(intent, report, isolation: isolation) }
                return
            }

            let echo: EchoCancellationSettings?
            if echoIsEnabled {
                let speaker =
                    echoSpeakers.first { $0.uid == wantedEchoSpeaker }
                    ?? (try? AudioDevices.defaultOutput()).flatMap {
                        $0.transport.isVirtual ? nil : $0
                    }
                    ?? echoSpeakers.first
                if let speaker {
                    // The far end is every audible application the exclusion
                    // permits. Empty stays empty: falling back to the excluded
                    // set would turn "never touch this application" into a rule
                    // that stops at the echo canceller.
                    let reference = Self.echoReferenceProcessIDs(
                        in: preparation.applications,
                        excluding: excludedApplications)
                    // Unmuted leaves those applications on their own speaker
                    // path. Routing them through the canceller would subtract
                    // better, but would also put YunAudio in the path of
                    // everything somebody hears without being asked.
                    echo = EchoCancellationSettings(
                        speakerUID: speaker.uid,
                        farEndProcessIDs: reference,
                        tapMuteBehavior: .unmuted)
                } else {
                    echo = nil
                }
            } else {
                echo = nil
            }

            engine.allowClockLockRetry()
            var failure: String?
            var quality: PathQuality?
            var didStart = false
            do {
                try engine.start(
                    sourceDeviceUID: source,
                    destinationDeviceUID: destination,
                    routes: preparation.routes,
                    taps: preparation.taps,
                    additionalSourceUIDs: extraSources,
                    additionalDestinationUIDs: extraDestinations,
                    monitorDeviceUID: monitorUID,
                    effects: effects,
                    plugins: pluginList,
                    preferredSampleRate: rate,
                    bufferFrames: buffer,
                    voiceIsolation: isolation,
                    echoCancellation: echo,
                    outputLatencyTrim: trim,
                    selftest: selftest)
                didStart = true
                quality = engine.pathQuality
            } catch {
                failure = String(describing: error)
            }

            // A stop or settings edit can arrive while CoreAudio is inside its
            // synchronous start. It cannot interrupt that call, but it can keep
            // the obsolete graph from ever being published to the interface.
            if intent.isCancelled {
                if didStart { engine.stop() }
                Task { @MainActor in self.finishCancelledStart(intent) }
                return
            }

            let report = StartReport(
                applications: preparation.applications,
                refreshedApplications: preparation.refreshedApplications,
                owners: preparation.owners,
                unresolved: preparation.unresolved,
                refused: preparation.refused,
                monitorRouteIndices: preparation.monitorRouteIndices,
                failure: failure,
                quality: quality,
                didStart: didStart)
            Task { @MainActor in self.finishStart(intent, report, isolation: isolation) }
        }
    }

    /// Finishes a start made obsolete before its result reached the main actor.
    private func finishCancelledStart(_ intent: StartIntent) {
        guard currentStartIntent === intent else { return }
        currentStartIntent = nil
        isBusy = false
        isStarting = false
        isRunning = false
        if honourPendingStop() { return }
        if restartIsPending {
            restartIsPending = false
            startFailed = false
            start()
        }
    }

    /// Publishes only the report belonging to the current start generation.
    private func finishStart(
        _ intent: StartIntent,
        _ report: StartReport,
        isolation: VoiceIsolationSettings?
    ) {
        guard currentStartIntent === intent else { return }
        // Cancellation can land after the queue's final check but before this
        // callback. A graph that came up in that gap is taken down on the same
        // queue before the cancelled generation is retired.
        if intent.isCancelled {
            if report.didStart {
                let engine = engine
                engineQueue.async {
                    engine.stop()
                    Task { @MainActor in self.finishCancelledStart(intent) }
                }
            } else {
                finishCancelledStart(intent)
            }
            return
        }

        currentStartIntent = nil
        if report.refreshedApplications {
            appListRevision &+= 1
            availableApps = report.applications
            appsRefreshedAt = Date()
        }
        tapOwners = report.didStart ? report.owners : [:]
        unresolvedCaptures = report.unresolved
        refusedCaptures = report.refused
        monitorRouteIndices = report.didStart ? report.monitorRouteIndices : [:]
        isBusy = false
        isStarting = false

        if let failure = report.failure {
            isRunning = false
            lastError = failure
            startFailed = true
            let stayDown = stopIsPending
            stopIsPending = false
            if stayDown {
                restartIsPending = false
                return
            }
            if restartIsPending {
                restartIsPending = false
                startFailed = false
                start()
            }
            return
        }

        isRunning = true
        lastError =
            report.refused.isEmpty
            ? nil
            : String(
                format: loc("%@ could not be captured."),
                report.refused.joined(separator: ", "))
        fire(.routingStarted)
        startFailed = false
        startVoiceActivity()
        appliedToGraph = []
        applyInputGain()
        applyInputMute()
        applyOutputGain()
        applyOutputMute()
        applyDucking()
        applyEffectValues()
        let installed = engine.currentRoutes
        activeRoutes = installed
        routeGains = installed.map(\.gain)
        routeMutes = installed.map(\.isMuted)
        if let dropped = engine.droppedMonitor { monitorWasDropped(dropped) }
        extrasWereDropped(engine.droppedExtras)
        applySourceLevels()
        applyOutputTrims()
        if isolation != nil, let reason = engine.lastIsolationError {
            lastError = Self.isolationMessage(reason)
        }
        pathQuality = report.quality
        let reported = report.quality?.sampleRate ?? 0
        startAnalysis(sampleRate: reported.isFinite && reported > 0 ? reported : 48000)
        applyCorrections()
        startPolling()
        if honourPendingStop() { return }
        drainPendingRestart()
    }

    func stop() {
        wasInterruptedByDeviceLoss = false
        // Somebody asking for the route to come down outranks any reason it was
        // already down. Left set, a failed start followed by Stop followed by an
        // unplug would start audio that the last person to touch the thing had
        // just put away.
        startFailed = false
        stop(then: nil)
    }

    /// - Parameter completion: Runs on the main actor once the engine is fully
    ///   down and `isBusy` has been cleared, so a caller can start again. It is
    ///   skipped when somebody asked for the route to stay down in the meantime:
    ///   the completion exists to chain a rebuild behind a teardown, and a
    ///   rebuild is the one thing a stop request rules out.
    func stop(then completion: (@MainActor () -> Void)? = nil) {
        guard !isBusy else {
            stopIsPending = true
            if isStarting { currentStartIntent?.cancel() }
            return
        }
        isBusy = true
        let engine = engine
        engineQueue.async {
            engine.stop()
            Task { @MainActor in
                self.isBusy = false
                self.finishStop()
                // Read before it is cleared, because the completion below is
                // usually a start and this is the only thing standing between a
                // stop somebody pressed and the route coming straight back up.
                let stayDown = self.stopIsPending
                self.stopIsPending = false
                if stayDown {
                    // `finishStop` has already dropped the pending rebuild, but
                    // an edit arriving between it and here would set another.
                    self.restartIsPending = false
                } else {
                    completion?()
                }
                self.drainPendingRestart()
            }
        }
    }

    private func finishStop() {
        isRunning = false
        fire(.routingStopped)
        stopVoiceActivity()
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
        // `engine.stop()` freed every source ring before returning. Keeping
        // this cache marked open made the same source IDs reuse zero taps after
        // a route restart, leaving lyrics, pitch and scoring permanently deaf.
        invalidateSourceTaps()
        // Transcription goes down with the route it was listening to, but the
        // transcript stays: it is what somebody was there for, and losing it
        // because a device changed underneath would be the worst moment to.
        if isTranscribing { stopTranscribing() }
        // The score goes with it for the same reason and not the same one: the
        // rings it reads are the route's, so there is nothing left to hear.
        isScoringSinging = false
        levels = []
        peakHolds = []
        clipped = []
        activeRoutes = []
        routeGains = []
        routeMutes = []
        pathQuality = nil
        isClockLocked = false
        // There is no graph to have been told anything, and no routes for the
        // monitor map to be pointing at. A restart waiting for the queue is
        // also moot: the route it wanted to rebuild is down.
        appliedToGraph = []
        monitorRouteIndices = [:]
        restartIsPending = false
    }

    func toggle() { isRunning ? stop() : start() }

    // MARK: Scripting

    /// What a script can read.
    ///
    /// One dictionary rather than a property each: a script that asks three
    /// questions should get one consistent moment, not three moments a few
    /// milliseconds apart. Plain values only — a script has to keep working
    /// across versions, and handing it a model object would make every internal
    /// rename somebody else's breaking change.
    var scriptStatus: [String: Any] {
        var status: [String: Any] = [
            "running": isRunning,
            "busy": isBusy,
            "muted": isInputMuted,
            "outputMuted": isOutputMuted,
            "recording": isRecording,
            "transcribing": isTranscribing,
            "inputDecibels": Double(inputDecibels),
            "outputDecibels": Double(outputDecibels),
            "effects": enabledEffects.map(\.rawValue).sorted(),
            "routes": activeRoutes.count,
        ]
        if let source = selectedSource {
            status["source"] = source.name
            status["sourceUID"] = source.uid
        }
        if let destination = selectedDestination {
            status["destination"] = destination.name
            status["destinationUID"] = destination.uid
        }
        if let quality = pathQuality {
            status["sampleRate"] = quality.sampleRate
            status["bufferFrames"] = Int(quality.bufferFrames)
        }
        if isRunning {
            status["peak"] = Double(peakLevel)
            status["loudness"] = analysis.shortTerm.isFinite ? analysis.shortTerm : -70
        }
        return status
    }

    var scriptPresetNames: [String] { allPresets.map { loc($0.name) } }
    var scriptConfigNames: [String] { quickConfigs.map(\.name) }

    /// Set by `perform`, read by whatever front end wants an exit status
    /// rather than a sentence.
    private(set) var lastCommandFailed = false

    /// Runs a script against this model.
    ///
    /// A fresh host per run: it holds nothing between runs by design — one
    /// script must not leave a global behind that changes what the next one
    /// means — so there is nothing to keep.
    func runScript(_ source: String) -> ScriptHost.Result {
        // Keep the host strongly alive through the call. Its target is weak to
        // avoid the resident host's ownership cycle; invoking `run` on a
        // temporary lets an optimised build release that temporary before the
        // weak target is read, and the script then reports that the application
        // has gone away.
        let host = ScriptHost(target: self)
        return host.run(source)
    }

    /// Runs a script once, now, and puts what came back where a person can read
    /// it.
    ///
    /// `runScript` has been in the vocabulary from the beginning — the URL
    /// scheme's `script`, the CLI's `run`, the MCP tool — and had no control
    /// anywhere in the interface. The script tab could install something that
    /// *reacts* to events and offered no way to make a script *do* anything, so
    /// a script whose top level is `yun.preset("Voice chat")` could not be tried
    /// from the panel that edits it. This is the same call that the URL takes,
    /// with its result routed into the log the tab already shows — otherwise a
    /// run that printed something would print it to nowhere.
    @discardableResult
    func runScriptNow(_ source: String) -> ScriptHost.Result {
        let result = runScript(source)
        for line in result.log { scriptLog.append(line) }
        // The error goes in the log rather than into `residentScriptError`:
        // that one means "this script would not load", and a run that threw
        // halfway through loaded perfectly well. Conflating them would leave a
        // red syntax error beside a script whose syntax is fine.
        if let error = result.error {
            scriptLog.append(loc("Script error:") + " " + error)
        } else if !result.value.isEmpty {
            scriptLog.append("→ " + result.value)
        }
        if scriptLog.count > 200 { scriptLog.removeFirst(scriptLog.count - 200) }
        return result
    }

    /// The script that stays loaded and reacts to things.
    ///
    /// Persisted, because a script that has to be pasted in again after every
    /// launch is a script nobody uses. Loaded on assignment so the editor shows
    /// the error immediately rather than at the next restart.
    var residentScript: String = "" {
        didSet {
            guard oldValue != residentScript else { return }
            persist()
            reloadResidentScript()
        }
    }

    /// What loading it said, so the interface can show a syntax error next to
    /// the script rather than nowhere.
    private(set) var residentScriptError: String?

    @ObservationIgnored private var residentHost: ScriptHost?

    private func reloadResidentScript() {
        guard !residentScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            residentHost = nil
            residentScriptError = nil
            return
        }
        let host = ScriptHost(target: self)
        let result = host.load(residentScript)
        residentScriptError = result.error
        // What the script said while it was loading goes to the same place as
        // what its handlers say. It was dropped, so a script whose top level
        // called `yun.log` wrote to nowhere while the panel above it is headed
        // "What it has said" — and the top level is exactly where somebody puts
        // the line that tells them the script is the one they think it is.
        for line in result.log { scriptLog.append(line) }
        if scriptLog.count > 200 { scriptLog.removeFirst(scriptLog.count - 200) }
        // Kept even when it failed to load, so `listens(for:)` is honestly
        // empty rather than the previous script's handlers going on firing
        // under the new script's name.
        residentHost = host
    }

    /// Tells the resident script something happened.
    ///
    /// Silent when nothing is listening, which is almost always: this is called
    /// from the poll and from every state change, so the cost of no script has
    /// to be one dictionary lookup.
    func fire(_ event: ScriptHost.Event, _ payload: [String: Any] = [:]) {
        guard let residentHost, residentHost.listens(for: event) else { return }
        let result = residentHost.dispatch(event, payload)
        // A handler that threw is reported once, where a person will see it.
        // Swallowing it would leave somebody's automation silently not running.
        if let error = result.error {
            residentScriptError = loc("Script error:") + " " + error
        }
        for line in result.log { scriptLog.append(line) }
        // Bounded: a handler on `tick` that logs runs once a second for as long
        // as the application does.
        if scriptLog.count > 200 { scriptLog.removeFirst(scriptLog.count - 200) }
    }

    /// Which inspector tab is showing.
    ///
    /// On the model so it survives a launch, and so the window photographer can
    /// reach it — the live window is built once by the scene, so before this
    /// five of the six tabs had never been photographed.
    var inspectorTab: MainWindow.Inspector = .sound

    /// What resident handlers have said, most recent last.
    private(set) var scriptLog: [String] = []

    @ObservationIgnored private var pollsSinceScriptTick = 0
    /// Asked once per second rather than per poll. `listens(for:)` is cheap,
    /// but the poll is the hottest path in the interface and the answer cannot
    /// change without a script being loaded.
    private var residentListensForTick: Bool {
        residentHost?.listens(for: .tick) ?? false
    }

    /// Carries out something another program asked for.
    ///
    /// - Returns: What happened, in a sentence, or nil when the command named
    ///   something this application does not have. The caller says it out loud
    ///   rather than swallowing it: a scene renamed since somebody wired a
    ///   button to it should not fail silently.
    @discardableResult
    func perform(_ command: RemoteCommand) -> String? {
        lastCommandFailed = false
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
            // "Recording stopped." in answer to "start recording" is a true
            // sentence about the state and a misleading answer to the
            // question. Recording needs a running route, and being told so is
            // the difference between a command that failed and one that was
            // ignored.
            if target, !isRecording {
                lastCommandFailed = true
                return lastError ?? loc("Recording could not be started.")
            }
            return isRecording ? loc("Recording.") : loc("Recording stopped.")
        case .transcribe(let wanted):
            let target = wanted ?? !isTranscribing
            if target, !isTranscribing {
                startTranscribing()
            } else if !target, isTranscribing {
                stopTranscribing()
            }
            if target, !isTranscribing {
                lastCommandFailed = true
                return transcriptionError ?? loc("Transcription could not be started.")
            }
            return isTranscribing ? loc("Transcribing.") : loc("Transcription stopped.")
        case .config(let name):
            guard
                let configuration = quickConfigs.first(where: {
                    $0.name.compare(name, options: .caseInsensitive) == .orderedSame
                })
            else {
                lastCommandFailed = true
                return nil
            }
            let outcome = apply(configuration)
            return outcome.isComplete
                ? configuration.name
                : configuration.name + " — " + loc("missing") + " "
                    + describeMissing(outcome.missing)
        case .script(let source):
            // Reported the same way a scene is: what happened, in a sentence.
            // A script that failed has to say so out loud — a button wired to
            // one that has since broken must not look like it worked.
            let result = runScript(source)
            if let error = result.error {
                lastCommandFailed = true
                return loc("Script error:") + " " + error
            }
            let said = result.log.joined(separator: " · ")
            return said.isEmpty
                ? (result.value.isEmpty ? loc("Script ran.") : result.value) : said
        case .preset(let name):
            // Matched without case, because a URL somebody typed will not have
            // the capitals right and refusing over that is pedantry.
            guard
                let preset = allPresets.first(where: {
                    loc($0.name).compare(name, options: .caseInsensitive) == .orderedSame
                        || $0.name.compare(name, options: .caseInsensitive) == .orderedSame
                })
            else {
                lastCommandFailed = true
                return nil
            }
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

    /// Cancellation shared by the main actor and one engine-queue start.
    ///
    /// This lock is never touched by the realtime path. It exists because Stop
    /// and a settings edit must be able to prevent a 118 ms capture preflight
    /// from going on to seize the audio devices after the request is obsolete.
    private final class StartIntent: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.withLock { cancelled = true }
        }

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }
    }

    /// Plain evidence returned after a start; live taps stay on the engine
    /// queue and, on success, are retained by `RoutingEngine`.
    private struct StartReport: Sendable {
        let applications: [AudioApplication]
        let refreshedApplications: Bool
        let owners: [String: String]
        let unresolved: [String]
        let refused: [String]
        let monitorRouteIndices: [String: [Int]]
        let failure: String?
        let quality: PathQuality?
        let didStart: Bool
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

    // MARK: What the running graph has been told

    /// One thing the model holds that the realtime graph has to be told
    /// separately.
    ///
    /// A published graph comes up at the realtime defaults, and the engine
    /// carries a different subset of the previous one across depending on how
    /// it was published: `start` carries nothing, `updateRoutes` carries
    /// everything except the output correction, `updateEffects` carries the
    /// correction but builds fresh Audio Units. Whatever is not carried has to
    /// be pushed again — and when it is not, the failure is silent, because the
    /// interface reports what the model holds and the model is right.
    enum GraphSetting: String, CaseIterable, Sendable {
        case inputGain
        case inputMute
        case outputGain
        case outputMute
        case effectValues
        case headphoneCorrection
        case ducking
    }

    /// Which of those the graph running right now has actually been given.
    ///
    /// Recorded rather than derived: there is no way to ask the graph what it
    /// is holding, and "the model has the value" is exactly the question that
    /// has already answered yes twice while the audio said no.
    @ObservationIgnored private(set) var appliedToGraph: Set<GraphSetting> = []

    /// Rebuilds triggered since launch. Only for the flow check, which asserts
    /// that one preset costs one rebuild — the alternative is a race, not
    /// merely waste: back-to-back restarts hit `stop`'s busy guard and are
    /// dropped, so whether the final settings reach the engine depends on how
    /// fast the engine queue happens to be.
    private(set) var restartCount = 0

    /// A restart that arrived while the engine queue was already working.
    ///
    /// `stop()` refuses while `isBusy`, so this used to return having done
    /// nothing at all: the model held the new value, the interface showed it,
    /// and the route went on running the old one until something unrelated
    /// happened to rebuild. It is not theoretical — attaching a monitor
    /// immediately after a chain swap took twenty seconds to appear in the flow
    /// check, and only then because a later change restarted the route for its
    /// own reasons. Recorded and carried out when the queue comes free instead.
    @ObservationIgnored private var restartIsPending = false

    /// A stop asked for while the engine queue was already working.
    ///
    /// This is how a stopped route came back on its own. `stop()` refuses while
    /// `isBusy` and used to return having done nothing whatever, while every
    /// rebuild chains a start behind its own teardown — so a Stop pressed during
    /// a rebuild was swallowed and the chained start then brought the route up
    /// with nobody having asked for it. The window is small when the rebuild
    /// came from a knob, and it is not a window at all when it came from
    /// applying a setup: that batches its device changes, the batch restarts a
    /// running route, and the "not routing" stop the setup then asks for lands
    /// squarely inside the restart it just caused. A setup saved with the router
    /// idle could not put the router down.
    ///
    /// Recorded and carried out when the queue comes free instead, and it
    /// outranks a pending restart — rebuilding a route somebody has just put
    /// down is no more wanted than starting it.
    @ObservationIgnored private var stopIsPending = false

    /// Carries out a stop that the busy guard refused.
    ///
    /// - Returns: True when there was one, in which case the caller must not go
    ///   on to start or rebuild anything: coming down is the last thing that was
    ///   asked for.
    @discardableResult
    private func honourPendingStop() -> Bool {
        guard stopIsPending else { return false }
        stopIsPending = false
        restartIsPending = false
        // Already down when the refused stop arrived during a teardown rather
        // than during a start; then there is nothing to do but not come back up.
        if isRunning { stop(then: nil) }
        return true
    }

    /// What choosing a device does: rebuild a running route, or bring back one
    /// that is down only because the last start would not come up.
    ///
    /// The second half is the whole of this. A start that fails leaves the
    /// route down and the model still pointing at the devices it failed on —
    /// and picking a different one, which is the one thing that could make the
    /// difference, did nothing whatever. `restartIfRunning` wants a running
    /// route and there is none; the resume in `handleDeviceChange` wants a
    /// device to have actually gone; the one place that reads `startFailed`
    /// wants a *confirmed unplug*. So nothing anywhere acted on it and the
    /// route stayed down for good, with the interface showing the device
    /// somebody had just chosen and no audio going anywhere near it.
    ///
    /// Reachable without any timing at all, which is why it survived: every
    /// device is in both lists, so the source appears in the output picker,
    /// choosing it is refused with a sentence saying so — and correcting the
    /// mistake left the destination bus at digital silence. Measured, and
    /// asserted in the flow check.
    ///
    /// Bounded by hand rather than by luck: only an edit somebody makes gets
    /// here, so a start that fails again costs one more attempt and not the
    /// self-feeding retry `startFailed` exists to prevent.
    private func rerouteAfterDeviceChange() {
        // Before anything else, and for the same reason `restartIfRunning`
        // checks it: a batch sets several devices and the route must come up
        // once, at the end, rather than against a half-applied configuration.
        guard !isApplyingPreset else { return }
        guard !isRunning, !isBusy, startFailed else {
            restartIfRunning()
            return
        }
        startFailed = false
        start()
    }

    private func restartIfRunning() {
        guard !isApplyingPreset else { return }
        guard !isBusy else {
            // A start in flight has already read every parameter off the model,
            // so a change arriving now is lost — and `isRunning` is still false,
            // which is why the old guard below never even saw it. A stop in
            // flight needs no note: the start chained after it reads the model
            // fresh.
            if isStarting {
                restartIsPending = true
                currentStartIntent?.cancel()
            }
            return
        }
        guard isRunning else { return }
        restartCount += 1
        // stop() is asynchronous and holds `isBusy` until the engine queue has
        // finished, so calling start() straight after it hits the busy guard and
        // the route never comes back. Chain them instead.
        stop {
            self.start()
        }
    }

    /// True while a start is in flight, as opposed to a stop.
    @ObservationIgnored private var isStarting = false

    /// The particular start whose capture preflight owns `engineQueue`.
    @ObservationIgnored private var currentStartIntent: StartIntent?

    /// Carries out a restart that was asked for while a start was in flight.
    ///
    /// Called wherever `isBusy` is cleared. Nothing here loops: the restart it
    /// runs sets `isBusy` again immediately, so a further request during that
    /// one is recorded rather than run.
    private func drainPendingRestart() {
        guard restartIsPending, !isBusy else { return }
        restartIsPending = false
        restartIfRunning()
    }

    /// Reroutes without stopping. Returns false when the change needs a rebuild.
    ///
    /// Only when the whole route list *is* `routes` — the microphone into the
    /// destination and nothing else. That computed property knows nothing about
    /// taps, which is why they are excluded, and nothing about the monitor
    /// either, which was not: swapping it in with a monitor attached replaced
    /// the second mix with silence and left the interface showing both buses,
    /// both sets of faders and no way to tell.
    @discardableResult
    private func reconfigureIfPossible() -> Bool {
        guard isRunning, capturedAppBundleIDs.isEmpty, monitorDeviceUID == nil else {
            return false
        }
        let updated = routes
        guard !updated.isEmpty, engine.updateRoutes(updated) else { return false }
        activeRoutes = engine.currentRoutes
        routeGains = activeRoutes.map(\.gain)
        routeMutes = activeRoutes.map(\.isMuted)
        rebuiltRoutes()
        return true
    }

    // MARK: Polling

    private func startPolling() {
        stopPolling()
        // Twenty hertz: fast enough that a meter reads as live, slow enough that
        // an idle menu bar app is not waking the CPU sixty times a second.
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            // Registered on the main run loop below, so another main-actor task
            // for every meter frame is allocation and scheduling with no hop.
            MainActor.assumeIsolated { self?.poll() }
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
    /// Counted in path-quality rounds rather than in polls, because that is
    /// where the refresh hangs.
    @ObservationIgnored private var pollsSinceDeviceControls = 0

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

    /// Reads the HAL-backed path verdict without stopping the main actor.
    private func refreshPathQualityAsynchronously() {
        guard !pathQualityReadInFlight else { return }
        pathQualityReadInFlight = true
        let engine = engine
        let destination = selectedDestination
        let monitor = monitorDeviceUID.flatMap { uid in
            outputDevices.first(where: { $0.uid == uid })
        }
        let outputs = outputDevices
        let preferredHeadsets = [selectedDestinationUID, monitorDeviceUID].compactMap { $0 }
        engineQueue.async {
            let quality = engine.pathQuality
            let latency =
                destination?.latencyFrames(scope: kAudioObjectPropertyScopeOutput) ?? 0
            let monitorLatency =
                monitor?.latencyFrames(scope: kAudioObjectPropertyScopeOutput) ?? 0
            let headset = Self.headsetInCallQuality(
                outputDevices: outputs,
                preferredUIDs: preferredHeadsets)
            Task { @MainActor in
                self.pathQualityReadInFlight = false
                // A queued read can finish after Stop. Publishing that route's
                // verdict again would resurrect a stale "bit-exact" pill over
                // an idle application.
                guard self.isRunning else { return }
                self.publish(quality, to: \.pathQuality)
                self.publish(latency, to: \.destinationLatencyFrames)
                self.publish(monitorLatency, to: \.monitorLatencyFrames)
                self.publish(headset, to: \.headsetInCallQuality)
            }
        }
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
            lap("pathQuality") { refreshPathQualityAsynchronously() }
            // For the same reason, and far less often. Everything this
            // application does to these refreshes them on the spot — a
            // selection, a device arriving, the window opening — so the only
            // thing the timer is for is somebody moving the gain in Audio MIDI
            // Setup behind our back, and five seconds is soon enough for that.
            // At the path verdict's own rate it put 53 µs on every poll, which
            // is a quarter of what the whole poll costs with nothing open.
            pollsSinceDeviceControls += 1
            if pollsSinceDeviceControls >= 10 {
                pollsSinceDeviceControls = 0
                lap("deviceControls") { if inspectorIsOnScreen { refreshDeviceControls() } }
            }
        }
        lap("isClockLocked") { publish(engine.isClockLocked, to: \.isClockLocked) }
        lap("rateRatio") { publish(engine.measuredRateRatio, to: \.measuredRateRatio) }
        lap("recordingState") { refreshRecordingState() }
        lap("outputPeak") { publish(engine.outputPeak, to: \.outputPeak) }
        lap("failedPlugins") { publish(engine.failedPlugins, to: \.failedPlugins) }
        // Not only after a start this model asked for: the clock-lock recovery
        // rebuilds the route from the engine's own snapshot, and a monitor
        // dropped there would otherwise go unmentioned while the picker went on
        // naming it. Reading a stale drop back is prevented by the comparison —
        // once it has been acted on, the monitor is nil and nothing matches.
        lap("droppedMonitor") {
            if let dropped = engine.droppedMonitor, dropped.uid == monitorDeviceUID {
                monitorWasDropped(dropped)
            }
        }
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
        if isTranscribing || isScoringSinging || isSingingVisible { pumpSourceTaps() }
        lap("singers") { if isScoringSinging { refreshSingers() } }
        // `updateSinging` was reached from the tab appearing and from nowhere
        // else, so the key was worked out once, from a single FFT window taken
        // before any audio had reached the analyser — and the singer's range
        // never got past one sample of the twenty it needs, which is why the
        // suggested transpose was permanently nil. Every unit test passed
        // throughout: they call `KeyDetector` directly.
        lap("nowPlaying") { if isSingingVisible { refreshNowPlaying(); updateSinging() } }
        // Once a second, not twenty times: a script watching a number does not
        // need it at the meter's rate, and a handler that runs twenty times a
        // second is a handler somebody's laptop can hear.
        pollsSinceScriptTick += 1
        if pollsSinceScriptTick >= 20 {
            pollsSinceScriptTick = 0
            if residentListensForTick {
                fire(
                    .tick,
                    [
                        "peak": Double(peakLevel),
                        "loudness": analysis.shortTerm.isFinite ? analysis.shortTerm : -70,
                        "muted": isInputMuted,
                        "recording": isRecording,
                    ])
            }
        }
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
    /// Identifies the explicit transcription session a callback belongs to.
    ///
    /// Stopping finalises the last sentence asynchronously. It still belongs
    /// to that session, but if somebody has already started another one its
    /// late callback must not appear among the new conversation.
    @ObservationIgnored private var transcriptSessionGeneration = 0
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
        guard !groups.compactMap(\.routes.first).isEmpty else {
            transcriptionError = loc("Nothing is routed to transcribe.")
            return
        }
        let opened = openSourceTaps()
        guard opened > 0 else {
            transcriptionError = loc("Could not listen to any source.")
            return
        }

        transcriptSessionGeneration &+= 1
        let generation = transcriptSessionGeneration
        transcript = []
        transcribers = groups.prefix(opened).map { group in
            Transcriber(
                speaker: representative(of: group).map(routeTitle) ?? loc("Source")
            ) { [weak self] line in
                Task { @MainActor [weak self] in
                    self?.receiveTranscript(line, generation: generation)
                }
            }
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
        closeSourceTapsIfIdle()
        let finishing = transcribers
        let generation = transcriptSessionGeneration
        transcribers = []
        // Finalised rather than dropped: the model is holding the end of the
        // last sentence, and a transcript that stops mid-word because somebody
        // pressed a button is not what they asked for.
        Task { @MainActor in
            for transcriber in finishing { await transcriber.stop() }
            await self.collectTranscript(from: finishing, generation: generation)
        }
    }

    /// True while the per-source rings are open.
    @ObservationIgnored private var sourceTapsOpen = false
    /// Which sources they were opened for. A tap is bound to the route it was
    /// built on, so this is what says whether the open ones are still the right
    /// ones.
    @ObservationIgnored private var sourceTapsFor: [String] = []
    /// The engine count recorded when these rings were opened.
    ///
    /// Reading `engine.transcriptTapCount` takes the engine's state lock. The
    /// singing poll used to take it twenty times a second merely to rediscover
    /// an invariant that only changes when a tap opens or the graph stops.
    @ObservationIgnored private var openedSourceTapCount = 0

    /// Whether the open rings can serve this request without touching the
    /// engine. A zero count is never reusable: it is the exact stale state a
    /// full route stop used to leave behind.
    nonisolated static func reusableSourceTapCount(
        isOpen: Bool, openedCount: Int, openedFor: [String], wanted: [String]
    ) -> Int? {
        guard isOpen, openedCount > 0, openedFor == wanted else { return nil }
        return openedCount
    }

    /// Opens one ring per source, or leaves the open ones alone.
    ///
    /// There is one set of rings and there are now two things that want them:
    /// the transcribers and the singing scorer. A ring is single-consumer by
    /// construction, so two independent drains would each get half the audio
    /// and neither would say so. One drain, handing the same block to whoever
    /// is listening, is the only shape that works — and it is the reason the
    /// second feature needed no new audio path at all.
    ///
    /// They are also reopened when the sources move under them. The panel holds
    /// these open while it is merely visible now, so a route rebuild —
    /// capturing an application, switching a device — happens *while* they are
    /// open, and the taps do not survive one. Measured: capturing a player with
    /// the singing panel open left `transcriptTapCount` at zero while
    /// `sourceTapsOpen` still said yes, so the next thing to ask for a tap was
    /// told there were none and scoring refused to start with "could not listen
    /// to any source". Keyed on which sources rather than on the count, so a
    /// machine where fewer taps open than there are sources does not tear them
    /// down and rebuild them twenty times a second.
    ///
    /// - Returns: How many were opened, or how many are already open.
    @discardableResult
    private func openSourceTaps() -> Int {
        let groups = sourceGroups
        let first = groups.compactMap(\.routes.first)
        guard !first.isEmpty else { return 0 }
        let uids = groups.map(\.uid)
        if let count = Self.reusableSourceTapCount(
            isOpen: sourceTapsOpen, openedCount: openedSourceTapCount,
            openedFor: sourceTapsFor, wanted: uids)
        {
            return count
        }
        if sourceTapsOpen { engine.stopTranscriptTaps() }
        invalidateSourceTaps()
        musicRecognition.reset()
        recognisedApplication = nil
        recognitionSourceUID = nil
        musicRecognitionProblem = nil
        let opened = engine.startTranscriptTaps(routes: first)
        sourceTapsOpen = opened > 0
        sourceTapsFor = opened > 0 ? uids : []
        openedSourceTapCount = opened
        transcriptRate = engine.pathQuality?.sampleRate ?? 48000
        return opened
    }

    /// Forgets rings the engine has already destroyed with its graph.
    ///
    /// This deliberately does not call the engine: `finishStop` runs after
    /// `engine.stop()`, when there is no graph left to modify.
    private func invalidateSourceTaps() {
        sourceTapsOpen = false
        sourceTapsFor = []
        openedSourceTapCount = 0
    }

    /// Closes them once nothing is listening. Not before: stopping the
    /// transcript while somebody is being scored would take the scorer's audio
    /// away with it.
    private func closeSourceTapsIfIdle() {
        // The singing panel counts as a listener whether or not it is scoring:
        // the note it shows is one of these rings, not the mixed bus.
        guard sourceTapsOpen, !isTranscribing, !isScoringSinging, !isSingingVisible else {
            return
        }
        engine.stopTranscriptTaps()
        invalidateSourceTaps()
    }

    /// Moves audio from the rings to whoever asked for it, and lines back.
    private func pumpSourceTaps() {
        let rate = transcriptRate
        let slots = max(transcribers.count, singerTracks.count)
        guard slots > 0 else { return }
        for slot in 0..<slots {
            transcriptScratch.withUnsafeMutableBufferPointer { buffer in
                let taken = engine.drainTranscript(
                    slot, into: buffer.baseAddress!, capacity: buffer.count)
                guard taken > 0 else { return }
                let borrowed = UnsafeBufferPointer(start: buffer.baseAddress, count: taken)
                if slot < singerTracks.count { singerTracks[slot].add(borrowed) }

                let application =
                    isSingingVisible ? recognitionApplication(for: slot) : nil
                // Pitch tracking consumes the scratch buffer synchronously, so
                // the ordinary singing panel allocates nothing per drain. The
                // two asynchronous consumers need ownership; when both are
                // active they share one copy rather than making one each.
                if slot < transcribers.count || application != nil {
                    let owned = Array(borrowed)
                    if slot < transcribers.count {
                        transcribers[slot].add(owned, sampleRate: rate)
                    }
                    if let application {
                        recognisedApplication = application
                        musicRecognition.add(owned, sampleRate: rate)
                    }
                }
            }
        }
    }

    /// The unsupported player behind one source-tap slot.
    ///
    /// Music and Spotify have supported scripting dictionaries and therefore a
    /// cheaper, immediate answer. Everything else is identified from the audio
    /// already captured into the route. The environment override exists only
    /// for the live flow check, where Spotify is the known recording available
    /// on this machine.
    private func recognitionApplication(for slot: Int) -> AudioApplication? {
        guard slot < sourceTapsFor.count,
            let group = sourceGroups.first(where: { $0.uid == sourceTapsFor[slot] }),
            let application = representative(of: group).flatMap(application(of:))
        else { return nil }
        let scripted = ["com.apple.Music", "com.spotify.client"]
        let checksScriptedPlayers =
            ProcessInfo.processInfo.environment["YUNAUDIO_RECOGNISE_PLAYERS"] == "1"
        guard checksScriptedPlayers || !scripted.contains(application.bundleID) else {
            return nil
        }
        // A signature is one recording. Feeding two captured applications into
        // one session would interleave their blocks and guarantee either no
        // match or, worse, metadata for whichever happened to dominate. Keep
        // one stable source until the route changes, preferring one CoreAudio
        // says is actually playing.
        if recognitionSourceUID == nil {
            let candidate = sourceGroups.compactMap { group -> (String, AudioApplication)? in
                guard let route = representative(of: group),
                    let app = self.application(of: route),
                    checksScriptedPlayers || !scripted.contains(app.bundleID)
                else { return nil }
                return (group.uid, app)
            }
            recognitionSourceUID =
                candidate.first(where: { $0.1.isPlaying })?.0 ?? candidate.first?.0
        }
        guard recognitionSourceUID == group.uid else { return nil }
        return application
    }

    /// Inserts one finished line into the attributed conversation.
    ///
    /// Duplicate IDs are ignored because stopping performs one final catch-up
    /// after callbacks have already delivered most lines. The timestamp search
    /// is logarithmic; moving later elements is unavoidable because SwiftUI
    /// observes an ordered array, but it now happens once per sentence rather
    /// than once per 50 ms poll.
    @discardableResult
    nonisolated static func insertTranscriptLine(
        _ line: Transcriber.Line, into transcript: inout [Transcriber.Line]
    ) -> Bool {
        guard !transcript.contains(where: { $0.id == line.id }) else { return false }
        var lower = 0
        var upper = transcript.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if transcript[middle].start <= line.start {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        transcript.insert(line, at: lower)
        return true
    }

    private func receiveTranscript(_ line: Transcriber.Line, generation: Int) {
        guard generation == transcriptSessionGeneration else { return }
        Self.insertTranscriptLine(line, into: &transcript)
    }

    private func collectTranscript(
        from transcribers: [Transcriber], generation: Int
    ) async {
        guard generation == transcriptSessionGeneration else { return }
        for transcriber in transcribers {
            for line in await transcriber.lines {
                receiveTranscript(line, generation: generation)
            }
        }
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
            guard oldValue != isAnalysisVisible else { return }
            refreshAnalysisNeeds()
            guard isAnalysisVisible else { return }
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
            MainActor.assumeIsolated { self?.calibrationTick() }
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
            applyDucking()
            persist()
        }
    }

    /// How far application audio drops while somebody is talking.
    var duckDecibels: Float = -14 {
        didSet {
            guard oldValue != duckDecibels else { return }
            applyDucking()
            persist()
        }
    }

    private func applyDucking() {
        let enabled = isDucking
        let depth = Self.gain(fromDecibels: duckDecibels)
        applyLiveControl { $0.setDucking(enabled: enabled, depth: depth) }
        appliedToGraph.insert(.ducking)
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
        let allowed = isSpeechRecent
        applyLiveControl { $0.setDuckingAllowed(allowed) }
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

    /// Where the loop works from after the trim is moved by hand.
    ///
    /// The invariant is that the total does not move: the loop's next tick sets
    /// the trim to `base + offset`, and that has to come out as the number the
    /// user just chose.
    static func autoLevelBase(afterManual trim: Float, offset: Double) -> Float {
        trim - Float(offset)
    }
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

    /// Which of `YunIconBadge.styles` the application icon wears.
    ///
    /// How far this reaches is worth being honest about, because it is not as
    /// far as the equivalent setting on an iPhone. iOS has
    /// `setAlternateIconName`, where the system owns a catalogue of icons the
    /// app declared up front and swapping between them is one call. macOS has
    /// no equivalent: what Finder and the Dock show is the `.icns` sealed
    /// inside the bundle, chosen when the bundle was built, and the only way to
    /// change it in place is to write a custom icon into the bundle — which
    /// breaks its code signature, and this application is signed with the
    /// microphone entitlement. A broken seal there does not mean a stale icon;
    /// it means the microphone permission is revoked. Not a trade worth making
    /// for a picture.
    ///
    /// So this changes every icon the *application* draws — the About panel and
    /// anything that shows `NSApp.applicationIconImage`, which includes its
    /// alerts and its notifications — and `./App/make-icon.sh --style <name>`
    /// changes the one Finder shows.
    var iconStyle: String = YunIconBadge.fallbackStyle {
        didSet {
            guard oldValue != iconStyle else { return }
            applyIconStyle()
            persist()
        }
    }

    func applyIconStyle() {
        NSApp?.applicationIconImage = YunIconBadge.image(
            size: 512, style: YunIconBadge.style(named: iconStyle))
    }

    /// IO cycles completed. Only used by the flow check, which needs to know
    /// whether audio survived a change rather than merely whether the model
    /// still says it is running.
    var cycleCountForDiagnostics: UInt64 { engine.cycleCount }

    /// Loudest route, for the menu bar icon and the signal path graphic.
    var peakLevel: Float { levels.max() ?? 0 }
}

/// How often each view's `body` is evaluated.
///
/// `@Observable` tracks per property, so a view reading only `isRunning` should
/// survive a meter moving. What decides that is not the view's *purpose* but
/// every property reached anywhere inside its body — including through a
/// computed property it merely passes along — and reasoning about which those
/// are has been wrong here every time it has been tried. So they are counted.
///
/// Off unless the flow check switches it on: the counter is a dictionary write,
/// and a measurement large enough to be part of what it measures is not one.
@MainActor
enum BodyCount {
    static var isCounting = false
    private(set) static var counts: [String: Int] = [:]

    /// Called as `let _ = BodyCount.tick("…")` at the head of a body, which is
    /// the only way to run a statement inside a `ViewBuilder`.
    static func tick(_ name: String) {
        guard isCounting else { return }
        counts[name, default: 0] += 1
    }

    static func reset() { counts = [:] }
}
