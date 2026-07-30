import Foundation
import YunAudioOBS
import YunDesign

/// This application's end of an OBS session.
///
/// Deliberately small, and the reason is written in `TODO.md`: this project's
/// problem is not too few features, it is more features than have been
/// verified. So this does the three things that are worth something and are not
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
/// What it deliberately does not do is in `RESEARCH.md`: it does not build
/// scenes, it does not mirror OBS's meters, and it does not model OBS's six
/// recording tracks.
@Observable
@MainActor
final class OBSLink {

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

    init(
        host: String = "127.0.0.1", port: Int = OBSConnection.defaultPort,
        inputName: String = "", mirrorsMute: Bool = false
    ) {
        self.host = host
        self.port = port
        self.inputName = inputName
        self.mirrorsMute = mirrorsMute
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
        state = .connecting
        let client = OBSClient(OBSConnection(host: host, port: port, password: password))
        do {
            let version = try await client.connect()
            self.client = client
            state = .connected(version)
            await refreshInputs()
        } catch let error as OBSError {
            self.client = nil
            state = .failed(error.message)
        } catch {
            self.client = nil
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        await client?.disconnect()
        client = nil
        inputs = []
        pushedOffsetMilliseconds = nil
        state = .off
    }

    /// Asks OBS what its audio sources are called.
    ///
    /// Both lists, because they answer different questions: `GetInputList` is
    /// everything, and `GetSpecialInputs` is the four microphone slots and two
    /// desktop slots OBS keeps outside any scene — which are exactly the ones a
    /// person will not find in a scene and will assume are missing.
    func refreshInputs() async {
        guard let client else { return }
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
        let offset = OBSSyncOffset.forProcessingLatency(
            frames: latencyFrames, sampleRate: sampleRate)
        do {
            try await client.send(.setSyncOffset(inputName, milliseconds: offset))
            pushedOffsetMilliseconds = offset
        } catch let error as OBSError {
            state = .failed(error.message)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Mirrors a mute. Silent when the link is off or the mirror is switched
    /// off, so callers do not have to ask first.
    func mirrorMute(_ muted: Bool) async {
        guard mirrorsMute, let client, !inputName.isEmpty else { return }
        _ = try? await client.send(.setMute(inputName, muted))
    }
}
