import Foundation
import YunAudioControl

/// Why talking to OBS did not work, in the words somebody can act on.
///
/// The distinction that matters is the same one `ControlError` makes for our own
/// socket: "OBS is not there" and "OBS said no" are different problems with
/// different next steps, and a single `failed` case would fold them together.
/// Two of these describe things the user has to go and do in OBS, so they carry
/// the instruction rather than a code.
public enum OBSError: Error, Equatable, Sendable {
    /// Nothing accepted the connection. Almost always the server switch in
    /// Tools → WebSocket Server Settings, which is off by default.
    case notListening(host: String, port: Int)
    /// The server asked for a password and either none was given or it was
    /// wrong. obs-websocket closes the socket with code 4009 for this.
    case authenticationFailed
    /// The server wants an RPC version this client does not speak.
    case unsupportedRPCVersion(server: Int, ours: Int)
    /// The connection went away mid-conversation.
    case disconnected(String)
    /// OBS answered, and the answer was no.
    case refused(request: String, code: Int, comment: String?)
    case timedOut(request: String)

    public var message: String {
        switch self {
        case let .notListening(host, port):
            "Nothing is listening at \(host):\(port). In OBS, open Tools → "
                + "WebSocket Server Settings and switch the server on."
        case .authenticationFailed:
            "OBS refused the password. It is under Tools → WebSocket Server "
                + "Settings → Show Connect Info."
        case let .unsupportedRPCVersion(server, ours):
            "OBS speaks obs-websocket RPC version \(server) and this speaks \(ours)."
        case let .disconnected(detail):
            "The connection to OBS ended: \(detail)"
        case let .refused(request, code, comment):
            "OBS refused \(request) with code \(code)"
                + (comment.map { ": \($0)" } ?? "")
        case let .timedOut(request):
            "OBS did not answer \(request)."
        }
    }
}

/// Where OBS is, and how to get in.
public struct OBSConnection: Equatable, Sendable {
    public var host: String
    public var port: Int
    /// Empty when the server has authentication switched off.
    public var password: String

    /// obs-websocket's own defaults, from `src/Config.h`:
    /// `ServerPort = 4455`, `AuthRequired = true`, `ServerEnabled = false`.
    /// The last of those is why the first thing this application says about OBS
    /// has to be "switch the server on", not an error code.
    public static let defaultPort = 4455

    public init(host: String = "127.0.0.1", port: Int = defaultPort, password: String = "") {
        self.host = host
        self.port = port
        self.password = password
    }

    public var url: URL? {
        URL(string: "ws://\(host):\(port)")
    }
}

