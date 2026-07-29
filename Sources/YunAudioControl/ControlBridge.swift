import Foundation

/// The wire between another process and the running application.
///
/// The URL scheme is one-way. `open yunaudio://mute/on` returns as soon as
/// Launch Services has handed the event over — it cannot say whether the
/// microphone is now muted, whether the scene existed, or whether the
/// application was even there to hear it. That is fine for a Stream Deck key,
/// where the person pressing it is looking at the result, and useless for an
/// agent, where nobody is.
///
/// So: a socket, one line of JSON each way. Two other reply paths were
/// considered and are worth writing down so they are not tried again as though
/// they were new ideas.
///
/// - **A distributed notification with a reply notification.** It works, but it
///   is a broadcast bus: correlating a reply with its request needs an id and a
///   timeout invented on top, every other process on the machine can watch the
///   traffic, and "no reply yet" and "the application is not running" are the
///   same observation until the timeout expires. That last one matters most —
///   an agent needs to be told the application is not running, not to wait.
/// - **App Intents.** Ruled out already, for the reason in `RemoteCommand`: the
///   metadata is extracted by an Xcode build phase this project does not have.
///
/// A Unix domain socket answers all of it for less code: `connect` failing is an
/// immediate, unambiguous "nothing is listening", the reply belongs to the
/// request by construction, and the filesystem does the access control.
public enum ControlSocket {
    /// Where the socket lives, unless something says otherwise.
    ///
    /// Beside the rest of the application's state rather than in a temporary
    /// directory, because a path that changes between logins is a path an MCP
    /// client's configuration cannot name.
    public static var defaultPath: String {
        if let override = ProcessInfo.processInfo.environment[environmentKey],
            !override.isEmpty
        {
            return override
        }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return
            (support?.appendingPathComponent("YunAudio/control.sock").path
            ?? "/tmp/yunaudio-control.sock")
    }

    /// Overrides `defaultPath`. Both ends read it, which is what lets a test
    /// stand up a real listener and a real client on a path of its own rather
    /// than fighting over the one the user's application is using.
    public static let environmentKey = "YUNAUDIO_CONTROL_SOCKET"
}

// MARK: - What crosses it

/// Something another process is asking the application for.
public enum ControlRequest: Equatable, Sendable {
    /// Do this. Carried as its URL rather than as a decoded command, so the
    /// grammar in `RemoteCommand` is the only grammar on the wire — a request
    /// that the URL scheme would refuse is refused here too, by the same code.
    case perform(RemoteCommand)
    /// What is the application doing.
    case status
    /// What scenes and setups exist, by name.
    case names

    public var json: JSONValue {
        switch self {
        case .perform(let command):
            .object(["request": .string("perform"), "url": .string(command.url.absoluteString)])
        case .status:
            .object(["request": .string("status")])
        case .names:
            .object(["request": .string("names")])
        }
    }

    /// Strict, for the same reason `RemoteCommand.parse` is: this arrives from
    /// another process, and guessing what an unrecognised request meant is how a
    /// mute becomes a stop.
    public init?(json: JSONValue) {
        switch json["request"]?.stringValue {
        case "perform":
            guard let text = json["url"]?.stringValue, let url = URL(string: text),
                let command = RemoteCommand.parse(url)
            else { return nil }
            self = .perform(command)
        case "status":
            self = .status
        case "names":
            self = .names
        default:
            return nil
        }
    }
}

/// What the application says back.
public enum ControlReply: Equatable, Sendable {
    /// What happened, in the sentence the model produced.
    case message(String)
    case status(JSONValue)
    case names(scenes: [String], setups: [String])
    /// The command named something this application does not have, or could not
    /// be carried out. Distinct from a transport failure: this one reached the
    /// application and was answered.
    case failure(String)

    public var json: JSONValue {
        switch self {
        case .message(let text):
            .object(["ok": .bool(true), "message": .string(text)])
        case .status(let value):
            .object(["ok": .bool(true), "status": value])
        case .names(let scenes, let setups):
            .object([
                "ok": .bool(true),
                "scenes": .array(scenes.map(JSONValue.string)),
                "setups": .array(setups.map(JSONValue.string)),
            ])
        case .failure(let reason):
            .object(["ok": .bool(false), "error": .string(reason)])
        }
    }

    public init?(json: JSONValue) {
        guard let ok = json["ok"]?.boolValue else { return nil }
        guard ok else {
            self = .failure(json["error"]?.stringValue ?? "unknown failure")
            return
        }
        if let status = json["status"] {
            self = .status(status)
        } else if let scenes = json["scenes"]?.arrayValue,
            let setups = json["setups"]?.arrayValue
        {
            self = .names(
                scenes: scenes.compactMap(\.stringValue),
                setups: setups.compactMap(\.stringValue))
        } else if let message = json["message"]?.stringValue {
            self = .message(message)
        } else {
            return nil
        }
    }
}

