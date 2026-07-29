import CryptoKit
import Foundation
import YunAudioControl

/// `obs-websocket` v5, written down as types.
///
/// This is the one place in the project where the vocabulary is somebody
/// else's. `RemoteCommand` is what this application answers to; this is what
/// OBS answers to, and the direction is reversed — here we are the client.
/// Keeping the two apart matters: a verb added to `RemoteCommand` is a promise
/// this application has to keep, whereas a request named here is a promise the
/// OBS project made and can change under us. Mixing them would put somebody
/// else's release schedule inside our own compatibility story.
///
/// Everything in this file is a pure function or a value; the socket is in
/// `OBSClient.swift`. That split is the whole reason this is testable: OBS is
/// **not installed on the machine this was written on**, so what can be
/// asserted here is the encoding, the arithmetic and the authentication — and
/// what cannot be asserted is written on the tests that would otherwise look
/// like proof that the integration works.
///
/// The protocol was read from obs-websocket's own generated documentation
/// rather than from a client library, because a library's idea of a field name
/// is one more thing that can be wrong:
/// <https://raw.githubusercontent.com/obsproject/obs-websocket/master/docs/generated/protocol.md>

// MARK: - Op codes

/// The message types. Numbered by the protocol; 4 is unused in v5.
public enum OBSOpCode: Int, Sendable, Equatable {
    case hello = 0
    case identify = 1
    case identified = 2
    case reidentify = 3
    case event = 5
    case request = 6
    case requestResponse = 7
    case requestBatch = 8
    case requestBatchResponse = 9
}

/// A message as it goes on the wire: `{"op": n, "d": {…}}`.
public struct OBSMessage: Equatable, Sendable {
    public let op: OBSOpCode
    public let data: JSONValue

    public init(op: OBSOpCode, data: [String: JSONValue]) {
        self.op = op
        self.data = .object(data)
    }

    public var text: String {
        JSONValue.object(["op": .int(op.rawValue), "d": data]).text
    }

    public init?(text: String) {
        guard let json = JSONValue.parse(text),
            let code = json["op"]?.intValue,
            let op = OBSOpCode(rawValue: code)
        else { return nil }
        self.op = op
        // A missing `d` is legal for nothing in v5, but treating it as an empty
        // object keeps the failure where it belongs: in the reader for the
        // specific message, which can say which field it wanted, rather than
        // here, which could only say "malformed".
        data = json["d"] ?? .object([:])
    }
}

// MARK: - Handshake

/// The server's opening message, and the half of it that decides whether a
/// password is needed.
public struct OBSHello: Equatable, Sendable {
    public let obsStudioVersion: String
    public let obsWebSocketVersion: String
    public let rpcVersion: Int
    /// Present exactly when the server requires authentication. Absent is not
    /// an error: obs-websocket ships with authentication *on*, but a user can
    /// turn it off, and refusing a server that did not ask for a password would
    /// be refusing the easy case.
    public let challenge: String?
    public let salt: String?

    public var requiresAuthentication: Bool { challenge != nil && salt != nil }

    public init?(_ data: JSONValue) {
        guard let rpcVersion = data["rpcVersion"]?.intValue else { return nil }
        self.rpcVersion = rpcVersion
        obsStudioVersion = data["obsStudioVersion"]?.stringValue ?? "unknown"
        obsWebSocketVersion = data["obsWebSocketVersion"]?.stringValue ?? "unknown"
        challenge = data["authentication"]?["challenge"]?.stringValue
        salt = data["authentication"]?["salt"]?.stringValue
    }
}

/// Which events the server should send.
///
/// A bit mask whose trap is written into the protocol itself: `All` is **not**
/// every bit. The high-volume events live above bit 15 and are excluded from
/// it, so a client that asks for `All` and then waits for level meters waits
/// for ever. That is why `all` and `inputVolumeMeters` are separate constants
/// here with the difference named, rather than left to a caller's arithmetic.
public struct OBSEventSubscription: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let general = OBSEventSubscription(rawValue: 1 << 0)
    public static let config = OBSEventSubscription(rawValue: 1 << 1)
    public static let scenes = OBSEventSubscription(rawValue: 1 << 2)
    public static let inputs = OBSEventSubscription(rawValue: 1 << 3)
    public static let transitions = OBSEventSubscription(rawValue: 1 << 4)
    public static let filters = OBSEventSubscription(rawValue: 1 << 5)
    public static let outputs = OBSEventSubscription(rawValue: 1 << 6)
    public static let sceneItems = OBSEventSubscription(rawValue: 1 << 7)
    public static let mediaInputs = OBSEventSubscription(rawValue: 1 << 8)
    public static let vendors = OBSEventSubscription(rawValue: 1 << 9)
    public static let ui = OBSEventSubscription(rawValue: 1 << 10)
    public static let canvases = OBSEventSubscription(rawValue: 1 << 11)

    /// The high-volume ones. Each has to be asked for by name.
    public static let inputVolumeMeters = OBSEventSubscription(rawValue: 1 << 16)
    public static let inputActiveStateChanged = OBSEventSubscription(rawValue: 1 << 17)
    public static let inputShowStateChanged = OBSEventSubscription(rawValue: 1 << 18)
    public static let sceneItemTransformChanged = OBSEventSubscription(rawValue: 1 << 19)

    /// What the protocol calls `All`: bits 0 through 11 and nothing above.
    public static let all: OBSEventSubscription = [
        .general, .config, .scenes, .inputs, .transitions, .filters, .outputs,
        .sceneItems, .mediaInputs, .vendors, .ui, .canvases,
    ]

    /// What this application actually wants. Subscribing to scene, transition
    /// and scene-item traffic in order to learn that somebody moved a volume
    /// slider is a wakeup per rendered frame for information nothing here reads.
    public static let audio: OBSEventSubscription = [.general, .inputs, .outputs]
}

