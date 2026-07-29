import Foundation
import Testing

@testable import YunAudioControl
@testable import yunaudio_mcp

// The MCP server is JSON-RPC framing, a tool catalogue, argument checking and
// error shapes. Every one of those is a pure function of a line of text, which
// means every one of them can be asserted rather than watched — and a protocol
// nobody asserts is a protocol that works until the first client that is not
// the one it was written against.
//
// The socket underneath is not a pure function, so it is exercised for real:
// the real listener, the real client, and the real server binary at the end.

// MARK: - Helpers

/// Stands in for the application. Records what was asked so a tool can be
/// checked by the command it produced rather than by the sentence it returned.
private final class StubTransport: ControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [ControlRequest] = []
    private var answer: ControlReply = .message("done")
    private var fault: ControlError?

    var sent: [ControlRequest] { lock.withLock { received } }

    func replying(_ reply: ControlReply) -> StubTransport {
        lock.withLock { answer = reply }
        return self
    }

    func failing(_ error: ControlError) -> StubTransport {
        lock.withLock { fault = error }
        return self
    }

    func send(_ request: ControlRequest) throws -> ControlReply {
        try lock.withLock {
            received.append(request)
            if let fault { throw fault }
            return answer
        }
    }
}

private func server(_ transport: StubTransport = StubTransport()) -> (MCPServer, StubTransport)
{
    (MCPServer(transport: transport), transport)
}

/// One request in, the parsed answer out.
private func ask(_ server: MCPServer, _ request: JSONValue) -> JSONValue {
    guard let line = server.respond(to: request.text) else { return .null }
    // Framing is newline-delimited. A response carrying a newline of its own
    // would not be a formatting difference; it would be two messages.
    #expect(!line.contains("\n"))
    return JSONValue.parse(line) ?? .null
}

private func call(
    _ server: MCPServer, _ name: String, _ arguments: JSONValue = .object([:]), id: Int = 1
) -> JSONValue {
    ask(
        server,
        .object([
            "jsonrpc": .string("2.0"), "id": .int(id), "method": .string("tools/call"),
            "params": .object(["name": .string(name), "arguments": arguments]),
        ]))
}

/// The text a successful tool call produced.
private func resultText(_ answer: JSONValue) -> String? {
    answer["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
}

private func errorCode(_ answer: JSONValue) -> Int? {
    answer["error"]?["code"]?.intValue
}

// MARK: - JSON

@Suite("The JSON value type")
struct JSONValueTests {

    /// `Bool` bridges to `NSNumber`, so a status dictionary crossing through
    /// `Any` will hand back `0` and `1` for `false` and `true` unless the type
    /// is asked rather than pattern-matched. An agent reading `"muted": 0` has
    /// to guess whether that is a boolean or a level.
    @Test("booleans survive the crossing as booleans")
    func booleansStayBooleans() throws {
        let status: [String: Any] = ["muted": true, "routes": 2, "peak": -6.02]
        let value = try #require(JSONValue(any: status))
        #expect(value["muted"] == .bool(true))
        #expect(value["routes"] == .int(2))
        #expect(value["peak"] == .double(-6.02))
        #expect(value.text == #"{"muted":true,"peak":-6.02,"routes":2}"#)
    }

    /// A silent meter reads −∞ dBFS. `JSONSerialization` throws on one, so
    /// before this the entire status document became the word `null` — every
    /// field lost because of one.
    @Test("an infinite level costs one field, not the whole document")
    func infinityIsContained() throws {
        let status: [String: Any] = [
            "inputDecibels": -Double.infinity, "muted": true, "routes": 3,
        ]
        let value = try #require(JSONValue(any: status))
        #expect(value["inputDecibels"] == .null)
        #expect(value["routes"] == .int(3))
        #expect(value.text == #"{"inputDecibels":null,"muted":true,"routes":3}"#)
    }

    @Test("a document round-trips through its own text")
    func roundTrip() throws {
        let value = JSONValue.object([
            "a": .array([.int(1), .double(1.5), .string("x"), .bool(false), .null]),
            "b": .object(["c": .string("d")]),
            // A scene called this is not likely; a scene called any of it is,
            // and each piece is a way a hand-written encoder goes wrong.
            "\u{01}quote\" back\\ tab\t line\n 語音": .string("語音 \"通話\"\n\u{1F}"),
        ])
        let text = value.text
        #expect(!text.contains("\n"))
        #expect(JSONValue.parse(text) == value)
        // Parsed by something that is not this encoder, so the check is that
        // the document is JSON rather than that it is self-consistent.
        #expect(
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil,
            "\(text)")
    }

    /// `JSONSerialization` renders this as `-6.0199999999999996`: seventeen
    /// significant figures of a level somebody read off a meter, in every
    /// status reply, for ever.
    @Test("a level is printed as the number it is")
    func shortestRoundTrip() {
        #expect(JSONValue.double(-6.02).text == "-6.02")
        #expect(JSONValue.double(0.1).text == "0.1")
        #expect(JSONValue.int(2).text == "2")
        #expect(JSONValue.double(.infinity).text == "null")
    }

    /// JSON-RPC ids are bare scalars, so a strict top-level-container reading
    /// would refuse half the protocol.
    @Test("a bare scalar is a document")
    func fragments() {
        #expect(JSONValue.parse("7") == .int(7))
        #expect(JSONValue.parse("null") == .null)
        #expect(JSONValue.parse("nope") == nil)
    }

    /// Anything JSON cannot carry is refused at the boundary rather than turned
    /// into something else, so a status field that grows a `Date` is a visible
    /// failure instead of a value that quietly reads wrong.
    @Test("what JSON cannot carry is refused")
    func refusesTheUncarryable() {
        #expect(JSONValue(any: ["when": Date()]) == nil)
    }
}

