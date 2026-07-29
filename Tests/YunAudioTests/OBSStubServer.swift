import Foundation
import Network
import Testing

@testable import YunAudioApp
@testable import YunAudioControl
@testable import YunAudioOBS

/// A websocket server that answers like obs-websocket v5.
///
/// This exists because everything else in `OBSTests.swift` checks an encoding,
/// and an encoding that is right is not a client that works. The handshake is
/// three messages, a SHA-256 with a specific concatenation order, and a
/// correlation table — none of which a round-trip test of `OBSMessage` can
/// reach, and all of which fail in ways that look like "the password is wrong".
///
/// It is a stub, not OBS. What it proves is that this client, over a real
/// socket, completes the sequence obs-websocket's protocol document describes
/// and gets its answer back on the right request id. What it cannot prove is
/// anything about OBS's *behaviour* — that a sync offset moves audio, that
/// `coreaudio_input_capture` finds one of this application's devices. Those
/// need OBS installed, and it is not installed here.
///
/// `Network.framework` rather than a hand-written RFC 6455 implementation:
/// `NWProtocolWebSocket` does the framing on the server side too, so what is
/// written here is the obs-websocket part and nothing else. A hand-written
/// framer in a test proves the test's framer works.
final class StubOBSServer: @unchecked Sendable {

    /// The challenge and salt from obs-websocket's own worked example, so a
    /// failure here and a failure in the authentication vector test point at
    /// the same arithmetic.
    static let salt = "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI="
    static let challenge = "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="

    private let listener: NWListener
    private let queue = DispatchQueue(label: "yun.obs.stub")
    private let password: String?
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var received: [OBSMessage] = []
    private var identifiedFlag = false

    /// Every message the client sent, in order.
    var requests: [OBSMessage] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// True once a client got past `Identify`.
    var didIdentify: Bool {
        lock.lock()
        defer { lock.unlock() }
        return identifiedFlag
    }

    private(set) var port: UInt16 = 0

    /// - Parameter password: Nil for a server with authentication switched off,
    ///   which is a configuration real users have and which takes a different
    ///   branch through the client.
    /// - Throws: `StubFailure.didNotStart` when the listener never became ready,
    ///   and whatever `NWListener` throws when it cannot be made at all.
    init(password: String?) throws {
        self.password = password
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        // Loopback only. This is a test fixture and it should not be reachable
        // from the network the machine is on.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            listener.cancel()
            throw StubFailure.didNotStart
        }
    }

    enum StubFailure: Error { case didNotStart }

    func stop() {
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        for connection in open { connection.cancel() }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)

        var hello: [String: JSONValue] = [
            "obsStudioVersion": .string("31.0.0"),
            "obsWebSocketVersion": .string("5.7.4"),
            "rpcVersion": .int(1),
        ]
        if password != nil {
            hello["authentication"] = .object([
                "challenge": .string(Self.challenge), "salt": .string(Self.salt),
            ])
        }
        send(OBSMessage(op: .hello, data: hello), on: connection)
        read(connection)
    }

    private func read(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { return }
            guard let message = OBSMessage(text: String(decoding: data, as: UTF8.self)) else {
                return
            }
            self.lock.lock()
            self.received.append(message)
            self.lock.unlock()
            self.handle(message, on: connection)
            self.read(connection)
        }
    }

    private func handle(_ message: OBSMessage, on connection: NWConnection) {
        switch message.op {
        case .identify:
            if let password {
                let expected = OBSAuthentication.response(
                    password: password, salt: Self.salt, challenge: Self.challenge)
                guard message.data["authentication"]?.stringValue == expected else {
                    // obs-websocket closes rather than replying, which is the
                    // path the client turns into "OBS refused the password".
                    connection.cancel()
                    return
                }
            }
            lock.lock()
            identifiedFlag = true
            lock.unlock()
            send(
                OBSMessage(op: .identified, data: ["negotiatedRpcVersion": .int(1)]),
                on: connection)
        case .request:
            let type = message.data["requestType"]?.stringValue ?? ""
            let id = message.data["requestId"]?.stringValue ?? ""
            var response: [String: JSONValue] = [
                "requestType": .string(type),
                "requestId": .string(id),
                "requestStatus": .object(["result": .bool(true), "code": .int(100)]),
            ]
            switch type {
            case "GetVersion":
                response["responseData"] = .object([
                    "obsVersion": .string("31.0.0"), "rpcVersion": .int(1),
                ])
            case "GetSpecialInputs":
                response["responseData"] = .object([
                    "mic1": .string("Mic/Aux"), "desktop1": .string("Desktop Audio"),
                ])
            case "SetInputAudioSyncOffset":
                break
            case "SetInputMute":
                break
            default:
                // An unknown request gets obs-websocket's own "no such request"
                // code, so the client's refusal path is reachable from a test.
                response["requestStatus"] = .object([
                    "result": .bool(false), "code": .int(204),
                    "comment": .string("Unknown request type"),
                ])
            }
            send(OBSMessage(op: .requestResponse, data: response), on: connection)
        default:
            break
        }
    }

    private func send(_ message: OBSMessage, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "obs", metadata: [metadata])
        connection.send(
            content: Data(message.text.utf8), contentContext: context,
            isComplete: true, completion: .idempotent)
    }
}

