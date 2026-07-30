import CoreMIDI
import Foundation
import Observation
import YunAudioControl
import YunDesign

/// Physical control surfaces.
///
/// A Stream Deck key is already served by the URL scheme, and a button is all a
/// URL can be. A fader is a different thing: it sends a continuous value, it
/// has a position of its own, and that position is almost never the one the
/// software is at. So the two halves here are the message decoding and the
/// *takeover* rule, and both are pure functions — there is rarely a controller
/// plugged into the machine this is written on, and a feature that can only be
/// tested on somebody else's desk is a feature nobody can change.

// MARK: - Messages

/// One channel-voice message, decoded.
struct MIDIMessage: Equatable, Sendable {
    /// Which control produced it. A knob sends a control change, a pad sends a
    /// note, and a bend wheel is neither — fourteen bits rather than seven,
    /// which is the only reason it is worth naming separately.
    enum Kind: Hashable, Sendable {
        case controlChange(UInt8)
        case note(UInt8)
        case pitchBend
    }

    /// Zero-based, as it is on the wire. Everything a person reads adds one.
    var channel: UInt8
    var kind: Kind
    /// The controller value or the note's velocity, 0…127, or the bend's
    /// fourteen bits.
    var value: UInt16
    /// False for a note-off. Also false for the note-on with velocity zero
    /// that most keyboards send instead of one — a pad bound to mute would
    /// otherwise stick down for ever.
    var isOn: Bool

    /// What a binding is made of: the message without its value, which is the
    /// part that identifies the physical control.
    var address: MIDIAddress { MIDIAddress(channel: channel, kind: kind) }

    /// Where the control is sitting, 0…1.
    var position: Float {
        Float(value) / Float(kind == .pitchBend ? 16383 : 127)
    }

    /// Reads a message out of one Universal MIDI Packet word.
    ///
    /// Message type 2 is a MIDI 1.0 channel voice message. The input port is
    /// created with the 1.0 protocol, so CoreMIDI translates a MIDI 2.0
    /// controller down to this shape on the way in and there is one thing to
    /// decode rather than two.
    static func decode(_ word: UInt32) -> MIDIMessage? {
        guard word >> 28 == 2 else { return nil }
        let status = UInt8((word >> 20) & 0xF)
        let channel = UInt8((word >> 16) & 0xF)
        let first = UInt8((word >> 8) & 0x7F)
        let second = UInt8(word & 0x7F)

        switch status {
        case 0x8:
            return MIDIMessage(
                channel: channel, kind: .note(first), value: UInt16(second), isOn: false)
        case 0x9:
            return MIDIMessage(
                channel: channel, kind: .note(first), value: UInt16(second),
                isOn: second > 0)
        case 0xB:
            return MIDIMessage(
                channel: channel, kind: .controlChange(first), value: UInt16(second),
                isOn: true)
        case 0xE:
            // Fourteen bits, least significant seven first.
            return MIDIMessage(
                channel: channel, kind: .pitchBend,
                value: UInt16(first) | (UInt16(second) << 7), isOn: true)
        default:
            return nil
        }
    }

    /// A knob turning.
    static func cc(_ controller: UInt8, _ value: UInt16, channel: UInt8 = 0) -> MIDIMessage {
        MIDIMessage(
            channel: channel, kind: .controlChange(controller), value: value, isOn: true)
    }

    /// A pad struck, or released when the velocity is zero.
    static func note(_ number: UInt8, velocity: UInt16, channel: UInt8 = 0) -> MIDIMessage {
        MIDIMessage(
            channel: channel, kind: .note(number), value: velocity, isOn: velocity > 0)
    }