// MARK: - The wire between the two processes

@Suite("The control socket protocol")
struct ControlProtocolTests {

    @Test("every request and reply round-trips through its own JSON")
    func roundTrip() throws {
        let requests: [ControlRequest] = [
            .status, .names,
            .perform(.routing(true)), .perform(.mute(nil)), .perform(.record(false)),
            .perform(.transcribe(true)), .perform(.preset("Voice call")),
            .perform(.config("Podcast")), .perform(.script("yun.mute(true)")),
        ]
        for request in requests {
            #expect(ControlRequest(json: request.json) == request, "\(request)")
        }
        let replies: [ControlReply] = [
            .message("Microphone muted."),
            .status(.object(["running": .bool(true), "routes": .int(1)])),
            .names(scenes: ["Voice call"], setups: ["Podcast"]),
            .failure("There is no scene called \"Nope\"."),
        ]
        for reply in replies {
            #expect(ControlReply(json: reply.json) == reply, "\(reply)")
        }
    }

    /// The grammar on the wire is `RemoteCommand`'s grammar and no other, so a
    /// URL the scheme would refuse is refused here by the same code.
    @Test("a request the URL scheme would refuse is refused here")
    func refusesWhatTheSchemeRefuses() {
        let bad: [JSONValue] = [
            .object([
                "request": .string("perform"), "url": .string("yunaudio://mute/sometimes"),
            ]),
            .object(["request": .string("perform"), "url": .string("yunaudio://explode")]),
            .object(["request": .string("perform"), "url": .string("http://mute/on")]),
            .object(["request": .string("perform")]),
            .object(["request": .string("detonate")]),
            .object([:]),
            .string("status"),
        ]
        for json in bad {
            #expect(ControlRequest(json: json) == nil, "\(json.text)")
        }
    }
}

// MARK: - Framing

@Suite("JSON-RPC framing")
struct MCPFramingTests {

    @Test("a request that is not JSON is a parse error, not a crash and not silence")
    func parseError() throws {
        let (server, _) = server()
        let line = try #require(server.respond(to: "{\"jsonrpc\": "))
        let answer = try #require(JSONValue.parse(line))
        #expect(errorCode(answer) == -32700)
        #expect(answer["id"] == .null)
        #expect(answer["jsonrpc"] == .string("2.0"))
    }