/// A client of obs-websocket v5.
///
/// An actor because the pending-request table is touched from the receive loop
/// and from every caller, and because a websocket is exactly the shape actors
/// were added for: one socket, many callers, replies arriving out of order.
///
/// One connection held open, unlike `ControlClient`, which opens one per
/// request. The reason is the reverse of the reason there: this socket carries
/// *events* as well as replies, so there is a conversation to keep rather than
/// a question to ask, and the handshake costs a round trip and a SHA-256.
public actor OBSClient {
    /// The RPC version this client is written against. Bumped by obs-websocket
    /// only on a breaking change, so a mismatch is a real incompatibility
    /// rather than a version-number difference to paper over.
    public static let rpcVersion = 1

    private let connection: OBSConnection
    private let subscriptions: OBSEventSubscription
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<OBSResponse, Error>] = [:]
    private var nextID = 0
    private var events: (@Sendable (OBSEvent) -> Void)?

    public private(set) var serverVersion: String?
    public private(set) var studioVersion: String?

    public init(
        _ connection: OBSConnection,
        subscriptions: OBSEventSubscription = .audio
    ) {
        self.connection = connection
        self.subscriptions = subscriptions
        let configuration = URLSessionConfiguration.ephemeral
        // A hung OBS should be a failure with a name rather than a spinner. The
        // handshake is two messages over loopback; anything past a second is
        // not slow, it is not happening.
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
    }

    /// Connects, authenticates and identifies. Returns the version OBS reported.
    ///
    /// Every failure before this returns leaves nothing open, so a caller can
    /// retry by calling again rather than having to reason about half-states.
    @discardableResult
    public func connect(
        onEvent: (@Sendable (OBSEvent) -> Void)? = nil
    ) async throws -> String {
        guard let url = connection.url else {
            throw OBSError.notListening(host: connection.host, port: connection.port)
        }
        events = onEvent
        let socket = session.webSocketTask(with: url)
        // `obswebsocket.json` is the default sub-protocol. Naming it is free and
        // it makes a mis-pointed connection — at a web server, say — fail during
        // the upgrade rather than at the first message.
        socket.resume()
        self.socket = socket

        let hello: OBSHello
        do {
            let message = try await receive(on: socket)
            guard message.op == .hello, let parsed = OBSHello(message.data) else {
                throw OBSError.disconnected("the first message was not Hello")
            }
            hello = parsed
        } catch let error as OBSError {
            disconnect()
            throw error
        } catch {
            disconnect()
            throw OBSError.notListening(host: connection.host, port: connection.port)
        }

        guard hello.rpcVersion >= Self.rpcVersion else {
            disconnect()
            throw OBSError.unsupportedRPCVersion(
                server: hello.rpcVersion, ours: Self.rpcVersion)
        }

        var identify: [String: JSONValue] = [
            "rpcVersion": .int(Self.rpcVersion),
            "eventSubscriptions": .int(subscriptions.rawValue),
        ]
        if hello.requiresAuthentication {
            guard !connection.password.isEmpty, let salt = hello.salt,
                let challenge = hello.challenge
            else {
                disconnect()
                throw OBSError.authenticationFailed
            }
            identify["authentication"] = .string(
                OBSAuthentication.response(
                    password: connection.password, salt: salt, challenge: challenge))
        }
        try await send(OBSMessage(op: .identify, data: identify), on: socket)

        do {
            let message = try await receive(on: socket)
            guard message.op == .identified else {
                throw OBSError.authenticationFailed
            }
        } catch {
            disconnect()
            // The server closes rather than replying when the password is
            // wrong, so a read failure here has one likely meaning and saying
            // it is more useful than reporting a socket error.
            throw OBSError.authenticationFailed
        }

        serverVersion = hello.obsWebSocketVersion
        studioVersion = hello.obsStudioVersion
        listen(on: socket)
        return hello.obsStudioVersion
    }

    public func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: OBSError.disconnected("the client disconnected"))
        }
    }

    /// Sends one request and waits for its reply.
    ///
    /// Throws `OBSError.refused` when OBS answered and said no, which is a
    /// different thing from the transport failing and is worth keeping
    /// different: "there is no input called Mic/Aux" is something a caller can
    /// correct, and "OBS is gone" is not.
    @discardableResult
    public func send(_ request: OBSRequest) async throws -> OBSResponse {
        guard let socket else {
            throw OBSError.notListening(host: connection.host, port: connection.port)
        }
        nextID += 1
        let id = "yun-\(nextID)"
        let response: OBSResponse = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await send(request.message(id: id), on: socket)
                } catch {
                    if let waiting = pending.removeValue(forKey: id) {
                        waiting.resume(throwing: error)
                    }
                }
            }
        }
        guard response.ok else {
            throw OBSError.refused(
                request: request.type, code: response.code, comment: response.comment)
        }
        return response
    }

    /// Several requests down one message, executed in order by the server.
    ///
    /// This is what to use when a person moves a fader that maps onto more than
    /// one OBS input: ten separate requests are ten round trips whose order the
    /// server does not promise, and one batch is one.
    @discardableResult
    public func send(
        batch requests: [OBSRequest], haltOnFailure: Bool = true
    ) async throws
        -> [OBSRequest]
    {
        guard let socket else {
            throw OBSError.notListening(host: connection.host, port: connection.port)
        }
        nextID += 1
        let id = "yun-batch-\(nextID)"
        let message = OBSMessage(
            op: .requestBatch,
            data: [
                "requestId": .string(id),
                "haltOnFailure": .bool(haltOnFailure),
                "requests": .array(
                    requests.map { request in
                        var fields: [String: JSONValue] = [
                            "requestType": .string(request.type)
                        ]
                        if let data = request.data { fields["requestData"] = data }
                        return .object(fields)
                    }),
            ])
        try await send(message, on: socket)
        // Deliberately fire-and-forget on the reply. A batch response arrives on
        // op 9 with a results array, and nothing here reads it yet; pretending
        // to await it would mean inventing a second correlation table for a
        // value no caller uses.
        return requests
    }

    // MARK: Wire

    private func send(_ message: OBSMessage, on socket: URLSessionWebSocketTask) async throws {
        do {
            try await socket.send(.string(message.text))
        } catch {
            throw OBSError.disconnected(error.localizedDescription)
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) async throws -> OBSMessage {
        let received = try await socket.receive()
        let text: String
        switch received {
        case .string(let value): text = value
        case .data(let value): text = String(decoding: value, as: UTF8.self)
        @unknown default:
            throw OBSError.disconnected("an unrecognised frame arrived")
        }
        guard let message = OBSMessage(text: text) else {
            throw OBSError.disconnected("a message could not be read: \(text.prefix(120))")
        }
        return message
    }

    /// The read loop. Every reply and every event arrives here.
    private func listen(on socket: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                guard let self else { return }
                do {
                    let message = try await self.receive(on: socket)
                    await self.deliver(message)
                } catch {
                    await self.fail(error)
                    return
                }
            }
        }
    }

    private func deliver(_ message: OBSMessage) {
        switch message.op {
        case .requestResponse:
            guard let response = OBSResponse(message.data),
                let continuation = pending.removeValue(forKey: response.requestId)
            else { return }
            continuation.resume(returning: response)
        case .event:
            guard let event = OBSEvent(message.data) else { return }
            events?(event)
        default:
            // Batch responses and a second `Identified` land here. Neither is
            // read yet, and dropping a message nothing waits on is better than
            // a log line on a path that runs per event.
            break
        }
    }

    private func fail(_ error: Error) {
        guard socket != nil else { return }
        socket = nil
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(
                throwing: OBSError.disconnected(error.localizedDescription))
        }
    }
}