    /// The same message as a UMP word on group 0.
    ///
    /// The inverse of `decode`, and it exists so that the CoreMIDI half can be
    /// driven with real packets rather than with a shortcut around it.
    var word: UInt32 {
        // Message type 2 on group 0; the status nibble sits above the channel
        // nibble, which is the one place this is easy to get backwards.
        let head: UInt32 = 0x2000_0000 | UInt32(channel & 0xF) << 16
        switch kind {
        case .controlChange(let controller):
            return head | 0x00B0_0000 | UInt32(controller & 0x7F) << 8
                | UInt32(value & 0x7F)
        case .note(let number):
            let status: UInt32 = isOn ? 0x0090_0000 : 0x0080_0000
            return head | status | UInt32(number & 0x7F) << 8 | UInt32(value & 0x7F)
        case .pitchBend:
            return head | 0x00E0_0000 | UInt32(value & 0x7F) << 8
                | UInt32((value >> 7) & 0x7F)
        }
    }
}

/// A physical control, without its value.
///
/// This is what gets written down. Two bindings may never share one, which is
/// the whole reason it is a separate type: a dictionary keyed by target cannot
/// say anything about the other direction on its own.
struct MIDIAddress: Hashable, Sendable {
    var channel: UInt8
    var kind: MIDIMessage.Kind

    /// A short flat form, because these live in the preferences file and a
    /// file somebody may have to read by hand is worth keeping legible.
    var storageKey: String {
        switch kind {
        case .controlChange(let controller): "\(channel).cc.\(controller)"
        case .note(let number): "\(channel).note.\(number)"
        case .pitchBend: "\(channel).bend"
        }
    }

    init(channel: UInt8, kind: MIDIMessage.Kind) {
        self.channel = channel
        self.kind = kind
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let channel = UInt8(parts[0]), channel < 16 else {
            return nil
        }
        switch (parts[1], parts.count) {
        case ("cc", 3):
            guard let controller = UInt8(parts[2]), controller < 128 else { return nil }
            self.init(channel: channel, kind: .controlChange(controller))
        case ("note", 3):
            guard let number = UInt8(parts[2]), number < 128 else { return nil }
            self.init(channel: channel, kind: .note(number))
        case ("bend", 2):
            self.init(channel: channel, kind: .pitchBend)
        default:
            return nil
        }
    }

    /// What the row says it is bound to. Channels are numbered from one here
    /// and nowhere else, because that is what is printed on the hardware.
    var displayName: String {
        switch kind {
        case .controlChange(let controller):
            String(format: loc("CC %d · ch %d"), Int(controller), Int(channel) + 1)
        case .note(let number):
            String(format: loc("Note %d · ch %d"), Int(number), Int(channel) + 1)
        case .pitchBend:
            String(format: loc("Bend · ch %d"), Int(channel) + 1)
        }
    }
}

// MARK: - What can be bound

/// Something a physical control can drive.
enum MIDITarget: Hashable, Sendable {
    /// The three levels that are not per-source.
    enum Fader: String, CaseIterable, Hashable, Sendable {
        case master, input, monitor
    }

    case fader(Fader)
    case sourceFader(uid: String)
    case sourceMute(uid: String)
    /// A press, carried out through `RemoteCommand`.
    ///
    /// Stored as the URL rather than as the command, so the list of things a
    /// pad can do and the list a Stream Deck key can do are the same list
    /// rather than two that drift. Anything the scheme learns to answer is
    /// bindable the same day.
    case command(url: String)

    /// True when the control's value is a position rather than a press, which
    /// is the difference that soft takeover exists for.
    var isContinuous: Bool {
        switch self {
        case .fader, .sourceFader: true
        case .sourceMute, .command: false
        }
    }

    var storageKey: String {
        switch self {
        case .fader(let which): "fader:\(which.rawValue)"
        case .sourceFader(let uid): "source.fader:\(uid)"
        case .sourceMute(let uid): "source.mute:\(uid)"
        case .command(let url): "command:\(url)"
        }
    }

