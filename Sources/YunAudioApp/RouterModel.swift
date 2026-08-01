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

/// Control-thread storage for draining source taps.
///
/// A route that is only forwarding audio has no source-tap consumer. Keeping
/// this separate makes both sides of that lifetime measurable: no allocation
/// before a tap opens or after the last one closes, and 96,000 Float samples
/// while a tap is live.
struct SourceTapScratch {
    static let frameCapacity = 96_000

    private final class Storage {
        var samples = [Float](repeating: 0, count: SourceTapScratch.frameCapacity)
    }

    private var storage: Storage?

    /// Bytes occupied by live Float elements, separate from allocator metadata.
    var retainedSampleBytes: Int {
        (storage?.samples.count ?? 0) * MemoryLayout<Float>.stride
    }

    /// Identity used to prove the owner and its uniquely-held Array die at the
    /// lifecycle boundary rather than merely reporting a count of zero.
    var allocationIdentity: AnyObject? {
        storage
    }

    mutating func activate() {
        guard storage == nil else { return }
        storage = Storage()
    }

    mutating func release() {
        storage = nil
    }

    mutating func withUnsafeMutableBufferPointer<Result>(
        _ body: (inout UnsafeMutableBufferPointer<Float>) throws -> Result
    ) rethrows -> Result {
        guard let storage else {
            var empty = UnsafeMutableBufferPointer<Float>(start: nil, count: 0)
            return try body(&empty)
        }
        return try storage.samples.withUnsafeMutableBufferPointer(body)
    }
}

/// Suppresses engine-queue work while ducking's coarse permission is unchanged.
///
/// The classifier is sampled at the meter's 20 Hz rate, but the realtime graph
/// needs only the two edges: speech became recent, or its hold expired. Keeping
/// the last value here turns a stable hour from 72,000 queued lock acquisitions
/// into one without delaying either edge.
struct DuckingAllowedGate {
    private var published: Bool?

    mutating func reset() {
        published = nil
    }

    mutating func shouldSend(_ value: Bool) -> Bool {
        guard published != value else { return false }
        published = value
        return true
    }
}

@Observable
@MainActor
final class RouterModel: ScriptTarget {
    // MARK: Devices

    private(set) var inputDevices: [AudioDevice] = []
    private(set) var outputDevices: [AudioDevice] = []
    /// False means the driver and device lists are unknown, not absent.
    ///
    /// Production construction publishes its first frame before asking HAL.
    /// Without a third state, those empty launch arrays briefly rendered the
    /// missing-driver warning and then took it back when discovery completed.
    private(set) var deviceInventoryIsReady = false

    private struct RestoredDeviceIntent: Sendable {
        let source: String?
        let destination: String?
        let monitor: String?
        let additionalSources: [String]
        let additionalDestinations: [String]
    }

    @ObservationIgnored private var restoredDeviceIntent: RestoredDeviceIntent?
    @ObservationIgnored private var deviceDiscoveryHasBegun = false

    private enum DeviceSelectionTarget: Hashable, Sendable {
        case primarySource
        case primaryDestination
        case additionalSource(String)
        case additionalDestination(String)
        case monitor
    }

    private struct PendingDeviceSelection: Sendable {
        let uid: String
        let token: UInt64
    }

    private struct DeviceSelectionWork: Sendable {
        var active: PendingDeviceSelection
        var latest: PendingDeviceSelection? = nil
    }

    /// A metadata-only Bluetooth row is not a route yet. The old selection stays
    /// live until a direct UID lookup has supplied exact channel counts.
    @ObservationIgnored private var deviceSelectionWork:
        [DeviceSelectionTarget: DeviceSelectionWork] = [:]
    @ObservationIgnored private var deviceSelectionSerial: UInt64 = 0
    @ObservationIgnored private var isCommittingHydratedDeviceSelection = false
    private(set) var deviceSelectionStatus: String?
    /// Inputs automation may open without waking another personal device or
    /// dropping a headset out of high-quality playback.
    ///
    /// Continuity Capture remains in `inputDevices` so a person can choose it
    /// deliberately. It is absent here so launch defaults, recovery and
    /// verification cannot turn a nearby phone into a microphone.
    var automaticallySelectableInputDevices: [AudioDevice] {
        inputDevices.filter {
            Self.canSelectInputAutomatically(transport: $0.transport)
        }
    }

    nonisolated static func canSelectInputAutomatically(
        transport: AudioTransport
    ) -> Bool {
        !transport.requiresExplicitInputSelection
            && !transport.losesOutputQualityToItsMicrophone
    }

    /// Whether a persisted input may wake itself at launch.
    ///
    /// Bluetooth LE can be a sensible picker default, but it is still personal
    /// radio hardware. Restoring it must not open an input profile merely
    /// because auto-start was saved in another session.
    nonisolated static func canAutoStartPersistedInput(
        transport: AudioTransport
    ) -> Bool {
        canSelectInputAutomatically(transport: transport)
            && transport != .bluetooth
            && transport != .bluetoothLE
    }

    nonisolated static func canProbeRestoredDeviceControls(
        transport: AudioTransport
    ) -> Bool {
        transport != .bluetooth
            && transport != .bluetoothLE
            && transport != .continuityCapture
    }

    /// Whether the remembered route contains an input that must not auto-start.
    private var routeRequiresExplicitInputSelection: Bool {
        activeSourceUIDs.contains { uid in
            inputDevices.first(where: { $0.uid == uid })?.transport
                .requiresExplicitInputSelection == true
        }
    }

