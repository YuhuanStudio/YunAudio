import Foundation
import Testing

@testable import YunAudioControl
@testable import YunAudioOBS

// MARK: - What these tests can and cannot say

/// OBS is **not installed on the machine these were written on**, so nothing
/// below is evidence that talking to OBS works. What each of them checks is
/// stated on it, and the boundary is worth stating once here because a suite
/// called "OBS" that is green reads like an integration that works:
///
/// - The authentication string is checked against the algorithm obs-websocket
///   documents, computed independently twice (Python's `hashlib` and OpenSSL,
///   which agreed) from the example challenge and salt in the protocol
///   document. That is a real vector, not a value copied out of this code.
/// - The message encodings are checked against the field names and units in
///   the same document.
/// - The sync-offset arithmetic is checked as arithmetic.
///
/// What is **not** checked anywhere: that a real obs-websocket server accepts
/// any of it, that a negative sync offset does what it is meant to do, or that
/// `coreaudio_input_capture` picks up one of this application's devices.

@Suite("obs-websocket authentication")
struct OBSAuthenticationTests {

    /// The protocol document's own worked example.
    ///
    /// obs-websocket publishes the challenge, the salt and the password but not
    /// the answer, so the answer here was computed twice from the documented
    /// steps by two implementations that share no code with this one. A wrong
    /// concatenation order, a hex digest where base64 was meant, or hashing the
    /// raw digest instead of its base64 text all produce a different string and
    /// all of them look like a password the user typed wrongly.
    @Test("the documented challenge produces the documented answer")
    func vector() {
        let password = "supersecretpassword"
        let salt = "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI="
        let challenge = "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="

        // The intermediate value the protocol calls the base64 secret, checked
        // separately: when only the final string is asserted, a fault in either
        // hash reports the same failure and neither is ruled out.
        #expect(
            OBSAuthentication.base64SHA256(password + salt)
                == "H1IfVz1pSREUQzbFTVnX/Tyb+gMhMik5x7yUBCY0PTs=")
        #expect(
            OBSAuthentication.response(
                password: password, salt: salt, challenge: challenge)
                == "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=")
    }

    @Test("the challenge is what makes two connections differ")
    func challengeMatters() {
        let salt = "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI="
        let first = OBSAuthentication.response(password: "p", salt: salt, challenge: "a")
        let second = OBSAuthentication.response(password: "p", salt: salt, challenge: "b")
        #expect(first != second)
    }
}

@Suite("obs-websocket messages")
struct OBSMessageTests {

    @Test("Hello is read, and says whether a password is wanted")
    func hello() {
        let text = """
            {"op":0,"d":{"obsStudioVersion":"31.0.0","obsWebSocketVersion":"5.7.4",\
            "rpcVersion":1,"authentication":{"challenge":"c","salt":"s"}}}
            """
        let message = OBSMessage(text: text)
        #expect(message?.op == .hello)
        let hello = OBSHello(message!.data)
        #expect(hello?.rpcVersion == 1)
        #expect(hello?.obsStudioVersion == "31.0.0")
        #expect(hello?.requiresAuthentication == true)
        #expect(hello?.salt == "s")
    }

    /// A server with authentication switched off sends no `authentication`
    /// object at all. Treating that as malformed would refuse the easy case.
    @Test("Hello without authentication is still a Hello")
    func helloOpen() {
        let hello = OBSHello(
            .object([
                "obsStudioVersion": .string("31.0.0"),
                "obsWebSocketVersion": .string("5.7.4"),
                "rpcVersion": .int(1),
            ]))
        #expect(hello?.requiresAuthentication == false)
    }

    /// `All` is bits 0–11 and nothing above, which is 4095. The number matters:
    /// a client that computes "everything" as `~0` or as `1 << 20 - 1` asks for
    /// the high-volume events by accident and gets a message every 50 ms from
    /// every source.
    @Test("All is 4095, and the volume meters are not in it")
    func subscriptions() {
        #expect(OBSEventSubscription.all.rawValue == 4095)
        #expect(OBSEventSubscription.inputVolumeMeters.rawValue == 65536)
        #expect(!OBSEventSubscription.all.contains(.inputVolumeMeters))
        #expect(OBSEventSubscription.audio.rawValue == 0b100_1001)
    }

    @Test("a request carries its id so the reply can be matched")
    func requestEncoding() {
        let message = OBSRequest.setMute("Mic/Aux", true).message(id: "yun-7")
        #expect(message.op == .request)
        #expect(message.data["requestType"]?.stringValue == "SetInputMute")
        #expect(message.data["requestId"]?.stringValue == "yun-7")
        #expect(message.data["requestData"]?["inputMuted"]?.boolValue == true)
        #expect(message.data["requestData"]?["inputName"]?.stringValue == "Mic/Aux")
    }