    init?(storageKey: String) {
        guard let separator = storageKey.firstIndex(of: ":") else { return nil }
        let head = String(storageKey[storageKey.startIndex..<separator])
        let tail = String(storageKey[storageKey.index(after: separator)...])
        guard !tail.isEmpty else { return nil }
        switch head {
        case "fader":
            guard let which = Fader(rawValue: tail) else { return nil }
            self = .fader(which)
        case "source.fader": self = .sourceFader(uid: tail)
        case "source.mute": self = .sourceMute(uid: tail)
        case "command":
            // Refused rather than kept, because a URL the scheme no longer
            // understands is a row that would sit in the window looking bound
            // and doing nothing.
            guard let url = URL(string: tail), RemoteCommand.parse(url) != nil else {
                return nil
            }
            self = .command(url: tail)
        default: return nil
        }
    }

    /// What the row is called. A per-source target names the control rather
    /// than the source, because the source is the row it sits under.
    var title: String {
        switch self {
        case .fader(.master): loc("Master level")
        case .fader(.input): loc("Input level")
        case .fader(.monitor): loc("Monitor level")
        case .sourceFader: loc("Fader")
        case .sourceMute: loc("Mute")
        case .command(let url):
            URL(string: url).flatMap(RemoteCommand.parse)?.title ?? url
        }
    }

    /// Everything the preferences window offers that is not per-source.
    static var offered: [MIDITarget] {
        Fader.allCases.map(MIDITarget.fader)
            + RemoteCommand.bindable.map { .command(url: $0.url.absoluteString) }
    }
}

// MARK: - Levels

/// How a controller position becomes a level.
enum MIDIScale {
    /// The range every fader in this application uses: silence at the bottom
    /// of the travel, twelve decibels of make-up at the top. Linear in
    /// decibels, because that is what the on-screen fader is and a knob that
    /// disagreed with the fader beside it would be worse than no knob.
    ///
    /// Written out rather than taken from `RouterModel.minimumDecibels`, which
    /// is main-actor isolated and cannot be a default value here. The two are
    /// asserted equal instead, so the pair cannot drift silently.
    static let decibels: ClosedRange<Float> = -40...12

    static func decibels(fromPosition position: Float) -> Float {
        let clamped = min(1, max(0, position))
        return decibels.lowerBound
            + clamped * (decibels.upperBound - decibels.lowerBound)
    }

    static func position(fromDecibels value: Float) -> Float {
        let span = decibels.upperBound - decibels.lowerBound
        return min(1, max(0, (value - decibels.lowerBound) / span))
    }
}

// MARK: - Soft takeover

/// Whether a hardware control is allowed to move the software one yet.
///
/// A motorised fader does not need this; nothing else on a desk is motorised.
/// A knob physically at the bottom and a software fader at −6 dB disagree, and
/// the first message after the knob is touched would slam the level to silence.
/// So the hardware does nothing until it *passes through* where the software
/// already is, and only then takes the lead.
struct MIDIPickup: Equatable, Sendable {
    /// Where the control was last seen, so a sweep past the software value can
    /// be recognised. A single message says only where the knob is; two say
    /// which way it is going.
    var lastControl: Float?
    /// What this binding last wrote. Nil means it is not in charge.
    var delivered: Float?

    /// One controller step. A seven-bit control cannot land closer than this
    /// to an arbitrary software position, so demanding better than a step
    /// would mean a fader at −6.3 dB could never be picked up at all.
    static let tolerance: Float = 1.0 / 127

    var isEngaged: Bool { delivered != nil }

    /// What the control should move the software value to, or nil to leave it
    /// alone.
    static func resolve(
        control: Float, software: Float, state: inout MIDIPickup
    ) -> Float? {
        defer { state.lastControl = control }

        // Already in charge, and the software value is still where this
        // binding put it — so nothing else has moved it and the hardware keeps
        // the lead without having to re-earn it every message.
        if let delivered = state.delivered, abs(delivered - software) <= tolerance {
            state.delivered = control
            return control
        }

        // Not in charge: either it never was, or somebody dragged the fader on
        // screen and the two have parted company again. Take over only where
        // they agree — the control arrives at the software value, or it sweeps
        // across it since the last message.
        let sweeps =
            state.lastControl.map { ($0 - software) * (control - software) < 0 } ?? false
        guard abs(control - software) <= tolerance || sweeps else {
            state.delivered = nil
            return nil
        }
        state.delivered = control
        return control
    }
}

