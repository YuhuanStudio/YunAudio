import Foundation
import YunAudioOBS
import YunDesign

/// Serial async delivery with one active command and one latest replacement.
///
/// A connection generation change revokes pending work, but an old operation
/// remains the sole active one until it actually returns. Starting a replacement
/// beside a socket call which has not returned would recreate the very task storm
/// this mailbox exists to contain.
@MainActor
final class OBSOneActiveLatestMailbox<Value: Sendable, Output: Sendable> {
    struct Statistics: Sendable, Equatable {
        let submitted: UInt64
        let startedApplications: UInt64
        let completedApplications: UInt64
        let superseded: UInt64
        let revoked: UInt64
        let staleCompletions: UInt64
        let pendingCount: Int
        let activeCount: Int
        let maximumPendingCount: Int
        let maximumConcurrentApplications: Int
    }

    private struct Command: Sendable {
        let identifier: UInt64
        let generation: UInt64
        let value: Value
    }

    private let apply: @Sendable (Value) async -> Output
    private let publish: @MainActor @Sendable (UInt64, Value, Output) -> Void
    private var generation: UInt64 = 0
    private var nextIdentifier: UInt64 = 0
    private var active: Command?
    private var pending: Command?
    private var submitted: UInt64 = 0
    private var startedApplications: UInt64 = 0
    private var completedApplications: UInt64 = 0
    private var superseded: UInt64 = 0
    private var revoked: UInt64 = 0
    private var staleCompletions: UInt64 = 0
    private var maximumPendingCount = 0
    private var concurrentApplications = 0
    private var maximumConcurrentApplications = 0

    init(
        apply: @escaping @Sendable (Value) async -> Output,
        publish: @escaping @MainActor @Sendable (UInt64, Value, Output) -> Void
    ) {
        self.apply = apply
        self.publish = publish
    }

    func activate(generation: UInt64) {
        guard self.generation != generation else { return }
        self.generation = generation
        if pending != nil {
            pending = nil
            revoked &+= 1
        }
    }

    func submit(generation: UInt64, value: Value) {
        submitted &+= 1
        guard generation == self.generation else {
            revoked &+= 1
            return
        }
        nextIdentifier &+= 1
        let command = Command(
            identifier: nextIdentifier, generation: generation, value: value)
        guard active != nil else {
            start(command)
            return
        }
        if pending != nil { superseded &+= 1 }
        pending = command
        maximumPendingCount = max(maximumPendingCount, 1)
    }

    var statistics: Statistics {
        Statistics(
            submitted: submitted,
            startedApplications: startedApplications,
            completedApplications: completedApplications,
            superseded: superseded,
            revoked: revoked,
            staleCompletions: staleCompletions,
            pendingCount: pending == nil ? 0 : 1,
            activeCount: active == nil ? 0 : 1,
            maximumPendingCount: maximumPendingCount,
            maximumConcurrentApplications: maximumConcurrentApplications)
    }

    private func start(_ command: Command) {
        precondition(active == nil)
        active = command
        startedApplications &+= 1
        concurrentApplications += 1
        maximumConcurrentApplications = max(
            maximumConcurrentApplications, concurrentApplications)
        let apply = apply
        Task { [weak self] in
            let output = await apply(command.value)
            self?.finish(command, output: output)
        }
    }

    private func finish(_ command: Command, output: Output) {
        guard active?.identifier == command.identifier else { return }
        active = nil
        concurrentApplications -= 1
        completedApplications &+= 1
        if command.generation == generation {
            publish(command.generation, command.value, output)
        } else {
            staleCompletions &+= 1
        }

        guard let next = pending else { return }
        pending = nil
        guard next.generation == generation else {
            revoked &+= 1
            return
        }
        start(next)
    }
}