    /// Everything a client can put on the wire, and what has to come back.
    /// Written as a table because the interesting property is that *none* of
    /// these is silence.
    @Test(
        "every malformed request is answered",
        arguments: [
            ("", -32700),
            ("not json at all", -32700),
            ("[]", -32600),
            (#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, -32600),
            ("7", -32600),
            (#""hello""#, -32600),
            (#"{"id":1,"method":"ping"}"#, -32600),
            (#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, -32600),
            (#"{"jsonrpc":"2.0","id":1}"#, -32600),
            (#"{"jsonrpc":"2.0","id":1,"method":7}"#, -32600),
            (#"{"jsonrpc":"2.0","id":1,"method":"tools/explode"}"#, -32601),
            (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#, -32602),
        ])
    func malformed(line: String, code: Int) throws {
        let (server, transport) = server()
        let raw = try #require(server.respond(to: line), "silence is never an answer")
        let answer = try #require(JSONValue.parse(raw))
        #expect(errorCode(answer) == code, "\(line)")
        #expect(answer["error"]?["message"]?.stringValue?.isEmpty == false, "\(line)")
        // Nothing malformed reaches the application. A request refused after it
        // had already muted somebody is not refused.
        #expect(transport.sent.isEmpty, "\(line)")
    }

    /// A notification has no id, and JSON-RPC says a notification is never
    /// answered — not even when it is wrong. Answering one puts a response on
    /// the wire the client has nothing to match it to.
    @Test("a notification is never answered")
    func notifications() {
        let (server, _) = server()
        #expect(
            server.respond(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
                == nil)
        #expect(server.respond(to: #"{"jsonrpc":"2.0","method":"tools/list"}"#) == nil)
        #expect(server.respond(to: #"{"jsonrpc":"2.0","method":"nonsense"}"#) == nil)
        #expect(server.respond(to: #"{"jsonrpc":"1.0","method":"ping"}"#) == nil)
    }

    /// Whatever the id was, that is what comes back. A client matches answers to
    /// questions by it and nothing else.
    @Test("the id comes back exactly as it went out")
    func idsEcho() {
        let (server, _) = server()
        for id in [JSONValue.int(42), .string("abc"), .null] {
            let answer = ask(
                server,
                .object(["jsonrpc": .string("2.0"), "id": id, "method": .string("ping")]))
            #expect(answer["id"] == id)
            #expect(answer["result"] == .object([:]))
        }
    }

    @Test("initialize answers with a version the client asked for when it can")
    func initialize() {
        let (server, _) = server()
        func version(asking asked: String?) -> String? {
            var parameters: [String: JSONValue] = [:]
            if let asked { parameters["protocolVersion"] = .string(asked) }
            let answer = ask(
                server,
                .object([
                    "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize"),
                    "params": .object(parameters),
                ]))
            #expect(answer["result"]?["serverInfo"]?["name"] == .string("yunaudio"))
            #expect(answer["result"]?["capabilities"]?["tools"] != nil)
            // An agent reads this before it reads any tool, so it has to say
            // what this server is for.
            let instructions = answer["result"]?["instructions"]?.stringValue ?? ""
            #expect(instructions.count > 100)
            return answer["result"]?["protocolVersion"]?.stringValue
        }
        #expect(version(asking: "2024-11-05") == "2024-11-05")
        #expect(version(asking: "2025-06-18") == "2025-06-18")
        // An unrecognised one is answered with something this server does
        // support, which is what the specification asks for.
        #expect(version(asking: "1999-01-01") == MCPServer.latestVersion)
        #expect(version(asking: nil) == MCPServer.latestVersion)
    }
}

// MARK: - The catalogue

@Suite("The tool catalogue")
struct MCPToolTests {

    private func listed() -> [JSONValue] {
        let (server, _) = server()
        let answer = ask(
            server,
            .object([
                "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/list"),
            ]))
        return answer["result"]?["tools"]?.arrayValue ?? []
    }

    @Test("every tool is listed, once, with a schema a client can validate against")
    func shape() throws {
        let tools = listed()
        #expect(tools.count == 9)
        #expect(Set(tools.compactMap { $0["name"]?.stringValue }).count == 9)

        for tool in tools {
            let name = try #require(tool["name"]?.stringValue)
            // Namespaced, because an agent sees every server's tools in one
            // list and `status` belongs to everybody.
            #expect(name.hasPrefix("yunaudio_"), "\(name)")

            // "mute" is not a description. An agent that cannot act on this
            // has to guess, and guessing at a mute is the failure this whole
            // vocabulary is shaped to avoid.
            let description = try #require(tool["description"]?.stringValue)
            #expect(description.count >= 120, "\(name): \(description.count) characters")

            let schema = try #require(tool["inputSchema"]?.objectValue)
            #expect(schema["type"] == .string("object"))
            #expect(schema["additionalProperties"] == .bool(false))
            let properties = try #require(schema["properties"]?.objectValue)
            for required in schema["required"]?.arrayValue ?? [] {
                let key = try #require(required.stringValue)
                #expect(properties[key] != nil, "\(name).\(key)")
            }
            for (argument, definition) in properties {
                #expect(definition["type"]?.stringValue != nil, "\(name).\(argument)")
                let text = definition["description"]?.stringValue ?? ""
                #expect(text.count >= 20, "\(name).\(argument)")
            }
        }
    }

    /// The two that only read are marked as only reading, because that is what
    /// an agent uses to decide what it may call while working out what is going
    /// on. Marking a mute read-only would be worse than marking nothing.
    @Test("only the two reading tools are marked read-only")
    func readOnly() {
        let readable = listed()
            .filter { $0["annotations"]?["readOnlyHint"] == .bool(true) }
            .compactMap { $0["name"]?.stringValue }
        #expect(Set(readable) == ["yunaudio_status", "yunaudio_list_names"])
    }

    /// The schema an agent reads and the check the server applies come from one
    /// declaration, so this asserts they agree rather than hoping.
    @Test("the schema's required list is the list that is enforced")
    func schemaMatchesEnforcement() throws {
        let (server, transport) = server()
        for tool in listed() {
            let name = try #require(tool["name"]?.stringValue)
            let required = tool["inputSchema"]?["required"]?.arrayValue ?? []
            let answer = call(server, name, .object([:]))
            if required.isEmpty {
                #expect(errorCode(answer) == nil, "\(name)")
            } else {
                #expect(errorCode(answer) == -32602, "\(name)")
            }
        }
        // Six of the nine have nothing they insist on — the four switches,
        // where an absent state is the toggle, and the two that only read — so
        // six were carried out and three were refused.
        #expect(transport.sent.count == 6)
    }
}

// MARK: - Calling

@Suite("Calling a tool")
struct MCPCallTests {

    /// Each verb, in all three states, checked by the command that reached the
    /// application rather than by the sentence that came back. The sentence is
    /// the stub's; the command is the code's.
    @Test("every switch reaches the application as the command it names")
    func switches() {
        let expected: [(String, [RemoteCommand])] = [
            ("yunaudio_routing", [.routing(true), .routing(false), .routing(nil)]),
            ("yunaudio_mute", [.mute(true), .mute(false), .mute(nil)]),
            ("yunaudio_record", [.record(true), .record(false), .record(nil)]),
            ("yunaudio_transcribe", [.transcribe(true), .transcribe(false), .transcribe(nil)]),
        ]
        for (name, commands) in expected {
            let (server, transport) = server()
            _ = call(server, name, .object(["state": .bool(true)]))
            _ = call(server, name, .object(["state": .bool(false)]))
            _ = call(server, name, .object([:]))
            #expect(transport.sent == commands.map(ControlRequest.perform), "\(name)")
        }
    }

    /// Absent and null both mean "no value", because an agent filling in a
    /// field it has nothing for produces the latter and means the former.
    @Test("a null state is a toggle, not a failure")
    func nullState() {
        let (server, transport) = server()
        _ = call(server, "yunaudio_mute", .object(["state": .null]))
        _ = call(server, "yunaudio_mute", .null)
        #expect(transport.sent == [.perform(.mute(nil)), .perform(.mute(nil))])
    }

    @Test("the named and scripted tools carry their argument through")
    func named() {
        let (server, transport) = server()
        _ = call(server, "yunaudio_apply_scene", .object(["name": .string("Voice call")]))
        _ = call(server, "yunaudio_apply_setup", .object(["name": .string("Podcast")]))
        _ = call(server, "yunaudio_run_script", .object(["source": .string("yun.mute(true)")]))
        _ = call(server, "yunaudio_status")
        _ = call(server, "yunaudio_list_names")
        #expect(
            transport.sent == [
                .perform(.preset("Voice call")), .perform(.config("Podcast")),
                .perform(.script("yun.mute(true)")), .status, .names,
            ])
    }

    /// A script with a space, a slash and a quotation mark in it, because the
    /// command crosses the socket as a URL and that is where a hand-built one
    /// goes wrong.
    @Test("a script survives the URL it crosses as")
    func scriptSurvivesTheURL() {
        let (server, transport) = server()
        let source = #"if (yun.status().muted) { yun.log("was muted"); } // 1/2"#
        _ = call(server, "yunaudio_run_script", .object(["source": .string(source)]))
        #expect(transport.sent == [.perform(.script(source))])
    }

    /// Every one of these must be refused *before* anything reaches the
    /// application. An agent that sends `{"value": true}` to a tool taking
    /// `state` would otherwise get the toggle: the microphone changes, the call
    /// reports success, and the mistake only surfaces as a mute that went the
    /// wrong way at the wrong moment.
    @Test(
        "a bad argument is refused before it can do anything",
        arguments: [
            ("yunaudio_mute", JSONValue.object(["state": .string("true")])),
            ("yunaudio_mute", .object(["state": .int(1)])),
            ("yunaudio_mute", .object(["value": .bool(true)])),
            ("yunaudio_mute", .string("on")),
            ("yunaudio_status", .object(["state": .bool(true)])),
            ("yunaudio_apply_scene", .object([:])),
            ("yunaudio_apply_scene", .object(["name": .int(3)])),
            ("yunaudio_apply_scene", .object(["name": .string("   ")])),
            ("yunaudio_apply_scene", .object(["name": .string("A"), "extra": .bool(true)])),
            ("yunaudio_run_script", .object(["src": .string("yun.mute()")])),
        ])
    func badArguments(name: String, arguments: JSONValue) throws {
        let (server, transport) = server()
        let answer = call(server, name, arguments)
        #expect(errorCode(answer) == -32602)
        // The message has to say what was wrong, not that something was.
        let message = try #require(answer["error"]?["message"]?.stringValue)
        #expect(message.count > 20, "\(message)")
        #expect(transport.sent.isEmpty)
    }

    @Test("a tool nobody has is refused with the list of the ones that exist")
    func unknownTool() throws {
        let (server, transport) = server()
        let answer = call(server, "yunaudio_explode")
        #expect(errorCode(answer) == -32602)
        let message = try #require(answer["error"]?["message"]?.stringValue)
        #expect(message.contains("yunaudio_status"))
        #expect(transport.sent.isEmpty)
    }

    /// The application answering "there is no scene called that" is not the
    /// protocol going wrong — it is a result the agent can act on, so it comes
    /// back as a result marked as an error rather than as a JSON-RPC error.
    @Test("a refusal from the application is a tool error, not a protocol error")
    func applicationRefusal() {
        let (server, _) = server(
            StubTransport().replying(.failure("There is no scene called \"Nope\".")))
        let answer = call(server, "yunaudio_apply_scene", .object(["name": .string("Nope")]))
        #expect(errorCode(answer) == nil)
        #expect(answer["result"]?["isError"] == .bool(true))
        #expect(resultText(answer) == "There is no scene called \"Nope\".")
    }

    /// The one thing an agent most needs to be told, and the one a URL cannot
    /// say. Silence or a hang here is how an afternoon goes into a server that
    /// was working.
    @Test("an application that is not running says so")
    func notRunning() throws {
        let (server, _) = server(StubTransport().failing(.notRunning(path: "/tmp/x.sock")))
        let answer = call(server, "yunaudio_status")
        #expect(errorCode(answer) == nil)
        #expect(answer["result"]?["isError"] == .bool(true))
        let text = try #require(resultText(answer))
        #expect(text.contains("not running"))
        #expect(text.contains("/tmp/x.sock"))
    }

    @Test("status comes back as the JSON it was")
    func status() throws {
        let reading = JSONValue.object([
            "running": .bool(true), "muted": .bool(false), "inputDecibels": .double(-6.02),
            "routes": .int(2),
        ])
        let (server, _) = server(StubTransport().replying(.status(reading)))
        let answer = call(server, "yunaudio_status")
        #expect(answer["result"]?["isError"] == .bool(false))
        let text = try #require(resultText(answer))
        #expect(JSONValue.parse(text) == reading)
    }

    @Test("the names come back as two lists")
    func names() throws {
        let (server, _) = server(
            StubTransport().replying(.names(scenes: ["Voice call"], setups: ["Podcast"])))
        let answer = call(server, "yunaudio_list_names")
        let text = try #require(resultText(answer))
        let listed = try #require(JSONValue.parse(text))
        #expect(listed["scenes"] == .array([.string("Voice call")]))
        #expect(listed["setups"] == .array([.string("Podcast")]))
    }
}

// MARK: - The real socket, and the real binary

/// Everything above is a pure function. This is not: it is the listener the
/// application installs, the client the server uses, and — at the end — the
/// built `yunaudio-mcp` binary with a pipe on its stdin, which is exactly what
/// an MCP client does to it.
@Suite("End to end over the control socket")
struct ControlSocketTests {

    /// A path of this test's own, so a run never touches the socket the user's
    /// application is sitting on.
    private static func temporaryPath() -> String {
        NSTemporaryDirectory() + "yunaudio-test-\(UUID().uuidString.prefix(8)).sock"
    }

    /// Off the main thread, and with a deadline.
    ///
    /// The listener hands each request to the main actor, so a caller blocking
    /// the main thread while it waits would deadlock — and a deadlocked test
    /// hangs a run rather than failing it, which is the worst way for this to
    /// go wrong.
    private final class Box: @unchecked Sendable {
        var outcome: Result<ControlReply, any Error>?
    }

    private func send(_ client: ControlClient, _ request: ControlRequest) throws -> ControlReply
    {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.outcome = Result { try client.send(request) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success else {
            throw ControlError.transport("the reply did not arrive within five seconds")
        }
        return try #require(box.outcome).get()
    }

    /// The stub application, standing where `RouterModel` stands.
    @MainActor private final class Model {
        var isMuted = false
        func answer(_ request: ControlRequest) -> ControlReply {
            switch request {
            case .perform(.mute(let wanted)):
                isMuted = wanted ?? !isMuted
                return .message(isMuted ? "Microphone muted." : "Microphone unmuted.")
            case .perform(.preset(let name)):
                return .failure("There is no scene called \"\(name)\".")
            case .status:
                return .status(.object(["muted": .bool(isMuted), "routes": .int(2)]))
            case .names:
                return .names(scenes: ["Voice call"], setups: ["Podcast"])
            default:
                return .message("done")
            }
        }
    }

    @Test("a command crosses the socket, changes the application, and is read back")
    func roundTrip() async throws {
        let path = Self.temporaryPath()
        let model = await MainActor.run { Model() }
        let listener = ControlListener(path: path)
        try listener.start { request in model.answer(request) }
        defer { listener.stop() }

        let client = ControlClient(path: path)
        #expect(
            try send(client, .status)
                == .status(.object(["muted": .bool(false), "routes": .int(2)])))
        #expect(try send(client, .perform(.mute(true))) == .message("Microphone muted."))
        // The point of the socket: the change can be read back. A URL cannot
        // do this, which is why there is a socket at all.
        #expect(
            try send(client, .status)
                == .status(.object(["muted": .bool(true), "routes": .int(2)])))
        #expect(await model.isMuted)
        #expect(try send(client, .names) == .names(scenes: ["Voice call"], setups: ["Podcast"]))
        #expect(
            try send(client, .perform(.preset("Nope")))
                == .failure("There is no scene called \"Nope\"."))
    }

    /// Nothing listening has to be an answer rather than a wait. An agent told
    /// to hold on has nothing to do with that.
    @Test("nothing listening is an immediate answer")
    func nothingListening() {
        let client = ControlClient(path: Self.temporaryPath())
        #expect(throws: ControlError.self) { try client.send(.status) }
    }

    /// `sun_path` is a fixed 104 bytes and the overflow is *silent*: the server
    /// would bind a truncated path and the client would look somewhere else,
    /// both reporting success.
    @Test("a path too long to carry is refused rather than truncated")
    func pathTooLong() {
        let path = "/tmp/" + String(repeating: "a", count: 200) + ".sock"
        #expect(throws: ControlError.self) { try ControlClient(path: path).send(.status) }
        #expect(throws: ControlError.self) {
            try ControlListener(path: path).start { _ in .message("") }
        }
    }

    /// A socket file outlives the process that made it, so one on disk means
    /// nothing on its own — but one with something *answering* is another copy
    /// of the application and must not be stolen from.
    @Test("a second listener refuses the socket rather than taking it")
    func doesNotStealTheSocket() async throws {
        let path = Self.temporaryPath()
        let model = await MainActor.run { Model() }
        let first = ControlListener(path: path)
        try first.start { request in model.answer(request) }
        defer { first.stop() }

        #expect(throws: ControlError.self) {
            try ControlListener(path: path).start { _ in .message("") }
        }
        // And the original is still the one answering.
        #expect(try send(ControlClient(path: path), .names).isNames)

        // Debris from a crash, on the other hand, has to be cleared: nothing is
        // answering, so binding over it is the only way this ever starts again.
        first.stop()
        FileManager.default.createFile(atPath: path, contents: nil)
        let second = ControlListener(path: path)
        try second.start { request in model.answer(request) }
        defer { second.stop() }
        #expect(try send(ControlClient(path: path), .names).isNames)
    }

    /// A line that is not a request must come back as a refusal. The listener
    /// is reachable by anything the user can run, and a crash here would take
    /// the audio down with it.
    @Test("rubbish on the socket is answered, not fatal")
    func rubbishOnTheSocket() async throws {
        let path = Self.temporaryPath()
        let model = await MainActor.run { Model() }
        let listener = ControlListener(path: path)
        try listener.start { request in model.answer(request) }
        defer { listener.stop() }

        let answers = try await raw(
            path, lines: ["not json", #"{"request":"detonate"}"#, "", #"{"request":"status"}"#])
        #expect(answers.count == 3)
        #expect(JSONValue.parse(answers[0])?["ok"] == .bool(false))
        #expect(JSONValue.parse(answers[1])?["ok"] == .bool(false))
        #expect(JSONValue.parse(answers[2])?["ok"] == .bool(true))
    }

    /// Writes lines straight at the socket, bypassing `ControlClient`, because
    /// what is being checked here is what the listener does with input the
    /// client would never produce.
    private func raw(_ path: String, lines: [String]) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    with: Result {
                        var address = try UnixSocket.address(for: path)
                        let descriptor = try UnixSocket.make()
                        defer { close(descriptor) }
                        guard
                            UnixSocket.withSockaddr(&address, { connect(descriptor, $0, $1) })
                                == 0
                        else { throw ControlError.notRunning(path: path) }
                        var answers: [String] = []
                        for line in lines {
                            UnixSocket.writeAll(descriptor, line)
                            guard !line.isEmpty else { continue }
                            guard let answer = UnixSocket.readLine(descriptor) else { break }
                            answers.append(answer)
                        }
                        return answers
                    })
            }
        }
    }
}