// MARK: - What a message does

/// The decision a message produces, before anything has been touched.
///
/// Separated from carrying it out so that the whole rule — note-off does
/// nothing, a switch acts on the press, a knob waits for pickup — can be
/// asserted without a controller, a model or an audio device in the room.
enum MIDIAction: Equatable, Sendable {
    case ignore
    /// Move a continuous control to this position, 0…1.
    case setPosition(Float)
    /// Act, once.
    case press
}

extension MIDIAction {
    /// Works out what a bound message should do.
    ///
    /// - Parameters:
    ///   - message: the message that arrived.
    ///   - target: what it is bound to.
    ///   - softwarePosition: where that target currently sits, 0…1. Ignored
    ///     for anything that is not continuous.
    ///   - pickup: the takeover state for this binding, updated in place.
    /// - Returns: what to do.
    static func decide(
        for message: MIDIMessage, target: MIDITarget, softwarePosition: Float,
        pickup: inout MIDIPickup
    ) -> MIDIAction {
        // A note binding acts on the press. A note-off carries a velocity like
        // any other message, and treating it as one is how a pad bound to mute
        // unmutes the instant it is let go.
        guard message.isOn else { return .ignore }

        guard target.isContinuous else {
            // A footswitch or a pad wired as a controller sends 127 on the way
            // down and 0 on the way up. Only the first of those is somebody
            // asking for something.
            if case .controlChange = message.kind, message.value < 64 { return .ignore }
            return .press
        }

        guard
            let position = MIDIPickup.resolve(
                control: message.position, software: softwarePosition, state: &pickup)
        else { return .ignore }
        return .setPosition(position)
    }
}

// MARK: - The client

/// Collapses one physical MIDI change's notification burst before MainActor.
///
/// CoreMIDI calls from its own thread. Locking this two-state gate there means
/// a thousand notifications allocate one MainActor task, not a thousand tasks
/// that later discover only one of them had work to do.
final class MIDISourceRefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isScheduled = false

    func request() -> Bool {
        lock.withLock {
            guard !isScheduled else { return false }
            isScheduled = true
            return true
        }
    }

    func finish() {
        lock.withLock { isScheduled = false }
    }
}

/// The CoreMIDI half: one client, one input port, every source connected.
///
/// Every source rather than a chosen one. A control surface is a single
/// physical thing on somebody's desk and asking which port it is on is a
/// question they should not have to answer; a learn button that watches
/// everything can answer it for them.
@Observable
@MainActor
final class MIDIController {
    struct Diagnostic: Equatable {
        let message: MIDIMessage
        let receivedAt: Date
    }

    /// What each control drives, by what it drives.
    private(set) var bindings: [MIDITarget: MIDIAddress] = [:]

    /// The row waiting to be told which control it belongs to, if any.
    var learningTarget: MIDITarget? {
        didSet {
            guard oldValue != learningTarget else { return }
            publishClientDemand()
        }
    }

    /// The last message that arrived at all, bound or not.
    ///
    /// The whole point of showing it is the case where nothing is bound yet:
    /// without it, a controller that is not connected and a controller that is
    /// connected but sending on another channel look identical.
    private(set) var lastDiagnostic: Diagnostic?
    var lastMessage: MIDIMessage? { lastDiagnostic?.message }
    var lastMessageAt: Date? { lastDiagnostic?.receivedAt }

    /// The names CoreMIDI is offering, for the same reason.
    private(set) var sourceNames: [String] = []