/// This application's end of an OBS session.
///
/// Deliberately small, and the reason is worth stating: this project's problem
/// is not too few features, it is more features than have been verified. So this does the three things that are worth something and are not
/// somebody else's job:
///
/// 1. **Connects**, and when it cannot, says which switch in OBS is off rather
///    than printing a status code. obs-websocket ships *disabled*, so that is
///    the common case rather than the edge case.
/// 2. **Tells OBS what this application's processing costs.** OBS has a
///    per-source sync offset and no way of knowing what to put in it; this
///    application knows its chain latency to the frame and, until now, only
///    displayed it. That pairing is the whole integration — see `OBSSyncOffset`.
/// 3. **Mirrors the microphone mute**, because a streamer who hits mute expects
///    everything to be muted, and OBS's own mute is a separate switch on a
///    separate window.
///
/// What it deliberately does not do: it does not build scenes, it does not
/// mirror OBS's meters, and it does not model OBS's six recording tracks. Each
/// of those is OBS's own interface doing a job better than a second copy of it
/// would.
@Observable
@MainActor
final class OBSLink {

    struct MuteCommand: Sendable {
        let client: OBSClient
        let inputName: String
        let muted: Bool
    }

    /// Where the conversation is. Every state a person can be in has a sentence
    /// attached, because "not connected" and "connected but there is no such
    /// input" are different problems and a single boolean cannot tell them
    /// apart.
    enum State: Equatable {
        case off
        case connecting
        /// Carries the OBS Studio version, which is the shortest possible proof
        /// that the far end is really OBS and not some other websocket.
        case connected(String)
        case failed(String)
    }

    private(set) var state: State = .off
    /// Inputs OBS reported, in the order it gave them.
    private(set) var inputs: [String] = []
    /// The offset last actually sent, so the interface can show what OBS was
    /// told rather than what it would be told.
    private(set) var pushedOffsetMilliseconds: Double?

    var host: String {
        didSet { persist?() }
    }
    var port: Int {
        didSet { persist?() }
    }
    /// Not persisted, and that is a decision rather than an omission.
    ///
    /// `UserDefaults` is a plain file in the user's home directory. This
    /// application's own control socket is `chmod 600` because it can mute
    /// somebody's microphone and read what they are recording; writing
    /// somebody's OBS password in clear beside that would be inconsistent. The
    /// Keychain is the right home, and the obstacle is this project's own
    /// distribution: the application is ad-hoc signed, so its identity changes
    /// on every build and a keychain item would prompt on every launch.
    var password: String = ""
    /// The OBS input that reads this application. Named by the user, because
    /// OBS lets them call it anything and guessing is how a request goes to the
    /// wrong source.
    var inputName: String {
        didSet { persist?() }
    }
    /// Whether muting the microphone here mutes that input there.
    var mirrorsMute: Bool {
        didSet { persist?() }
    }

    /// Called when one of the settings above changes. Set by `RouterModel`,
    /// which owns the preferences file; this type does not know there is one.
    @ObservationIgnored var persist: (() -> Void)?

    private var client: OBSClient?
    @ObservationIgnored private var connectionGeneration: UInt64 = 0
    @ObservationIgnored private let muteMailbox:
        OBSOneActiveLatestMailbox<
            MuteCommand, Bool
        >