@Suite("Talking to something that answers like OBS", .serialized)
struct OBSClientAgainstStubTests {

    /// The whole handshake over a real socket: `Hello`, a SHA-256 the server
    /// checks rather than one this code checks against itself, `Identified`,
    /// and a request whose answer comes back on the id it was sent with.
    @Test("the handshake completes and a request is answered")
    func authenticated() async throws {
        let server = try StubOBSServer(password: "supersecretpassword")
        defer { server.stop() }

        let client = OBSClient(
            OBSConnection(
                host: "127.0.0.1", port: Int(server.port),
                password: "supersecretpassword"))
        let version = try await client.connect()
        #expect(version == "31.0.0")
        #expect(server.didIdentify)

        let response = try await client.send(.version())
        #expect(response.ok)
        #expect(response.data["obsVersion"]?.stringValue == "31.0.0")
        await client.disconnect()

        // The subscription mask really did go out, and it really is the
        // non-high-volume set. A client that quietly asked for the volume
        // meters would work here and drown a real OBS session in traffic.
        let identify = try #require(server.requests.first { $0.op == .identify })
        #expect(
            identify.data["eventSubscriptions"]?.intValue
                == OBSEventSubscription.audio.rawValue)
        #expect(identify.data["rpcVersion"]?.intValue == 1)
    }

    /// A wrong password is a specific answer, not a timeout. obs-websocket
    /// closes the socket rather than replying, so the client has to turn a read
    /// failure at this exact point into the sentence about Show Connect Info —
    /// and this is the only test that can tell whether it does.
    @Test("a wrong password is refused, with somewhere to go")
    func wrongPassword() async throws {
        let server = try StubOBSServer(password: "supersecretpassword")
        defer { server.stop() }

        let client = OBSClient(
            OBSConnection(host: "127.0.0.1", port: Int(server.port), password: "wrong"))
        await #expect(throws: OBSError.authenticationFailed) {
            try await client.connect()
        }
    }

    /// A server with authentication switched off sends no challenge, and the
    /// client must not insist on one.
    @Test("a server with no password is still joined")
    func openServer() async throws {
        let server = try StubOBSServer(password: nil)
        defer { server.stop() }

        let client = OBSClient(
            OBSConnection(host: "127.0.0.1", port: Int(server.port)))
        _ = try await client.connect()
        #expect(server.didIdentify)
        let identify = try #require(server.requests.first { $0.op == .identify })
        #expect(identify.data["authentication"] == nil)
        await client.disconnect()
    }

    /// The number the whole integration exists for, on the wire.
    ///
    /// 2688 frames of chain at 48 kHz is 56 ms, and what OBS is told is −56.
    /// Checked at the server rather than at the request builder, so the path
    /// from `RoutingEngine`'s frame count to the field name in somebody else's
    /// protocol is covered end to end.
    @Test("the chain's latency arrives as a negative sync offset")
    func syncOffsetOnTheWire() async throws {
        let server = try StubOBSServer(password: nil)
        defer { server.stop() }

        let client = OBSClient(OBSConnection(host: "127.0.0.1", port: Int(server.port)))
        _ = try await client.connect()
        let offset = OBSSyncOffset.forProcessingLatency(frames: 2688, sampleRate: 48000)
        try await client.send(.setSyncOffset("Mic/Aux", milliseconds: offset))
        await client.disconnect()

        let sent = try #require(
            server.requests.first {
                $0.data["requestType"]?.stringValue == "SetInputAudioSyncOffset"
            })
        #expect(sent.data["requestData"]?["inputAudioSyncOffset"]?.doubleValue == -56)
        #expect(sent.data["requestData"]?["inputName"]?.stringValue == "Mic/Aux")
    }

    /// OBS saying no is not the transport failing, and the client has to keep
    /// them apart or a mistyped source name reads as "OBS is gone".
    @Test("a refusal carries OBS's own status code")
    func refusal() async throws {
        let server = try StubOBSServer(password: nil)
        defer { server.stop() }

        let client = OBSClient(OBSConnection(host: "127.0.0.1", port: Int(server.port)))
        _ = try await client.connect()
        await #expect(
            throws: OBSError.refused(
                request: "GetInputList", code: 204, comment: "Unknown request type")
        ) {
            try await client.send(.inputList())
        }
        await client.disconnect()
    }

    /// Nothing listening is a named failure rather than a wait.
    ///
    /// The common case by a distance: obs-websocket ships disabled, so the
    /// first thing most people meet is this, and a spinner would be the wrong
    /// answer to it.
    @Test("a closed port is answered at once, with the switch to turn on")
    func nothingListening() async throws {
        // A port taken and released, so it is known to be free rather than
        // hoped to be.
        let scout = try StubOBSServer(password: nil)
        let port = Int(scout.port)
        scout.stop()

        let client = OBSClient(OBSConnection(host: "127.0.0.1", port: port))
        let started = Date()
        await #expect(throws: (any Error).self) { try await client.connect() }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

@Suite("The application's end of the OBS link")
@MainActor
struct OBSLinkTests {

    /// The same claims the flow check makes about `OBSLink`, runnable without
    /// the audio hardware.
    ///
    /// Not redundant with the flow-check section: that one drives the *real*
    /// model in the *real* application, which is the only place the settings
    /// round-trip through the preferences file. This one can run while somebody
    /// else has the microphone, which on a machine with several sessions on it
    /// is most of the time.
    @Test("it starts off, fails usefully, and comes back to off")
    func lifecycle() async throws {
        // A port that was listening a moment ago, so it is known to be free
        // rather than assumed to be.
        let scout = try StubOBSServer(password: nil)
        let port = Int(scout.port)
        scout.stop()

        let link = OBSLink(host: "127.0.0.1", port: port)
        #expect(link.state == .off)
        #expect(!link.isConnected)

        await link.connect()
        guard case .failed(let reason) = link.state else {
            Issue.record("a closed port should have failed, and the state was \(link.state)")
            return
        }
        // The sentence has to name the switch. obs-websocket ships disabled, so
        // this is the first thing most people see, and a status code here would
        // send them looking for a fault that is not there.
        #expect(reason.contains("WebSocket Server Settings"))
        #expect(link.pushedOffsetMilliseconds == nil)

        await link.disconnect()
        #expect(link.state == .off)
    }

    /// Sending with nothing connected is silent rather than an error. The mirror
    /// is off by default, and somebody who never opens the streaming settings
    /// should never be told anything about OBS.
    @Test("it says nothing when there is nothing to say to")
    func quietWhenUnlinked() async {
        let link = OBSLink()
        await link.mirrorMute(true)
        await link.pushSyncOffset(latencyFrames: 2688, sampleRate: 48000)
        #expect(link.state == .off)
        #expect(link.pushedOffsetMilliseconds == nil)
    }

    /// And it does send once there is somebody listening — the whole path from
    /// a frame count to `pushedOffsetMilliseconds`, which is what the interface
    /// shows as "last sent to OBS".
    @Test("connected, the chain's latency reaches the far end and is recorded")
    func pushesTheOffset() async throws {
        let server = try StubOBSServer(password: nil)
        defer { server.stop() }

        let link = OBSLink(host: "127.0.0.1", port: Int(server.port), inputName: "Mic/Aux")
        await link.connect()
        #expect(link.isConnected)
        await link.pushSyncOffset(latencyFrames: 2688, sampleRate: 48000)
        #expect(link.pushedOffsetMilliseconds == -56)
        await link.disconnect()

        let sent = try #require(
            server.requests.first {
                $0.data["requestType"]?.stringValue == "SetInputAudioSyncOffset"
            })
        #expect(sent.data["requestData"]?["inputAudioSyncOffset"]?.doubleValue == -56)
    }
}