    /// Why the client could not be created, if it could not.
    private(set) var startupError: String?

    /// Where a continuous target currently sits, 0…1. Supplied by the model.
    var softwarePosition: ((MIDITarget) -> Float)?
    /// Carries a decision out. Supplied by the model.
    var perform: ((MIDITarget, MIDIAction) -> Void)?
    /// Called whenever the bindings change, so they get written down.
    var onBindingsChanged: (() -> Void)?
    /// Supplied by the application so pure controller tests never open CoreMIDI.
    var onClientDemandChanged: ((Bool) -> Void)?

    @ObservationIgnored private var pickups: [MIDITarget: MIDIPickup] = [:]
    /// Updated for every event without invalidating a view. Opening the MIDI
    /// page publishes it immediately, so hiding diagnostics never loses the
    /// answer to "did this controller send anything?".
    @ObservationIgnored private var latestDiagnostic: Diagnostic?
    @ObservationIgnored private var lastDiagnosticPublicationNanoseconds: UInt64?
    @ObservationIgnored private(set) var diagnosticPublications = 0
    /// Only the MIDI preferences page reads this information. Control delivery
    /// remains live regardless of whether that page exists.
    @ObservationIgnored var diagnosticsAreVisible = false {
        didSet {
            guard oldValue != diagnosticsAreVisible else { return }
            if diagnosticsAreVisible {
                publishLatestDiagnostic(now: DispatchTime.now().uptimeNanoseconds)
            } else {
                lastDiagnosticPublicationNanoseconds = nil
            }
            publishClientDemand()
        }
    }
    /// The receive path runs for every controller message. Bindings are shown
    /// by target, but incoming messages arrive by address; keeping both indices
    /// avoids scanning every bound fader for every MIDI word.
    @ObservationIgnored private var targetsByAddress: [MIDIAddress: MIDITarget] = [:]
    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var port = MIDIPortRef()
    @ObservationIgnored private var connected: Set<MIDIEndpointRef> = []
    @ObservationIgnored private let sourceRefreshGate = MIDISourceRefreshGate()
    @ObservationIgnored private var sourceRefreshTask: Task<Void, Never>?

    // MARK: Bindings

    func binding(for target: MIDITarget) -> MIDIAddress? { bindings[target] }

    /// Binds a control, taking it off whatever else held it.
    ///
    /// Stealing rather than refusing. One message driving two things is the
    /// failure worth preventing — a knob that both fades the master and toggles
    /// recording is not a configuration anybody meant — and refusing would
    /// leave somebody guessing which of a dozen rows already owns CC 7.
    func bind(_ address: MIDIAddress, to target: MIDITarget) {
        if let previous = bindings[target], previous != address {
            targetsByAddress[previous] = nil
        }
        if let other = targetsByAddress[address], other != target {
            bindings[other] = nil
            pickups[other] = nil
        }
        bindings[target] = address
        targetsByAddress[address] = target
        // A fresh binding starts disengaged, so the first thing a newly
        // learned fader does is nothing.
        pickups[target] = MIDIPickup()
        onBindingsChanged?()
        publishClientDemand()
    }

    func forget(_ target: MIDITarget) {
        guard let address = bindings.removeValue(forKey: target) else { return }
        targetsByAddress[address] = nil
        pickups[target] = nil
        onBindingsChanged?()
        publishClientDemand()
    }

    /// The flat form kept in the preferences file.
    var storedBindings: [String: String] {
        Self.storedBindings(for: bindings)
    }

    nonisolated static func storedBindings(
        for bindings: [MIDITarget: MIDIAddress]
    ) -> [String: String] {
        bindings.reduce(into: [:]) { $0[$1.key.storageKey] = $1.value.storageKey }
    }