    init(
        host: String = "127.0.0.1", port: Int = OBSConnection.defaultPort,
        inputName: String = "", mirrorsMute: Bool = false
    ) {
        self.host = host
        self.port = port
        self.inputName = inputName
        self.mirrorsMute = mirrorsMute
        muteMailbox = OBSOneActiveLatestMailbox(
            apply: { command in
                do {
                    try await command.client.send(
                        .setMute(command.inputName, command.muted))
                    return true
                } catch {
                    return false
                }
            },
            publish: { _, _, _ in })
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// One line for the interface, in the language it is being read in.
    var summary: String {
        switch state {
        case .off: loc("Not connected")
        case .connecting: loc("Connecting…")
        case .connected(let version): String(format: loc("OBS %@"), version)
        case .failed(let reason): reason
        }
    }

    // MARK: Connecting

    func connect() async {
        guard state != .connecting else { return }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        muteMailbox.activate(generation: generation)
        state = .connecting
        let client = OBSClient(OBSConnection(host: host, port: port, password: password))
        do {
            let version = try await client.connect()
            guard generation == connectionGeneration else {
                await client.disconnect()
                return
            }
            self.client = client
            state = .connected(version)
            await refreshInputs(client: client, generation: generation)
        } catch let error as OBSError {
            guard generation == connectionGeneration else { return }
            self.client = nil
            state = .failed(error.message)
        } catch {
            guard generation == connectionGeneration else { return }
            self.client = nil
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        connectionGeneration &+= 1
        muteMailbox.activate(generation: connectionGeneration)
        let disconnectedClient = client
        client = nil
        inputs = []
        pushedOffsetMilliseconds = nil
        state = .off
        await disconnectedClient?.disconnect()
    }

    /// Asks OBS what its audio sources are called.
    ///
    /// Both lists, because they answer different questions: `GetInputList` is
    /// everything, and `GetSpecialInputs` is the four microphone slots and two
    /// desktop slots OBS keeps outside any scene — which are exactly the ones a
    /// person will not find in a scene and will assume are missing.
    func refreshInputs() async {
        guard let client else { return }
        await refreshInputs(client: client, generation: connectionGeneration)
    }

    private func refreshInputs(client: OBSClient, generation: UInt64) async {
        var names: [String] = []
        if let response = try? await client.send(.specialInputs()) {
            for key in ["mic1", "mic2", "mic3", "mic4", "desktop1", "desktop2"] {
                if let name = response.data[key]?.stringValue, !name.isEmpty {
                    names.append(name)
                }
            }
        }
        if let response = try? await client.send(.inputList()),
            let list = response.data["inputs"]?.arrayValue
        {
            for input in list {
                if let name = input["inputName"]?.stringValue, !names.contains(name) {
                    names.append(name)
                }
            }
        }
        guard generation == connectionGeneration, self.client === client else { return }
        inputs = names
        if inputName.isEmpty, let first = names.first { inputName = first }
    }

    // MARK: The two things worth sending

    /// Tells OBS how far ahead of itself this application's audio has to be
    /// treated, in milliseconds.
    ///
    /// - Parameters:
    ///   - latencyFrames: What the complete processing path adds, from `RoutingEngine`.
    ///   - sampleRate: The rate those frames are counted at.
    func pushSyncOffset(latencyFrames: Int, sampleRate: Double) async {
        guard let client, !inputName.isEmpty else { return }
        let generation = connectionGeneration
        let offset = OBSSyncOffset.forProcessingLatency(
            frames: latencyFrames, sampleRate: sampleRate)
        do {
            try await client.send(.setSyncOffset(inputName, milliseconds: offset))
            guard generation == connectionGeneration, self.client === client else { return }
            pushedOffsetMilliseconds = offset
        } catch let error as OBSError {
            guard generation == connectionGeneration, self.client === client else { return }
            state = .failed(error.message)
        } catch {
            guard generation == connectionGeneration, self.client === client else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Mirrors a mute. Silent when the link is off or the mirror is switched
    /// off, so callers do not have to ask first.
    func requestMuteMirror(_ muted: Bool) {
        guard mirrorsMute, let client, !inputName.isEmpty else { return }
        muteMailbox.submit(
            generation: connectionGeneration,
            value: MuteCommand(client: client, inputName: inputName, muted: muted))
    }

    /// Kept for source compatibility with callers which already await this
    /// fire-and-forget mirror. New event paths submit synchronously so a burst
    /// cannot create one task per mute edge.
    func mirrorMute(_ muted: Bool) async {
        requestMuteMirror(muted)
    }

    var muteDeliveryStatistics: OBSOneActiveLatestMailbox<MuteCommand, Bool>.Statistics {
        muteMailbox.statistics
    }
}