    /// Volume goes as `inputVolumeDb`, not as a multiplier, and the server's
    /// documented bounds are applied here so a fader dragged to silence does
    /// not become a refused request.
    @Test("volume is sent in decibels and clamped to what the server accepts")
    func volume() {
        let normal = OBSRequest.setVolume("Desktop Audio", decibels: -6.02)
        #expect(normal.data?["inputVolumeDb"]?.doubleValue == -6.02)
        #expect(
            OBSRequest.setVolume("x", decibels: -200).data?["inputVolumeDb"]?.doubleValue
                == -100)
        #expect(
            OBSRequest.setVolume("x", decibels: 40).data?["inputVolumeDb"]?.doubleValue == 26)
    }

    /// Every track is named, not only the ones being switched on. A partial
    /// object would leave the others wherever they were, which is a delta, and
    /// the caller asked for an assignment.
    @Test("a track assignment names all six tracks")
    func tracks() {
        let request = OBSRequest.setTracks("Mic/Aux", [1, 3])
        let tracks = request.data?["inputAudioTracks"]?.objectValue
        #expect(tracks?.count == 6)
        #expect(tracks?["1"]?.boolValue == true)
        #expect(tracks?["2"]?.boolValue == false)
        #expect(tracks?["3"]?.boolValue == true)
        #expect(tracks?["6"]?.boolValue == false)
    }

    @Test("a monitor type goes as the string OBS defines")
    func monitorType() {
        #expect(
            OBSRequest.setMonitorType("x", .monitorAndOutput).data?["monitorType"]?
                .stringValue == "OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT")
    }

    /// The settings key is `device_id` and the value is a device UID. Getting
    /// either wrong creates a source that exists, appears in the mixer and is
    /// silent — which is the shape of failure this project keeps finding.
    @Test("a CoreAudio input is created by device UID")
    func createInput() {
        let request = OBSRequest.createCoreAudioInput(
            name: "YunAudio", deviceUID: "YunAudioDevice_UID", scene: "Scene")
        #expect(request.data?["inputKind"]?.stringValue == "coreaudio_input_capture")
        #expect(
            request.data?["inputSettings"]?["device_id"]?.stringValue
                == "YunAudioDevice_UID")
    }

    @Test("a response separates OBS saying no from the transport failing")
    func response() {
        let text = """
            {"op":7,"d":{"requestType":"SetInputMute","requestId":"yun-1",\
            "requestStatus":{"result":false,"code":600,"comment":"Parameter: inputName"}}}
            """
        let response = OBSResponse(OBSMessage(text: text)!.data)
        #expect(response?.ok == false)
        #expect(response?.code == 600)
        #expect(response?.comment == "Parameter: inputName")
        #expect(response?.requestId == "yun-1")
    }

    @Test("an event carries its type and payload")
    func event() {
        let text = """
            {"op":5,"d":{"eventType":"InputMuteStateChanged","eventIntent":8,\
            "eventData":{"inputName":"Mic/Aux","inputMuted":true}}}
            """
        let event = OBSEvent(OBSMessage(text: text)!.data)
        #expect(event?.type == "InputMuteStateChanged")
        #expect(event?.data["inputMuted"]?.boolValue == true)
    }

    @Test("a message that is not one is refused rather than guessed at")
    func rubbish() {
        #expect(OBSMessage(text: "not json") == nil)
        // Op code 4 is not used by v5. A client that accepted it would be
        // accepting a message from a protocol it does not speak.
        #expect(OBSMessage(text: #"{"op":4,"d":{}}"#) == nil)
    }
}

@Suite("Sync offset")
struct OBSSyncOffsetTests {

    /// Voice isolation alone is 56 ms, measured on this machine and written
    /// down in `MEASUREMENT.md`. At 48 kHz that is 2688 frames, and the whole
    /// point of the integration is that this number crosses to OBS rather than
    /// only being displayed.
    @Test("a 56 ms chain at 48 kHz is 56 ms of offset")
    func isolation() {
        #expect(
            OBSSyncOffset.forProcessingLatency(frames: 2688, sampleRate: 48000) == -56)
    }

    /// The same latency in frames is a different offset at a different rate,
    /// which is the reason this takes a rate at all rather than assuming one.
    @Test("the same frame count at 96 kHz is half the milliseconds")
    func rate() {
        #expect(
            OBSSyncOffset.forProcessingLatency(frames: 2688, sampleRate: 96000) == -28)
    }

    @Test("no chain is no offset")
    func none() {
        #expect(OBSSyncOffset.forProcessingLatency(frames: 0, sampleRate: 48000) == 0)
        // A rate of zero is a graph that is not running. Dividing by it would
        // produce a NaN that JSON cannot carry and the server would refuse.
        #expect(OBSSyncOffset.forProcessingLatency(frames: 2688, sampleRate: 0) == 0)
    }

    /// The server's documented range is −950…20000 ms. A longer chain than that
    /// cannot be compensated, and sending −2000 would be refused with a code
    /// nobody reads, so it is clamped where the number is made.
    @Test("a chain longer than OBS can shift is clamped, not refused")
    func clamped() {
        #expect(
            OBSSyncOffset.forProcessingLatency(frames: 96000, sampleRate: 48000) == -950)
        #expect(OBSSyncOffset.clamp(50000) == 20000)
    }

    /// OBS's own dialog is a whole-millisecond spin box, so a fractional value
    /// would show there as a different number from the one that was sent.
    @Test("the offset is whole milliseconds, because OBS's dialog is")
    func rounded() {
        // 1000 frames at 48 kHz is 20.833… ms.
        #expect(
            OBSSyncOffset.forProcessingLatency(frames: 1000, sampleRate: 48000) == -21)
    }
}

@Suite("OBS connection")
struct OBSConnectionTests {

    /// obs-websocket's defaults, from its own `src/Config.h`. The port is the
    /// one thing a user should never have to type, and the *disabled* default
    /// is why the first thing this application says about OBS has to be an
    /// instruction rather than an error code.
    @Test("the default port is obs-websocket's own")
    func defaults() {
        #expect(OBSConnection.defaultPort == 4455)
        #expect(OBSConnection().url?.absoluteString == "ws://127.0.0.1:4455")
    }

    @Test("a connection that is not there says which switch to turn on")
    func notListening() {
        let message = OBSError.notListening(host: "127.0.0.1", port: 4455).message
        #expect(message.contains("WebSocket Server Settings"))
    }
}