    /// Reads bindings back, dropping anything that no longer parses.
    ///
    /// Silently, and on purpose: a target this version does not have and an
    /// address written by a future one are both "not a binding any more", and
    /// neither is worth an alert on launch.
    func restore(_ stored: [String: String]) {
        var restored: [MIDITarget: MIDIAddress] = [:]
        var claimed: Set<MIDIAddress> = []
        for (key, value) in stored.sorted(by: { $0.key < $1.key }) {
            guard let target = MIDITarget(storageKey: key),
                let address = MIDIAddress(storageKey: value),
                !claimed.contains(address)
            else { continue }
            claimed.insert(address)
            restored[target] = address
        }
        bindings = restored
        targetsByAddress = restored.reduce(into: [:]) { $0[$1.value] = $1.key }
        pickups = restored.keys.reduce(into: [:]) { $0[$1] = MIDIPickup() }
    }

    // MARK: Receiving

    /// One decoded message, from the hardware or from the flow check.
    func receive(_ message: MIDIMessage) {
        let now = DispatchTime.now().uptimeNanoseconds
        latestDiagnostic = Diagnostic(message: message, receivedAt: Date())
        if Self.shouldPublishDiagnostics(
            isVisible: diagnosticsAreVisible, now: now,
            previous: lastDiagnosticPublicationNanoseconds)
        {
            publishLatestDiagnostic(now: now)
        }

        if let target = learningTarget {
            // Learn on the press, so holding a pad down does not bind and then
            // immediately act. A knob is bound by the first value it sends,
            // which is what moving it produces.
            guard message.isOn else { return }
            bind(message.address, to: target)
            learningTarget = nil
            return
        }

        let address = message.address
        guard let target = target(for: address) else { return }
        var pickup = pickups[target] ?? MIDIPickup()
        let action = MIDIAction.decide(
            for: message, target: target,
            softwarePosition: softwarePosition?(target) ?? 0, pickup: &pickup)
        pickups[target] = pickup
        guard action != .ignore else { return }
        perform?(target, action)
    }

    /// Ten hertz is faster than somebody can read a diagnostic row and two
    /// orders of magnitude below a high-resolution controller's message rate.
    nonisolated static let diagnosticPublishIntervalNanoseconds: UInt64 = 100_000_000

    nonisolated static func shouldPublishDiagnostics(
        isVisible: Bool, now: UInt64, previous: UInt64?
    ) -> Bool {
        guard isVisible else { return false }
        guard let previous, now >= previous else { return true }
        return now - previous >= diagnosticPublishIntervalNanoseconds
    }

    private func publishLatestDiagnostic(now: UInt64) {
        guard let latestDiagnostic else { return }
        lastDiagnosticPublicationNanoseconds = now
        guard lastDiagnostic != latestDiagnostic else { return }
        lastDiagnostic = latestDiagnostic
        diagnosticPublications += 1
    }

    /// The constant-time receive index, internal so tests can prove it stays
    /// coherent when a control is stolen, replaced or restored.
    func target(for address: MIDIAddress) -> MIDITarget? {
        targetsByAddress[address]
    }

    /// True when the control is currently allowed to move the software value.
    /// Shown in the window so "nothing happened" can be told apart from
    /// "nothing is connected".
    func isEngaged(_ target: MIDITarget) -> Bool {
        pickups[target]?.isEngaged ?? false
    }

    // MARK: CoreMIDI

    /// No bindings and no visible MIDI interface means zero CoreMIDI objects.
    nonisolated static func requiresClient(
        bindingCount: Int, diagnosticsAreVisible: Bool, isLearning: Bool
    ) -> Bool {
        bindingCount > 0 || diagnosticsAreVisible || isLearning
    }

    /// Publishes once after restore, then whenever the demand inputs change.
    func publishClientDemand() {
        onClientDemandChanged?(
            Self.requiresClient(
                bindingCount: bindings.count,
                diagnosticsAreVisible: diagnosticsAreVisible,
                isLearning: learningTarget != nil))
    }