/// Why a request did not reach the application, or did not come back.
///
/// Separate from `ControlReply.failure`, which is the application answering.
/// An agent told "there is no scene called Podcast" should try another name; an
/// agent told "YunAudio is not running" should stop and say so.
public enum ControlError: Error, Equatable, Sendable {
    case notRunning(path: String)
    case alreadyServing(path: String)
    case pathTooLong(path: String, limit: Int)
    case transport(String)

    public var message: String {
        switch self {
        case .notRunning(let path):
            "YunAudio is not running, or is not listening on \(path). "
                + "Launch YunAudio and try again."
        case .alreadyServing(let path):
            "Another copy of YunAudio is already listening on \(path)."
        case .pathTooLong(let path, let limit):
            "The control socket path is \(path.utf8.count) bytes and a Unix domain "
                + "socket allows \(limit): \(path)"
        case .transport(let detail):
            "The control socket failed: \(detail)"
        }
    }
}

// MARK: - Sockets

/// The socket calls both ends need, in one place so the SIGPIPE and framing
/// decisions are made once.
enum UnixSocket {

    /// How many bytes of path a `sockaddr_un` can carry, minus the terminator.
    static var pathLimit: Int {
        MemoryLayout<sockaddr_un>.size - MemoryLayout<UInt8>.size * 2 - 1
    }