/// The reply to `Hello` when a password is required.
///
/// CryptoKit and no dependency, which is the reason this is worth doing
/// in-process rather than shelling out to a client library.
public enum OBSAuthentication {
    /// `base64(sha256(base64(sha256(password + salt)) + challenge))`.
    ///
    /// The double hash is not decoration. The salted digest is what the server
    /// holds, and the per-connection challenge is what stops a captured
    /// `Identify` from being replayed.
    public static func response(password: String, salt: String, challenge: String) -> String {
        base64SHA256(base64SHA256(password + salt) + challenge)
    }

    static func base64SHA256(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
    }
}

// MARK: - Requests

/// One request, as a type rather than as a dictionary literal at each call site.
///
/// The factory methods below are the audio surface of obs-websocket. They are
/// spelled out one by one rather than generated, because each carries a unit or
/// a range that is easy to get wrong and impossible to notice afterwards:
/// volume is accepted in two different units, sync offset is milliseconds where
/// OBS itself stores nanoseconds, and tracks are one-based.
public struct OBSRequest: Equatable, Sendable {
    public let type: String
    public let data: JSONValue?

    public init(_ type: String, _ data: [String: JSONValue]? = nil) {
        self.type = type
        self.data = data.map(JSONValue.object)
    }

    /// The `Request` message for this, carrying the id the reply comes back on.
    public func message(id: String) -> OBSMessage {
        var fields: [String: JSONValue] = [
            "requestType": .string(type),
            "requestId": .string(id),
        ]
        if let data { fields["requestData"] = data }
        return OBSMessage(op: .request, data: fields)
    }
}

/// What OBS says back to a request.
public struct OBSResponse: Equatable, Sendable {
    public let requestType: String
    public let requestId: String
    public let ok: Bool
    /// A `RequestStatus` code. 100 is success; the 600s are the interesting
    /// failures — 600 is "no such resource", 604 is "the resource is not the
    /// right kind".
    public let code: Int
    public let comment: String?
    public let data: JSONValue

    public init?(_ data: JSONValue) {
        guard let requestType = data["requestType"]?.stringValue,
            let requestId = data["requestId"]?.stringValue,
            let status = data["requestStatus"]
        else { return nil }
        self.requestType = requestType
        self.requestId = requestId
        ok = status["result"]?.boolValue ?? false
        code = status["code"]?.intValue ?? 0
        comment = status["comment"]?.stringValue
        self.data = data["responseData"] ?? .object([:])
    }
}

/// An event OBS pushed.
public struct OBSEvent: Equatable, Sendable {
    public let type: String
    public let data: JSONValue

    public init?(_ data: JSONValue) {
        guard let type = data["eventType"]?.stringValue else { return nil }
        self.type = type
        self.data = data["eventData"] ?? .object([:])
    }
}

// MARK: - The audio verbs

/// OBS's three monitoring states, which is one more than this application has.
///
/// The third is why this enum is spelled out: `monitorAndOutput` means the
/// source is heard by the operator *and* sent onward, and OBS makes that a
/// per-source choice. Here, monitoring is an extra destination for the whole
/// mix. The difference is the arrangement, not the capability.
public enum OBSMonitorType: String, Sendable, CaseIterable {
    case none = "OBS_MONITORING_TYPE_NONE"
    case monitorOnly = "OBS_MONITORING_TYPE_MONITOR_ONLY"
    case monitorAndOutput = "OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT"
}

extension OBSRequest {
    public static func version() -> OBSRequest { .init("GetVersion") }
    public static func inputList() -> OBSRequest { .init("GetInputList") }

    /// The names OBS gave its own desktop and microphone slots.
    ///
    /// Worth asking rather than guessing: they are renameable, and the English
    /// defaults ("Desktop Audio", "Mic/Aux") are not what a Chinese OBS shows.
    public static func specialInputs() -> OBSRequest { .init("GetSpecialInputs") }

    public static func setMute(_ input: String, _ muted: Bool) -> OBSRequest {
        .init("SetInputMute", ["inputName": .string(input), "inputMuted": .bool(muted)])
    }