    func start() {
        guard client == 0 else { return }
        var newClient = MIDIClientRef()
        // Both blocks below are explicitly `@Sendable`. Without it a closure
        // written inside a main-actor type inherits that isolation, and
        // CoreMIDI calls these from its own thread — which is not an
        // observation, it is a `dispatch_assert_queue` trap on the first
        // message that arrives. The whole body has to be safe off the main
        // actor, which is why nothing here touches state directly.
        let sourceRefreshGate = sourceRefreshGate
        let clientStatus = MIDIClientCreateWithBlock("YunAudio" as CFString, &newClient) {
            @Sendable [weak self] notification in
            // Hardware comes and goes. Without this, a controller plugged in
            // after launch is invisible until the application is restarted —
            // and plugging it in is exactly what somebody does just before
            // pressing learn.
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            guard sourceRefreshGate.request() else { return }
            Task { @MainActor in self?.scheduleSourceRefresh() }
        }
        guard clientStatus == noErr else {
            startupError = String(
                format: loc("Could not reach CoreMIDI (%d)."), Int(clientStatus))
            return
        }
        client = newClient

        var newPort = MIDIPortRef()
        let portStatus = MIDIInputPortCreateWithProtocol(
            client, "YunAudio in" as CFString, ._1_0, &newPort
        ) { @Sendable [weak self] eventList, _ in
            // Decoded here and handed over as values. This runs on CoreMIDI's
            // own thread, and the packet memory is valid for the length of this
            // call and no longer.
            var decoded: [MIDIMessage] = []
            for packet in eventList.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { tuple in
                    tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                        for index in 0..<count {
                            if let message = MIDIMessage.decode(words[index]) {
                                decoded.append(message)
                            }
                        }
                    }
                }
            }
            guard !decoded.isEmpty else { return }
            Task { @MainActor in
                for message in decoded { self?.receive(message) }
            }
        }
        guard portStatus == noErr else {
            startupError = String(
                format: loc("Could not open a MIDI input (%d)."), Int(portStatus))
            MIDIClientDispose(client)
            client = 0
            return
        }
        port = newPort
        startupError = nil
        connectSources()
    }

    private func scheduleSourceRefresh() {
        guard client != 0 else {
            sourceRefreshGate.finish()
            return
        }
        sourceRefreshTask = Task { [weak self] in
            // CoreMIDI publishes several setup changes for one physical event.
            // A tenth of a second is imperceptible beside plugging something
            // in and replaces the whole burst with one endpoint inventory.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.finishSourceRefresh()
        }
    }

    private func finishSourceRefresh() {
        sourceRefreshTask = nil
        sourceRefreshGate.finish()
        connectSources()
    }

    /// Connects anything not already connected, and refreshes the names.
    ///
    /// Additive rather than a teardown and rebuild: a source that was already
    /// connected must not be disconnected and reconnected every time some
    /// unrelated device appears, or a knob being turned during the change
    /// would drop messages.
    private func connectSources() {
        guard port != 0 else { return }
        var names: [String] = []
        var seen: Set<MIDIEndpointRef> = []
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            seen.insert(source)
            names.append(Self.name(of: source))
            guard !connected.contains(source) else { continue }
            if MIDIPortConnectSource(port, source, nil) == noErr {
                connected.insert(source)
            }
        }
        for gone in connected.subtracting(seen) {
            MIDIPortDisconnectSource(port, gone)
            connected.remove(gone)
        }
        if sourceNames != names { sourceNames = names }
    }

    static func name(of endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        guard
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr,
            let name = value?.takeRetainedValue() as String?
        else { return loc("Unnamed") }
        return name
    }

    func tearDown() {
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        sourceRefreshGate.finish()
        if client != 0 { MIDIClientDispose(client) }
        client = 0
        port = 0
        connected.removeAll()
    }
}

// MARK: - Carrying it out