    /// Fills in a `sockaddr_un`, or refuses.
    ///
    /// `sun_path` is a fixed 104-byte array and the overflow is silent: a long
    /// enough path binds a *truncated* one, so the server listens somewhere the
    /// client will never look and both ends report success. Refusing loudly is
    /// the only version of this that can be debugged.
    static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= pathLimit else {
            throw ControlError.pathTooLong(path: path, limit: pathLimit)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
            destination[bytes.count] = 0
        }
        return address
    }

    /// A socket that will not kill the process.
    ///
    /// Writing to a socket whose far end has gone raises SIGPIPE, and the
    /// default disposition terminates. For the application that would mean an
    /// MCP client quitting mid-reply takes the audio down with it, which is an
    /// absurd way to lose a session.
    static func make() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ControlError.transport("socket: \(String(cString: strerror(errno)))")
        }
        var on: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    static func withSockaddr<T>(
        _ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Reads up to and including the next newline. Nil at end of stream.
    ///
    /// Byte at a time. A control message is a few hundred bytes and arrives
    /// once a second at worst, so the cost is irrelevant and the alternative —
    /// a buffer that has to hold whatever came after the newline — is state
    /// that has to be right.
    static func readLine(_ descriptor: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = read(descriptor, &byte, 1)
            if count <= 0 {
                return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
            }
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
            // A line this long is not a control message; it is a process that
            // connected to the wrong socket. Stopping is better than growing.
            if bytes.count > 1 << 20 { return nil }
        }
    }

    /// Writes all of it, or gives up. `write` is allowed to write less than it
    /// was given, and a half-written JSON line is a parse error on the far end
    /// rather than a short read anybody would recognise as one.
    @discardableResult
    static func writeAll(_ descriptor: Int32, _ text: String) -> Bool {
        var bytes = Array(text.utf8)
        bytes.append(UInt8(ascii: "\n"))
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer {
                write(descriptor, $0.baseAddress, $0.count)
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}

// MARK: - The client

/// Asks the running application something, over the control socket.
///
/// One connection per request rather than one held open. A request is a few
/// hundred bytes over a local socket, so the connect costs microseconds, and in
/// exchange there is no reconnect logic, no half-open state to notice, and an
/// application restarted between two calls is invisible instead of fatal.
public struct ControlClient: Sendable {
    public let path: String

    public init(path: String = ControlSocket.defaultPath) {
        self.path = path
    }

    public func send(_ request: ControlRequest) throws -> ControlReply {
        var address = try UnixSocket.address(for: path)
        let descriptor = try UnixSocket.make()
        defer { close(descriptor) }

        let connected = UnixSocket.withSockaddr(&address) { pointer, length in
            connect(descriptor, pointer, length)
        }
        guard connected == 0 else {
            // Every reason connect fails here — no such file, nothing accepting,
            // a socket left behind by a crash — is the same fact to whoever
            // asked: the application is not there.
            throw ControlError.notRunning(path: path)
        }

        guard UnixSocket.writeAll(descriptor, request.json.text) else {
            throw ControlError.transport("the request could not be sent")
        }
        guard let line = UnixSocket.readLine(descriptor) else {
            throw ControlError.transport(
                "the application closed the connection without answering")
        }
        guard let json = JSONValue.parse(line), let reply = ControlReply(json: json) else {
            throw ControlError.transport("the application answered with something unreadable")
        }
        return reply
    }
}

// MARK: - The listener

/// The application's end of the control socket.
///
/// Lives here rather than in the application target so that a test can stand up
/// the *real* server against a stub model. A hand-written stub socket in a test
/// proves the test's socket works.
public final class ControlListener: @unchecked Sendable {

    /// Answers a request. On the main actor because the model is, and every
    /// question here is about the model.
    public typealias Handler = @MainActor @Sendable (ControlRequest) -> ControlReply

    public let path: String
    /// Guards `descriptor` alone. The accept loop reads it, `stop` closes it,
    /// and those are on different threads by construction.
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    public init(path: String = ControlSocket.defaultPath) {
        self.path = path
    }

    /// Binds and begins accepting. Throws rather than failing quietly: an
    /// application whose control socket did not come up looks exactly like one
    /// that is running normally, right up until an agent asks it something.
    public func start(handler: @escaping Handler) throws {
        var address = try UnixSocket.address(for: path)

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)

        // A socket file outlives the process that made it, so the one on disk
        // means nothing on its own. Ask it. Something answering is a copy of
        // this application already running and must not be stolen from;
        // nothing answering is debris, and unlinking it is the only way this
        // ever starts again.
        //
        // Debris is not hypothetical: the flow check ends on `exit()`, which
        // does not run `applicationWillTerminate`, so every flow-check run
        // leaves one of these behind. Cleaning up on the way out is worth
        // doing, but it can never be the thing this relies on — a crash has no
        // way out to clean up on.
        if isServed(&address) { throw ControlError.alreadyServing(path: path) }
        unlink(path)

        let listening = try UnixSocket.make()
        var reuse: Int32 = 1
        setsockopt(
            listening, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        guard UnixSocket.withSockaddr(&address, { bind(listening, $0, $1) }) == 0 else {
            let reason = String(cString: strerror(errno))
            close(listening)
            throw ControlError.transport("bind \(path): \(reason)")
        }
        // The socket carries the ability to mute somebody's microphone and read
        // what they are recording. `bind` applies the umask, which on a default
        // account leaves it group- and world-readable.
        chmod(path, 0o600)

        guard listen(listening, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(listening)
            unlink(path)
            throw ControlError.transport("listen \(path): \(reason)")
        }

        lock.lock()
        descriptor = listening
        lock.unlock()

        // A thread rather than a `DispatchSource`, because `accept` blocking is
        // exactly the behaviour wanted and the loop ends when `stop` closes the
        // descriptor out from under it.
        let thread = Thread { [weak self] in self?.acceptLoop(listening, handler) }
        thread.name = "yunaudio.control"
        thread.start()
    }

    /// Closes the socket and takes the file away, so the next launch does not
    /// have to reason about debris it left itself.
    public func stop() {
        lock.lock()
        let listening = descriptor
        descriptor = -1
        lock.unlock()
        guard listening >= 0 else { return }
        close(listening)
        unlink(path)
    }

    private func isServed(_ address: inout sockaddr_un) -> Bool {
        guard let probe = try? UnixSocket.make() else { return false }
        defer { close(probe) }
        return UnixSocket.withSockaddr(&address) { connect(probe, $0, $1) } == 0
    }

    private func acceptLoop(_ listening: Int32, _ handler: @escaping Handler) {
        while true {
            let client = accept(listening, nil, nil)
            guard client >= 0 else {
                // `stop` closed it, or the application is going away. Either
                // way there is nothing left to accept on.
                lock.lock()
                let stopped = descriptor < 0
                lock.unlock()
                if stopped || errno != EINTR { return }
                continue
            }
            var on: Int32 = 1
            setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Each connection on its own, so one client sitting idle with a
            // socket open cannot stop a second from being served.
            DispatchQueue.global(qos: .userInitiated).async { Self.serve(client, handler) }
        }
    }

    private static func serve(_ client: Int32, _ handler: @escaping Handler) {
        defer { close(client) }
        while let line = UnixSocket.readLine(client) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let reply: ControlReply
            if let json = JSONValue.parse(line), let request = ControlRequest(json: json) {
                // Synchronously, because the answer is the point and the next
                // request on this connection must see the effect of this one.
                reply = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { handler(request) }
                }
            } else {
                reply = .failure("not a request this application understands: \(line)")
            }
            guard UnixSocket.writeAll(client, reply.json.text) else { return }
        }
    }
}