    /// Volume in decibels, which is the unit this application thinks in.
    ///
    /// obs-websocket takes either `inputVolumeMul` or `inputVolumeDb`, and the
    /// dB form is bounded by the server at −100…+26. Sending dB rather than
    /// converting to a multiplier here means the fader value read off our
    /// interface is the number OBS's own dialog shows for the same source.
    public static func setVolume(_ input: String, decibels: Double) -> OBSRequest {
        .init(
            "SetInputVolume",
            [
                "inputName": .string(input),
                "inputVolumeDb": .double(min(max(decibels, -100), 26)),
            ])
    }

    /// Milliseconds. `OBSSyncOffset` is where the number comes from.
    public static func setSyncOffset(_ input: String, milliseconds: Double) -> OBSRequest {
        .init(
            "SetInputAudioSyncOffset",
            [
                "inputName": .string(input),
                "inputAudioSyncOffset": .double(OBSSyncOffset.clamp(milliseconds)),
            ])
    }

    public static func setMonitorType(_ input: String, _ type: OBSMonitorType) -> OBSRequest {
        .init(
            "SetInputAudioMonitorType",
            ["inputName": .string(input), "monitorType": .string(type.rawValue)])
    }

    /// Which of OBS's six recording tracks this input feeds.
    ///
    /// One-based, because that is what the OBS interface calls them, and a
    /// zero-based wire format under a one-based dialog is a defect waiting to
    /// be filed as "track 2 is silent". Every track is named in the object
    /// rather than only the ones being switched on: obs-websocket applies what
    /// it is given, so a partial object would leave the rest at whatever they
    /// happened to be, and the caller asked for an assignment rather than a
    /// delta.
    public static func setTracks(_ input: String, _ tracks: Set<Int>) -> OBSRequest {
        var assignment: [String: JSONValue] = [:]
        for track in OBSRecordingTracks.all {
            assignment[String(track)] = .bool(tracks.contains(track))
        }
        return .init(
            "SetInputAudioTracks",
            ["inputName": .string(input), "inputAudioTracks": .object(assignment)])
    }

    /// A CoreAudio input source pointed at one of this application's devices.
    ///
    /// `device_id` is the settings key `plugins/mac-capture/mac-audio.c` reads,
    /// and its value is a device UID — the same string this application already
    /// uses to name a device everywhere else, so nothing has to be translated.
    public static func createCoreAudioInput(
        name: String, deviceUID: String, scene: String
    ) -> OBSRequest {
        .init(
            "CreateInput",
            [
                "sceneName": .string(scene),
                "inputName": .string(name),
                "inputKind": .string("coreaudio_input_capture"),
                "inputSettings": .object(["device_id": .string(deviceUID)]),
            ])
    }
}

/// OBS's recording tracks. Six, and the number is a compile-time constant in
/// libobs (`MAX_AUDIO_MIXES`) rather than a setting — which is the reason this
/// project records stems as files instead of adopting a track model. Six is
/// somebody else's muxer limit and there is no reason to inherit it.
public enum OBSRecordingTracks {
    public static let count = 6
    public static let all = 1...count
}

// MARK: - Sync offset

/// Turning this application's processing latency into OBS's sync offset.
///
/// The one integration point nobody else can build, and it is arithmetic rather
/// than cleverness: this is the only thing that knows how many frames the
/// effect chain adds, and OBS is the only thing that can shift a source against
/// the video. Neither half is worth anything on its own.
///
/// **Sign.** The microphone reaches OBS *late* by the chain's latency, because
/// it really did take that long. OBS cannot make those samples arrive earlier,
/// but a negative offset tells it to treat them as having happened earlier,
/// which comes to the same thing once its own buffering absorbs the difference.
/// So the offset for our input is negative and its magnitude is our latency.
///
/// **What is not verified.** That OBS accepts a negative offset of this
/// magnitude, and that the result is audibly aligned, has not been checked —
/// it needs OBS running, and OBS is not installed here. What *is* checked is
/// the arithmetic and the clamp.
public enum OBSSyncOffset {
    /// The documented range of `inputAudioSyncOffset`, in milliseconds.
    ///
    /// Asymmetric, and the short end is the one that bites: a chain longer than
    /// 950 ms cannot be compensated at all, and quietly sending −2000 would be
    /// refused by the server with a status code nobody reads.
    public static let range: ClosedRange<Double> = -950...20000

    public static func clamp(_ milliseconds: Double) -> Double {
        min(max(milliseconds, range.lowerBound), range.upperBound)
    }

    /// The offset to set on the input OBS reads this application through.
    ///
    /// Rounded to whole milliseconds because OBS's Advanced Audio Properties
    /// dialog is a whole-millisecond spin box: a fractional value would show
    /// there as a different number, and a setting somebody cannot type back in
    /// is a setting they cannot undo.
    public static func forProcessingLatency(frames: Int, sampleRate: Double) -> Double {
        guard sampleRate > 0, frames > 0 else { return 0 }
        return clamp(-(Double(frames) / sampleRate * 1000).rounded())
    }
}