extension RouterModel {
    /// Wires the controller to this model and opens CoreMIDI only on demand.
    func installMIDI() {
        let midi = midiControl
        midi.softwarePosition = { [weak self] target in
            self?.midiPosition(of: target) ?? 0
        }
        midi.perform = { [weak self] target, action in
            self?.applyMIDI(action, to: target)
        }
        midi.onBindingsChanged = { [weak self] in self?.persistMIDIBindings() }
        midi.onClientDemandChanged = { [weak midi] isNeeded in
            if isNeeded {
                midi?.start()
            } else {
                midi?.tearDown()
            }
        }
        midi.publishClientDemand()
    }

    /// Where a continuous target currently sits, 0…1.
    func midiPosition(of target: MIDITarget) -> Float {
        switch target {
        case .fader(.master): MIDIScale.position(fromDecibels: outputDecibels)
        case .fader(.input): MIDIScale.position(fromDecibels: inputDecibels)
        case .fader(.monitor): MIDIScale.position(fromDecibels: monitorDecibels)
        case .sourceFader(let uid):
            sourceGroups.first { $0.uid == uid }
                .map { MIDIScale.position(fromDecibels: faderDecibels(of: $0)) } ?? 0
        case .sourceMute, .command: 0
        }
    }

    func applyMIDI(_ action: MIDIAction, to target: MIDITarget) {
        switch (action, target) {
        case (.setPosition(let position), .fader(.master)):
            outputDecibels = MIDIScale.decibels(fromPosition: position)
        case (.setPosition(let position), .fader(.input)):
            inputDecibels = MIDIScale.decibels(fromPosition: position)
        case (.setPosition(let position), .fader(.monitor)):
            monitorDecibels = MIDIScale.decibels(fromPosition: position)
        case (.setPosition(let position), .sourceFader(let uid)):
            guard let group = sourceGroups.first(where: { $0.uid == uid }) else { return }
            setFaderDecibels(MIDIScale.decibels(fromPosition: position), for: group)
        case (.press, .sourceMute(let uid)):
            guard let group = sourceGroups.first(where: { $0.uid == uid }) else { return }
            setMuted(!isMuted(group), for: group)
        case (.press, .command(let url)):
            // Through the same door the URL scheme comes in by, so a pad and a
            // Stream Deck key that say the same thing do the same thing.
            guard let parsed = URL(string: url).flatMap(RemoteCommand.parse) else { return }
            perform(parsed)
        default:
            return
        }
    }

    /// The per-source rows the preferences window offers, in mixer order.
    var midiSourceTargets: [(uid: String, label: String, targets: [MIDITarget])] {
        sourceGroups.map { group in
            (
                group.uid, sourceLabel(for: group),
                [.sourceFader(uid: group.uid), .sourceMute(uid: group.uid)]
            )
        }
    }
}

// MARK: - Exercising the CoreMIDI half without hardware

/// A virtual MIDI source, so this process can post real messages to itself.
///
/// Not a feature: nothing in the interface reaches it. It exists because the
/// machine this was written on reports `MIDIGetNumberOfSources() == 0`, and the
/// alternative is that the client, the input port, the setup-changed
/// reconnection and the decode of a real `MIDIEventList` are only ever
/// exercised on somebody else's desk. As far as the rest of the system is
/// concerned a virtual source is a source: the application's own port finds it
/// through `MIDIGetNumberOfSources`, connects to it and receives from it by
/// exactly the path a controller would.
@MainActor
final class MIDILoopback {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    let name: String

    init?(name: String) {
        self.name = name
        guard MIDIClientCreateWithBlock(name as CFString, &client, nil) == noErr else {
            return nil
        }
        guard
            MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source) == noErr
        else {
            MIDIClientDispose(client)
            return nil
        }
    }

    @discardableResult
    func send(_ message: MIDIMessage) -> OSStatus {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = message.word
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        return MIDIReceivedEventList(source, &list)
    }

    func tearDown() {
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
        source = 0
        client = 0
    }
}