    private var persistedRouteRequiresManualStart: Bool {
        activeSourceUIDs.contains { uid in
            guard let transport = inputDevices.first(where: { $0.uid == uid })?.transport
            else { return false }
            return !Self.canAutoStartPersistedInput(transport: transport)
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
            || environment["YUNAUDIO_UI_BENCHMARK"] != nil
    }()

    /// The UI benchmark is deliberately more constrained than other verification.
    ///
    /// Render and flow verification need a real inventory. This one exists to
    /// separate SwiftUI work from the router, so even enumerating HAL or starting
    /// MIDI would put an unknown system cost back into the number it reports.
    private static let isUIBenchmarkProcess =
        ProcessInfo.processInfo.environment["YUNAUDIO_UI_BENCHMARK"] != nil

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
            if !isRestoring, let uid = selectedSourceUID,
                inputDevices.first(where: { $0.uid == uid })?.hasCompleteTopology == false
            {
                selectedSourceUID = oldValue
                requestHydratedSelection(uid, for: .primarySource)
                return
            }
            cancelHydratedSelection(for: .primarySource)
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
            publish(nil, to: \.hardwareGainReading)
            publish(nil, to: \.hardwareMonitorReading)
            if !isRestoring { refreshDeviceControls() }
            if !isRestoring, !isCommittingHydratedDeviceSelection {
                hydrateConfiguredDevicesAsynchronously()
            }
            persist()
            rerouteAfterDeviceChange()
        }
    }
    var selectedDestinationUID: String? {
        didSet {
            guard oldValue != selectedDestinationUID else { return }
            if !isRestoring, let uid = selectedDestinationUID,
                outputDevices.first(where: { $0.uid == uid })?.hasCompleteTopology == false
            {
                selectedDestinationUID = oldValue
                requestHydratedSelection(uid, for: .primaryDestination)
                return
            }
            cancelHydratedSelection(for: .primaryDestination)
            recentDestinationUIDs = Self.remember(
                selectedDestinationUID, in: recentDestinationUIDs)
            if !isSubstitutingDevice {
                displacedDestinationUID = nil
                displacedDestinationName = nil
            }
            publish(true, to: \.destinationHasVolumeControl)
            if !isRestoring {
                refreshDeviceControls()
                refreshHeadsetQualityAsynchronously()
            }
            if !isRestoring, !isCommittingHydratedDeviceSelection {
                hydrateConfiguredDevicesAsynchronously()
            }
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
            device.hasInput
                && !activeSourceUIDs.contains(device.uid)
                && !activeDestinationUIDs.contains { isSamePhysicalDevice($0, device.uid) }
                && !(monitorDeviceUID.map { isSamePhysicalDevice($0, device.uid) } ?? false)
        }
    }

    /// And outputs, on the same terms.
    var addableDestinationDevices: [AudioDevice] {
        outputDevices.filter { device in
            device.hasOutput
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
        if inputDevices.first(where: { $0.uid == uid })?.hasCompleteTopology == false {
            requestHydratedSelection(uid, for: .additionalSource(uid))
            return
        }
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
        if !isCommittingHydratedDeviceSelection {
            hydrateConfiguredDevicesAsynchronously()
        }
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
        if !isCommittingHydratedDeviceSelection {
            hydrateConfiguredDevicesAsynchronously()
        }
        persist()
        rerouteAfterDeviceChange()
    }

    func addDestination(_ uid: String) {
        guard !activeDestinationUIDs.contains(uid) else { return }
        if outputDevices.first(where: { $0.uid == uid })?.hasCompleteTopology == false {
            requestHydratedSelection(uid, for: .additionalDestination(uid))
            return
        }
        droppedExtraInputNames = []
        droppedExtraOutputNames = []
        guard selectedDestinationUID != nil else {
            selectedDestinationUID = uid
            return
        }
        additionalDestinationUIDs.append(uid)
        if !isCommittingHydratedDeviceSelection {
            hydrateConfiguredDevicesAsynchronously()
        }
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
        hydrateConfiguredDevicesAsynchronously()
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
    @ObservationIgnored private var headphoneProfilesWereRequested = false
    @ObservationIgnored private var headphoneProfileRefreshGate = LatestRefreshGate()

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
    nonisolated static var headphoneDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YunAudio/Headphones", isDirectory: true)
    }

    func refreshHeadphoneProfiles() {
        headphoneProfilesWereRequested = true
        headphoneProfileRefreshGate.invalidate()
        applyHeadphoneProfiles(Self.readHeadphoneProfiles())
    }

    func refreshHeadphoneProfilesIfNeeded() {
        guard !headphoneProfilesWereRequested else { return }
        refreshHeadphoneProfilesAsynchronously()
    }

    func refreshHeadphoneProfilesAsynchronously() {
        headphoneProfilesWereRequested = true
        guard let token = headphoneProfileRefreshGate.request() else { return }
        runHeadphoneProfileRefresh(token)
    }

    nonisolated private static func readHeadphoneProfiles() -> [ParametricEQ] {
        guard let directory = Self.headphoneDirectory,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return
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
    }

    private func runHeadphoneProfileRefresh(_ token: LatestRefreshGate.Token) {
        systemDiscoveryQueue.async {
            let profiles = Self.readHeadphoneProfiles()
            Task { @MainActor in
                self.finishHeadphoneProfileRefresh(profiles, token: token)
            }
        }
    }

    private func finishHeadphoneProfileRefresh(
        _ profiles: [ParametricEQ], token: LatestRefreshGate.Token
    ) {
        guard headphoneProfileRefreshGate.accepts(token) else { return }
        applyHeadphoneProfiles(profiles)
        if case .start(let next) = headphoneProfileRefreshGate.finish(token) {
            runHeadphoneProfileRefresh(next)
        }
    }

    private func applyHeadphoneProfiles(_ profiles: [ParametricEQ]) {
        let profilesChanged = headphoneProfiles != profiles
        if profilesChanged { headphoneProfiles = profiles }
        // A profile that has been deleted from the folder must stop being used,
        // not silently keep running from memory. Every bus, not only the one
        // the device tab shows: a file deleted while the send was using it
        // would otherwise keep running off a copy nothing can reach.
        let available = Set(headphoneProfiles.map(\.name))
        let stale = busHeadphoneProfiles.filter { !available.contains($0.value) }
        if !stale.isEmpty {
            for id in stale.keys { busHeadphoneProfiles[id] = nil }
            persist()
        }
        // This also reapplies a selected file whose coefficients changed.
        if profilesChanged || !stale.isEmpty { scheduleCorrections() }
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

    /// How many more polls may try to install the output correction.
    ///
    /// Reset by `start`, spent by the poll, and zero for the whole of a steady
    /// session — which is what keeps the retry off the twenty-times-a-second
    /// path once it has done its job. See the poll for why the window exists.
    @ObservationIgnored private var correctionRetriesLeft = 0

    /// Two seconds at twenty polls a second.
    private static let correctionRetries = 40

    /// Which buses have a curve, and which the graph can actually reach.
    var correctionBusReport: String {
        let wanted = Self.correctionCurves(from: correctionSnapshot).keys.sorted()
        return "curve on \(wanted), graph has \(engine.outputDeviceUIDs)"
    }

    /// Why the last correction install did nothing, straight from the engine.
    var lastCorrectionOutcome: String { engine.lastCorrectionOutcome.rawValue }

    /// How many live buses actually have a curve to push.
    ///
    /// The honest denominator for "did everything reach the graph". A router
    /// nobody has dialled a tone into has no correction to install, and an
    /// assertion that demands one anyway fails on a route that is complete —
    /// which is what it did, for long enough that the failure became furniture.
    var busesWithACurve: Int {
        Self.correctionCurves(from: correctionSnapshot).count
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
    @ObservationIgnored private var deviceControlRefreshGate = LatestRefreshGate()

    struct DeviceControlSnapshot: Sendable {
        let sourceUID: String?
        let destinationUID: String?
        let hardwareGain: AudioDevice.HardwareGain?
        let hardwareMonitor: AudioDevice.HardwareGain?
        let destinationHasVolumeControl: Bool
    }

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

    nonisolated static func readDeviceControlSnapshot(
        sourceUID: String?,
        destinationUID: String?,
        readsHardwareGain: (String) -> AudioDevice.HardwareGain?,
        readsHardwareMonitor: (String) -> AudioDevice.HardwareGain?,
        readsDestinationVolumeControl: (String) -> Bool
    ) -> DeviceControlSnapshot {
        DeviceControlSnapshot(
            sourceUID: sourceUID,
            destinationUID: destinationUID,
            hardwareGain: sourceUID.flatMap(readsHardwareGain),
            hardwareMonitor: sourceUID.flatMap(readsHardwareMonitor),
            destinationHasVolumeControl:
                destinationUID.map(readsDestinationVolumeControl) ?? true)
    }

    /// Schedules the HAL reads; this method itself is safe to call from a view
    /// lifecycle or a selection observer on MainActor.
    func refreshDeviceControls() {
        guard let token = deviceControlRefreshGate.request() else { return }
        runDeviceControlRefresh(token)
    }

    private func runDeviceControlRefresh(_ token: LatestRefreshGate.Token) {
        let source = selectedSource
        let destination = selectedDestination
        let queue = engineQueue
        queue.async { [weak self] in
            let snapshot = Self.readDeviceControlSnapshot(
                sourceUID: source?.uid,
                destinationUID: destination?.uid,
                readsHardwareGain: { _ in
                    source?.hardwareGain(scope: kAudioObjectPropertyScopeInput)
                },
                readsHardwareMonitor: { _ in source?.playThrough() },
                readsDestinationVolumeControl: { _ in
                    destination?.hasSettableVolume(scope: kAudioObjectPropertyScopeOutput)
                        ?? true
                })
            Task { @MainActor in
                self?.finishDeviceControlRefresh(snapshot, token: token)
            }
        }
    }

    private func finishDeviceControlRefresh(
        _ snapshot: DeviceControlSnapshot,
        token: LatestRefreshGate.Token
    ) {
        guard deviceControlRefreshGate.accepts(token) else { return }
        if Self.deviceControlSnapshotIsCurrent(
            snapshotSourceUID: snapshot.sourceUID,
            snapshotDestinationUID: snapshot.destinationUID,
            selectedSourceUID: selectedSourceUID,
            selectedDestinationUID: selectedDestinationUID)
        {
            publish(snapshot.hardwareGain, to: \.hardwareGainReading)
            publish(snapshot.hardwareMonitor, to: \.hardwareMonitorReading)
            publish(
                snapshot.destinationHasVolumeControl,
                to: \.destinationHasVolumeControl)
        }
        if case .start(let next) = deviceControlRefreshGate.finish(token) {
            runDeviceControlRefresh(next)
        }
    }

    nonisolated static func deviceControlSnapshotIsCurrent(
        snapshotSourceUID: String?,
        snapshotDestinationUID: String?,
        selectedSourceUID: String?,
        selectedDestinationUID: String?
    ) -> Bool {
        snapshotSourceUID == selectedSourceUID
            && snapshotDestinationUID == selectedDestinationUID
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
    /// Nil until captured audio from a player without scripting support needs
    /// identifying. `SHSession` is not a harmless placeholder: constructing it
    /// owns catalogue machinery, so Spotify and Music must never create one.
    @ObservationIgnored private var musicRecognition: MusicRecognition?
    @ObservationIgnored private var recognisedApplication: AudioApplication?
    @ObservationIgnored private var recognitionSourceUID: String?
    /// A verification-only override, fixed for the lifetime of the process.
    ///
    /// `recognitionApplication(for:)` runs once per source at the 20 Hz singing
    /// poll. Asking `ProcessInfo` there rebuilt the environment dictionary for
    /// a value that cannot change after launch.
    private static let recognisesScriptedPlayers =
        ProcessInfo.processInfo.environment["YUNAUDIO_RECOGNISE_PLAYERS"] == "1"
    /// Lyrics for it, when a file was found.
    private(set) var lyrics: Lyrics?
    /// The `[offset:]` the file itself declared, kept apart from the nudge so
    /// that clearing the nudge restores the file's own value rather than zero.
    private var fileLyricOffset: Double = 0
    /// Words with no reliable timeline, used only when no timed copy exists.
    private(set) var plainLyrics: String?
    /// The source actually shown, so a fallback is visible rather than opaque.
    private(set) var lyricsSourceName: String?
    /// Rights text supplied by the online catalogue, restored with its cache.
    private(set) var lyricsCopyright: String?
    /// Catalogue region attached to the online result, restored with its cache.
    private(set) var lyricsRegion: String?
    static let maximumMusixmatchSessionKeyLength = 1_024
    /// An official API key held in memory for this process only.
    ///
    /// There is deliberately no `didSet` persistence hook. The preferences
    /// file and diagnostic surfaces are not credential stores.
    private(set) var musixmatchSessionKey = RouterModel.initialMusixmatchSessionKey(
        environment: ProcessInfo.processInfo.environment)
    var isMusixmatchSessionConfigured: Bool { !musixmatchSessionKey.isEmpty }

    func setMusixmatchSessionKey(_ rawValue: String) {
        musixmatchSessionKey = Self.boundedMusixmatchSessionKey(rawValue)
    }

    func clearMusixmatchSessionKey() {
        musixmatchSessionKey = ""
    }

    static func initialMusixmatchSessionKey(
        environment: [String: String]
    ) -> String {
        boundedMusixmatchSessionKey(environment["MUSIXMATCH_API_KEY"] ?? "")
    }

    static func boundedMusixmatchSessionKey(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumMusixmatchSessionKeyLength))
    }

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

    /// Whether the words carry their own timings.
    ///
    /// A plain lyric cannot sweep, and somebody watching a stage whose words
    /// never light up is owed that sentence rather than left to conclude the
    /// feature is broken. Both presentations show it now; only one used to.
    var lyricsAreTimed: Bool { lyrics?.lines.contains { $0.time > 0 } ?? false }
    @ObservationIgnored private var lyricsLookupTask: Task<Void, Never>?
    /// Which line is being sung, and how far through it.
    private(set) var lyricLine: Int?
    private(set) var lyricProgress: Double = 0
    /// A sparse clock anchor for the layer-backed lyric compositor.
    ///
    /// `lyricProgress` remains as the legacy benchmark control and numerical
    /// flow-check value. Production views use this anchor instead, so a smooth
    /// fill does not put ten animation frames a second through Observation.
    private(set) var lyricPlaybackAnchor: LyricPlaybackAnchor?
    @ObservationIgnored private var lyricPlaybackRevision: UInt64 = 0
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
    /// Set while somebody is looking at the lyrics, so nothing is asked of the
    /// music players when nobody is.
    /// Whether the stage has its own window on screen.
    ///
    /// Observable, which `KTVWindow.isVisible` cannot be — it reads an
    /// `NSWindow`, and SwiftUI has no way to know when that changes. Without
    /// this the panel inside the main window had no way to notice the stage had
    /// been opened, so both drew the whole thing at once: two lyric layouts,
    /// two backdrops, two sets of meters, for one song.
    private(set) var isKTVWindowOpen = false

    func setKTVWindowOpen(_ open: Bool) {
        guard isKTVWindowOpen != open else { return }
        isKTVWindowOpen = open
    }

    var isSingingVisible = false {
        didSet {
            guard oldValue != isSingingVisible else { return }
            refreshAnalysisNeeds()
            if isSingingVisible { refreshNowPlaying(); updateSinging() } else { clearSinging() }
            // The poll has to exist for the words to move.
            //
            // `startPolling` was called from one place — the completion of a
            // successful route start — so with nothing routed there was no
            // timer at all, and the branch added to `poll()` for exactly this
            // case was never reached. Half a fix reads the same as none.
            keepThePollAlive()
        }
    }

    /// Moves the words against the recording, in tenths of a second.
    ///
    /// Bounded at two seconds either way: past that the file is for a different
    /// recording rather than out by a lead-in, and a control that can put the
    /// words a verse out is a control that loses somebody their place.
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
        publish(key, to: \.songKey)
        publish(
            comfortableMidi.map {
                KeyDetector.suggestedShift(songKey: key, comfortableMidi: $0)
            },
            to: \.suggestedShift)
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
        releaseMusicRecognition()
        nowPlayingSessionGeneration &+= 1
        isAskingThePlayer = false
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
        lyricsCopyright = nil
        lyricsRegion = nil
        melody = nil
        lyricLine = nil
        lyricProgress = 0
        lyricPlaybackAnchor = nil
        songSecond = 0
        isHandRun = false
        trackClock.stop()
        pollsSinceNowPlaying = Self.nowPlayingEveryNPolls
        pollsSinceLyricFrame = Self.lyricFrameEveryNPolls
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

    /// What a finished song came to, kept after the song itself has gone.
    ///
    /// The scores move while somebody sings and then vanish with the track,
    /// which is every KTV machine's one unforgivable omission: the number that
    /// matters is the one at the end, and it was on screen for as long as it
    /// took the next song to start.
    struct Performance: Equatable, Sendable {
        let title: String
        let artist: String
        let singers: [Singer]
    }

    private(set) var lastPerformance: Performance? {
        didSet { performanceShownAt = Self.now }
    }

    private var performanceShownAt: Double = 0

    /// The least time a scoreboard stays up before the next song can take it
    /// away.
    ///
    /// Without this the card is gone before it is read on exactly the songs
    /// this project started with: 慢冷 has no leading silence, so its first
    /// line is being sung within a frame of the track changing, and the rule
    /// that hides the card when the next song reaches a line of its own fires
    /// immediately. Four seconds is long enough to read two numbers and short
    /// enough not to sit over the first verse.
    static let leastPerformanceSeconds: Double = 4

    private static var now: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    func dismissPerformance() { lastPerformance = nil }

    /// Forgets the song's length, so a gate can check what still works without
    /// one. Only the flow check calls this.
    func forgetDurationForCheck() {
        nowPlaying?.duration = 0
        trackClock.duration = 0
    }

    /// Pretends another index answered, so a gate can press the switch.
    ///
    /// The control appears only when two indexes both returned words for the
    /// song, which needs a network and two services agreeing to answer. What
    /// is being checked here is what pressing it does to everything around it
    /// — the offset, the browse, the line numbering — not how the answers
    /// arrived. Only the flow check calls this.
    func offerSecondLyricSourceForCheck() {
        guard let lyrics, let identity = nowPlaying.map(Self.lyricsIdentity(for:)) else {
            return
        }
        _ = identity
        // Written out as an `.lrc` rather than handed over as a parsed value:
        // `Match` only accepts an answer that carries the words it claims to
        // have, and a fixture that side-steps that would be checking a path no
        // provider can take.
        let written = lyrics.lines.map { line in
            String(
                format: "[%02d:%05.2f]%@", Int(line.time) / 60,
                line.time.truncatingRemainder(dividingBy: 60), line.text)
        }.joined(separator: "\n")
        let alternative = OnlineLyrics.Match(
            source: .qqMusic, trackName: nowPlaying?.title ?? "", artistName: "",
            albumName: "", duration: nowPlaying?.duration,
            synchronised: written, plain: nil)
        guard let alternative else { return }
        lyricAnswers = [alternative]
        lyricAlternatives = [.netEase, .qqMusic]
        lyricSource = .netEase
    }

    /// Puts a scoreboard up so the flow check can watch it go away again.
    ///
    /// The card's own trigger is a song ending, which a gate cannot arrange
    /// without waiting out a song. What is being checked is not how it arrives
    /// but that it leaves.
    func showPerformanceForCheck(title: String, artist: String, percentage: Double) {
        lastPerformance = Performance(
            title: title, artist: artist,
            singers: [
                Singer(
                    uid: "flow-check", name: title, hertz: 220,
                    score: KaraokeScore(
                        percentage: percentage, onPitchSeconds: percentage,
                        nearPitchSeconds: 0, silentSeconds: 0, referenceSeconds: 100,
                        sungSeconds: 100, meanErrorSemitones: nil, lines: []))
            ])
    }

    /// Keeps the scores of the song that has just ended, if they mean anything.
    ///
    /// Only on a real change of song, and only where a tune was actually being
    /// scored: a card announcing 0% because nobody sang is a card in the way.
    private func keepPerformance(of finished: NowPlaying.Track?) {
        guard isScoringSinging, let finished,
            singers.contains(where: { $0.score.isMeaningful })
        else { return }
        // The alignment happens here and nowhere else, and the timing is why.
        //
        // The live score is incremental — it has to be, four times a second
        // over a growing performance — and an incremental score cannot be
        // realigned, because the alignment of the whole is not the sum of the
        // alignments of the parts. Doing it at the end costs one pass over a
        // finished performance, on a main thread that has just stopped having
        // anything else to do, and gives the reading somebody actually keeps.
        //
        // Beside the live number rather than replacing it: what somebody
        // watches while singing and what they are told at the end must agree
        // about what they did, and they would not if one were aligned.
        let lines = lyrics?.lines ?? []
        let aligned = singers.enumerated().map { index, singer -> Singer in
            guard singerTracks.indices.contains(index) else { return singer }
            let timing = KaraokeScore.timing(
                sung: singerTracks[index].samples,
                reference: scoringReference,
                lyrics: lines)
            return Singer(
                uid: singer.uid, name: singer.name, hertz: singer.hertz,
                score: singer.score.withTiming(timing))
        }
        lastPerformance = Performance(
            title: finished.title, artist: finished.artist, singers: aligned)
    }
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
            // Only a deliberate change is written down.
            //
            // `startScoring` turns this straight back off when there is no
            // route, and that refusal must not erase what somebody chose — the
            // first version of this persisted it, so restoring the setting at
            // launch (where the route is never up yet) wiped the very
            // preference it was reading. Stored and then destroyed by the act
            // of reading it is worse than never stored at all.
            guard !isRefusingToScore else { return }
            wantsScoring = isScoringSinging
            persist()
        }
    }

    /// True while `startScoring` is putting the switch back, rather than a
    /// person.
    @ObservationIgnored private var isRefusingToScore = false

    /// Whether somebody asked for scoring, as opposed to whether it is running.
    ///
    /// The two differ for the whole of a launch: the wish survives, and the
    /// route it needs does not exist until `start`. Kept separately so that
    /// wanting to be scored is remembered even on the evenings the route never
    /// comes up.
    @ObservationIgnored private(set) var wantsScoring = false

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
    /// A few minutes of raw pitch is ample for a four-hertz incremental
    /// consumer to catch up after a busy main actor. `SingerPitch` compacts at
    /// twice this count, bounding each source below 128 KiB.
    private static let scoringHistoryCapacity = 4_096

    private struct KeyScoreConfiguration: Equatable {
        let sungStep: Double
        let key: KeyDetector.Key
        let lines: [Lyrics.Line]
    }

    @ObservationIgnored private var keyScoreConfigurations: [String: KeyScoreConfiguration] =
        [:]
    @ObservationIgnored private var keyScorers: [String: KaraokeScore.IncrementalKeyScorer] =
        [:]

    private struct ExactScoreConfiguration: Equatable {
        let sungStep: Double
        let referenceCount: Int
        let firstReference: PitchSample?
        let lastReference: PitchSample?
        let referenceStep: Double
        let lines: [Lyrics.Line]
    }

    @ObservationIgnored private var exactScoreConfigurations:
        [String: ExactScoreConfiguration] = [:]
    @ObservationIgnored private var exactScorers:
        [String: KaraokeScore.IncrementalExactScorer] = [:]

    private struct CapturedScoringReference {
        let samples: [PitchSample]
        let step: Double
    }

    /// True when the score is against an exact MIDI tune rather than the
    /// detected-key fallback used by ordinary streaming tracks.
    var hasExactScoringReference: Bool { !scoringReference.isEmpty }

    /// The exact note under the playhead, when a MIDI reference supplies one.
    ///
    /// Nil across rests and for the key/captured-vocal fallbacks: drawing a
    /// target bar when there is no exact written note would turn a useful guess
    /// into a confident lie.
    var scoringTargetMidi: Double? {
        guard !scoringReference.isEmpty else { return nil }
        let position = songPosition
        var lower = 0
        var upper = scoringReference.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if scoringReference[middle].time < position {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let candidates = [lower - 1, lower].filter { scoringReference.indices.contains($0) }
        guard
            let index = candidates.min(by: {
                abs(scoringReference[$0].time - position)
                    < abs(scoringReference[$1].time - position)
            }),
            abs(scoringReference[index].time - position)
                <= KaraokeScore.referenceInterval * 1.5
        else { return nil }
        return scoringReference[index].midi
    }

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

    /// The part of the poll that belongs to the song rather than to the route.
    ///
    /// Deliberately the smallest thing that makes the stage work with nothing
    /// routed: where the song is, which line that is, and what the transport
    /// should read. Scoring is not here and cannot be — the singer only exists
    /// in the router's own ring, so a microphone needs the route up.
    private func pollTheSongOnly() {
        guard isSingingVisible else { return }
        refreshNowPlaying()
        updateSinging()
    }

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
        let allGroups = sourceGroups
        let groupCount = min(opened, allGroups.count)
        guard
            !Self.sourceUIDsMatch(
                groups: allGroups, prefixCount: groupCount, cached: scoringUIDs)
                || singerTracks.count != groupCount
        else {
            return !singerTracks.isEmpty
        }
        let groups = Array(allGroups.prefix(groupCount))
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
            track.historyCapacity = nil
            track.reset(at: songPosition)
        }
        return !singerTracks.isEmpty
    }

    private func releaseSingerTracks() {
        singerTracks = []
        keyScoreConfigurations = [:]
        keyScorers = [:]
        exactScoreConfigurations = [:]
        exactScorers = [:]
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
            isRefusingToScore = true
            isScoringSinging = false
            isRefusingToScore = false
            return
        }
        guard refreshSingerTracks() else {
            singingError = loc("Could not listen to any source.")
            isRefusingToScore = true
            isScoringSinging = false
            isRefusingToScore = false
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
            track.historyCapacity = nil
            track.reset(at: songPosition)
        }
        keyScoreConfigurations = [:]
        keyScorers = [:]
        exactScoreConfigurations = [:]
        exactScorers = [:]
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
            track.historyCapacity = nil
            track.reset(at: songPosition)
        }
        keyScoreConfigurations = [:]
        keyScorers = [:]
        exactScoreConfigurations = [:]
        exactScorers = [:]
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
            let mode: ScoringReferenceMode
            if !scoringReference.isEmpty {
                mode = .midi
            } else if capturedReference != nil {
                mode = .capturedPlayer
            } else if songKey != nil {
                mode = .key
            } else {
                mode = .waiting
            }
            publish(mode, to: \.scoringReferenceMode)
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
                    track,
                    uid: uid,
                    lines: lines,
                    capturedReference: capturedReference)
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
            singerTracks[index],
            uid: uid,
            lines: lines,
            capturedReference: reference)
        return Singer(
            uid: uid, name: index < scoringNames.count ? scoringNames[index] : loc("Source"),
            hertz: singerTracks[index].hertz, score: score)
    }

    private func scoreForTrack(
        _ track: SingerPitch,
        uid: String,
        lines: [Lyrics.Line],
        capturedReference: CapturedScoringReference? = nil
    ) -> KaraokeScore {
        // The player clock is the authority. A microphone ring keeps producing
        // while Spotify, Music or hand-run words are paused; using the ring's
        // elapsed time charged that pause as missed singing.
        let through = songPosition
        if !scoringReference.isEmpty {
            keyScoreConfigurations[uid] = nil
            keyScorers[uid] = nil
            let configuration = ExactScoreConfiguration(
                sungStep: track.sampleInterval,
                referenceCount: scoringReference.count,
                firstReference: scoringReference.first,
                lastReference: scoringReference.last,
                referenceStep: KaraokeScore.referenceInterval,
                lines: lines)
            if exactScoreConfigurations[uid] != configuration {
                exactScoreConfigurations[uid] = configuration
                exactScorers[uid] = KaraokeScore.IncrementalExactScorer(
                    sungStep: configuration.sungStep,
                    reference: scoringReference,
                    referenceStep: configuration.referenceStep,
                    lyrics: configuration.lines)
            }
            track.historyCapacity = Self.scoringHistoryCapacity
            guard var scorer = exactScorers[uid] else { return .none }
            let score = scorer.update(
                sung: track.samples,
                historyStartIndex: track.historyStartIndex,
                historyGeneration: track.historyGeneration,
                through: through)
            exactScorers[uid] = scorer
            return score
        }
        if let capturedReference {
            track.historyCapacity = nil
            keyScoreConfigurations[uid] = nil
            keyScorers[uid] = nil
            exactScoreConfigurations[uid] = nil
            exactScorers[uid] = nil
            return KaraokeScore.scoreChronological(
                sung: track.samples, sungStep: track.sampleInterval,
                reference: capturedReference.samples,
                referenceStep: capturedReference.step,
                lyrics: lines, through: through)
        }
        guard let songKey else {
            track.historyCapacity = nil
            keyScoreConfigurations[uid] = nil
            keyScorers[uid] = nil
            exactScoreConfigurations[uid] = nil
            exactScorers[uid] = nil
            return .none
        }
        track.historyCapacity = Self.scoringHistoryCapacity
        exactScoreConfigurations[uid] = nil
        exactScorers[uid] = nil
        let configuration = KeyScoreConfiguration(
            sungStep: track.sampleInterval,
            key: songKey,
            lines: lines)
        if keyScoreConfigurations[uid] != configuration {
            keyScoreConfigurations[uid] = configuration
            keyScorers[uid] = KaraokeScore.IncrementalKeyScorer(
                sungStep: configuration.sungStep,
                key: configuration.key,
                lyrics: configuration.lines)
        }
        guard var scorer = keyScorers[uid] else { return .none }
        let score = scorer.update(
            sung: track.samples,
            historyStartIndex: track.historyStartIndex,
            historyGeneration: track.historyGeneration,
            through: through)
        keyScorers[uid] = scorer
        return score
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
            through: songPosition)
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
        // Free, so it happens every poll rather than once a second: the answer
        // is a counter in this process, not a question put to another one.
        adoptOwnSongPosition()
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
        pollsSinceLyricFrame += 1
        followTheWords(
            publishingProgress: Self.isLyricProgressFrameDue(
                afterPolls: pollsSinceLyricFrame),
            reanchoringCompositor: false)
    }

    /// Ten legacy progress targets a second for the flow check and A/B control.
    nonisolated static func isLyricProgressFrameDue(afterPolls polls: Int) -> Bool {
        polls >= lyricFrameEveryNPolls
    }

    /// A line boundary is semantic state, not an animation frame.
    nonisolated static func shouldPublishLyricProgress(
        periodicFrameDue: Bool, lineChanged: Bool
    ) -> Bool {
        periodicFrameDue || lineChanged
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

    static let maximumHandLyricsFieldLength = 200

    /// Builds the same bounded track whether it came from a text field, a
    /// browser bridge or a future command-line entry point.
    static func handRunTrack(title: String, artist: String) -> NowPlaying.Track? {
        let title = boundedHandLyricsField(title)
        guard !title.isEmpty else { return nil }
        let artist = boundedHandLyricsField(artist)
        return NowPlaying.Track(
            application: loc("By hand"),
            title: title,
            artist: artist,
            album: "",
            position: 0,
            duration: 0,
            isPlaying: false,
            identity: "hand:\(artist)\u{1F}\(title)")
    }

    /// Finds words for music YunAudio cannot identify from captured audio.
    ///
    /// This enters the existing hand-run path before adopting the track, so
    /// the once-a-second Apple-event poll stays disabled. `adopt` checks local
    /// and cached words first and only then starts the public-provider lookup.
    /// No microphone, Accessibility or private metadata API is involved.
    @discardableResult
    func findWordsByTitle(_ title: String, artist: String) -> Bool {
        guard let track = Self.handRunTrack(title: title, artist: artist) else {
            return false
        }
        isHandRun = true
        trackClock.stop()
        lyricLine = nil
        lyricProgress = 0
        lyricPlaybackAnchor = nil
        songSecond = 0
        adopt(track)

        let ends = max(
            melody?.duration ?? 0,
            lyrics.map { ($0.lines.last?.time ?? 0) - $0.offset + 4 } ?? 0)
        trackClock.duration = ends
        if ends > 0, var current = nowPlaying {
            current.duration = ends
            nowPlaying = current
        }
        followTheWords()
        return true
    }

    private static func boundedHandLyricsField(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumHandLyricsFieldLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        lyricsCopyright = nil
        lyricsRegion = nil
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
            position: 0, duration: ends, isPlaying: false,
            artworkURL: Self.artworkBesideWords(at: url))
        trackClock.stop()
        trackClock.duration = ends
        lyricLine = nil
        lyricProgress = 0
        lyricPlaybackAnchor = nil
        songSecond = 0
        if isScoringSinging { rebuildScoringReference() }
        return true
    }

    // MARK: A song this application plays itself

    /// The one path where nobody has to be asked where the music is.
    ///
    /// Every other source here is somebody else's player answered through an
    /// Apple event — 73 ms to open the conversation, once a second at best, and
    /// the whole of `TrackClock` extrapolating in between. A file we opened is
    /// a count of samples the output has consumed, so the words are on the
    /// music by construction rather than by correction.
    ///
    /// It enters the hand-run path rather than inventing a second one: that
    /// path already means "the clock is not a player's", already keeps the
    /// once-a-second poll switched off, and already carries words, tune, score
    /// and stage. The only difference is who moves the clock.
    /// Built on the first song, not at launch.
    ///
    /// **Three crash reports say this matters.** With the player constructed
    /// eagerly, `AVAudioEngine` and its `AudioSession` thread existed in every
    /// session whether or not anybody played a file, and after about two
    /// minutes every *dynamic main-actor check* in the process started faulting
    /// — `EXC_BAD_ACCESS at 0x1e` inside `swift_task_isCurrentExecutor`, once
    /// from a `Canvas` draw closure and twice from the twenty-hertz polling
    /// timer, the last two from the same binary at the same place. The root
    /// cause is not established; what is established is that the engine was
    /// present in all three and that nothing before it had ever done this.
    ///
    /// Lazy is also simply right. An application nobody has asked to play a
    /// file has no business holding an audio graph open, and this keeps the
    /// whole of it — threads, session, units — inside the feature that needs
    /// it rather than in everybody's launch.
    var songPlayer: LocalSongPlayer {
        if let player = madeSongPlayer { return player }
        let player = LocalSongPlayer()
        madeSongPlayer = player
        return player
    }

    /// Nil until somebody opens a song. Read directly where the answer for "no
    /// player yet" is the same as the answer for "player with nothing in it",
    /// so that merely asking cannot build one.
    private var madeSongPlayer: LocalSongPlayer?

    /// The songs that have been put on. See `KTVQueue` for what its verbs mean.
    ///
    /// Written down whenever it changes, rather than at eight call sites that
    /// would have to be kept in step — `append`, `playNext`, `choose`,
    /// `remove`, `clear`, `advance`, `goBack` and the replacement that opening
    /// a single song performs. A ninth verb added later gets this for nothing,
    /// which is the point: the list was lost on every quit because saving it
    /// was nobody's particular job.
    private(set) var songQueue = KTVQueue() {
        didSet {
            guard oldValue != songQueue else { return }
            persist()
        }
    }

    /// Whether the song being sung comes round again instead of the next one.
    var repeatsOneSong: Bool {
        get { songQueue.repeatsOne }
        set {
            songQueue.repeatsOne = newValue
            settingsRevision &+= 1
            persist()
        }
    }

    /// Whether ⏭ has somewhere to go other than further into this song.
    var hasAnotherSongQueued: Bool { !songQueue.upcoming.isEmpty }

    /// Puts songs on, and starts the first if nothing is being sung.
    ///
    /// - Returns: False when the first song could not be opened. Songs that
    ///   follow are not opened until their turn, so a folder with one bad file
    ///   in it still plays.
    @discardableResult
    func openSongs(at urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        guard let start = songQueue.append(urls) else { return true }
        return openSong(at: start, keepingQueue: true)
    }

    /// 插播: after this one, not behind the other eleven.
    func playSongNext(_ url: URL) {
        songQueue.playNext(url)
        settingsRevision &+= 1
    }

    /// The songs still to come, for a list somebody can look at.
    ///
    /// The queue was built, tested to death and wired into the transport, and
    /// then had no interface at all — not one button for 點歌, 插播 or 重唱. A
    /// feature nobody can reach is a feature that was not delivered, so these
    /// are the accessors the list needs.
    var upcomingSongs: [URL] { songQueue.upcoming }

    /// Every song put on, so a list can show what has already been sung as well
    /// as what is coming.
    var allQueuedSongs: [URL] { songQueue.songs }

    /// Which line of that list is being sung.
    var currentQueueIndex: Int? { songQueue.index }

    /// Somebody pointing at a line: play that one now.
    func chooseQueuedSong(at position: Int) {
        guard let chosen = songQueue.choose(position) else { return }
        openSong(at: chosen, keepingQueue: true)
        runWords(from: 0)
        settingsRevision &+= 1
    }

    /// Taking a song out of the list.
    func removeQueuedSong(at position: Int) {
        // The queue answers with a song only when the removal disturbed the one
        // being sung; otherwise the evening carries on where it was.
        if let nowPlay = songQueue.remove(at: position) {
            openSong(at: nowPlay, keepingQueue: true)
            runWords(from: 0)
        } else if songQueue.current == nil {
            closeWords()
        }
        settingsRevision &+= 1
    }

    func clearSongQueue() {
        songQueue.clear()
        closeWords()
        settingsRevision &+= 1
    }

    /// ⏭ when there is a queue: the next song rather than ten seconds on.
    func skipToNextSong() {
        guard let next = songQueue.advance() else { return }
        openSong(at: next, keepingQueue: true)
        runWords(from: 0)
    }

    /// True while the song on the stage is a file this application is playing.
    var isPlayingOwnSong: Bool { madeSongPlayer?.song != nil }

    /// Where the media keys, Control Centre and the button on a pair of AirPods
    /// go. Built on the first song rather than at launch: claiming the now
    /// playing application is system-wide, and an application that has never
    /// played anything has no business holding it.
    private var madeNowPlayingStage: NowPlayingStage?

    /// Tells the system what is on this stage, or gives the keys back.
    ///
    /// Called from the poll, so the gate matters: `needsPublishing` compares
    /// everything but the playhead exactly and the playhead against a tolerance,
    /// because the system moves the playhead itself from the rate. A song
    /// playing steadily therefore publishes about once a second rather than
    /// twenty times.
    private func tellTheSystemWhatIsPlaying() {
        guard isPlayingOwnSong, let player = madeNowPlayingSong else {
            // Only when something was claimed. Resigning on every poll would
            // tell the system to forget a song it was never told about.
            madeNowPlayingStage?.resign()
            return
        }
        let stage = nowPlayingStage
        stage.publish(
            NowPlayingBroadcast.forOurOwnSong(
                title: player.title, artist: player.artist, album: player.album,
                duration: player.duration, elapsed: songPosition,
                isPlaying: madeSongPlayer?.isPlaying ?? false,
                hasQueuedSong: hasAnotherSongQueued, repeatsOne: songQueue.repeatsOne,
                hasPreviousSong: songQueue.hasSongBefore,
                hasArtwork: player.artwork?.isEmpty == false),
            artwork: player.artwork,
            identity: player.url.path)
    }

    private var madeNowPlayingSong: LocalSongPlayer.Song? { madeSongPlayer?.song }

    private var nowPlayingStage: NowPlayingStage {
        if let stage = madeNowPlayingStage { return stage }
        let stage = NowPlayingStage()
        stage.takeCommands(
            NowPlayingStage.Commands(
                play: { [weak self] in self?.runWords(from: self?.songPosition ?? 0) },
                pause: { [weak self] in self?.stopWords() },
                next: { [weak self] in self?.skipToNextSong() },
                previous: { [weak self] in self?.goBackASong() },
                seek: { [weak self] seconds in self?.seekNowPlaying(toSeconds: seconds) }))
        madeNowPlayingStage = stage
        return stage
    }

    /// ⏮: the song before, or the top of this one.
    ///
    /// Restarting rather than doing nothing at the front of the list, because
    /// that is what every transport control ever built does and somebody who
    /// wanted the beginning of the first song would otherwise have to drag the
    /// bar.
    func goBackASong() {
        guard let previous = songQueue.goBack() else {
            runWords(from: 0)
            return
        }
        if previous == madeSongPlayer?.song?.url {
            runWords(from: 0)
        } else {
            openSong(at: previous, keepingQueue: true)
            runWords(from: 0)
        }
    }

    /// Opens an audio file and makes it the song.
    ///
    /// Words are looked for beside the file first — `慢冷.mp3` next to
    /// `慢冷.lrc` is how anybody with a folder of backing tracks already has
    /// them — and only then online, keyed on whatever the file's own tags say.
    @discardableResult
    func openSong(at url: URL, keepingQueue: Bool = false) -> Bool {
        // Opening a single song is starting again; opening the next one out of
        // the queue is the queue doing its job. Without the distinction,
        // advancing would throw away the list it was advancing through.
        if !keepingQueue {
            songQueue.clear()
            songQueue.append([url])
        }
        guard let song = songPlayer.open(url) else { return false }
        cancelLyricsLookup()
        isHandRun = true
        lyrics = nil
        plainLyrics = nil
        melody = nil
        lyricsSourceName = nil
        lyricsCopyright = nil
        lyricsRegion = nil
        let track = NowPlaying.Track(
            application: loc("This song"),
            title: song.title,
            artist: song.artist,
            album: song.album,
            position: 0,
            duration: song.duration,
            isPlaying: false,
            artworkURL: Self.artwork(for: song),
            identity: "file:\(url.path)")
        nowPlaying = track
        trackClock.stop()
        trackClock.duration = song.duration
        lyricLine = nil
        lyricProgress = 0
        lyricPlaybackAnchor = nil
        songSecond = 0
        let words = ["lrc", "LRC"]
            .lazy
            .map { url.deletingPathExtension().appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        // The key this person sings this song in, from the last time. Applied
        // before a note is played, so nobody hears the original key and then
        // the transpose arriving a beat later.
        songPlayer.pitchCents = SongKeys.cents(
            forSemitones: SongKeys.semitones(for: track.identity))
        if let words {
            adoptWordsBeside(words, keepingDuration: song.duration)
        } else {
            startLyricsLookup(for: track)
        }
        if isScoringSinging { rebuildScoringReference() }
        return true
    }

    /// Words found next to the audio file, which beat every online index.
    ///
    /// The song's own length is kept: a `.lrc` says when its last line starts,
    /// not when the recording ends, and the file we are playing knows the
    /// second of those exactly.
    private func adoptWordsBeside(_ url: URL, keepingDuration duration: Double) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let parsed = Lyrics.parse(text)
        else { return }
        lyrics = parsed
        lyricsSourceName = loc("Local file")
        lyricsLookupStatus = .local
        melody =
            ["mid", "midi"]
            .lazy
            .map { url.deletingPathExtension().appendingPathExtension($0) }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap(MidiMelody.parse)
            .first
        trackClock.duration = duration
        applyLyricOffset()
    }

    /// Embedded artwork, written where a view can point an image at it.
    ///
    /// A tag block is bytes inside the audio file and `NowPlaying.Track` speaks
    /// in URLs, so the bytes go to a file named after their own content: the
    /// same song opened twice writes nothing the second time, and two songs
    /// never collide.
    private static func artwork(for song: LocalSongPlayer.Song) -> URL? {
        if let beside = artworkBesideWords(at: song.url) { return beside }
        guard let data = song.artwork, !data.isEmpty else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YunAudio-artwork", isDirectory: true)
        let file = directory.appendingPathComponent("\(data.count)-\(data.hashValue).img")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: file)) != nil else { return nil }
        return file
    }

    /// How far the song has been transposed, in semitones.
    ///
    /// The button every KTV machine has and this application could not offer:
    /// nothing in a scripting dictionary transposes anything, so it exists for
    /// a song we are playing and for no other source. Remembered per song —
    /// somebody who takes a song down two takes it down two every time.
    var songKeySemitones: Int {
        _ = settingsRevision
        guard isPlayingOwnSong, let identity = nowPlaying?.identity else { return 0 }
        return SongKeys.semitones(for: identity)
    }

    /// Whether the two key buttons mean anything for what is on the stage.
    var canTransposeSong: Bool { isPlayingOwnSong || ownsSongForRendering }

    /// Renderer only, so the key control appears in a picture.
    ///
    /// The control exists only while a file is open in our own player, and no
    /// offscreen render opens one — decoding an audio file to draw a stage is a
    /// dependency a picture should not have. Set by the render fixture; the
    /// running application never assigns it, and `songKeySemitones` still comes
    /// from the store, so what is drawn is what a real song would show.
    private(set) var ownsSongForRendering = false

    /// Moves the key, and hands it to the unit that does the work.
    func shiftSongKey(by delta: Int) {
        guard isPlayingOwnSong, let identity = nowPlaying?.identity else { return }
        let updated = SongKeys.shift(identity, by: delta)
        songPlayer.pitchCents = SongKeys.cents(forSemitones: updated)
        settingsRevision &+= 1
    }

    /// Whether the lead vocal is being taken out of the song we are playing.
    var isCancellingLeadVocal: Bool {
        _ = settingsRevision
        return madeSongPlayer?.isCancellingCentre == true
    }

    /// Whether the button would do anything: our own song, and in stereo.
    var canCancelLeadVocal: Bool {
        isPlayingOwnSong && madeSongPlayer?.canCancelCentre == true
    }

    func toggleLeadVocal() {
        guard canCancelLeadVocal else { return }
        songPlayer.setCancellingCentre(!songPlayer.isCancellingCentre)
        settingsRevision &+= 1
    }

    func resetSongKey() {
        guard isPlayingOwnSong, let identity = nowPlaying?.identity else { return }
        SongKeys.clear(identity)
        songPlayer.pitchCents = 0
        settingsRevision &+= 1
    }

    /// Takes the exact position from the player we are running.
    ///
    /// Called from the same poll that would otherwise have asked another
    /// process, and costing nothing: no Apple event, no round trip, and
    /// `lastCorrection` reads as the render quantum rather than as the tens of
    /// milliseconds an extrapolated answer drifts by.
    private func adoptOwnSongPosition() {
        guard isPlayingOwnSong, let songPlayer = madeSongPlayer else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        // A song that has run out stops rather than sitting at the end
        // pretending to play, which is what leaves the scoreboard waiting.
        if songPlayer.isPlaying, songPlayer.hasFinished {
            songPlayer.pause()
            nowPlaying?.isPlaying = false
            // And then the next one, which is the entire point of a queue:
            // nobody should have to walk back to the machine between songs.
            // The scoreboard has already been kept by `keepPerformance`, which
            // runs off the same stop.
            if let next = songQueue.advance() {
                openSong(at: next, keepingQueue: true)
                runWords(from: 0)
            }
        }
        trackClock.adopt(
            songPlayer.position, isPlaying: songPlayer.isPlaying, trueAt: now)
        if ProcessInfo.processInfo.environment["YUNAUDIO_NO_NOW_PLAYING"] == nil {
            tellTheSystemWhatIsPlaying()
        }
    }

    /// Starts the hand-run words from a moment on the song's clock.
    ///
    /// The same instant re-anchors every singer, because the score and the
    /// words have to be measured against the same zero or the per-line
    /// breakdown belongs to different lines than the ones it names.
    func runWords(from seconds: Double = 0) {
        guard isHandRun else { return }
        if isPlayingOwnSong { songPlayer.play(from: seconds) }
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
        if isPlayingOwnSong { songPlayer.pause() }
        let held = songPosition
        trackClock.adopt(
            held, isPlaying: false,
            trueAt: Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
        if var track = nowPlaying, track.isPlaying {
            track.isPlaying = false
            nowPlaying = track
        }
        followTheWords()
    }

    /// Hands the panel back to whatever a player says.
    func closeWords() {
        guard isHandRun else { return }
        cancelLyricsLookup()
        // Before the state is cleared: the engine holds a file open and an
        // output device running, and handing the panel back to somebody else's
        // player while still playing our own would put two songs in the room.
        madeSongPlayer?.stop()
        // Before anything else clears: the keys go back the moment the song
        // stops being ours, or pressing pause would pause a player we are only
        // watching.
        madeNowPlayingStage?.resign()
        isHandRun = false
        trackClock.stop()
        nowPlaying = nil
        nowPlayingFailure = nil
        lyrics = nil
        plainLyrics = nil
        lyricsSourceName = nil
        lyricsCopyright = nil
        lyricsRegion = nil
        melody = nil
        lyricLine = nil
        lyricProgress = 0
        lyricPlaybackAnchor = nil
        songSecond = 0
        lyricsLookupStatus = .idle
        pollsSinceNowPlaying = Self.nowPlayingEveryNPolls
        pollsSinceLyricFrame = Self.lyricFrameEveryNPolls
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
    /// The legacy A/B renderer interpolates each target for 100 ms. Production
    /// does not observe this value; its sparse anchor drives Core Animation.
    nonisolated static let lyricFrameEveryNPolls = 2

    @ObservationIgnored private var trackClock = TrackClock()
    /// Starts at the interval so that opening the panel asks at once rather
    /// than showing an empty header for a second.
    @ObservationIgnored private var pollsSinceNowPlaying = RouterModel.nowPlayingEveryNPolls
    /// Starts due so the first visible lyric frame is immediate.
    @ObservationIgnored private var pollsSinceLyricFrame = RouterModel.lyricFrameEveryNPolls
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
        let generation = nowPlayingSessionGeneration
        NowPlaying.positionAsynchronously(
            preferring: lastPlayer, knownIdentity: nowPlaying?.identity
        ) { [weak self] position, track, failure, middle in
            guard let self else { return }
            self.isAskingThePlayer = false
            guard self.isSingingVisible,
                generation == self.nowPlayingSessionGeneration
            else { return }
            self.receivePosition(
                position, track: track, failure: failure, trueAt: middle)
        }
    }

    /// True while an ask is in flight.
    @ObservationIgnored private var isAskingThePlayer = false
    /// Invalidates an Apple-event answer when KTV closes before it arrives.
    @ObservationIgnored private var nowPlayingSessionGeneration = 0

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
            case .denied, .javaScriptNotAllowed:
                // Both need somebody to change a setting, and asking again
                // before they have is a minute of events nobody wanted.
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
            if lyricsCopyright != nil { lyricsCopyright = nil }
            if lyricsRegion != nil { lyricsRegion = nil }
            if melody != nil { melody = nil }
            return
        }
        lastPlayer = position.application
        if let track, Self.shouldAdoptPlayerTrack(current: nowPlaying, incoming: track) {
            adopt(track)
        }
        if var current = nowPlaying, current.isPlaying != position.isPlaying {
            current.isPlaying = position.isPlaying
            nowPlaying = current
        }
        trackClock.duration = nowPlaying?.duration ?? 0
        trackClock.adopt(position.seconds, isPlaying: position.isPlaying, trueAt: middle)
        reanchorIfSeeked(to: position.seconds)
        // A fresh player answer can be a seek or a newly adopted song. Neither
        // waits for the periodic progress frame: the authoritative position is
        // already here, so the words move in the same turn.
        followTheWords()
    }

    struct PlayerTrackFingerprint: Equatable {
        let application: String
        let title: String
        let artist: String
        let durationSeconds: Int
    }

    /// Whether fresh metadata represents a song the model has not adopted.
    ///
    /// A player with no track id still needs its metadata read every second:
    /// otherwise a stream can change underneath one empty identifier and remain
    /// frozen forever. The unchanged metadata is not a new song, though. Treating
    /// every read as one cancelled and restarted the four or five lyric-provider
    /// requests every second and repeatedly rescanned the local library.
    nonisolated static func shouldAdoptPlayerTrack(
        current: NowPlaying.Track?,
        incoming: NowPlaying.Track
    ) -> Bool {
        guard let current else { return true }
        if !incoming.identity.isEmpty {
            return incoming.identity != current.identity
        }
        return playerTrackFingerprint(current) != playerTrackFingerprint(incoming)
    }

    nonisolated static func playerTrackFingerprint(
        _ track: NowPlaying.Track
    ) -> PlayerTrackFingerprint {
        PlayerTrackFingerprint(
            application: track.application,
            title: track.title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: track.artist.trimmingCharacters(in: .whitespacesAndNewlines),
            durationSeconds: Int(exactly: track.duration.rounded()) ?? 0)
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
            nowPlayingFailure = nil
            musicRecognitionProblem = loc(
                "This build is not signed for the Shazam catalogue. Enable ShazamKit for the App ID to identify players without scripting support."
            )
        case let .failure(.failed(reason)):
            nowPlayingFailure = nil
            musicRecognitionProblem = String(
                format: loc("Music recognition is unavailable: %@"), reason)
        case let .success(match):
            musicRecognitionProblem = nil
            nowPlayingFailure = nil
            let track = NowPlaying.Track(
                application: application.name, title: match.title,
                artist: match.artist, album: match.album,
                position: match.position, duration: match.duration,
                isPlaying: true, artworkURL: match.artworkURL,
                appleMusicURL: match.appleMusicURL, identity: match.identity)
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
        case let .javaScriptNotAllowed(application):
            return String(
                format: loc(
                    "%@ will not run JavaScript for YunAudio. Turn on “Allow "
                        + "JavaScript from Apple Events” in its Develop menu."),
                application)
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

    // MARK: Transport

    /// Asks the player the stage is showing to do something.
    ///
    /// Off the main actor: an Apple event to Music or Spotify was measured at
    /// 20.7 ms for the cheap read and 61.4 for the expensive one, all of it
    /// spent inside the player's own main thread. A button that costs a frame
    /// and a half is a button that feels broken.
    ///
    /// The local state moves first. The poll will confirm it within a tick, but
    /// waiting for that means the glyph changes a twentieth of a second after
    /// the click, which reads as the click not having landed.
    func sendTransport(_ transport: NowPlaying.Transport) {
        guard let track = nowPlaying else { return }
        // Our own song is not asked; it is told. No Apple event, no round trip,
        // and the button takes effect in the same turn it was pressed.
        if isPlayingOwnSong {
            switch transport {
            case .playPause:
                if songPlayer.isPlaying {
                    stopWords()
                } else {
                    runWords(from: songPosition)
                }
            case .next:
                // The next song where there is one, ten seconds on where there
                // is not. A skip button that moves inside the song while a
                // queue is waiting is a skip button pointing at the wrong
                // thing.
                if hasAnotherSongQueued {
                    skipToNextSong()
                } else {
                    skipNowPlaying(by: 10)
                }
            case .previous:
                // The previous song, or the top of this one, or ten seconds
                // back — in that order, which is what every transport ever
                // built does and what this one did not.
                //
                // It went back ten seconds and nothing else, so ⏮ could never
                // reach the song before even though the queue has always been
                // able to: `KTVQueue.goBack` exists and is tested, the media key
                // was wired to it, and `NowPlayingBroadcast` advertises the
                // capability to the system. The key did the right thing and the
                // button on screen did not, which is worse than neither doing
                // it. `.next` was written correctly at the time and this was
                // not.
                switch TransportBack.of(
                    position: songPosition, hasPreviousSong: songQueue.hasSongBefore)
                {
                case .previousSong: goBackASong()
                case .restart: runWords(from: 0)
                case .rewind: skipNowPlaying(by: -10)
                }
            }
            return
        }
        if transport == .playPause {
            nowPlaying?.isPlaying.toggle()
            trackClock.adopt(
                Double(songSecond), isPlaying: nowPlaying?.isPlaying ?? false,
                trueAt: Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
        }
        let application = track.application
        Task.detached(priority: .userInitiated) {
            NowPlaying.send(transport, to: application)
        }
    }

    /// Moves the playhead to a fraction of the track.
    ///
    /// The lyric clock is moved here rather than left to the poll for the same
    /// reason: dragging the bar and watching the words arrive a beat later is
    /// the difference between a control and a request.
    func seekNowPlaying(toFraction fraction: Double) {
        guard let track = nowPlaying, track.duration > 0 else { return }
        seekNowPlaying(toSeconds: track.duration * fraction)
    }

    /// Moves the music to a moment, whether or not the song's length is known.
    ///
    /// Length is not a precondition for seeking, and treating it as one made
    /// clicking a lyric line do nothing at all on a song whose duration had
    /// not arrived yet — Spotify answers 0 until the track settles, and this
    /// model fills the gap from the lyric match, which lands later still. The
    /// words are on screen and clickable before either. Without a length there
    /// is nothing to clamp against and the floor at zero is the whole check.
    func seekNowPlaying(toSeconds target: Double) {
        guard let track = nowPlaying, target.isFinite else { return }
        let seconds =
            track.duration > 0
            ? max(0, min(track.duration, target))
            : max(0, target)
        nowPlaying?.position = seconds
        trackClock.adopt(
            seconds, isPlaying: track.isPlaying,
            trueAt: Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
        followTheWords()
        if isPlayingOwnSong {
            // Exact, and immediate. A seek sent to another player is a request
            // whose result arrives at the next poll; this one is the file being
            // scheduled from a frame.
            songPlayer.seek(to: seconds)
            return
        }
        let application = track.application
        Task.detached(priority: .userInitiated) {
            NowPlaying.seek(to: seconds, in: application)
        }
    }

    /// Jumps the music to a line somebody pointed at.
    ///
    /// The one interaction a synchronised lyric sheet owes back: the words are
    /// already an index of the song, and until now they were a read-only one —
    /// finding the second chorus meant dragging a bar and guessing.
    ///
    /// The shift applied to the words is undone rather than ignored. A song
    /// held back by two seconds is showing line *n* at the moment the music
    /// reaches it, so seeking to the line's raw timestamp would land two
    /// seconds off — the correction would fight the seek exactly as far as
    /// somebody had corrected it.
    func seekToLyricLine(_ index: Int) {
        guard let lyrics, lyrics.lines.indices.contains(index) else { return }
        seekNowPlaying(
            // `lyrics.offset` is the whole correction: the file's own
            // `[offset:]` plus whatever this song was moved by. There used to be
            // a second one beside it — a transient ±2 s the panel drove and the
            // stage did not — so the same thing had two controls, they added up,
            // and only one of them was remembered. See `KTVWordsControls`.
            toSeconds: max(0, lyrics.lines[index].time - lyrics.offset))
    }

    /// Moves the music by a few seconds, keeping it inside the song.
    func skipNowPlaying(by seconds: Double) {
        guard nowPlaying != nil else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        seekNowPlaying(toSeconds: trackClock.position(at: now) + seconds)
    }

    /// Where the lyric column is looking, when that is not where the song is.
    ///
    /// On the model rather than on the stage, and the reason is verifiability
    /// rather than sharing. As view state it was correct — the stage's identity
    /// is stable, so scrolling survived an arrangement change — but "correct"
    /// there was something I could reason about and no gate could observe.
    /// Every other piece of state this feature added has a flow check behind
    /// it; this one could not have had one while it lived in a `@State`.
    private(set) var lyricBrowse = KTVLyricBrowse()

    /// Takes the wheel, and says whether it moved the column.
    @discardableResult
    func browseLyrics(byWheel deltaY: CGFloat, precise: Bool = true) -> Bool {
        guard let lyrics, lyrics.lines.count > 1 else { return false }
        lyricBrowse.scroll(
            by: deltaY, playing: lyricLine, lineCount: lyrics.lines.count,
            precise: precise)
        return lyricBrowse.isBrowsing
    }

    /// Moves the column a whole line, which is what a key press means.
    @discardableResult
    func browseLyrics(byLines lines: Int) -> Bool {
        guard let lyrics, lyrics.lines.count > 1 else { return false }
        lyricBrowse.step(by: lines, playing: lyricLine, lineCount: lyrics.lines.count)
        return lyricBrowse.isBrowsing
    }

    func followTheSongAgain() {
        guard lyricBrowse.isBrowsing else { return }
        lyricBrowse.stop()
    }

    /// Bumped whenever the words are replaced under the same song.
    ///
    /// Switching lyric source keeps the track and changes the line numbering,
    /// which nothing else in the model distinguishes — `nowPlaying.identity` is
    /// the same before and after.
    private(set) var lyricsRevision = 0

    /// Every index's answer for the song playing now.
    ///
    /// Held here rather than read back from `OnlineLyrics.lastAnswers` at the
    /// moment the button is pressed: that global belongs to whichever lookup
    /// ran last, which after a song with no online words at all is the song
    /// before — and cycling would then have drawn the previous song's words.
    private var lyricAnswers: [OnlineLyrics.Match] = []

    /// Indexes that answered for this song, so another can be chosen.
    private(set) var lyricAlternatives: [OnlineLyrics.Source] = []

    /// Which index the words on screen came from.
    private(set) var lyricSource: OnlineLyrics.Source?

    /// Takes the next index that answered for this song and remembers it.
    ///
    /// Cycling rather than presenting a list: at the moment somebody notices
    /// the words are wrong they do not know which index is right either, and
    /// pressing until it looks correct is the shape of that question.
    func useNextLyricSource() {
        guard let identity = nowPlaying.map(Self.lyricsIdentity(for:)),
            let next = LyricSourceChoice.next(
                after: lyricSource, among: lyricAlternatives),
            next != lyricSource
        else { return }
        LyricSourceChoice.remember(next, for: identity)
        guard let match = lyricAnswers.first(where: { $0.source == next }),
            let parsed = match.parsed
        else { return }
        lyricSource = next
        // A shift measured against one take is not evidence about another. The
        // whole reason this control exists is that indexes disagree, and the
        // commonest disagreement is exactly the one the offset compensates
        // for: whether the file leaves room for the intro. Carrying it over
        // means somebody who corrected 慢冷 by two seconds gets those two
        // seconds applied to a take that already had them, and the words are
        // wrong again in the direction they just fixed.
        LyricOffsets.clear(identity)
        // The new take has its own line numbering, so anything holding a line
        // index from the old one is now pointing at a different lyric or at
        // nothing. Published so the stage can put its column back on the song.
        lyricsRevision &+= 1
        // Another take of the same song has its own line numbering, so a
        // browsed line points at a different lyric or at nothing.
        lyricBrowse.stop()
        lyricsSourceName = Self.lyricsSourceName(for: next)
        lyricsCopyright = match.providerMetadata?.copyright
        lyricsRegion = match.providerMetadata?.region
        fileLyricOffset = parsed.offset
        lyrics = parsed
        applyLyricOffset()
    }

    /// How much larger or smaller the stage's words are than the window implies.
    ///
    /// A KTV stage is read from across a room as often as from a desk, and the
    /// two want different type. The window's own size can only serve one of
    /// them, so this is the person's say over it — remembered, because
    /// somebody who sings at a distance sings at a distance every time.
    var lyricScale: Double {
        get {
            _ = settingsRevision
            let stored = UserDefaults.standard.double(forKey: Self.lyricScaleKey)
            return stored == 0 ? 1 : Self.boundedLyricScale(stored)
        }
        set {
            UserDefaults.standard.set(
                Self.boundedLyricScale(newValue), forKey: Self.lyricScaleKey)
            settingsRevision &+= 1
        }
    }

    private static let lyricScaleKey = "YunAudioLyricScale"

    /// Small enough to fit a verse on a short stage, large enough to be read
    /// from the back of a room, and never zero or a NaN however it got in.
    nonisolated static func boundedLyricScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(1.8, max(0.7, (value * 20).rounded() / 20))
    }

    /// Steps the size, and says nothing when it is already at the end.
    func nudgeLyricScale(by step: Double) {
        lyricScale = Self.boundedLyricScale(lyricScale + step)
    }

    func resetLyricScale() { lyricScale = 1 }

    /// What one line of the song now loaded costs the column, in point-size
    /// multiples, counted from the words themselves.
    ///
    /// Cached on the song and the pronunciation setting: the count walks every
    /// line and, when pronunciation is on, romanises each of them — cheap once,
    /// and not something to do inside a view body that runs whenever the line
    /// being sung changes.
    var lyricRowBudget: (rowsPerLine: CGFloat, extraRows: CGFloat) {
        let romanised = showsRomanisation
        // Translations arrive *after* the words, from a second field of the
        // same reply, and change nothing else about the lyrics — same line
        // count, same first line. A stamp made of those two would not notice,
        // and the column would go on being budgeted for a song without
        // translation rows while drawing one with them, which is an overflow
        // by exactly the height of those rows.
        let translated = lyrics?.lines.contains { $0.translation != nil } ?? false
        let stamp =
            "\(lyrics?.lines.count ?? 0)|\(lyrics?.lines.first?.text ?? "")"
            + "|\(lyrics?.lines.last?.text ?? "")|\(romanised)|\(translated)"
        if let cached = rowBudgetCache, cached.stamp == stamp {
            return (cached.rowsPerLine, cached.extraRows)
        }
        guard let lyrics, !lyrics.lines.isEmpty else {
            return (KTVLyricMetrics.rowsPerLine, 0)
        }
        let budget = KTVLyricMetrics.budget(
            for: lyrics.lines.map { line in
                (
                    words: line.isInterlude ? KTVStage.interludeMark : line.text,
                    romanisation: romanised && !line.isInterlude
                        ? LyricRomanisation.of(line.text) : nil,
                    translation: line.translation
                )
            })
        rowBudgetCache = (stamp, budget.rowsPerLine, budget.extraRows)
        return budget
    }

    private var rowBudgetCache: (stamp: String, rowsPerLine: CGFloat, extraRows: CGFloat)?

    /// Whether the floating desktop lyric is showing.
    var showsDesktopLyrics: Bool {
        get {
            _ = settingsRevision
            return UserDefaults.standard.bool(forKey: "YunAudioShowsDesktopLyrics")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "YunAudioShowsDesktopLyrics")
            settingsRevision &+= 1
        }
    }

    /// Whether the stage prints how the words are pronounced.
    ///
    /// Off by default and remembered: most people reading their own language
    /// want the characters and nothing else, and a second row under every line
    /// costs the stage real height. The people who need it need it every time.
    var showsRomanisation: Bool {
        get {
            _ = settingsRevision
            return UserDefaults.standard.bool(forKey: "YunAudioShowsRomanisation")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "YunAudioShowsRomanisation")
            settingsRevision &+= 1
        }
    }

    /// Whether the learned head helps choose the singer's pitch.
    ///
    /// On by default, and it is a real choice rather than a hedge. Measured end
    /// to end, with the accompaniment at the singer's own level it is worth
    /// nothing; at one and a half, two and three times it is worth three, six
    /// and thirteen points; at four times nothing helps. It costs 0.24 ms a
    /// frame at a four-hertz scoring cadence, which is free — but somebody
    /// scoring a quiet studio take is entitled to switch off a thing that
    /// cannot help them.
    var usesLearnedPitch: Bool {
        get {
            _ = settingsRevision
            guard !SingerPitch.isForcedOff else { return false }
            return UserDefaults.standard.object(forKey: "YunAudioLearnedPitch") as? Bool
                ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "YunAudioLearnedPitch")
            SingerPitch.usesLearnedHead = newValue && !SingerPitch.isForcedOff
            settingsRevision &+= 1
        }
    }

    /// Whether the words are converted between the two Chinese scripts.
    ///
    /// Remembered, like the pronunciation row: a catalogue answers in whichever
    /// script it holds, and somebody who reads traditional should not have to
    /// notice which index a song came from. See `LyricScript`.
    var lyricScript: LyricScript {
        get {
            _ = settingsRevision
            return UserDefaults.standard.string(forKey: LyricScript.defaultsKey)
                .flatMap(LyricScript.init(rawValue:)) ?? .asWritten
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: LyricScript.defaultsKey)
            settingsRevision &+= 1
        }
    }

    /// Whether the song loaded has anything the script switch could convert.
    ///
    /// Cached on the song, because it walks every line: the answer cannot change
    /// without the words changing, and asking it inside a view body would ask it
    /// whenever the line being sung moved.
    var lyricsHaveChinese: Bool {
        let stamp = "\(lyricsRevision)|\(lyrics?.lines.count ?? 0)"
        if let cached = chineseLyricsCache, cached.stamp == stamp { return cached.answer }
        let answer =
            lyrics?.lines.contains { LyricScript.containsHan($0.text) } ?? false
        chineseLyricsCache = (stamp, answer)
        return answer
    }

    @ObservationIgnored private var chineseLyricsCache: (stamp: String, answer: Bool)?

    /// One line of the song, in the script somebody asked for.
    ///
    /// The single place the conversion happens, so the two presentations cannot
    /// disagree about it — and so a line that is not Chinese costs a scalar scan
    /// rather than a transform.
    func words(_ text: String) -> String { lyricScript.convert(text) }

    /// Bumped by every setting that lives in `UserDefaults`, and read by every
    /// getter that returns one.
    ///
    /// Observation instruments stored properties. A computed property backed by
    /// defaults is invisible to it, so changing one notified nothing and the
    /// view that drew it kept drawing the old value until something else
    /// happened to invalidate it — which, on the stage, is the next lyric line.
    /// Reading this stored value in the getter is what puts the dependency
    /// back.
    private var settingsRevision = 0

    /// Seconds this song's words have been nudged. Negative holds them back.
    var lyricOffsetSeconds: Double {
        guard let identity = nowPlaying.map(Self.lyricsIdentity(for:)) else { return 0 }
        return LyricOffsets.offset(for: identity)
    }

    /// Moves the words against the music and remembers it for this song.
    ///
    /// A published `.lrc` is timed against whatever master its author had.
    /// 「慢冷」 arrives with no lead-in, so the stage lights its first line
    /// before anyone sings and no better file exists to find.
    func nudgeLyricOffset(by delta: Double) {
        guard let identity = nowPlaying.map(Self.lyricsIdentity(for:)) else { return }
        LyricOffsets.nudge(identity, by: delta)
        applyLyricOffset()
    }

    func clearLyricOffset() {
        guard let identity = nowPlaying.map(Self.lyricsIdentity(for:)) else { return }
        LyricOffsets.clear(identity)
        applyLyricOffset()
    }

    /// Puts the remembered nudge into the parsed lyric.
    ///
    /// Through `Lyrics.offset`, which already exists for the `[offset:]` tag
    /// and is applied by `index(at:)` and `progress(at:)` alike — so one place
    /// decides what time it is for the words, and the highlight and the sweep
    /// cannot disagree.
    func applyLyricOffset() {
        guard var updated = lyrics else { return }
        updated.offset = fileLyricOffset + lyricOffsetSeconds
        lyrics = updated
        followTheWords()
    }

    /// Word times for the line being sung, when the file carried them.
    ///
    /// Read by the compositor to fill along the shape the words describe
    /// rather than evenly across the line. Empty is the ordinary case and the
    /// linear sweep remains the honest approximation for it.
    var currentLyricSyllables: [Lyrics.Line.Syllable] {
        guard let lyrics, let index = lyricLine,
            lyrics.lines.indices.contains(index)
        else { return [] }
        return lyrics.lines[index].syllables
    }

    /// Takes a new song, with the words and the tune that go with it.
    private func adopt(_ track: NowPlaying.Track?) {
        // Before anything is replaced: this is the last moment the song that
        // has just finished still has its scores.
        if nowPlaying?.identity != track?.identity { keepPerformance(of: nowPlaying) }
        cancelLyricsLookup()
        // A new song is not the song somebody was reading ahead in.
        lyricBrowse.stop()
        // A new song has no alternatives until its own lookup answers.
        lyricAnswers = []
        lyricAlternatives = []
        lyricSource = nil
        let track = track.map { incoming in
            var resolved = incoming
            if resolved.artworkURL == nil {
                resolved.artworkURL = Self.findArtwork(for: incoming)
            }
            return resolved
        }
        nowPlaying = track
        let localLyrics = track.flatMap(Self.findLyricsMatch)
        lyrics = localLyrics?.lyrics
        let localPlain = track.flatMap(Self.findPlainLyricsMatch)
        plainLyrics =
            lyrics == nil
            ? localPlain?.text ?? track?.nativeLyrics
            : nil
        lyricsSourceName =
            localLyrics.map { Self.lyricsSourceName(forLocalURL: $0.url) }
            ?? localPlain.map { Self.lyricsSourceName(forLocalURL: $0.url) }
            ?? (track?.nativeLyrics == nil ? nil : loc("Music"))
        let cachedAttribution = (localLyrics?.url ?? localPlain?.url)
            .flatMap(Self.cachedLyricsAttribution)
        lyricsCopyright = cachedAttribution?.copyright
        lyricsRegion = cachedAttribution?.region
        // The file's own declared shift, kept apart so that clearing a nudge
        // restores it rather than zero — then the remembered nudge on top.
        fileLyricOffset = lyrics?.offset ?? 0
        applyLyricOffset()
        melody = track.flatMap(Self.findMelody)
        if let track {
            if let localURL = localLyrics?.url ?? localPlain?.url {
                lyricsLookupStatus = Self.lyricsStatus(forLocalURL: localURL)
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
        // A switch for bisecting the `0x1e` crash, nothing else. See TODO.md.
        guard ProcessInfo.processInfo.environment["YUNAUDIO_NO_LYRIC_LOOKUP"] == nil
        else { return }
        let identity = Self.lyricsIdentity(for: track)
        let client = OnlineLyrics(
            musixmatch: OnlineLyrics.musixmatchAdapter(
                apiKey: musixmatchSessionKey))
        if plainLyrics == nil { lyricsLookupStatus = .loading }
        lyricsLookupTask = Task { [weak self] in
            do {
                // The cast, before the words are asked for. A duet file marks
                // who sings by putting a performer's name on a line of its own,
                // and a name is only taken for a marker when the track names
                // that performer — so with Spotify's one-name Apple Event
                // answer, 「黃霄雲」 was drawn on the stage as a line to sing.
                var query = OnlineLyrics.Query(
                    title: track.title, artist: track.artist, album: track.album,
                    duration: track.duration, performers: [track.artist])
                if let cast = await SpotifyCatalogue.performers(
                    forIdentity: track.identity), cast.count > 1
                {
                    query.performers = cast
                    if let self, self.nowPlaying?.identity == track.identity {
                        self.nowPlaying?.performers = cast
                        self.nowPlaying?.artist = cast.joined(separator: " / ")
                    }
                }
                try Task.checkCancellation()
                // OnlineLyrics is nonisolated, so its network and decoding work
                // runs on the generic executor. Keeping it as this task's child
                // also means changing songs cancels every configured provider;
                // Task.detached left them running after their answer was stale.
                let match = try await client.fetch(query)
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
                self.lyricAnswers = OnlineLyrics.lastAnswers
                self.lyricAlternatives = OnlineLyrics.lastAnswers.map(\.source)
                self.lyricSource = match.source
                // A choice this person already made for this song wins over the
                // ranking. Without it the ranking picks the same wrong cover
                // every time the song comes round, and the correction has to be
                // made again on every play.
                let chosen: OnlineLyrics.Match = {
                    guard let remembered = LyricSourceChoice.preferred(for: identity),
                        remembered != match.source,
                        let alternative = OnlineLyrics.lastAnswers.first(
                            where: { $0.source == remembered }),
                        // A remembered index that has nothing to show for this
                        // song is not a reason to leave the stage blank.
                        alternative.parsed != nil || alternative.plain != nil
                    else { return match }
                    self.lyricSource = remembered
                    return alternative
                }()
                if let parsed = chosen.parsed {
                    self.lyrics = parsed
                    self.plainLyrics = nil
                } else if let plain = chosen.plain {
                    self.plainLyrics = plain
                } else {
                    self.lyricsLookupStatus =
                        self.plainLyrics == nil ? .notFound : self.lyricsLookupStatus
                    return
                }
                // `chosen`, not `match`: when a remembered choice overrode the
                // ranking the attribution has to name the words on the stage.
                self.lyricsSourceName = Self.lyricsSourceName(for: chosen.source)
                self.lyricsCopyright = chosen.providerMetadata?.copyright
                self.lyricsRegion = chosen.providerMetadata?.region
                self.lyricsLookupStatus = .online
                if var current = self.nowPlaying,
                    current.duration <= 0,
                    let duration = match.duration,
                    duration.isFinite,
                    duration > 0
                {
                    current.duration = duration
                    self.nowPlaying = current
                    self.trackClock.duration = duration
                }
                self.followTheWords()
                if self.isScoringSinging { self.rebuildScoringReference() }

                guard let directory = Self.lyricsDirectory else { return }
                guard let text = match.cacheText else { return }
                let url = OnlineLyrics.cacheURL(
                    for: query, source: match.source,
                    extension: match.cacheExtension, in: directory)
                let attributionURL = OnlineLyrics.cacheAttributionURL(for: url)
                let attributionData = try? OnlineLyrics.encodeCacheAttribution(
                    match.cacheAttribution)
                await Task.detached(priority: .utility) {
                    try? FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                    if let attributionData {
                        try? attributionData.write(to: attributionURL, options: .atomic)
                    }
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
        case .musixmatch: source.rawValue
        }
    }

    private func cancelLyricsLookup() {
        lyricsLookupTask?.cancel()
        lyricsLookupTask = nil
    }

    func retryLyricsLookup() {
        guard let track = nowPlaying, lyrics == nil else { return }
        cancelLyricsLookup()
        startLyricsLookup(for: track)
    }

    /// Moves the highlight to wherever the clock now says the song is.
    ///
    /// The line is checked on every poll. Production publishes only a sparse
    /// compositor anchor on direct clock changes and line boundaries. The
    /// numerical flow check and legacy A/B renderer retain their ten-hertz
    /// `lyricProgress` value, but no production view observes it.
    private func followTheWords(
        publishingProgress periodicFrameDue: Bool = true,
        reanchoringCompositor: Bool = true
    ) {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let position = trackClock.position(at: now)
        // Published only when the second it displays changes. The timecode is
        // whole seconds, so republishing it twenty times a second would
        // invalidate the whole panel for a string that is the same string.
        if Int(position) != songSecond { songSecond = Int(position) }
        guard let lyrics else {
            if lyricLine != nil { lyricLine = nil }
            if lyricProgress != 0 { lyricProgress = 0 }
            if lyricPlaybackAnchor != nil { lyricPlaybackAnchor = nil }
            return
        }
        let heard = position
        let index = lyrics.index(at: heard)
        // The scoreboard belongs to the song that finished, and the moment the
        // next one is actually being sung it is in the way. Documented as this
        // behaviour when the card was written and not implemented: it stayed
        // up over the following song until somebody clicked it.
        if lastPerformance != nil, index != nil,
            Self.now - performanceShownAt >= Self.leastPerformanceSeconds
        {
            lastPerformance = nil
        }
        let lineChanged = lyricLine != index
        if lineChanged { lyricLine = index }
        if reanchoringCompositor || lineChanged || lyricPlaybackAnchor?.lineIndex != index {
            lyricPlaybackRevision &+= 1
            lyricPlaybackAnchor = LyricPlaybackAnchor(
                lineIndex: index,
                lineStart: index.map {
                    lyrics.lines[$0].time - lyrics.offset
                } ?? 0,
                lineEnd: index.map {
                    $0 + 1 < lyrics.lines.count
                        ? lyrics.lines[$0 + 1].time - lyrics.offset
                        : lyrics.lines[$0].time - lyrics.offset + 4
                } ?? 0,
                position: position,
                trueAt: now,
                isPlaying: trackClock.isPlaying,
                revision: lyricPlaybackRevision)
        }
        if Self.shouldPublishLyricProgress(
            periodicFrameDue: periodicFrameDue, lineChanged: lineChanged)
        {
            // Direct actions and line changes restart the cadence here too, so
            // a periodic frame cannot land one poll later and duplicate them.
            pollsSinceLyricFrame = 0
            let progress = lyrics.progress(at: heard)
            if lyricProgress != progress { lyricProgress = progress }
        }
    }

    /// Finds an `.lrc` for a track by name.
    static func findLyrics(for track: NowPlaying.Track) -> Lyrics? {
        findLyricsMatch(for: track)?.lyrics
    }

    private struct LocalLyricsMatch {
        let lyrics: Lyrics
        let url: URL
    }

    private static func findLyricsMatch(for track: NowPlaying.Track) -> LocalLyricsMatch? {
        guard let url = bestFile(for: track, extensions: ["lrc"]),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        guard let lyrics = Lyrics.parse(text) else { return nil }
        return LocalLyricsMatch(lyrics: lyrics, url: url)
    }

    /// Finds locally cached or user-supplied words with no timing.
    static func findPlainLyrics(for track: NowPlaying.Track) -> String? {
        findPlainLyricsMatch(for: track)?.text
    }

    private struct LocalPlainLyricsMatch {
        let text: String
        let url: URL
    }

    private static func findPlainLyricsMatch(
        for track: NowPlaying.Track
    ) -> LocalPlainLyricsMatch? {
        guard let url = bestFile(for: track, extensions: ["txt"]),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : LocalPlainLyricsMatch(text: words, url: url)
    }

    /// A downloaded cache keeps its provider; only user files say local.
    static func lyricsSourceName(forLocalURL url: URL) -> String {
        OnlineLyrics.cachedSource(for: url).map { Self.lyricsSourceName(for: $0) }
            ?? loc("Local file")
    }

    /// A provider cache is online evidence even though it is now read from disk.
    static func lyricsStatus(forLocalURL url: URL) -> LyricsLookupStatus {
        OnlineLyrics.cachedSource(for: url) == nil ? .local : .online
    }

    /// Restores bounded provider attribution beside a downloaded cache.
    ///
    /// The provider in the sidecar must agree with the provider encoded in the
    /// cache filename. A stale or hand-edited sidecar must not relabel another
    /// catalogue's words on the next play.
    static func cachedLyricsAttribution(
        for lyricsURL: URL
    ) -> OnlineLyrics.CacheAttribution? {
        guard let source = OnlineLyrics.cachedSource(for: lyricsURL) else { return nil }
        let url = OnlineLyrics.cacheAttributionURL(for: lyricsURL)
        guard let data = try? Data(contentsOf: url),
            let attribution = try? OnlineLyrics.decodeCacheAttribution(data),
            attribution.provider == source
        else { return nil }
        return attribution
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

    /// Finds cover artwork beside local words and melody files.
    ///
    /// This is the final source in the cover chain: the player and recognition
    /// catalogue stay authoritative, while a user-supplied image makes local
    /// and hand-curated Chinese karaoke libraries complete without a network
    /// service or an embedded API key.
    static func findArtwork(for track: NowPlaying.Track) -> URL? {
        bestFile(
            for: track,
            extensions: ["jpg", "jpeg", "png", "heic", "webp"])
    }

    /// The exact-name cover beside a hand-selected `.lrc`.
    static func artworkBesideWords(at words: URL) -> URL? {
        let stem = words.deletingPathExtension()
        return ["jpg", "jpeg", "png", "heic", "webp"]
            .lazy
            .map(stem.appendingPathExtension)
            .first { FileManager.default.fileExists(atPath: $0.path) }
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
        return bestFileName(for: track, names: names, extensions: extensions).map {
            directory.appendingPathComponent($0)
        }
    }

    /// Pure half of local asset matching, shared by words, melody and artwork.
    static func bestFileName(
        for track: NowPlaying.Track, names: [String], extensions: [String]
    ) -> String? {
        let wanted = normalised(track.searchKey)
        let title = normalised(track.title)

        let candidates = names.filter { name in
            extensions.contains { name.lowercased().hasSuffix("." + $0) }
        }
        let userFiles = candidates.filter {
            OnlineLyrics.cachedSource(for: URL(fileURLWithPath: $0)) == nil
        }
        let downloaded = candidates.filter {
            OnlineLyrics.cachedSource(for: URL(fileURLWithPath: $0)) != nil
        }

        func best(in candidates: [String]) -> String? {
            let ordered = candidates.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            // Both names present is a better match than the title alone, so it
            // is preferred rather than taking whatever the directory listed first.
            return
                ordered.first { normalised($0).contains(wanted) }
                ?? ordered.first {
                    let file = normalised($0)
                    return file.contains(title) && file.contains(normalised(track.artist))
                }
                ?? ordered.first { normalised($0).contains(title) }
        }

        // A file the listener deliberately supplied remains authoritative.
        // Provider caches are fallbacks, even when their generated filename is
        // an artist-and-title match and the user chose a title-only filename.
        return best(in: userFiles) ?? best(in: downloaded)
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

    /// Existing installs must opt back into launch routing once.
    ///
    /// An older build could leave this preference enabled without making the
    /// resulting route visible enough. Measured in the system log: opening the
    /// app created an aggregate eight seconds later while the person reasonably
    /// believed no route had been started. A versioned consent keeps the useful
    /// feature without silently inheriting that unsafe state.
    nonisolated static let autoStartConsentVersion = 1
    private static let autoStartConsentVersionKey = "autoStartConsentVersion"

    var autoStart: Bool = false {
        didSet {
            guard oldValue != autoStart else { return }
            if !isRestoring, !Self.isVerificationProcess, autoStart {
                UserDefaults.standard.set(
                    Self.autoStartConsentVersion,
                    forKey: Self.autoStartConsentVersionKey)
            }
            persist()
        }
    }

    nonisolated static func restoredAutoStart(
        savedEnabled: Bool, consentVersion: Int
    ) -> Bool {
        savedEnabled && consentVersion >= autoStartConsentVersion
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
    @ObservationIgnored private var pluginRefreshGate = LatestRefreshGate()
    @ObservationIgnored private var pluginRegistryWasRequested = false
    private let systemDiscoveryQueue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.system-discovery", qos: .utility)

    func refreshPlugins() {
        // An explicit Rescan is deterministic: when it returns, the window
        // shows the answer. It also makes an older launch scan obsolete.
        pluginRegistryWasRequested = true
        pluginRefreshGate.invalidate()
        applyPluginRefresh(AudioUnitPlugins.installed())
    }

    /// Loads the registry when a route or the plug-in page first needs it.
    func refreshPluginsIfNeeded() {
        guard !pluginRegistryWasRequested else { return }
        pluginRegistryWasRequested = true
        refreshPluginsAsynchronously()
    }

    private func refreshPluginsAsynchronously() {
        guard let token = pluginRefreshGate.request() else { return }
        runPluginRefresh(token)
    }

    private func runPluginRefresh(_ token: LatestRefreshGate.Token) {
        let queue = systemDiscoveryQueue
        queue.async {
            let installed = AudioUnitPlugins.installed()
            Task { @MainActor in
                self.finishPluginRefresh(installed, token: token)
            }
        }
    }

    private func finishPluginRefresh(
        _ installed: [AudioUnitPlugin], token: LatestRefreshGate.Token
    ) {
        guard pluginRefreshGate.accepts(token) else { return }
        applyPluginRefresh(installed)
        if case .start(let next) = pluginRefreshGate.finish(token) {
            runPluginRefresh(next)
        }
    }

    /// MainActor half of registry discovery: comparisons and value publication.
    private func applyPluginRefresh(_ installedPlugins: [AudioUnitPlugin]) {
        if availablePlugins != installedPlugins { availablePlugins = installedPlugins }
        // Anything remembered that is no longer installed is dropped rather
        // than carried: a reference to a plugin somebody uninstalled would fail
        // to load on every start and say so every time.
        let installed = Set(installedPlugins.map(\.id))
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
    /// Whether voice isolation is going to ruin the singing.
    ///
    /// Apple's model keeps one person speaking and removes everything else. On
    /// a call that is the whole point; on a KTV stage it treats the backing
    /// track and the singing as the noise it exists to delete, and adds 56 ms
    /// while doing it.
    ///
    /// Two of the presets turn it on — 「語音通話」and 「吵雜環境」— because both
    /// of them are about a phone call, and somebody who set one up in February
    /// and opened the stage in July has no reason to connect the two. So the
    /// stage says it, rather than either staying quiet or overriding a setting
    /// somebody chose on purpose.
    ///
    /// The threshold is not zero: a little isolation on a noisy room is a
    /// judgement somebody may have made deliberately, and warning about 5% would
    /// train people to ignore the line that matters at 100%.
    var voiceIsolationWillHurtSinging: Bool {
        isSingingVisible && voiceIsolationEnabled && voiceIsolationMix >= 40
    }

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
    var showsBackgroundApps = false {
        didSet {
            guard oldValue != showsBackgroundApps else { return }
            persist()
        }
    }

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

    /// Reads the live sample rate only from outputs YunAudio is using.
    ///
    /// Even the system default is deliberately absent when it is not selected
    /// or monitored here. Some Bluetooth plug-ins suspend audio for about two
    /// seconds while answering this property; asking an unrelated endpoint as
    /// background health monitoring would create the interruption it is meant
    /// to diagnose.
    nonisolated static func headsetInCallQuality(
        outputDevices: [AudioDevice],
        preferredUIDs: [String]
    ) -> AudioDevice? {
        firstPreferredMatch(
            in: outputDevices,
            preferredIDs: preferredUIDs,
            id: \.uid,
            matches: \.hasFallenToCallQuality)
    }

    /// Selects the first matching named value without evaluating duplicates or
    /// anything outside the named set.
    ///
    /// Generic so a pure spy can assert the number of expensive reads. The
    /// production match is a live HAL sample-rate query; making the selection
    /// testable without an AudioDevice is what proves an unrelated Bluetooth
    /// endpoint receives zero of them.
    nonisolated static func firstPreferredMatch<Device, Identifier: Hashable>(
        in devices: [Device],
        preferredIDs: [Identifier],
        id: (Device) -> Identifier,
        matches: (Device) -> Bool
    ) -> Device? {
        var visited: Set<Identifier> = []
        for preferredID in preferredIDs where visited.insert(preferredID).inserted {
            guard let device = devices.first(where: { id($0) == preferredID }) else {
                continue
            }
            if matches(device) { return device }
        }
        return nil
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
    /// The daemons, meaning everything the list above did not already take.
    ///
    /// A partition, by construction. It used to be its own predicate —
    /// `isBackground && !isPlaying` — against the top half's
    /// `!isBackground || isPlaying || isRecording`, and the two overlap: a
    /// background process that is *recording* but not playing satisfies both.
    /// It was therefore drawn twice, once in each half, and counted twice in
    /// everything derived from them.
    ///
    /// Two predicates over one list have to be kept complementary by hand, and
    /// nobody was. Subtracting the first from the whole cannot drift.
    private var backgroundApps: [AudioApplication] {
        let offered = Set(offeredApps.map(\.bundleID))
        return availableApps.filter { !offered.contains($0.bundleID) }
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
        let applications = Array(offered.prefix(limit))
        let background = showsBackgroundApps ? backgroundApps : []
        // Counted as what is *not on screen*, rather than as what the truncation
        // cut.
        //
        // The two halves overlap. `offeredApps` takes anything playing or
        // recording, `backgroundApps` takes anything in the background that is
        // not playing — so a background application that is *recording* is in
        // both. Truncated out of the top half it still appears in the lower
        // one, and the old arithmetic counted it as overflow anyway: the panel
        // offered "1 more" that was already on the screen, and pressing it
        // revealed nothing.
        //
        // Found by the flow check once its accounting was compared against one
        // snapshot instead of two: `23 row(s) + 1 overflow against 23
        // application(s)`.
        return AppListing(
            applications: applications,
            overflow: AppListing.overflow(
                offered: offered.map(\.bundleID),
                showing: applications.map(\.bundleID) + background.map(\.bundleID)),
            background: background)
    }

    struct AppListing {
        /// The applications, truncated to what there is room for.
        var applications: [AudioApplication]
        /// How many applications are not on the screen anywhere.
        var overflow: Int
        /// The daemons, in full, when they have been asked for.
        var background: [AudioApplication]

        /// How many of the offered applications no row is showing.
        ///
        /// Not "how many the truncation cut", which is what it used to be and
        /// is a different number: the two halves of this list overlap, so an
        /// application cut from the top can still be on the screen in the lower
        /// one. Counting the cut therefore offered "1 more" that was already
        /// visible, and pressing it revealed nothing.
        ///
        /// A function of the two lists of identifiers, so the rule can be
        /// checked without a running router and a machine full of processes.
        static func overflow(offered: [String], showing: [String]) -> Int {
            let shown = Set(showing)
            return offered.filter { !shown.contains($0) }.count
        }
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
            if !isRestoring, let uid = monitorDeviceUID,
                outputDevices.first(where: { $0.uid == uid })?.hasCompleteTopology == false
            {
                monitorDeviceUID = oldValue
                requestHydratedSelection(uid, for: .monitor)
                return
            }
            cancelHydratedSelection(for: .monitor)
            persist()
            if !isRestoring { refreshHeadsetQualityAsynchronously() }
            if !isRestoring, !isCommittingHydratedDeviceSelection {
                hydrateConfiguredDevicesAsynchronously()
            }
            // A monitor the engine itself gave up on is already out of a route
            // that is running. Restarting would take a working mix down to
            // arrive exactly where it already is — and the start it would run
            // is the one that has just been proved to work.
            guard !isRestoring, !isDroppingMonitor else { return }
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

    /// Outputs that can be monitored on.
    ///
    /// The microphone's own headphone socket is one of them, and used not to be.
    /// A Razer Seiren, a Yeti, a Shure MV7 and every audio interface ever made
    /// present as **one** CoreAudio device with the microphone's input and the
    /// headphone jack's output on it, and this excluded the source device
    /// outright — so the socket people buy those microphones for was the one
    /// output the monitor picker would not offer. Choosing it as the
    /// destination instead is refused, correctly, with "the input and the
    /// output cannot be the same device", and monitoring had no entry at all.
    /// Between the two there was no way to hear yourself in your own
    /// microphone's headphones.
    ///
    /// The loop the old rule was guarding against is real, but it is about the
    /// *destination*: the mix the far end hears must not be fed back in. A
    /// headphone jack is not a microphone. Speakers still are — that is what
    /// `monitorMayFeedBack` warns about, and it is a warning rather than a
    /// refusal because somebody with a directional microphone across the room
    /// knows better than this application does.
    var monitorOptions: [AudioDevice] {
        outputDevices.filter {
            Self.canMonitor(
                uid: $0.uid, name: $0.name, hasOutput: $0.hasOutput,
                destinationUID: selectedDestinationUID, sourceUID: selectedSourceUID)
        }
    }

    /// What to say when somebody puts one device at both ends.
    ///
    /// The refusal is right and the old sentence was not enough. Somebody who
    /// sets a Razer Seiren as the input *and* the output is not confused about
    /// routing — they want to hear themselves in the microphone's own headphone
    /// socket, which is what that socket is for, and the destination is the
    /// wrong control for it: it is what the far end hears, and pointing it at
    /// the headphones would send Discord nothing.
    ///
    /// The right control is the monitor, three rows down and easy to miss. A
    /// message that names it turns a dead end into an instruction — and it is
    /// only offered when the device really can do it, so it never sends anybody
    /// to a picker that will not have their microphone in it.
    private func sameDeviceMessage(source: String, destination: String) -> String {
        let refusal = loc("The input and the output cannot be the same device.")
        guard let device = outputDevices.first(where: { $0.uid == destination }),
            device.hasInput, device.hasOutput, device.uid == source
        else { return refusal }
        return refusal + " "
            + loc(
                "To hear yourself in this microphone's own headphone socket, choose it under Monitor instead."
            )
    }

    /// Whether one device can carry the monitor mix.
    ///
    /// Static and parameterised so the rule can be argued with in a test rather
    /// than only by plugging a microphone in.
    /// Takes what it uses rather than a device, so it can be asserted without
    /// a microphone plugged in. The source is not a parameter any more, which
    /// is the change: it was the only reason the socket was hidden.
    nonisolated static func canMonitor(
        uid: String, name: String, hasOutput: Bool,
        destinationUID: String?, sourceUID: String?
    ) -> Bool {
        guard hasOutput else { return false }
        // Our own virtual device is what the far end is listening to. Sending
        // the microphone back into it is a loop, not a monitor.
        guard !name.localizedCaseInsensitiveContains("YunAudio") else { return false }
        // The mix already goes there — unless the destination is the source,
        // which is a pair that cannot start at all.
        //
        // That combination is exactly what somebody trying to hear themselves
        // in their microphone's headphone socket sets first, and hiding the
        // device from the monitor for being a destination it can never actually
        // be left them locked out of both controls at once: the output refuses
        // the device, and the monitor will not list it until the output has been
        // changed back to something they were not thinking about. The message
        // that now points them at the monitor would have pointed at a picker
        // with nothing in it.
        if let destinationUID, uid == destinationUID, destinationUID != sourceUID {
            return false
        }
        return true
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
        let keys = indices.compactMap(routeKey(at:))
        for key in keys { rememberGain(gain, for: key) }
        applyLiveControl { engine in
            for key in keys { engine.setGain(gain, for: key) }
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
        let keys = indices.compactMap(routeKey(at:))
        for key in keys { rememberGain(gain, for: key) }
        applyLiveControl { engine in
            for key in keys { engine.setGain(gain, for: key) }
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
            if newValue != .off { lighting.refreshDeviceAsynchronously() }
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

    /// The numbers behind the sentence — the rates a device offered against the
    /// one that was needed. Not shown to a user, who cannot act on it, but a
    /// report that says only "pick another speaker" is not enough to fix the
    /// code with when the speaker was not the problem.
    var echoCancellationDetail: String? {
        guard cancelsEcho, isRunning else { return nil }
        return engine.lastEchoCancellationDetail
    }

    /// Split out for the reason `isolationMessage` is: the failure cannot be
    /// produced on demand, and the mapping is the testable part of it.
    /// Each sentence names the thing the user could change. "It could not be
    /// built" was true of six unrelated refusals and actionable for none of
    /// them: the one that actually happens here is a Bluetooth headset chosen
    /// as the speaker, and the answer to that is to pick another speaker —
    /// which nobody could work out from the old wording.
    static func echoMessage(_ reason: String) -> String {
        switch reason {
        case RoutingEngine.EchoFailure.notBuilt:
            loc("The echo canceller could not be built.")
        case RoutingEngine.EchoFailure.wouldNotStart:
            loc("The echo canceller would not start.")
        case RoutingEngine.EchoFailure.microphoneMissing:
            loc("The microphone the canceller needs is no longer there.")
        case RoutingEngine.EchoFailure.speakerMissing:
            loc("The speaker to cancel against is no longer there.")
        case RoutingEngine.EchoFailure.microphoneCannotPresentRouterRate:
            loc(
                "This microphone cannot run at the route's sample rate, so it cannot be echo-cancelled."
            )
        case RoutingEngine.EchoFailure.noSharedSampleRate:
            loc("The microphone and the speaker share no sample rate.")
        case RoutingEngine.EchoFailure.sampleRateNotApplied:
            loc("The devices would not take the sample rate the canceller needs.")
        case RoutingEngine.EchoFailure.aggregateNotCreated:
            loc(
                "macOS refused to hold this microphone and speaker together. Try another speaker."
            )
        case RoutingEngine.EchoFailure.unitNotInstantiated:
            loc("macOS did not supply its echo canceller.")
        case RoutingEngine.EchoFailure.unitRefusedSetup:
            loc(
                "macOS's echo canceller refused this microphone and speaker. Try another speaker."
            )
        case RoutingEngine.EchoFailure.clockDiffersFromRouter:
            loc("The canceller and the route ended up on different sample rates.")
        case RoutingEngine.EchoFailure.ringNotAllocated:
            loc("There was not enough memory to carry the cancelled audio.")
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
        publish(engine.recordingDuration, to: \.recordingSeconds)
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
    func prepareForRendering(refreshesApplications: Bool = true) {
        if refreshesApplications { refreshAppsForVerification() }
        // So the two key buttons are in a picture. Every other control on that
        // row is, and a control nobody has ever looked at is the one that comes
        // out cut off at the window edge.
        ownsSongForRendering = true
        // A finite live reading alongside a stopped route is not a state the
        // application can reach. This fixture is used only by the two design
        // harnesses, so make the synthetic signal and its transport state agree.
        isRunning = true
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
        outputVerdict = Self.classifyOutput(peak: outputPeak, clippedSamples: 0)
        // A long title with a bracketed subtitle, which is what a drama theme
        // is actually called. The short one never made the strip's text column
        // wider than the window, so the title that pushed the duration off the
        // right-hand edge could not appear in any render.
        nowPlaying = NowPlaying.Track(
            application: "Spotify",
            title: "年少心動雨季 (《那年盛夏》電視劇片頭曲)", artist: "黃霄雲",
            album: "天賜的聲音", position: 80.7, duration: 265, isPlaying: true,
            // A real cover, because the two branches of `SongArtwork` are not
            // the same view: without a URL it draws a gradient and a letter,
            // which takes whatever size it is given, and with one it draws a
            // resizable image that arrives asynchronously and lays the stage
            // out twice. Every render and every photograph of this stage took
            // the first branch, so the one a user actually sees was untested.
            artworkURL: URL(
                string:
                    "https://p2.music.126.net/VZBj5FRD5zQpvkquGkBYEw==/109951173224181614.jpg"))
        // The line being sung carries word times, because a fixture without
        // them can only ever exercise the linear sweep — the compositor's
        // key-frame path had no picture of itself at all. Held syllables are
        // deliberately uneven: 「时光」 is quick and 「橡皮」 is slow, which is
        // the difference a linear fill gets wrong.
        //
        // A real file, parsed rather than assembled: the credit block that
        // opens it, the timestamps as the index sends them, and a rest in the
        // middle. Every earlier fixture was three short sentences written to
        // look right, so the stage was only ever rendered in a state it never
        // reaches — no credits to strip, no line long enough to wrap, and three
        // of the six slots empty. 年少心動雨季, from NetEase, as it arrives.
        lyrics = Lyrics.parse(
            """
            [00:00.00] 作词 Lyricist : 翟云鹏/冉亦/黄霄雲
            [00:01.00] 作曲Composer : 黄霄雲
            [00:03.00] 编曲Arrangement : 马克/黄霄雲
            [00:15.00] 母带 Mastering : 时俊峰@福达录音棚
            [00:19.00] 出品 : 环球音乐
            [00:57.54]告别总来不及练习
            [01:02.16]我只追到你的背影
            [01:09.39]原来年少心动是逆行在一场雨季
            [01:14.79]注定了无法走进同一个晴天里
            [01:20.70]<01:20.70>可<01:20.95>偏<01:21.20>偏<01:21.60>时<01:21.85>光<01:22.10>的<01:22.55>橡<01:23.10>皮
            [01:23.91]擦去很多却放过你姓名
            [01:28.00]
            [01:33.15]原来有些相遇明明知道会分离
            [01:38.16]再重来我依然有选择你的勇气
            [01:44.10]只可惜青春的诗句
            [01:47.31]总有挥散不去的叹息
            """)?
            // A translation, because the stage now shows one and no render or
            // photograph of it has ever contained a line that has one.
            .withTranslation(
                """
                [01:09.39]So a young heart moving was walking backwards through a season of rain
                [01:14.79]Never to arrive at the same clear day
                [01:20.70]Yet the eraser of time
                [01:23.91]Took so much and spared your name
                """)
        // On for the design harness, so the row has a picture. A user's own
        // choice is untouched: this fixture only ever runs under the renderer
        // and the capture gate.
        showsRomanisation = true
        lyricsSourceName = loc("NetEase Cloud Music")
        lyricsLookupStatus = .online
        // Two indexes answering, so the capture contains the control that only
        // appears when there is somewhere else to go.
        lyricSource = .netEase
        lyricAlternatives = [.netEase, .qqMusic]
        trackClock.duration = 265
        trackClock.adopt(
            80.7, isPlaying: true,
            trueAt: Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
        followTheWords()
        scoringReference = stride(from: 78.0, through: 90.0, by: 0.05).map {
            PitchSample(time: $0, midi: $0 < 86 ? 57 : 60)
        }
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

    /// Moves the fixture to a moment in the song it is already showing.
    ///
    /// Some states exist only at one point in a song — the count into the
    /// singing is four seconds long — and a capture that always renders the
    /// same second can never contain them. Only the renderer calls this.
    func renderAt(second: Double) {
        trackClock.adopt(
            second, isPlaying: true,
            trueAt: Double(DispatchTime.now().uptimeNanoseconds) / 1e9)
        followTheWords()
    }

    /// Ends a song on the fixture stage, for the capture that judges the card.
    ///
    /// A performance card only exists in the second between one song ending
    /// and the next beginning, which no gate can wait for. Renderer only.
    func renderFinishedPerformance() {
        prepareForRendering()
        lastPerformance = Performance(
            title: "年少心動雨季 《那年盛夏》電視劇片頭曲", artist: "黃霄雲",
            singers: [
                Singer(
                    uid: "preview-one", name: loc("Microphone"), hertz: 220,
                    score: KaraokeScore(
                        percentage: 82, onPitchSeconds: 148, nearPitchSeconds: 22,
                        silentSeconds: 12, referenceSeconds: 181, sungSeconds: 169,
                        meanErrorSemitones: -0.31,
                        lines: [
                            KaraokeScore.Line(
                                index: 6, time: 69.39, text: "原来年少心动是逆行在一场雨季",
                                referenceSeconds: 5.4, onPitchSeconds: 5.1,
                                nearPitchSeconds: 0.2, percentage: 94)
                        ])),
                Singer(
                    uid: "preview-two", name: loc("Source"), hertz: 330,
                    score: KaraokeScore(
                        percentage: 54, onPitchSeconds: 92, nearPitchSeconds: 30,
                        silentSeconds: 41, referenceSeconds: 181, sungSeconds: 140,
                        meanErrorSemitones: 0.42,
                        lines: [
                            KaraokeScore.Line(
                                index: 9, time: 93.15, text: "原来有些相遇明明知道会分离",
                                referenceSeconds: 5, onPitchSeconds: 3.6,
                                nearPitchSeconds: 0.5, percentage: 71)
                        ])),
            ])
    }

    /// Puts a song read out of a browser tab on the fixture stage.
    ///
    /// The one source no capture has ever shown. A browser track is a
    /// different shape from a player's: no album at all, a cover derived from
    /// the address rather than supplied, and an "artist" that is often a
    /// broadcaster's full name because the tab's title carried no credit — ten
    /// characters where 「黃霄雲」 is three. If that overflows the track column
    /// it does so only here. Renderer only.
    func renderBrowserTrack() {
        prepareForRendering()
        nowPlaying?.application = "Safari"
        nowPlaying?.title = "情結"
        nowPlaying?.artist = "中國浙江衛視官方頻道"
        nowPlaying?.album = ""
        nowPlaying?.artworkURL = BrowserNowPlaying.artworkURL(
            forTab: "https://www.youtube.com/watch?v=EkxJTjYGD70")
        nowPlaying?.identity = "https://www.youtube.com/watch?v=EkxJTjYGD70"
        // Both, or the image says 4:25 for a song the clock knows is 3:37 —
        // a capture that disagrees with itself is worse than no capture.
        nowPlaying?.duration = 217.021
        trackClock.duration = 217.021
        renderAt(second: 88.7)
    }

    /// Puts a duet on the fixture stage, for the capture that judges it.
    ///
    /// The song the renderer normally uses is sung by one person, so the
    /// colours that tell one voice from the other had no image to be judged
    /// in. This is 「往事只能回味」 as a duet file writes it: a name on a line
    /// of its own, which the attribution pass lifts off and hands to the line
    /// below. Renderer only.
    func renderDuet() {
        lyrics = Lyrics.parse(
            """
            [00:00.00]王赫野
            [00:04.00]时光一逝永不回
            [00:09.00]往事只能回味
            [00:14.00]黃霄雲
            [00:18.00]忆童年时竹马青梅
            [00:23.00]两小无猜日夜相随
            [00:28.00]合
            [00:32.00]春风又吹红了花蕊
            [00:37.00]你已经也添了新岁
            [00:42.00]王赫野
            [00:46.00]你就要变心
            [00:51.00]像时光难倒回
            """, performers: ["王赫野", "黃霄雲"])
        nowPlaying?.title = "往事只能回味"
        nowPlaying?.artist = "王赫野 / 黃霄雲"
        trackClock.duration = 240
        renderAt(second: 29)
    }

    /// A score with nothing behind it, for the design captures only.
    private static func previewScore(percentage: Double, error: Double) -> KaraokeScore {
        KaraokeScore(
            percentage: percentage, onPitchSeconds: 84 * percentage / 100,
            nearPitchSeconds: 6, silentSeconds: 12, referenceSeconds: 96, sungSeconds: 88,
            meanErrorSemitones: error,
            lines: [
                KaraokeScore.Line(
                    index: 1, time: 82, text: "",
                    referenceSeconds: 4, onPitchSeconds: 3.1,
                    nearPitchSeconds: 0.4, percentage: percentage)
            ])
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
        let cleared = Self.classifyOutput(peak: outputPeak, clippedSamples: 0)
        if outputVerdict != cleared { outputVerdict = cleared }
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
    enum OutputVerdict: Sendable, Equatable {
        case clipping, hot, good, quiet, veryQuiet, silent
    }

    /// Discrete so a continuously moving peak does not invalidate every status
    /// pill when the one-word answer has not changed.
    private(set) var outputVerdict: OutputVerdict = .silent

    nonisolated static func classifyOutput(
        peak: Float, clippedSamples: UInt64
    ) -> OutputVerdict {
        if clippedSamples > 0 { return .clipping }
        let decibels = peak > 0 ? Double(20 * log10(peak)) : -.infinity
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

    /// Peak-hold arithmetic without the publication around it.
    nonisolated static func nextPeakHold(previous: Float, incoming: Float) -> Float {
        let next = incoming > previous ? incoming : previous * 0.97
        // The meter floors at −60 dBFS, so anything below this draws exactly
        // nothing. Without an exact zero the Float decay eventually sticks on a
        // subnormal value and keeps publishing at 20 Hz for the process lifetime.
        return next <= 0.001 ? 0 : next
    }

    private func refreshPeaks(_ current: [Float]) {
        if peakHolds.count != current.count {
            publish(current, to: \.peakHolds)
            publish(current.map { $0 >= Self.clipThreshold }, to: \.clipped)
            return
        }
        for index in current.indices {
            // Rises at once, falls slowly. The poll runs twenty times a second,
            // so this is roughly a second and a half of hold.
            let held = Self.nextPeakHold(
                previous: peakHolds[index],
                incoming: current[index])
            publish(held, at: index, to: \.peakHolds)
            if current[index] >= Self.clipThreshold, !clipped[index] {
                publish(true, at: index, to: \.clipped)
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
        let current = desiredTopologyRoutes
        guard
            !current.contains(where: {
                $0.source == source && $0.destination == destination
            })
        else { return }
        applyPatch(current + [Route(source: source, destination: destination)])
    }

    /// Pulls one cable, leaving everything else where it is.
    func disconnectRoute(source: ChannelRef, destination: ChannelRef) {
        let current = desiredTopologyRoutes
        let remaining = current.filter {
            !($0.source == source && $0.destination == destination)
        }
        guard remaining.count != current.count else { return }
        applyPatch(remaining)
    }

    /// Pulls every cable reaching a destination.
    func disconnect(destination: ChannelRef) {
        let current = desiredTopologyRoutes
        let remaining = current.filter { $0.destination != destination }
        guard remaining.count != current.count else { return }
        applyPatch(remaining)
    }

    /// The newest topology requested while the engine is still publishing an
    /// earlier one. Every subsequent edit must build on this, not on the graph
    /// the UI happened to last observe, or two quick cable additions collapse
    /// into whichever one completed last.
    @ObservationIgnored private var pendingTopologyRoutes: [Route]?
    /// False from the instant Stop is requested until a new graph has started.
    ///
    /// `isRunning` stays true throughout the asynchronous teardown. Using it
    /// as the admission check let a cable edit queue after Stop and report its
    /// old-run result after the next Start.
    @ObservationIgnored private var routeUpdatesAreAccepted = false

    private var desiredTopologyRoutes: [Route] {
        applyingLatestRouteControls(to: pendingTopologyRoutes ?? activeRoutes)
    }

    private func applyPatch(_ routes: [Route]) {
        let routes = applyingLatestRouteControls(to: routes)
        guard isRunning else {
            // Nothing to swap into; the patch takes effect when routing starts.
            pendingTopologyRoutes = nil
            activeRoutes = routes
            return
        }
        guard routeUpdatesAreAccepted else { return }
        pendingTopologyRoutes = routes
        routeApplier.submit(routes)
    }

    private struct RouteUpdateResult: Sendable {
        let requested: [Route]
        let installed: [Route]?
    }

    private func finishRouteUpdate(_ result: RouteUpdateResult) {
        guard routeUpdatesAreAccepted else { return }
        if pendingTopologyRoutes == result.requested { pendingTopologyRoutes = nil }
        guard isRunning else { return }
        guard let installed = result.installed else {
            restartIfRunning()
            return
        }
        let controlled = applyingLatestRouteControls(to: installed)
        activeRoutes = controlled
        routeGains = controlled.map(\.gain)
        routeMutes = controlled.map(\.isMuted)
        rebuiltRoutes()
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
        scheduleCorrections()
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
    @ObservationIgnored private var activeRouteKeys: [RouteOccurrenceKey] = []

    /// Pointer-event truth that may be newer than an in-flight topology result.
    ///
    /// Each field is optional so moving a fader cannot restore an old mute, or
    /// pressing mute restore an old gain. Capacity is reserved when topology
    /// changes; the slider path updates one existing scalar entry.
    private struct LatestRouteControl {
        var gain: Float?
        var muted: Bool?
    }

    @ObservationIgnored private var latestRouteControls:
        [RouteOccurrenceKey: LatestRouteControl] = [:]

    private func routeKey(at index: Int) -> RouteOccurrenceKey? {
        guard activeRouteKeys.indices.contains(index) else { return nil }
        return activeRouteKeys[index]
    }

    private func rememberGain(_ gain: Float, for key: RouteOccurrenceKey) {
        var control = latestRouteControls[key] ?? LatestRouteControl()
        control.gain = gain
        latestRouteControls[key] = control
    }

    private func rememberMute(_ muted: Bool, for key: RouteOccurrenceKey) {
        var control = latestRouteControls[key] ?? LatestRouteControl()
        control.muted = muted
        latestRouteControls[key] = control
    }

    private func applyingLatestRouteControls(to routes: [Route]) -> [Route] {
        var routes = routes
        for (index, key) in Route.occurrenceKeys(in: routes).enumerated() {
            guard let control = latestRouteControls[key] else { continue }
            if let gain = control.gain { routes[index].gain = gain }
            if let muted = control.muted { routes[index].isMuted = muted }
        }
        return routes
    }

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
        let mutes = routeMutes.indices.compactMap { index in
            routeKey(at: index).map {
                (key: $0, muted: isSilenced(index))
            }
        }
        for entry in mutes { rememberMute(entry.muted, for: entry.key) }
        applyLiveControl { engine in
            for entry in mutes {
                engine.setMuted(entry.muted, for: entry.key)
            }
        }
    }

    func setGain(_ gain: Float, forRouteAt index: Int) {
        guard index < routeGains.count, let key = routeKey(at: index) else {
            return
        }
        routeGains[index] = gain
        rememberGain(gain, for: key)
        applyLiveControl { $0.setGain(gain, for: key) }
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
        guard index < routeMutes.count, let key = routeKey(at: index) else {
            return
        }
        routeMutes[index] = muted
        rememberMute(muted, for: key)
        applyLiveControl { $0.setMuted(muted, for: key) }
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
        guard !isApplyingPreset, isRunning else { return false }
        // Audio Units can take long enough to build for several more toggles
        // to arrive. The graph being built is immutable, so mutating it is not
        // an option; remember that the latest model state needs one more swap.
        // Returning true keeps each intermediate toggle from ordering a full
        // stop/start while the current live swap is already doing useful work.
        if effectSwapIsInFlight {
            effectSwapIsPending = true
            return true
        }
        guard !isBusy else { return false }
        isBusy = true
        effectSwapIsInFlight = true
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
                self.effectSwapIsInFlight = false
                // A chain swap holds the queue for as long as it takes to build
                // the Audio Units, which is long enough for somebody to press
                // Stop into it and be refused.
                if self.honourPendingStop() {
                    self.effectSwapIsPending = false
                    return
                }
                // A device, rate, buffer or echo edit needs a whole graph, and
                // that latest graph already contains every intervening effect
                // toggle. It outranks another effect-only build.
                if self.restartIsPending {
                    self.restartIsPending = false
                    self.effectSwapIsPending = false
                    self.restartIfRunning()
                    return
                }
                // The result belongs to the snapshot captured above. If the
                // model moved while it was building, neither its plugin errors
                // nor its default parameters are the current answer. Coalesce
                // every intervening toggle into one swap of the newest state.
                if self.effectSwapIsPending {
                    self.effectSwapIsPending = false
                    if !self.swapChainIfPossible() { self.restartIfRunning() }
                    return
                }
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

    /// A chain build already on `engineQueue`, and whether its captured state
    /// has since been superseded.
    @ObservationIgnored private var effectSwapIsInFlight = false
    @ObservationIgnored private var effectSwapIsPending = false

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

    /// Dynamics-meter ballistics without the observable dictionary write.
    nonisolated static func nextGainReduction(previous: Float, incoming: Float) -> Float {
        let next = incoming > previous ? incoming : previous * 0.82 + incoming * 0.18
        // One hundredth of a decibel is below one pixel of the 24 dB meter. Snap
        // there rather than letting the release stall forever on a subnormal.
        return next <= 0.01 ? 0 : next
    }

    private func refreshGainReduction() {
        for kind in Self.meteredStages where enabledEffects.contains(kind) {
            guard let value = engine.gainReduction(of: kind) else { continue }
            // Falls at a readable rate rather than following the unit exactly:
            // the reduction moves at the release time, which at 150 ms is a
            // flicker rather than a reading.
            let previous = gainReduction[kind] ?? 0
            publish(
                Self.nextGainReduction(previous: previous, incoming: value),
                for: kind,
                to: \.gainReduction)
        }
        // Snapshotted, because the loop mutates the dictionary it is walking.
        for kind in Array(gainReduction.keys) where !enabledEffects.contains(kind) {
            publish(Optional<Float>.none, for: kind, to: \.gainReduction)
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
        return engine.processingLatency.totalMilliseconds(sampleRate: rate)
    }

    /// What the chain costs, and what the paths that skipped it are held back
    /// by to meet it. The two are the same number or something is adrift.
    var chainAlignment: (chain: Int, applied: Int) {
        (engine.sourceProcessingLatencyFrames, engine.alignmentFrames)
    }

    /// Source and final-output processing together, in graph frames.
    var totalProcessingLatencyFrames: Int { engine.totalProcessingLatencyFrames }

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
    private(set) var autoStartNeedsPermissionReview = false

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
        didSet {
            groupedActiveRoutes = Self.groupRoutes(activeRoutes)
            activeRouteKeys = Route.occurrenceKeys(in: activeRoutes)
            let liveKeys = Set(activeRouteKeys)
            latestRouteControls = latestRouteControls.filter {
                liveKeys.contains($0.key)
            }
            latestRouteControls.reserveCapacity(activeRouteKeys.count)
        }
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
    /// Keeps cable and channel edits off MainActor and collapses a burst to its
    /// newest complete topology.
    @ObservationIgnored private lazy var routeApplier = LatestValueApplier<
        [Route], RouteUpdateResult
    >(
        queue: engineQueue,
        apply: { [engine] requested in
            let didUpdate = engine.updateRoutes(requested)
            return RouteUpdateResult(
                requested: requested,
                installed: didUpdate ? engine.currentRoutes : nil)
        },
        publish: { [weak self] result in
            self?.finishRouteUpdate(result)
        })

    /// Applies a live control without ever taking an engine lock on MainActor.
    ///
    /// Faders and mutes travel through the realtime command queue, but reaching
    /// that queue still takes the engine's state lock because a graph swap can
    /// replace and free it. Calling those methods on the main actor while
    /// `start` or `updateEffects` held the lock therefore froze every control
    /// for the whole CoreAudio or Audio Unit operation. `isBusy` covers starts
    /// and effect swaps, but not route publication or automatic clock recovery.
    /// Always using the serial queue preserves order across all four and keeps
    /// a 200 ms graph-retirement wait out of a fader gesture.
    private func applyLiveControl(
        _ work: @escaping @Sendable (RoutingEngine) -> Void
    ) {
        let engine = engine
        engineQueue.async { work(engine) }
    }

    /// Set while a start or stop is in flight so the button cannot be pressed
    /// twice into a half-built route.
    private(set) var isBusy = false
    private var levelTimer: Timer?
    private var deviceWatcher: DeviceChangeWatcher?
    @ObservationIgnored private var deviceRefreshGate = LatestRefreshGate()
    @ObservationIgnored private var deviceHydrationGate = LatestRefreshGate()

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
        // The verification harness expects a complete model immediately and
        // explicitly owns the hardware. Production construction must instead
        // reach its first live run-loop turn without a HAL read or even a
        // queued HAL job; applicationDidFinishLaunching starts discovery.
        if Self.isVerificationProcess, !Self.isUIBenchmarkProcess { refreshDevices() }
        userPresets = UserPresets.load()
        quickConfigs = QuickConfigStore.load()
        restore()
        // Registry discovery walks every installed Audio Unit. It was one
        // synchronous MainActor operation before the first frame, and it ran
        // before restore — when there were no enabled plug-ins to prune anyway.
        // Verification asks explicitly where it needs a deterministic answer.
        if !Self.isVerificationProcess {
            // Optional system registries stay completely asleep for the
            // default configuration. A saved feature still becomes available
            // without waiting for its settings page to be opened.
            if !enabledPlugins.isEmpty { refreshPluginsIfNeeded() }
            if !busHeadphoneProfiles.isEmpty { refreshHeadphoneProfilesIfNeeded() }
            if lighting.mode != .off { lighting.refreshDeviceAsynchronously() }
        }
        // After `restore`, so loading the file does not immediately write it
        // back — and `restore` is guarded anyway, which is belt and braces on
        // the one path where a setting arriving from disk looked like a change.
        obsLink.persist = { [weak self] in self?.persist() }

        engine.onClockLockFailure = { [weak self] in
            Task { @MainActor in self?.clockLockFailed = true }
        }

        installHotkeys()
        installMIDI(
            startsClientImmediately:
                Self.isVerificationProcess && !Self.isUIBenchmarkProcess)

        if Self.isVerificationProcess, !Self.isUIBenchmarkProcess {
            requestAutomaticStartIfConfigured()
        }
    }

    /// Starts HAL discovery only once the application has a live run loop.
    ///
    /// Kept out of `init` rather than merely dispatched from it: queueing an
    /// inventory there still lets coreaudiod contention delay the first frame,
    /// and `Task.yield()` does not promise that AppKit has presented one.
    func beginInitialDeviceDiscovery() {
        guard !deviceDiscoveryHasBegun else { return }
        deviceDiscoveryHasBegun = true

        // Register before reading the inventory so a plug event in the read's
        // window becomes the gate's one latest rerun rather than being lost.
        deviceWatcher = DeviceChangeWatcher { [weak self] in
            Task { @MainActor in self?.requestDeviceChangeRefresh() }
        }

        if deviceInventoryIsReady {
            // Verification constructs synchronously, but restored Bluetooth
            // endpoints still need their exact topology before a route starts.
            //
            // The baseline goes with it. `finishInitialDeviceRefresh` was the
            // only place that ever supplied one, and this branch returns before
            // reaching it — so in exactly the process that runs the flow check
            // the watcher was handed a listener and never a baseline, and every
            // device appearing or disappearing for the next four minutes was
            // dropped on the floor. The decoy aggregate was never seen, and
            // neither was a destination being destroyed underneath a route.
            deviceWatcher?.establishBaseline(lastInventoryIDs)
            hydrateConfiguredDevicesAsynchronously()
            requestAutomaticStartIfConfigured()
            return
        }
        // Nothing baselines the watcher on the refused-token path, and nothing
        // needs to: with no inventory read yet there is no snapshot to hand
        // over, and the probe baselines itself from its first read.
        guard let token = deviceRefreshGate.request() else { return }
        runInitialDeviceRefresh(token)
    }

    @ObservationIgnored private var automaticStartAwaitsDeviceHydration = false
    @ObservationIgnored private var requestedStartAwaitsDeviceHydration: Bool?

    /// A restored Bluetooth route starts only after its metadata rows have been
    /// upgraded to exact topology. Starting sooner would build an empty route
    /// from the intentional zero channel counts.
    private func requestAutomaticStartIfConfigured() {
        guard !Self.isVerificationProcess, autoStart,
            selectedSource != nil, selectedDestination != nil,
            !persistedRouteRequiresManualStart
        else { return }
        guard configuredDevicesHaveCompleteTopology else {
            automaticStartAwaitsDeviceHydration = true
            hydrateConfiguredDevicesAsynchronously()
            return
        }
        automaticStartAwaitsDeviceHydration = false
        if FirstLaunchPermissions.canAutoStartWithoutRequest(
            microphoneIsAllowed: PermissionCentre.shared.microphone == .allowed,
            capturesApplications: !capturedAppBundleIDs.isEmpty,
            cancelsEcho: cancelsEcho)
        {
            start()
        } else {
            autoStartNeedsPermissionReview = true
            lastError = loc("Automatic routing is waiting for permission review.")
        }
    }

    private var configuredDevicesHaveCompleteTopology: Bool {
        let devices = inputDevices + outputDevices
        return deviceDetailUIDs.allSatisfy { uid in
            devices.first(where: { $0.uid == uid })?.hasCompleteTopology == true
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
                    onTheMainThread { self?.toggle() }
                }
            case .toggleMute:
                handler = { [weak self] isPressed in
                    guard isPressed else { return }
                    onTheMainThread { self?.toggleMute() }
                }
            case .pushToTalk:
                handler = { [weak self] isPressed in
                    onTheMainThread { self?.setPushToTalk(held: isPressed) }
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
    /// Negative, and the magnitude is the complete processing path's latency.
    /// Computable with nothing connected, which is why it is here rather than
    /// inside `OBSLink`: it is a fact about this application, and the interface
    /// should show it whether or not anybody is streaming.
    var obsSyncOffsetMilliseconds: Double {
        OBSSyncOffset.forProcessingLatency(
            frames: engine.totalProcessingLatencyFrames,
            sampleRate: pathQuality?.sampleRate ?? preferredSampleRate)
    }

    /// Tells OBS what the complete processing path costs now.
    func pushOBSSyncOffset() {
        let frames = engine.totalProcessingLatencyFrames
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
        // The engine reads a static, so the stored preference has to reach it
        // before anything is scored — a setting nobody applies is a switch that
        // does nothing.
        SingerPitch.usesLearnedHead = usesLearnedPitch
        isRestoring = true
        defer { isRestoring = false }

        let saved = PreferencesStore.load()
        // The launch already decodes this blob here. MIDI used to load it a
        // second time during installation solely for this one field.
        midiControl.restore(saved.midiBindings ?? [:])
        autoStart = Self.restoredAutoStart(
            savedEnabled: saved.autoStart,
            consentVersion: UserDefaults.standard.integer(
                forKey: Self.autoStartConsentVersionKey))
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
        restoredDeviceIntent = RestoredDeviceIntent(
            source: saved.sourceDeviceUID,
            destination: saved.destinationDeviceUID,
            monitor: saved.monitorDeviceUID,
            additionalSources: saved.additionalSourceUIDs ?? [],
            additionalDestinations: saved.additionalDestinationUIDs ?? [])
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
        outputTrims = saved.outputTrims ?? [:]
        sourceLevels = saved.sourceLevels ?? [:]
        preferredSampleRate = saved.preferredSampleRate
        bufferFrames =
            Self.bufferSizes.contains(saved.bufferFrames) ? saved.bufferFrames : 128
        monoChannel = saved.monoChannel
        channelMode = SourceChannelMode(rawValue: saved.channelMode) ?? .mono

        obsLink.host = saved.obsHost ?? "127.0.0.1"
        obsLink.port = saved.obsPort ?? OBSConnection.defaultPort
        obsLink.inputName = saved.obsInputName ?? ""
        obsLink.mirrorsMute = saved.obsMirrorsMute ?? false
        // What somebody switched on, put back.
        //
        // Every one of these was forgotten at every launch, and each was a
        // choice made on purpose: the KTV scoring switch, 重唱, the inspector
        // tab, whether the daemons are listed, and whether Apple's classifier
        // is running. `watchesIOAllocations` is deliberately *not* here — see
        // its own note; a process-wide allocation hook that survives a relaunch
        // is a machine that is quietly slower with nothing on screen to say so.
        // The list, before the switch that belongs to it.
        if let paths = saved.queuedSongPaths, !paths.isEmpty {
            songQueue = KTVQueue.restored(paths: paths, currentIndex: saved.queuedSongIndex)
        }
        songQueue.repeatsOne = saved.repeatsOneSong ?? false
        showsBackgroundApps = saved.showsBackgroundApps ?? false
        isSoundIdentificationEnabled = saved.isSoundIdentificationEnabled ?? false
        if let tab = saved.inspectorTab.flatMap(MainWindow.Inspector.init(rawValue:)) {
            inspectorTab = tab
        }
        // The wish, not the switch. There is no route at this point in a launch
        // and there cannot be, so throwing the switch here only produces the
        // refusal above. `start` honours it once there is something to score.
        wantsScoring = saved.isScoringSinging ?? false

        if deviceInventoryIsReady {
            resolveRestoredDeviceIntent(defaultInputUID: try? AudioDevices.defaultInputUID())
        }
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
                    obsMirrorsMute: obsLink.mirrorsMute,
                    isScoringSinging: wantsScoring,
                    repeatsOneSong: songQueue.repeatsOne,
                    inspectorTab: inspectorTab.rawValue,
                    showsBackgroundApps: showsBackgroundApps,
                    isSoundIdentificationEnabled: isSoundIdentificationEnabled,
                    queuedSongPaths: songQueue.songs.map(\.path),
                    queuedSongIndex: songQueue.index),
                capturedAppBundleIDs: capturedAppBundleIDs,
                excludedAppBundleIDs: excludedAppBundleIDs,
                enabledEffects: enabledEffects,
                sourceRoles: sourceRoles,
                midiBindings: midiControl.bindings))
    }

    // MARK: Devices

    /// Resolves one metadata-only Bluetooth row without enumerating any other
    /// endpoint. Selection is committed only after exact topology arrives.
    private func requestHydratedSelection(
        _ uid: String,
        for target: DeviceSelectionTarget
    ) {
        deviceSelectionSerial &+= 1
        let pending = PendingDeviceSelection(uid: uid, token: deviceSelectionSerial)
        if var work = deviceSelectionWork[target] {
            if work.latest?.uid == uid || (work.latest == nil && work.active.uid == uid) {
                return
            }
            work.latest = pending
            deviceSelectionWork[target] = work
            refreshDeviceSelectionStatus()
            return
        }
        deviceSelectionWork[target] = DeviceSelectionWork(active: pending)
        refreshDeviceSelectionStatus()
        runHydratedSelection(pending, for: target)
    }

    private func runHydratedSelection(
        _ pending: PendingDeviceSelection,
        for target: DeviceSelectionTarget
    ) {
        let queue = engineQueue
        queue.async { [weak self] in
            let device = try? AudioDevices.device(uid: pending.uid)
            Task { @MainActor in
                self?.finishHydratedSelection(device, pending: pending, for: target)
            }
        }
    }

    private func finishHydratedSelection(
        _ device: AudioDevice?,
        pending: PendingDeviceSelection,
        for target: DeviceSelectionTarget
    ) {
        guard var work = deviceSelectionWork[target],
            work.active.token == pending.token,
            work.active.uid == pending.uid
        else { return }
        if let latest = work.latest {
            work.active = latest
            work.latest = nil
            deviceSelectionWork[target] = work
            refreshDeviceSelectionStatus()
            runHydratedSelection(latest, for: target)
            return
        }
        deviceSelectionWork[target] = nil
        refreshDeviceSelectionStatus()
        guard let device, device.uid == pending.uid, device.hasCompleteTopology else {
            reportHydratedSelectionFailure(uid: pending.uid)
            return
        }

        publishHydratedDevice(device)
        isCommittingHydratedDeviceSelection = true
        defer { isCommittingHydratedDeviceSelection = false }
        switch target {
        case .primarySource:
            guard device.inputChannels > 0 else {
                reportHydratedSelectionFailure(uid: pending.uid)
                return
            }
            selectedSourceUID = device.uid
        case .primaryDestination:
            guard device.outputChannels > 0 else {
                reportHydratedSelectionFailure(uid: pending.uid)
                return
            }
            selectedDestinationUID = device.uid
        case .additionalSource(let uid):
            guard uid == device.uid,
                addableSourceDevices.contains(where: { $0.uid == device.uid })
            else {
                reportHydratedSelectionFailure(uid: pending.uid)
                return
            }
            addSource(device.uid)
        case .additionalDestination(let uid):
            guard uid == device.uid,
                addableDestinationDevices.contains(where: { $0.uid == device.uid })
            else {
                reportHydratedSelectionFailure(uid: pending.uid)
                return
            }
            addDestination(device.uid)
        case .monitor:
            guard monitorOptions.contains(where: { $0.uid == device.uid }) else {
                reportHydratedSelectionFailure(uid: pending.uid)
                return
            }
            monitorDeviceUID = device.uid
        }
        if let selftest = requestedStartAwaitsDeviceHydration,
            deviceSelectionWork.isEmpty, configuredDevicesHaveCompleteTopology
        {
            requestedStartAwaitsDeviceHydration = nil
            start(selftest: selftest)
        }
    }

    private func cancelHydratedSelection(for target: DeviceSelectionTarget) {
        guard deviceSelectionWork.removeValue(forKey: target) != nil else { return }
        refreshDeviceSelectionStatus()
    }

    private func refreshDeviceSelectionStatus() {
        let pending = deviceSelectionWork.values
            .map { $0.latest ?? $0.active }
            .max { $0.token < $1.token }
        guard let pending else {
            deviceSelectionStatus = nil
            return
        }
        let devices = inputDevices + outputDevices
        let name =
            devices.first(where: { $0.uid == pending.uid })?.name
            ?? deviceNames[pending.uid] ?? pending.uid
        deviceSelectionStatus = String(format: loc("Loading %@…"), name)
    }

    private func reportHydratedSelectionFailure(uid: String) {
        // A Start requested by a Quick Config was waiting for this selection.
        // Failure keeps the old route selected and must not start that old route
        // later under the failed configuration's intent.
        requestedStartAwaitsDeviceHydration = nil
        let devices = inputDevices + outputDevices
        let name =
            devices.first(where: { $0.uid == uid })?.name
            ?? deviceNames[uid] ?? uid
        lastError = String(
            format: loc("%@ could not be selected; the previous device is still in use."),
            name)
    }

    /// Replaces a picker row with its exact snapshot, correcting its side too if
    /// a plug-in's fixed role metadata disagreed with the live topology.
    private func publishHydratedDevice(_ device: AudioDevice) {
        func replacing(
            _ devices: [AudioDevice],
            includesDevice: Bool
        ) -> [AudioDevice] {
            var result = devices
            if let index = result.firstIndex(where: { $0.uid == device.uid }) {
                if includesDevice {
                    result[index] = device
                } else {
                    result.remove(at: index)
                }
            } else if includesDevice {
                result.append(device)
            }
            return result
        }

        let inputs = replacing(inputDevices, includesDevice: device.inputChannels > 0)
        let outputs = replacing(outputDevices, includesDevice: device.outputChannels > 0)
        if inputs != inputDevices { inputDevices = inputs }
        if outputs != outputDevices { outputDevices = outputs }
        deviceNames[device.uid] = device.name
    }

    struct DeviceRefreshSnapshot: Sendable {
        let all: [AudioDevice]
        let inventoryIDs: Set<AudioObjectID>
        let selectedSourceUID: String?
        let selectedDestinationUID: String?
        let detailUIDs: Set<String>
        let defaultInputUID: String?
        let hardwareGain: AudioDevice.HardwareGain?
        let hardwareMonitor: AudioDevice.HardwareGain?
        let destinationHasVolumeControl: Bool
    }

    /// Reads every HAL-backed value before crossing to MainActor.
    ///
    /// A complete snapshot used to ask `coreaudiod` at least thirteen times per
    /// device. A notification must neither turn that into one long main-thread
    /// turn nor wake an unrelated Bluetooth capability provider.
    nonisolated static func readDeviceRefreshSnapshot(
        selectedSourceUID: String?, selectedDestinationUID: String?,
        detailUIDs: Set<String>, readsDefaultInput: Bool = false
    ) -> DeviceRefreshSnapshot {
        // Only Bluetooth endpoints the user placed in this route earn live
        // capability reads. RoutingEngine resolves its own full devices again
        // at Start; unrelated wireless outputs must stay asleep.
        let all =
            (try? AudioDevices.inventory(loadingBluetoothCapabilitiesFor: detailUIDs)) ?? []
        let source = selectedSourceUID.flatMap { uid in all.first { $0.uid == uid } }
        let destination = selectedDestinationUID.flatMap { uid in all.first { $0.uid == uid } }
        return DeviceRefreshSnapshot(
            all: all,
            inventoryIDs: Set(all.map(\.id)),
            selectedSourceUID: selectedSourceUID,
            selectedDestinationUID: selectedDestinationUID,
            detailUIDs: detailUIDs,
            defaultInputUID: readsDefaultInput ? (try? AudioDevices.defaultInputUID()) : nil,
            hardwareGain: source?.hardwareGain(scope: kAudioObjectPropertyScopeInput),
            hardwareMonitor: source?.playThrough(),
            destinationHasVolumeControl:
                destination?.hasSettableVolume(scope: kAudioObjectPropertyScopeOutput) ?? true)
    }

    /// Applies an immutable device answer without asking HAL another question.
    /// The HAL object IDs behind the published lists, for the device watcher to
    /// compare its own reads against. Kept here rather than derived from
    /// `inputDevices + outputDevices`, which drops any endpoint that presents
    /// neither side.
    @ObservationIgnored private var lastInventoryIDs: Set<AudioObjectID> = []

    private func applyDeviceInventory(_ snapshot: DeviceRefreshSnapshot) {
        lastInventoryIDs = snapshot.inventoryIDs
        // This snapshot already contains full details for every configured UID.
        // A direct hydration queued from an older picker state must not replace
        // any member of it after publication.
        deviceHydrationGate.invalidate()
        let inputs = snapshot.all.filter(\.hasInput)
        let outputs = snapshot.all.filter(\.hasOutput)
        if inputDevices != inputs { inputDevices = inputs }
        if outputDevices != outputs { outputDevices = outputs }
        for device in snapshot.all { deviceNames[device.uid] = device.name }
        pruneAdditionalDevices()
    }

    private func applyDeviceControlSnapshot(_ snapshot: DeviceRefreshSnapshot) {
        publish(snapshot.hardwareGain, to: \.hardwareGainReading)
        publish(snapshot.hardwareMonitor, to: \.hardwareMonitorReading)
        publish(
            snapshot.destinationHasVolumeControl,
            to: \.destinationHasVolumeControl)
    }

    private func applyDeviceRefreshSnapshot(_ snapshot: DeviceRefreshSnapshot) {
        applyDeviceInventory(snapshot)
        applyDeviceControlSnapshot(snapshot)
    }

    func refreshDevices() {
        // This deterministic form is for launch and explicit verification.
        // It supersedes an older event answer that may already be crossing back
        // from the serial queue.
        deviceRefreshGate.invalidate()
        let snapshot = Self.readDeviceRefreshSnapshot(
            selectedSourceUID: selectedSourceUID,
            selectedDestinationUID: selectedDestinationUID,
            detailUIDs: deviceDetailUIDs,
            readsDefaultInput: !deviceInventoryIsReady)
        applyDeviceRefreshSnapshot(snapshot)
        if !deviceInventoryIsReady {
            deviceInventoryIsReady = true
            resolveRestoredDeviceIntent(defaultInputUID: snapshot.defaultInputUID)
        }
    }

    /// Endpoints whose live format is relevant to the configured route.
    private var deviceDetailUIDs: Set<String> {
        Self.deviceDetailUIDs(
            source: selectedSourceUID,
            destination: selectedDestinationUID,
            monitor: monitorDeviceUID,
            additionalSources: additionalSourceUIDs,
            additionalDestinations: additionalDestinationUIDs)
    }

    nonisolated static func deviceDetailUIDs(
        source: String?, destination: String?, monitor: String?,
        additionalSources: [String], additionalDestinations: [String]
    ) -> Set<String> {
        Set(
            [source, destination, monitor].compactMap { $0 }
                + additionalSources + additionalDestinations)
    }

    /// Upgrades only configured endpoints after restore or a picker change.
    ///
    /// Re-enumerating the machine here would ask every unrelated plug-in to
    /// identify itself again. UID translation resolves one endpoint directly,
    /// and the first/latest gate bounds a rapid sequence of picker changes to
    /// two queue jobs.
    private func hydrateConfiguredDevicesAsynchronously() {
        guard !deviceDetailUIDs.isEmpty else {
            // Clearing the final endpoint also makes an in-flight answer stale.
            // With no route configured, launch now schedules zero hydration
            // jobs instead of one empty utility-queue round trip.
            deviceHydrationGate.invalidate()
            return
        }
        guard let token = deviceHydrationGate.request() else { return }
        runConfiguredDeviceHydration(token)
    }

    private func runConfiguredDeviceHydration(_ token: LatestRefreshGate.Token) {
        let expectedUIDs = deviceDetailUIDs
        let queue = engineQueue
        queue.async {
            let devices = expectedUIDs.compactMap { try? AudioDevices.device(uid: $0) }
            Task { @MainActor in
                self.finishConfiguredDeviceHydration(
                    devices, expectedUIDs: expectedUIDs, token: token)
            }
        }
    }

    private func finishConfiguredDeviceHydration(
        _ devices: [AudioDevice], expectedUIDs: Set<String>,
        token: LatestRefreshGate.Token
    ) {
        guard deviceHydrationGate.accepts(token) else { return }
        if expectedUIDs == deviceDetailUIDs {
            for device in devices { publishHydratedDevice(device) }
            if let source = selectedSource, source.hasCompleteTopology,
                !restoreChannelChoice()
            {
                applyChannelDefaults()
            }
        } else {
            _ = deviceHydrationGate.request()
        }
        if case .start(let next) = deviceHydrationGate.finish(token) {
            runConfiguredDeviceHydration(next)
        }
        if automaticStartAwaitsDeviceHydration, configuredDevicesHaveCompleteTopology {
            requestAutomaticStartIfConfigured()
        }
        if let selftest = requestedStartAwaitsDeviceHydration,
            configuredDevicesHaveCompleteTopology
        {
            requestedStartAwaitsDeviceHydration = nil
            start(selftest: selftest)
        }
    }

    /// Resolves persisted UIDs only after one complete inventory exists.
    ///
    /// Holding the intent separately prevents an empty first-frame array from
    /// erasing a saved route. Presence and picker role come from the snapshot;
    /// no HAL question is asked while this runs on MainActor.
    private func resolveRestoredDeviceIntent(defaultInputUID: String?) {
        guard let intent = restoredDeviceIntent else { return }
        restoredDeviceIntent = nil

        let wasRestoring = isRestoring
        isRestoring = true
        defer { isRestoring = wasRestoring }

        let inputs = Set(inputDevices.map(\.uid))
        let outputs = Set(outputDevices.map(\.uid))
        // Additional endpoints precede the primaries so pruning sees one
        // complete restored arrangement rather than half of one.
        additionalSourceUIDs = intent.additionalSources.filter(inputs.contains)
        additionalDestinationUIDs = intent.additionalDestinations.filter(outputs.contains)
        monitorDeviceUID = intent.monitor.flatMap { outputs.contains($0) ? $0 : nil }
        selectedSourceUID = intent.source.flatMap { inputs.contains($0) ? $0 : nil }
        selectedDestinationUID =
            intent.destination.flatMap { outputs.contains($0) ? $0 : nil }
        selectDefaults(defaultInputUID: defaultInputUID)
        pruneAdditionalDevices()
    }

    func selectDefaults() {
        selectDefaults(defaultInputUID: try? AudioDevices.defaultInputUID())
    }

    private func selectDefaults(defaultInputUID: String?) {
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
            let realInput = defaultInputUID.flatMap { uid in
                inputDevices.first(where: { $0.uid == uid })
            }.flatMap { device in
                Self.canSelectInputAutomatically(transport: device.transport)
                    && !device.transport.isVirtual
                    ? device : nil
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

    /// Starts one background enumeration for the first notification and keeps
    /// at most one latest rerun behind it.
    private func requestDeviceChangeRefresh() {
        guard let token = deviceRefreshGate.request() else { return }
        runDeviceChangeRefresh(token)
    }

    private func runInitialDeviceRefresh(_ token: LatestRefreshGate.Token) {
        let queue = engineQueue
        queue.async {
            // Launch is inventory only. A persisted Bluetooth microphone is a
            // remembered row, not consent to open its input profile and drop
            // the headset out of high-quality playback. Picker inspection or
            // an explicit Start performs the direct topology hydration later.
            let snapshot = Self.readDeviceRefreshSnapshot(
                selectedSourceUID: nil,
                selectedDestinationUID: nil,
                detailUIDs: [],
                readsDefaultInput: true)
            Task { @MainActor in
                self.finishInitialDeviceRefresh(snapshot, token: token)
            }
        }
    }

    private func finishInitialDeviceRefresh(
        _ snapshot: DeviceRefreshSnapshot, token: LatestRefreshGate.Token
    ) {
        guard deviceRefreshGate.accepts(token) else { return }

        // Inventory first, restored identities second, controls last. Selection
        // observers therefore see value-only metadata and do not schedule their
        // own duplicate HAL reads while the restore flag is held.
        applyDeviceInventory(snapshot)
        resolveRestoredDeviceIntent(defaultInputUID: snapshot.defaultInputUID)
        applyDeviceControlSnapshot(snapshot)
        deviceInventoryIsReady = true
        deviceWatcher?.establishBaseline(snapshot.inventoryIDs)
        refreshRestoredDeviceControlsIfSafe()

        if case .start(let next) = deviceRefreshGate.finish(token) {
            runDeviceChangeRefresh(next)
        }
        requestAutomaticStartIfConfigured()
    }

    private func refreshRestoredDeviceControlsIfSafe() {
        let configured = [selectedSource, selectedDestination].compactMap { $0 }
        guard !configured.isEmpty,
            configured.allSatisfy({
                Self.canProbeRestoredDeviceControls(transport: $0.transport)
            })
        else { return }
        refreshDeviceControls()
    }

    private func runDeviceChangeRefresh(_ token: LatestRefreshGate.Token) {
        let sourceUID = selectedSourceUID
        let destinationUID = selectedDestinationUID
        let detailUIDs = deviceDetailUIDs
        let queue = engineQueue
        queue.async {
            let snapshot = Self.readDeviceRefreshSnapshot(
                selectedSourceUID: sourceUID,
                selectedDestinationUID: destinationUID,
                detailUIDs: detailUIDs)
            Task { @MainActor in
                self.finishDeviceChangeRefresh(snapshot, token: token)
            }
        }
    }

    private func finishDeviceChangeRefresh(
        _ snapshot: DeviceRefreshSnapshot, token: LatestRefreshGate.Token
    ) {
        guard deviceRefreshGate.accepts(token) else { return }

        // A selection made while HAL was answering needs controls from the new
        // endpoints. Keep this answer from publishing stale hardware values and
        // turn the mismatch into the one latest rerun.
        let selectionIsCurrent =
            snapshot.selectedSourceUID == selectedSourceUID
            && snapshot.selectedDestinationUID == selectedDestinationUID
            && snapshot.detailUIDs == deviceDetailUIDs
        if selectionIsCurrent {
            handleDeviceChange(snapshot)
        } else {
            _ = deviceRefreshGate.request()
        }

        if case .start(let next) = deviceRefreshGate.finish(token) {
            runDeviceChangeRefresh(next)
        }
    }

    private func handleDeviceChange(_ snapshot: DeviceRefreshSnapshot) {
        let before = Set((inputDevices + outputDevices).map(\.uid))
        applyDeviceRefreshSnapshot(snapshot)
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
            let snapshot = await self.readDeviceRefreshSnapshotAsynchronously()
            guard !Task.isCancelled else { return }
            // The selected endpoints can change during the background read.
            // A mismatched control snapshot is not safe to publish.
            guard
                snapshot.selectedSourceUID == self.selectedSourceUID,
                snapshot.selectedDestinationUID == self.selectedDestinationUID,
                snapshot.detailUIDs == self.deviceDetailUIDs
            else {
                self.requestDeviceChangeRefresh()
                return
            }
            self.applyDeviceRefreshSnapshot(snapshot)
            guard self.isMissingDevice else { return }
            self.handleConfirmedDeviceLoss()
        }
    }

    private func readDeviceRefreshSnapshotAsynchronously() async -> DeviceRefreshSnapshot {
        let sourceUID = selectedSourceUID
        let destinationUID = selectedDestinationUID
        let detailUIDs = deviceDetailUIDs
        let queue = engineQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: Self.readDeviceRefreshSnapshot(
                        selectedSourceUID: sourceUID,
                        selectedDestinationUID: destinationUID,
                        detailUIDs: detailUIDs))
            }
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

    nonisolated static func capturePermissionWasDenied(_ error: Error) -> Bool {
        guard let tapError = error as? ProcessTapError else { return false }
        guard case .creationFailed(let status) = tapError else { return false }
        return status == kAudioDevicePermissionsError
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
        let permissionWasDenied: Bool
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
        var permissionWasDenied = false

        for application in captured {
            let tap: ProcessTap
            do {
                tap = try ProcessTap(
                    processIDs: application.processIDs,
                    muteBehavior: muteBehavior,
                    bundleIDs: [application.bundleID])
            } catch {
                refused.append(captureFailure(application.name, error))
                permissionWasDenied =
                    permissionWasDenied || capturePermissionWasDenied(error)
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
            permissionWasDenied: permissionWasDenied,
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
        guard deviceSelectionWork.isEmpty, configuredDevicesHaveCompleteTopology else {
            requestedStartAwaitsDeviceHydration = selftest
            if deviceSelectionWork.isEmpty { hydrateConfiguredDevicesAsynchronously() }
            return
        }
        requestedStartAwaitsDeviceHydration = nil
        autoStartNeedsPermissionReview = false
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
            lastError = sameDeviceMessage(source: source, destination: destination)
            return
        }
        guard source != destination else {
            startFailed = true
            lastError = sameDeviceMessage(source: source, destination: destination)
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
        // A monitor that is the destination is not a monitor, it is the mix.
        //
        // Left in, every route into the destination is also a route into the
        // monitor: the engine builds both, so the signal is summed twice — six
        // decibels of level nobody asked for — and `remapMonitorRoutes` claims
        // every main route as a monitor route, so the monitor fader drives what
        // the far end hears. Both are audible and neither says anything.
        //
        // Reachable because the picker now offers a device that is *currently*
        // the destination when the destination is also the source, which is a
        // pair that cannot start; change the source afterwards and the pair
        // becomes valid with the monitor sitting on top of it. So the invariant
        // is enforced where it matters — at the start — rather than trusted to
        // a list.
        let monitorUID = monitorDeviceUID == selectedDestinationUID ? nil : monitorDeviceUID
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
        routeUpdatesAreAccepted = false
        routeApplier.invalidate()
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
                    permissionWasDenied: preparation.permissionWasDenied,
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
                permissionWasDenied: preparation.permissionWasDenied,
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
        routeUpdatesAreAccepted = false
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
        PermissionCentre.shared.refreshSafeStatuses()
        if !report.owners.isEmpty {
            PermissionCentre.shared.recordSystemAudioAttempt(succeeded: true)
        } else if report.permissionWasDenied {
            PermissionCentre.shared.recordSystemAudioAttempt(succeeded: false)
        }
        monitorRouteIndices = report.didStart ? report.monitorRouteIndices : [:]
        isBusy = false
        isStarting = false

        if let failure = report.failure {
            isRunning = false
            routeUpdatesAreAccepted = false
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
        lighting.setSignalActive(true)
        routeUpdatesAreAccepted = true
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
        startPolling()
        // The output correction goes in *after* the route is up, not during.
        //
        // It was applied here in the middle of `start`, and the engine answered
        // `noOutputForTheBus` every time: at that moment the graph's output map
        // does not yet carry the destination, so the curve is installed against
        // a bus the graph cannot name and is dropped. Nothing tried again —
        // `rebuiltRoutes` is what re-applies after a publication and it only
        // runs for a route *edit*, which is exactly why dragging a cable put the
        // correction back and stopping and starting did not.
        //
        // Measured rather than reasoned: the flow check printed the two sides
        // together and they were the same device —
        // `curve on ["44-5E-CD-68-E3-69:output"], graph has the same` — so the
        // bus was never wrong, only early. Going through `rebuiltRoutes` uses
        // the one path that is known to work instead of a second copy of it.
        rebuiltRoutes()
        // Scoring, if somebody asked for it before there was a route to do it
        // with. This is the other half of `wantsScoring`: the wish is restored
        // at launch and spent here, the first time there is something to score.
        if wantsScoring, !isScoringSinging { isScoringSinging = true }
        // And the poll keeps trying for two seconds, because even here the
        // outputs are not always nameable yet.
        correctionRetriesLeft = Self.correctionRetries
        refreshHeadsetQualityAsynchronously()
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
        requestedStartAwaitsDeviceHydration = nil
        automaticStartAwaitsDeviceHydration = false
        // Invalidate before the busy guard. The engine may still be rendering,
        // but no route result from this lifetime may reach the interface or
        // trigger a fallback restart after Stop has been asked for.
        lighting.setSignalActive(false)
        routeUpdatesAreAccepted = false
        routeApplier.invalidate()
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
        outputPeak = 0
        outputClippedSamples = 0
        outputVerdict = .silent
        activeRoutes = []
        routeGains = []
        routeMutes = []
        pathQuality = nil
        isClockLocked = false
        routeUpdatesAreAccepted = false
        pendingTopologyRoutes = nil
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
    var inspectorTab: MainWindow.Inspector = .sound {
        didSet {
            guard oldValue != inspectorTab else { return }
            persist()
        }
    }

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
        midiControl.tearDown(waitUntilFinished: true)
        stopPolling()
        stopAnalysis()
        routeUpdatesAreAccepted = false
        routeApplier.invalidate()
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
        let permissionWasDenied: Bool
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
            if isStarting || effectSwapIsInFlight {
                restartIsPending = true
                if isStarting { currentStartIntent?.cancel() }
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
        guard !updated.isEmpty else { return false }
        applyPatch(updated)
        return true
    }

    // MARK: Polling

    private func startPolling() {
        stopPolling()
        // Twenty hertz: fast enough that a meter reads as live, slow enough that
        // an idle menu bar app is not waking the CPU sixty times a second.
        //
        // **A timer, not a task, and the flow check is why.**
        //
        // This was briefly a resident `@MainActor` task loop — statically
        // isolated, no dynamic executor check, which is what five crashes had
        // in common. It also broke twenty-seven flow assertions at a stroke,
        // all of the same shape: "cycles 24 just after, 24 a moment later",
        // "the meters are still redrawing", "the lyric sweep stayed live". The
        // audio was fine every time; the *reading* had stopped.
        //
        // The reason is the one thing a task cannot do. A `Timer` in
        // `.common` mode fires from a **nested run loop** — which is what an
        // application is inside while it tracks a drag, runs a modal, or does
        // the blocking work the flow check does between two samples. A
        // continuation cannot be serviced there: `await` resumes when the main
        // actor next returns to its own scheduler, and inside a nested run loop
        // it has not. So the poll simply stops for the duration, and everything
        // that reads a polled value reads a stale one.
        //
        // A twenty-hertz poll that pauses whenever the interface is busy is
        // worse than one that costs a dynamic check, so the check comes back.
        // Whether it is still dangerous is genuinely open: it stopped appearing
        // once the audio engine became lazy and the two `Canvas` closures
        // stopped reaching for `@MainActor` state, and this run — the whole
        // flow check, six minutes, every device switch — did not fault once.
        // `TODO.md` says so rather than pretending either way.
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            // Registered on the main run loop below, so this is the main
            // thread by construction and another task per meter frame would be
            // allocation and scheduling with no hop. `onTheMainThread` rather
            // than `MainActor.assumeIsolated` because this exact line is where
            // seven crash reports land — see the note there.
            onTheMainThread { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    /// Whether the twenty-hertz poll exists, for the flow check.
    ///
    /// Not visible any other way, and the defect it guards is invisible too: a
    /// missing timer looks exactly like a song that is not playing.
    var isPollingForCheck: Bool { levelTimer != nil }

    /// Runs the poll for as long as anything needs it.
    ///
    /// Two things do: a route, whose meters and cycle counter are the reason
    /// twenty hertz was chosen, and the stage, whose words move whether or not
    /// any audio is being routed. Neither owns the timer, so neither may stop
    /// it while the other still wants it.
    private func keepThePollAlive() {
        if isRunning || isSingingVisible {
            if levelTimer == nil { startPolling() }
        } else {
            stopPolling()
        }
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

    /// Alternating storage for route meters.
    ///
    /// A published Swift array shares its allocation with Observation. Filling
    /// that same array on the next poll would therefore trigger copy-on-write.
    /// Fill the other buffer instead; once it is published, the previous one is
    /// uniquely owned here again and can be reused on the following frame.
    @ObservationIgnored private var telemetryRoutePeaksA: [Float] = []
    @ObservationIgnored private var telemetryRoutePeaksB: [Float] = []
    @ObservationIgnored private var telemetryUsesFirstBuffer = true

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
        guard Self.shouldPublish(current: self[keyPath: keyPath], incoming: value) else {
            pollCost.unchanged += 1
            return
        }
        self[keyPath: keyPath] = value
    }

    /// Pure decision behind every high-frequency publication.
    ///
    /// Kept reachable to tests so a minute of stable poll input can assert an
    /// exact publication count without constructing audio hardware.
    nonisolated static func shouldPublish<Value: Equatable>(
        current: Value, incoming: Value
    ) -> Bool {
        current != incoming
    }

    /// The same gate for one observable array element.
    ///
    /// Meter holds are intentionally mutable arrays, but Observation sees a
    /// subscript write as a publication of the whole property. At silence the
    /// old loop wrote zero back to every route twenty times a second.
    private func publish<Value: Equatable>(
        _ value: Value,
        at index: Int,
        to keyPath: ReferenceWritableKeyPath<RouterModel, [Value]>
    ) {
        pollCost.writes += 1
        guard
            Self.shouldPublish(
                current: self[keyPath: keyPath][index],
                incoming: value)
        else {
            pollCost.unchanged += 1
            return
        }
        self[keyPath: keyPath][index] = value
    }

    /// The same gate for one observable dictionary entry.
    ///
    /// A compressor at rest reports zero on every poll. Writing that zero into
    /// its dictionary still invalidated the complete effects panel.
    private func publish<Key: Hashable, Value: Equatable>(
        _ value: Value?,
        for key: Key,
        to keyPath: ReferenceWritableKeyPath<RouterModel, [Key: Value]>
    ) {
        pollCost.writes += 1
        guard
            Self.shouldPublish(
                current: self[keyPath: keyPath][key],
                incoming: value)
        else {
            pollCost.unchanged += 1
            return
        }
        self[keyPath: keyPath][key] = value
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
        engineQueue.async {
            let quality = engine.pathQuality
            let latency =
                destination?.latencyFrames(scope: kAudioObjectPropertyScopeOutput) ?? 0
            let monitorLatency =
                monitor?.latencyFrames(scope: kAudioObjectPropertyScopeOutput) ?? 0
            Task { @MainActor in
                self.pathQualityReadInFlight = false
                // A queued read can finish after Stop. Publishing that route's
                // verdict again would resurrect a stale "bit-exact" pill over
                // an idle application.
                guard self.isRunning else { return }
                self.publish(quality, to: \.pathQuality)
                self.publish(latency, to: \.destinationLatencyFrames)
                self.publish(monitorLatency, to: \.monitorLatencyFrames)
            }
        }
    }

    private func poll() {
        guard isRunning else {
            // The words are not the router's.
            //
            // This whole poll was behind that guard, and everything the stage
            // needs is in it: the position of the song, the line being sung and
            // the now-playing state. So with the route stopped the words simply
            // did not move, and using this application as a lyrics player or a
            // KTV machine meant first routing audio somewhere for no reason.
            //
            // Nothing else runs here. Meters, the cycle counter, path quality,
            // recording, ducking and the source taps are all questions about a
            // graph that is not there, and asking them would cost the poll
            // twenty times a second to answer "no route" twenty times a second.
            pollTheSongOnly()
            return
        }
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
        // The output correction, if it has not landed yet.
        //
        // A graph is published before its output map carries the destination,
        // so the install in `start` is answered with `noOutputForTheBus` and
        // the curve is dropped — and until this, nothing ever asked again. A
        // route *edit* re-applied through `rebuiltRoutes` and put it back,
        // which is why dragging a cable fixed it and stopping and starting did
        // not: somebody's headphone correction survived everything except the
        // one thing they do most.
        //
        // Bounded by its own success. Once the correction reaches an output,
        // `appliedToGraph` records it and the condition is false for the rest
        // of the session; with no curve on any live bus it is false from the
        // start. So the ordinary cost is one set membership test per poll,
        // twenty times a second, and the retry runs for the handful of polls
        // between the graph appearing and its outputs being nameable.
        lap("corrections") {
            // A bounded number of attempts, and one integer to decide it.
            //
            // The window this exists for is the handful of polls between a
            // graph being published and its outputs being nameable. Retrying
            // for ever costs 21 µs a poll — a fifth of the whole idle poll —
            // on any machine where the correction legitimately has nowhere to
            // go, which is every machine with no curve on a live bus. Guarding
            // on `busesWithACurve` was worse: it *builds* the curves to count
            // them.
            //
            // Two seconds of trying. If the graph has not named its outputs by
            // then it is not going to, and a route edit or a chain swap will
            // re-apply through `rebuiltRoutes` when one happens.
            guard correctionRetriesLeft > 0,
                !appliedToGraph.contains(.headphoneCorrection)
            else { return }
            correctionRetriesLeft -= 1
            // Submitted, never flushed. `applyCorrections` waits on the engine
            // queue, and this runs on the main actor twenty times a second —
            // so while `start` held that queue the poll stopped, and the check
            // that changes the buffer size mid-start read `-1 frames` because
            // it asked during the stall. The whole of `LatestValueApplier`
            // exists so that control changes never take an engine lock on
            // MainActor; the retry has to obey that like everything else.
            //
            // Coalescing is right here too: this fires on consecutive polls
            // until the graph can name the bus, and only the last one matters.
            scheduleCorrections()
        }
        var telemetry: RoutingEngine.TelemetryValues?
        lap("telemetry") {
            if telemetryUsesFirstBuffer {
                telemetry = engine.readTelemetry(into: &telemetryRoutePeaksA)
            } else {
                telemetry = engine.readTelemetry(into: &telemetryRoutePeaksB)
            }
        }
        if let telemetry {
            let routePeaks =
                telemetryUsesFirstBuffer ? telemetryRoutePeaksA : telemetryRoutePeaksB
            // One coherent read and one lock acquisition. A busy graph means
            // "hold the last frame", not "publish silence": the latter made
            // every meter blink during an effect or device swap and read two
            // mutable diagnostic arrays outside their protecting lock.
            let routePeaksChanged = routePeaks != levels
            lap("routePeaks") { publish(routePeaks, to: \.levels) }
            lap("refreshPeaks") { refreshPeaks(routePeaks) }
            // An unchanged scratch buffer is still uniquely owned, so keep
            // filling it. A published one is shared with `levels`; switch to
            // the buffer that became unique when `levels` released it.
            if routePeaksChanged { telemetryUsesFirstBuffer.toggle() }
            lap("outputPeak") { publish(telemetry.outputPeak, to: \.outputPeak) }
            lap("outputVerdict") {
                publish(
                    Self.classifyOutput(
                        peak: telemetry.outputPeak,
                        clippedSamples: telemetry.outputClippedSamples),
                    to: \.outputVerdict)
            }
            lap("failedPlugins") {
                publish(telemetry.failedPlugins, to: \.failedPlugins)
            }
            lap("droppedMonitor") {
                if let dropped = telemetry.droppedMonitor,
                    dropped.uid == monitorDeviceUID
                {
                    monitorWasDropped(dropped)
                }
            }
            lap("clipped") {
                publish(telemetry.outputClippedSamples, to: \.outputClippedSamples)
            }
        }
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
        // Drained every poll whether or not the analysis panel is open. The ring
        // is finite, so a consumer that only ran while a view was visible would
        // hand the loudness meter a stream with holes in it and report an
        // integrated figure for audio it never saw.
        lap("analysisNeeds") { refreshAnalysisNeeds() }
        lap("analyser") {
            if let analyser, !analyser.isIdle {
                analyser.drain(from: engine)
                publish(analyser.reading(), to: \.analysis)
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
        lap("lighting") {
            if lighting.needsSignalUpdate {
                lighting.update(level: levels.max() ?? 0, isMuted: isInputMuted)
            }
        }
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
    /// Reused across polls only while a source tap exists. Two seconds at
    /// 48 kHz is more than the ring behind it holds, so a drain is never cut
    /// short by this buffer.
    @ObservationIgnored private var transcriptScratch = SourceTapScratch()
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

    /// Compares a cached source identity without materialising a mapped array.
    nonisolated static func sourceUIDsMatch(
        groups: [SourceGroup], prefixCount: Int, cached: [String]
    ) -> Bool {
        guard prefixCount >= 0, prefixCount <= groups.count,
            cached.count == prefixCount
        else { return false }
        for index in 0..<prefixCount where groups[index].uid != cached[index] {
            return false
        }
        return true
    }

    /// Whether the open rings can serve this request without touching the
    /// engine. A zero count is never reusable: it is the exact stale state a
    /// full route stop used to leave behind.
    nonisolated static func reusableSourceTapCount(
        isOpen: Bool, openedCount: Int, groups: [SourceGroup], cached: [String]
    ) -> Int? {
        guard isOpen, openedCount > 0,
            sourceUIDsMatch(
                groups: groups, prefixCount: groups.count, cached: cached)
        else { return nil }
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
        if let count = Self.reusableSourceTapCount(
            isOpen: sourceTapsOpen, openedCount: openedSourceTapCount,
            groups: groups, cached: sourceTapsFor)
        {
            return count
        }
        let first = groups.compactMap(\.routes.first)
        guard !first.isEmpty else { return 0 }
        let uids = groups.map(\.uid)
        if sourceTapsOpen { engine.stopTranscriptTaps() }
        invalidateSourceTaps()
        musicRecognition?.reset(releasingBuffers: true)
        recognisedApplication = nil
        recognitionSourceUID = nil
        musicRecognitionProblem = nil
        let opened = engine.startTranscriptTaps(routes: first)
        sourceTapsOpen = opened > 0
        sourceTapsFor = opened > 0 ? uids : []
        openedSourceTapCount = opened
        if opened > 0 { transcriptScratch.activate() }
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
        transcriptScratch.release()
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
                // An idle route releases this storage, and the accessor then
                // hands out an empty buffer whose base address is nil — which
                // this force-unwrapped. The poll timer only has to fall in the
                // window where the scratch is already gone and the transcribers
                // are not yet cleared, and the main thread dies: "Unexpectedly
                // found nil while unwrapping an Optional value", in the middle
                // of a line of flow-check output.
                guard let base = buffer.baseAddress, buffer.count > 0 else { return }
                let taken = engine.drainTranscript(
                    slot, into: base, capacity: buffer.count)
                guard taken > 0 else { return }
                let borrowed = UnsafeBufferPointer(start: base, count: taken)
                if slot < singerTracks.count {
                    // Keep the tuner live while paused without moving the score
                    // clock or recording the voice as part of the performance.
                    let advancesTimeline = !isScoringSinging || trackClock.isPlaying
                    singerTracks[slot].add(
                        borrowed, advancesTimeline: advancesTimeline)
                }

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
                        recognitionService().add(owned, sampleRate: rate)
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
        guard slot < sourceTapsFor.count else { return nil }
        // Loops rather than `first(where:)`, `compactMap` and `contains`, and
        // this is not a style preference. Handing a main-actor-isolated closure
        // to a non-isolated generic makes the compiler insert a *dynamic*
        // executor check at the conversion, and in this process those faults:
        // `EXC_BAD_ACCESS at 0x1e` inside `swift_task_isMainExecutorImpl`,
        // reached only when the check's fast path has already failed. Nine
        // crash reports, every one of them at a dynamic executor check, and
        // this function is the hottest one in the twenty-hertz poll.
        //
        // What is ruled out, each with an experiment rather than an argument:
        // memory corruption (`MallocScribble`, `MallocPreScribble` and
        // `MallocGuardEdges` leave the faulting address at exactly `0x1e`), the
        // toolchain and the syntax (a reproduction with this shape, this
        // toolchain and this timer survives 8,400 checks), and `AVAudioEngine`
        // (the same reproduction with a file playing through a time-pitch unit
        // survives too). A loop needs no conversion, so it needs no check.
        var found: SourceGroup? = nil
        let wanted = sourceTapsFor[slot]
        for group in sourceGroups where group.uid == wanted {
            found = group
            break
        }
        guard let group = found,
            let route = representative(of: group),
            let application = self.application(of: route)
        else { return nil }
        let scripted = ["com.apple.Music", "com.spotify.client"]
        let checksScriptedPlayers = Self.recognisesScriptedPlayers
        guard checksScriptedPlayers || !scripted.contains(application.bundleID) else {
            return nil
        }
        // A signature is one recording. Feeding two captured applications into
        // one session would interleave their blocks and guarantee either no
        // match or, worse, metadata for whichever happened to dominate. Keep
        // one stable source until the route changes, preferring one CoreAudio
        // says is actually playing.
        if recognitionSourceUID == nil {
            // Loops, for the reason above.
            var firstAny: String? = nil
            var firstPlaying: String? = nil
            for candidate in sourceGroups {
                guard let route = representative(of: candidate),
                    let app = self.application(of: route)
                else { continue }
                var isScripted = false
                for identifier in scripted where identifier == app.bundleID {
                    isScripted = true
                    break
                }
                guard checksScriptedPlayers || !isScripted else { continue }
                if firstAny == nil { firstAny = candidate.uid }
                if app.isPlaying, firstPlaying == nil { firstPlaying = candidate.uid }
            }
            recognitionSourceUID = firstPlaying ?? firstAny
        }
        guard recognitionSourceUID == group.uid else { return nil }
        return application
    }

    /// Creates the Shazam catalogue session at the first block that can use it,
    /// not when a KTV view happens to close or a scripted player is selected.
    private func recognitionService() -> MusicRecognition {
        if let musicRecognition { return musicRecognition }
        let service = MusicRecognition { [weak self] result in
            self?.receiveMusicRecognition(result)
        }
        musicRecognition = service
        return service
    }

    private func releaseMusicRecognition() {
        musicRecognition?.reset(releasingBuffers: true)
        musicRecognition = nil
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

    /// True while the diagnostic sound label is wanted.
    ///
    /// Loudness, spectrum and pitch are useful whenever the analysis card is
    /// visible. The classifier is different: constructing it loads Apple's
    /// CoreML sound model and keeping it fed costs CPU. It therefore stays
    /// opt-in unless automatic levelling or ducking needs the verdict to make
    /// an audio decision.
    var isSoundIdentificationEnabled = false {
        didSet {
            guard oldValue != isSoundIdentificationEnabled else { return }
            refreshAnalysisNeeds()
            persist()
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
            onTheMainThread { self?.calibrationTick() }
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
        duckingAllowedGate.reset()
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
    @ObservationIgnored private var duckingAllowedGate = DuckingAllowedGate()

    /// True while the model's verdict still counts.
    var isSpeechRecent: Bool {
        guard let lastSpeechAt else { return false }
        return Date().timeIntervalSince(lastSpeechAt) < Self.speechHold
    }

    private func refreshDucking() {
        guard isDucking else { return }
        if analyser?.classifier?.hearsSpeech == true { lastSpeechAt = Date() }
        let allowed = isSpeechRecent
        guard duckingAllowedGate.shouldSend(allowed) else { return }
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
        publish(offset, to: \.autoLevelOffset)

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
        let wanted = Self.analysisNeeds(
            isAnalysisVisible: isAnalysisVisible,
            identifiesSounds: isSoundIdentificationEnabled,
            isSingingVisible: isSingingVisible,
            isAutoLevelling: isAutoLevelling,
            isDucking: isDucking)

        guard wanted != analysisNeeds else { return }
        analysisNeeds = wanted
        analyser?.require(wanted)
        let analysisIsEnabled = !wanted.isEmpty
        applyLiveControl { $0.setAnalysisEnabled(analysisIsEnabled) }
        if wanted.isEmpty { analysis = .silent }
    }

    nonisolated static func analysisNeeds(
        isAnalysisVisible: Bool,
        identifiesSounds: Bool,
        isSingingVisible: Bool,
        isAutoLevelling: Bool,
        isDucking: Bool
    ) -> SignalAnalyser.Needs {
        var wanted: SignalAnalyser.Needs = []
        if isAnalysisVisible { wanted.formUnion([.loudness, .spectrum, .pitch]) }
        if isAnalysisVisible, identifiesSounds { wanted.insert(.classification) }
        // Singing needs the pitch and the spectrum for the key of what is
        // playing — no sound model, which is the expensive one.
        if isSingingVisible { wanted.formUnion([.pitch, .spectrum]) }
        if isAutoLevelling { wanted.formUnion([.loudness, .classification]) }
        if isDucking { wanted.formUnion([.classification]) }
        return wanted
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
    /// It is deliberately **not** remembered across launches, for the same
    /// reason: a hook that survives a relaunch is a machine that is quietly
    /// slower with nothing on screen to say why. Every other switch somebody
    /// throws is persisted; this one is the exception, and this is the note
    /// saying so rather than an omission that looks like one.
    var watchesIOAllocations = false {
        didSet {
            guard oldValue != watchesIOAllocations else { return }
            if watchesIOAllocations, isDebugBuild {
                // The hook would count Swift's debug checking hundreds of
                // thousands of times a second and slow every allocator call in
                // the process while producing no shipping-code evidence.
                watchesIOAllocations = false
                return
            }
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

    /// The image currently installed into AppKit.
    ///
    /// Restore and status-item installation both ask for the icon. On systems
    /// where `NSApp` already exists during model construction, the first call
    /// is not the no-op the launch code once assumed: AppKit rasterises and
    /// retains another full backing image. The style name is enough to make
    /// this operation idempotent without retaining a second `NSImage` here.
    @ObservationIgnored private var appliedIconStyle: String?

    nonisolated static func shouldApplyIconStyle(
        _ requested: String, previouslyApplied: String?,
        applicationIsAvailable: Bool
    ) -> Bool {
        applicationIsAvailable && requested != previouslyApplied
    }

    func applyIconStyle() {
        guard let application = NSApp,
            Self.shouldApplyIconStyle(
                iconStyle, previouslyApplied: appliedIconStyle,
                applicationIsAvailable: true)
        else { return }
        application.applicationIconImage = YunIconBadge.image(
            size: 512, style: YunIconBadge.style(named: iconStyle))
        appliedIconStyle = iconStyle
    }

    /// IO cycles completed. Only used by the flow check, which needs to know
    /// whether audio survived a change rather than merely whether the model
    /// still says it is running.
    var cycleCountForDiagnostics: UInt64 { engine.cycleCount }

    /// The same counter, but able to say it does not know.
    ///
    /// The flow check compares two readings taken seconds apart, and a reading
    /// that failed to take the lock is not a smaller number — it is no number.
    /// See `RoutingEngine.cycleCountIfKnown`.
    var cycleCountIfKnownForDiagnostics: UInt64? { engine.cycleCountIfKnown }

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