extension ControlReply {
    fileprivate var isNames: Bool {
        if case .names = self { return true }
        return false
    }
}

/// The whole thing, as an MCP client meets it: the built binary, a pipe on its
/// stdin, a pipe on its stdout, and a real socket at the far end.
///
/// Everything else here is either a pure function or one process. This is the
/// only check that would notice the two mistakes that live between them —
/// stdout block-buffering a complete and correct answer into a pipe nobody
/// flushes, and a response the framing splits in half.
@Suite("The built server, driven the way a client drives it")
struct MCPBinaryTests {

    /// Where `swift build` put it. Both layouts are looked at because the build
    /// system has moved the products directory once already in this project's
    /// life, and a check that silently stops running is worse than no check.
    private static func binary() -> String? {
        if let named = ProcessInfo.processInfo.environment["YUNAUDIO_MCP_BINARY"] {
            return named
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for candidate in ["out/Products/Debug", "debug", "out/Products/Release", "release"] {
            let path = root.appendingPathComponent(".build/\(candidate)/yunaudio-mcp").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    @MainActor private final class Model {
        var isMuted = false
        func answer(_ request: ControlRequest) -> ControlReply {
            switch request {
            case .perform(.mute(let wanted)):
                isMuted = wanted ?? !isMuted
                return .message(isMuted ? "Microphone muted." : "Microphone unmuted.")
            case .status:
                return .status(.object(["muted": .bool(isMuted), "running": .bool(false)]))
            case .names:
                return .names(scenes: ["Voice call"], setups: ["Podcast"])
            default:
                return .message("done")
            }
        }
    }

    @Test("a session with the real binary: initialise, list, call, read back")
    func session() async throws {
        let executable = try #require(
            Self.binary(), "yunaudio-mcp was not built; there is nothing to drive")
        let path = NSTemporaryDirectory() + "yunaudio-mcp-\(UUID().uuidString.prefix(8)).sock"
        let model = await MainActor.run { Model() }
        let listener = ControlListener(path: path)
        try listener.start { request in model.answer(request) }
        defer { listener.stop() }

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"yunaudio_status","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"yunaudio_mute","arguments":{"state":true}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"yunaudio_status"}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"yunaudio_mute","arguments":{"state":"yes"}}}"#,
            "{not json",
        ]
        let lines = try await run(executable, socket: path, sending: requests)

        // Eight requests, one of them a notification, so seven answers. A
        // notification that produced an eighth would be a response the client
        // has nothing to match to.
        #expect(lines.count == 7, "\(lines.joined(separator: " | "))")
        let answers = lines.map { JSONValue.parse($0) ?? .null }

        #expect(answers[0]["id"] == .int(1))
        #expect(answers[0]["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(answers[1]["result"]?["tools"]?.arrayValue?.count == 9)
        #expect(
            JSONValue.parse(
                answers[2]["result"]?["content"]?.arrayValue?[0]["text"]?.stringValue ?? "")?[
                    "muted"] == .bool(false))
        #expect(
            answers[3]["result"]?["content"]?.arrayValue?[0]["text"]
                == .string("Microphone muted."))
        // The point of the whole exercise: the change is visible on the next
        // read, through the binary, over the socket, in the model.
        #expect(
            JSONValue.parse(
                answers[4]["result"]?["content"]?.arrayValue?[0]["text"]?.stringValue ?? "")?[
                    "muted"] == .bool(true))
        #expect(await model.isMuted)
        #expect(answers[5]["error"]?["code"] == .int(-32602))
        #expect(answers[6]["error"]?["code"] == .int(-32700))
    }

    /// Spawns it, writes every line, closes stdin, and reads what came back.
    /// Closing stdin is how an MCP client says it is finished, and a server that
    /// does not exit on it is one the client has to kill.
    private func run(
        _ executable: String, socket: String, sending requests: [String]
    )
        async throws -> [String]
    {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    with: Result {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: executable)
                        process.arguments = ["--socket", socket]
                        let input = Pipe()
                        let output = Pipe()
                        process.standardInput = input
                        process.standardOutput = output
                        process.standardError = FileHandle.nullDevice
                        try process.run()
                        input.fileHandleForWriting.write(
                            Data(requests.map { $0 + "\n" }.joined().utf8))
                        try input.fileHandleForWriting.close()
                        let data = output.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        #expect(process.terminationStatus == 0)
                        return String(decoding: data, as: UTF8.self)
                            .split(separator: "\n").map(String.init)
                    })
            }
        }
    }
}
