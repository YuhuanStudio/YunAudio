import Foundation
import YunAudioControl

/// Whatever this server talks to on the other side.
///
/// A protocol so the whole protocol layer can be exercised without a socket and
/// without an application: everything below is a pure function of a request line
/// and what this returns, and a pure function is a thing that can be asserted
/// rather than watched.
public protocol ControlTransport: Sendable {
    func send(_ request: ControlRequest) throws -> ControlReply
}

extension ControlClient: ControlTransport {}

/// A Model Context Protocol server for YunAudio.
///
/// MCP is JSON-RPC 2.0 over stdio: one JSON object per line in, one per line
/// out. That is the whole transport, which is why there is no dependency here —
/// a package to write `{"jsonrpc":"2.0"}` would be more code to audit than the
/// code it replaces, and this project vendors nothing.
///
/// The fourth front end onto `RemoteCommand`, after the URL scheme, MIDI and
/// JavaScript. It is a *separate process* from the application, because that is
/// what an MCP client requires: it spawns the server, hands it a pipe, and
/// expects it to exit when the pipe closes. A menu bar application cannot be
/// spawned once per client — there is one menu bar — so the server is a thin
/// process in front of the application rather than the application itself.
public struct MCPServer: Sendable {

    let transport: ControlTransport

    public init(transport: ControlTransport) {
        self.transport = transport
    }

    /// The protocol revisions this understands. The newest is what an
    /// unrecognised request gets told about, which is what the specification
    /// asks for: answer with a version you do support rather than refusing.
    static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let latestVersion = versions[0]
    static let serverName = "yunaudio"
    static let serverVersion = "0.1.2"

    // MARK: - One line in, one line out

    /// Answers one JSON-RPC message, or returns nil when there is nothing to
    /// answer with.
    ///
    /// Nil means the message was a notification. That is the only case: a
    /// malformed request, an unknown method and a tool that failed all produce
    /// something on the wire, because a client left waiting on a request that
    /// silently vanished has no way to tell that from a slow one.
    public func respond(to line: String) -> String? {
        guard let json = JSONValue.parse(line) else {
            return failure(id: .null, code: -32700, message: "Parse error: not valid JSON")
        }
        // JSON-RPC 2.0 defines a batch as an array. MCP removed batching in
        // 2025-06-18, and half-supporting it would be worse than not: a client
        // that sent one would get some of its calls carried out.
        if json.arrayValue != nil {
            return failure(
                id: .null, code: -32600,
                message: "Invalid Request: batched requests are not supported")
        }
        guard let object = json.objectValue else {
            return failure(
                id: .null, code: -32600, message: "Invalid Request: expected a JSON object")
        }

        // Absent id is a notification and gets no answer, ever — not even an
        // error. A present id is echoed back exactly, whatever it is, because
        // that is how the client matches the answer to the question.
        let id = object["id"]
        guard object["jsonrpc"]?.stringValue == "2.0" else {
            return reply(
                id,
                failure(
                    id: id ?? .null, code: -32600,
                    message: "Invalid Request: \"jsonrpc\" must be \"2.0\""))
        }
        guard let method = object["method"]?.stringValue else {
            return reply(
                id,
                failure(
                    id: id ?? .null, code: -32600,
                    message: "Invalid Request: \"method\" must be a string"))
        }
        let parameters = object["params"] ?? .null

        switch method {
        case "initialize":
            return reply(id, success(id: id ?? .null, result: initialize(parameters)))
        case "ping":
            return reply(id, success(id: id ?? .null, result: .object([:])))
        case "tools/list":
            return reply(
                id,
                success(
                    id: id ?? .null,
                    result: .object(["tools": .array(Self.tools.map(\.schema))])))
        case "tools/call":
            return reply(id, call(id: id ?? .null, parameters: parameters))
        default:
            // Notifications the specification defines and this server has
            // nothing to do about — `notifications/initialized` above all — are
            // silently accepted by the notification rule below, which is the
            // behaviour the specification asks for.
            return reply(
                id,
                failure(id: id ?? .null, code: -32601, message: "Method not found: \(method)"))
        }
    }

    /// Swallows the answer when there was no id to answer to.
    private func reply(_ id: JSONValue?, _ answer: String) -> String? {
        id == nil ? nil : answer
    }

    private func initialize(_ parameters: JSONValue) -> JSONValue {
        let asked = parameters["protocolVersion"]?.stringValue
        let version = Self.versions.contains(asked ?? "") ? asked! : Self.latestVersion
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object([
                "name": .string(Self.serverName), "version": .string(Self.serverVersion),
            ]),
            "instructions": .string(
                "YunAudio is a macOS audio router. These tools drive the copy running on this "
                    + "machine: they start and stop routing, mute, record, transcribe, apply "
                    + "saved scenes and setups, and read what it is doing. Every tool needs "
                    + "YunAudio to be running; if it is not, they say so. Read yunaudio_status "
                    + "before and after a change if it matters that the change took effect."),
        ])
    }

    // MARK: - Calling a tool

    private func call(id: JSONValue, parameters: JSONValue) -> String {
        guard let name = parameters["name"]?.stringValue else {
            return failure(
                id: id, code: -32602, message: "Invalid params: \"name\" must be a string")
        }
        guard let tool = Self.tools.first(where: { $0.name == name }) else {
            return failure(
                id: id, code: -32602,
                message: "Invalid params: there is no tool called \"\(name)\". "
                    + "The tools are: \(Self.tools.map(\.name).joined(separator: ", "))")
        }
        let arguments: [String: JSONValue]
        switch tool.validate(parameters["arguments"] ?? .null) {
        case .failure(let fault):
            return failure(id: id, code: -32602, message: "Invalid params: \(fault.reason)")
        case .success(let checked):
            arguments = checked
        }

        do {
            let reply = try transport.send(tool.request(arguments))
            switch reply {
            case .message(let text):
                return content(id: id, text: text, isError: false)
            case .status(let status):
                return content(id: id, text: status.text, isError: false)
            case .names(let scenes, let setups):
                let json = JSONValue.object([
                    "scenes": .array(scenes.map(JSONValue.string)),
                    "setups": .array(setups.map(JSONValue.string)),
                ])
                return content(id: id, text: json.text, isError: false)
            case .failure(let reason, let alternatives):
                // A tool that reached the application and was refused is an
                // error the *agent* can act on — a scene that has been renamed,
                // say — so it belongs in the result rather than in a JSON-RPC
                // error, which is for the protocol going wrong.
                //
                // The names that would have worked come back with the refusal,
                // so they are said here rather than left to a `list_names` call
                // the agent has to think to make. An agent that has to ask a
                // second question to find out what it should have said the
                // first time will sometimes just give up instead.
                let suggestion =
                    alternatives.isEmpty
                    ? "" : " The ones that exist: " + alternatives.joined(separator: ", ") + "."
                return content(id: id, text: reason + suggestion, isError: true)
            }
        } catch let error as ControlError {
            return content(id: id, text: error.message, isError: true)
        } catch {
            return content(id: id, text: "\(error)", isError: true)
        }
    }

    // MARK: - Shapes

    private func content(id: JSONValue, text: String, isError: Bool) -> String {
        success(
            id: id,
            result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "isError": .bool(isError),
            ]))
    }

    private func success(id: JSONValue, result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).text
    }

    private func failure(id: JSONValue, code: Int, message: String) -> String {
        JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .int(code), "message": .string(message)]),
        ]).text
    }
}
