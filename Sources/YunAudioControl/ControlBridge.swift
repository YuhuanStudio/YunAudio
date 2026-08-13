import Darwin
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
/// - **A distributed notification with a reply notification.** It works — it
///   was what `yunaudio-cli` used, for a while, beside this — but it is a
///   broadcast bus: correlating a reply with its request needs an id and a
///   timeout invented on top, every other process on the machine can watch the
///   traffic, and "no reply yet" and "the application is not running" are the
///   same observation until the timeout expires. That last one matters most —
///   an agent needs to be told the application is not running, not to wait.
///   The command line has been moved onto this socket and that channel is gone;
///   one vocabulary over two transports was one transport too many.
/// - **App Intents.** Ruled out already, for the reason in `RemoteCommand`: the
///   metadata is extracted by an Xcode build phase this project does not have.
///
/// A Unix domain socket answers all of it for less code: `connect` failing is an
/// immediate, unambiguous "nothing is listening", the reply belongs to the
/// request by construction, and the filesystem does the access control.
public enum ControlSocket {
    /// Maximum request or reply payload, before its framing newline.
    public static let maximumFrameBytes = 64 * 1024

    /// Connections admitted at once. Excess peers are closed before a worker
    /// or a main-actor job is created for them.
    public static let maximumActiveClients = 16

    /// The command-line and MCP side must always regain control in under two
    /// seconds, even when something accepted the connection and then went
    /// silent.
    public static let clientTransportTimeout: TimeInterval = 1.5

    /// A silent inbound peer gets one second to produce its complete request.
    static let serverReadTimeout: TimeInterval = 1
    static let serverWriteTimeout: TimeInterval = 0.5
    static let serverTotalTimeout: TimeInterval = 1.5

    /// The bundle a tool is looking for.
    ///
    /// A failed `connect` already means "nothing is listening", which is the
    /// whole answer for most callers. This sharpens the one case where it is
    /// not: an application that is in the menu bar and still not answering is
    /// an older build with no control socket in it, and "launch YunAudio" is
    /// unhelpful advice to somebody looking straight at it.
    public static let bundleIdentifier = "com.yuhuanstudio.yunaudio"

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
    ///
    /// `alternatives` is the names that would have worked, when the refusal was
    /// about a name. "There is no scene called Podcast" is a dead end and a
    /// list beside it is an answer, so it travels *with* the refusal rather
    /// than needing a second question — which is what the notification channel
    /// this replaced did, and what both front ends would otherwise have had to
    /// rebuild for themselves. Empty for every other kind of failure.
    case failure(String, alternatives: [String] = [])

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
        case .failure(let reason, let alternatives):
            // The key is left out entirely when there is nothing to suggest,
            // rather than sent as an empty array: a reader then has one
            // question — is it there — instead of two.
            alternatives.isEmpty
                ? .object(["ok": .bool(false), "error": .string(reason)])
                : .object([
                    "ok": .bool(false), "error": .string(reason),
                    "alternatives": .array(alternatives.map(JSONValue.string)),
                ])
        }
    }

    public init?(json: JSONValue) {
        guard let ok = json["ok"]?.boolValue else { return nil }
        guard ok else {
            self = .failure(
                json["error"]?.stringValue ?? "unknown failure",
                alternatives: json["alternatives"]?.arrayValue?.compactMap(\.stringValue)
                    ?? [])
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

extension ControlReply {
    /// A valid, fixed-size answer when an application-produced reply cannot fit
    /// in the transport frame. Closing the connection here would turn a model
    /// bug into an indistinguishable transport failure for every caller.
    static let oversizedWireFailure = ControlReply.failure(
        "The application produced a reply larger than 64 KiB.")

    /// JSON text that the socket can always carry in one frame.
    var boundedWireText: String {
        let proposed = json.text
        guard proposed.utf8.count <= ControlSocket.maximumFrameBytes else {
            let fallback = Self.oversizedWireFailure.json.text
            precondition(fallback.utf8.count <= ControlSocket.maximumFrameBytes)
            return fallback
        }
        return proposed
    }
}

/// Transport metadata carried beside, but not inside, `ControlRequest`.
///
/// Both processes are on the same machine and therefore share the same
/// monotonic uptime clock. Older clients omit the field and continue to receive
/// the server's admission-time bound.
private enum ControlRequestEnvelope {
    static let deadlineKey = "deadlineUptimeNanoseconds"

    enum ParsedDeadline {
        case absent
        case invalid
        case value(UInt64)
    }

    static func encode(_ request: ControlRequest, deadline: UnixSocket.Deadline) -> JSONValue {
        guard case .object(var fields) = request.json else {
            preconditionFailure("a control request must be a JSON object")
        }
        fields[deadlineKey] = .int(Int(clamping: deadline.uptimeNanoseconds))
        return .object(fields)
    }

    static func deadline(in json: JSONValue) -> ParsedDeadline {
        guard let encoded = json[deadlineKey] else { return .absent }
        if let value = encoded.intValue, value >= 0 { return .value(UInt64(value)) }
        if let text = encoded.stringValue, let value = UInt64(text) {
            return .value(value)
        }
        return .invalid
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

/// The monotonic end of one admitted control transaction.
///
/// Passing the original socket deadline into the application keeps every
/// asynchronous continuation inside the caller's opportunity to receive its
/// answer. A handler may use less time, but must not manufacture a fresh 1.5
/// seconds after the request has already waited for the main actor.
public struct ControlRequestDeadline: Equatable, Sendable {
    public let uptimeNanoseconds: UInt64

    public init(uptimeNanoseconds: UInt64) {
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    public var remainingNanoseconds: UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return uptimeNanoseconds > now ? uptimeNanoseconds - now : 0
    }

    public var remainingTime: TimeInterval {
        Double(remainingNanoseconds) / 1_000_000_000
    }

    public var hasExpired: Bool { remainingNanoseconds == 0 }
}

// MARK: - Sockets

/// The socket calls both ends need, in one place so the SIGPIPE and framing
/// decisions are made once.
enum UnixSocket {

    enum IOError: Error, Equatable {
        case closed
        case timedOut
        case frameTooLarge(limit: Int)
        case system(String)
    }

    /// A monotonic boundary shared by every phase of one transaction.
    struct Deadline: Sendable {
        let uptimeNanoseconds: UInt64

        init(after seconds: TimeInterval) {
            let interval = UInt64(max(0, seconds) * 1_000_000_000)
            uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds &+ interval
        }

        private init(uptimeNanoseconds: UInt64) {
            self.uptimeNanoseconds = uptimeNanoseconds
        }

        func limited(toUptimeNanoseconds requested: UInt64) -> Deadline {
            Deadline(uptimeNanoseconds: min(uptimeNanoseconds, requested))
        }

        func limited(to seconds: TimeInterval) -> Deadline {
            let interval = UInt64(max(0, seconds) * 1_000_000_000)
            let phase = DispatchTime.now().uptimeNanoseconds &+ interval
            return Deadline(uptimeNanoseconds: min(uptimeNanoseconds, phase))
        }

        var dispatchTime: DispatchTime {
            DispatchTime(uptimeNanoseconds: uptimeNanoseconds)
        }

        var pollMilliseconds: Int32 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard uptimeNanoseconds > now else { return 0 }
            let nanoseconds = uptimeNanoseconds - now
            let roundedUp = (nanoseconds + 999_999) / 1_000_000
            return Int32(min(UInt64(Int32.max), max(1, roundedUp)))
        }
    }

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

    /// Connects without allowing a full listen queue to block the caller.
    static func connect(
        _ descriptor: Int32, to address: inout sockaddr_un, timeout: TimeInterval,
        total: Deadline
    ) -> Bool {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }
        let result = withSockaddr(&address) { pointer, length in
            Darwin.connect(descriptor, pointer, length)
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS || errno == EAGAIN || errno == EWOULDBLOCK else {
            return false
        }
        guard wait(descriptor, for: Int16(POLLOUT), until: total.limited(to: timeout)) else {
            return false
        }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
            socketError == 0
        else { return false }
        return true
    }

    /// Accepted descriptors are made non-blocking so a readiness race cannot
    /// turn a bounded poll into an unbounded read or write.
    static func makeNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL, 0)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
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

    /// Reads exactly one newline-terminated frame within both phase and total
    /// deadlines. Bytes after that newline are intentionally discarded when the
    /// caller closes the one-request connection.
    static func readLine(
        _ descriptor: Int32, maximumBytes: Int = ControlSocket.maximumFrameBytes,
        timeout: TimeInterval, total: Deadline
    ) throws -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(maximumBytes, 4096))
        var chunk = [UInt8](repeating: 0, count: 4096)
        let readDeadline = total.limited(to: timeout)
        while true {
            guard wait(descriptor, for: Int16(POLLIN), until: readDeadline) else {
                throw IOError.timedOut
            }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count == 0 { throw IOError.closed }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw IOError.system(String(cString: strerror(errno)))
            }
            let received = chunk.prefix(count)
            if let newline = received.firstIndex(of: UInt8(ascii: "\n")) {
                let beforeNewline = received.distance(from: received.startIndex, to: newline)
                guard bytes.count + beforeNewline <= maximumBytes else {
                    throw IOError.frameTooLarge(limit: maximumBytes)
                }
                bytes.append(contentsOf: received.prefix(beforeNewline))
                return String(decoding: bytes, as: UTF8.self)
            }
            guard bytes.count + count <= maximumBytes else {
                throw IOError.frameTooLarge(limit: maximumBytes)
            }
            bytes.append(contentsOf: received)
        }
    }

    /// Writes all of it, or gives up. `write` is allowed to write less than it
    /// was given, and a half-written JSON line is a parse error on the far end
    /// rather than a short read anybody would recognise as one.
    @discardableResult
    static func writeAll(
        _ descriptor: Int32, _ text: String,
        maximumBytes: Int = ControlSocket.maximumFrameBytes,
        timeout: TimeInterval, total: Deadline
    ) -> Bool {
        var bytes = Array(text.utf8)
        guard bytes.count <= maximumBytes else { return false }
        bytes.append(UInt8(ascii: "\n"))
        var offset = 0
        let writeDeadline = total.limited(to: timeout)
        while offset < bytes.count {
            guard wait(descriptor, for: Int16(POLLOUT), until: writeDeadline) else {
                return false
            }
            let written = bytes[offset...].withUnsafeBufferPointer {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    private static func wait(
        _ descriptor: Int32, for events: Int16, until deadline: Deadline
    ) -> Bool {
        while true {
            let milliseconds = deadline.pollMilliseconds
            guard milliseconds > 0 else { return false }
            var state = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&state, 1, milliseconds)
            if result > 0 {
                let terminal = Int16(POLLERR | POLLHUP | POLLNVAL)
                return state.revents & (events | terminal) != 0
            }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
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
        try send(request, transportTimeout: ControlSocket.clientTransportTimeout)
    }

    /// The same path as the public client with an injectable total bound for
    /// deterministic deadline tests. Production callers use the fixed public
    /// transport timeout above.
    func send(
        _ request: ControlRequest, transportTimeout: TimeInterval
    ) throws -> ControlReply {
        var address = try UnixSocket.address(for: path)
        let descriptor = try UnixSocket.make()
        defer { close(descriptor) }
        let total = UnixSocket.Deadline(after: transportTimeout)

        let connected = UnixSocket.connect(
            descriptor, to: &address, timeout: 0.5, total: total)
        guard connected else {
            // Every reason connect fails here — no such file, nothing accepting,
            // a socket left behind by a crash — is the same fact to whoever
            // asked: the application is not there.
            throw ControlError.notRunning(path: path)
        }

        guard
            UnixSocket.writeAll(
                descriptor, ControlRequestEnvelope.encode(request, deadline: total).text,
                timeout: 0.5, total: total)
        else {
            throw ControlError.transport("the request could not be sent")
        }
        let line: String
        do {
            line = try UnixSocket.readLine(
                descriptor, timeout: ControlSocket.clientTransportTimeout, total: total)
        } catch UnixSocket.IOError.timedOut {
            throw ControlError.transport("the application did not answer within 1.5 seconds")
        } catch UnixSocket.IOError.frameTooLarge(let limit) {
            throw ControlError.transport(
                "the application answered with more than \(limit) bytes")
        } catch {
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

/// Keeps a listener admission occupied until both the socket worker and any
/// main-actor job it submitted have finished. If the main actor stalls, the
/// socket still closes at its deadline but at most sixteen jobs can be queued.
private final class ControlAdmission: @unchecked Sendable {
    let deadline: UnixSocket.Deadline

    private let lock = NSLock()
    private var references = 1
    private var completion: (@Sendable () -> Void)?

    init(deadline: UnixSocket.Deadline, completion: @escaping @Sendable () -> Void) {
        self.deadline = deadline
        self.completion = completion
    }

    func retain() {
        lock.lock()
        precondition(references > 0)
        references += 1
        lock.unlock()
    }

    func release() {
        let finished: (@Sendable () -> Void)?
        lock.lock()
        precondition(references > 0)
        references -= 1
        if references == 0 {
            finished = completion
            completion = nil
        } else {
            finished = nil
        }
        lock.unlock()
        finished?()
    }
}

/// A reply handed across the worker/main-actor boundary without letting the
/// worker wait past the transaction deadline.
private final class PendingControlReply: @unchecked Sendable {
    enum Cancellation {
        case deadline
        case stopped
    }

    private enum State {
        case awaiting
        case completed(ControlReply)
        case cancelled(Cancellation)
    }

    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let deadline: UnixSocket.Deadline
    private var state: State = .awaiting

    init(deadline: UnixSocket.Deadline) {
        self.deadline = deadline
    }

    func begin() -> Bool {
        let decision: (begins: Bool, signals: Bool) = lock.withLock {
            guard case .awaiting = state else { return (false, false) }
            guard deadline.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds else {
                state = .cancelled(.deadline)
                return (false, true)
            }
            return (true, false)
        }
        if decision.signals { ready.signal() }
        return decision.begins
    }

    @discardableResult
    func finish(_ reply: ControlReply) -> Bool {
        let decision: (Bool, Bool) = lock.withLock {
            switch state {
            case .awaiting:
                guard deadline.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds else {
                    state = .cancelled(.deadline)
                    return (false, true)
                }
                state = .completed(reply)
                return (true, true)
            case .completed:
                return (false, false)
            case .cancelled:
                return (false, false)
            }
        }
        if decision.1 { ready.signal() }
        return decision.0
    }

    @discardableResult
    func cancel(_ reason: Cancellation) -> Bool {
        let cancelled = lock.withLock {
            guard case .awaiting = state else { return false }
            state = .cancelled(reason)
            return true
        }
        if cancelled { ready.signal() }
        return cancelled
    }

    func wait() -> ControlReply? {
        if ready.wait(timeout: deadline.dispatchTime) != .success {
            _ = cancel(.deadline)
        }
        return lock.withLock {
            guard case .completed(let reply) = state else { return nil }
            return reply
        }
    }
}

/// One ownership epoch for the listening descriptor.
///
/// `close` from a different thread does not join a blocked `accept`, and the
/// kernel may give that integer to the next socket before the old loop has
/// observed the close. The accept thread is therefore the descriptor's only
/// close owner. `stop` invalidates the epoch and wakes it with `shutdown`; if
/// scheduling delays the acknowledgement, the still-open descriptor remains
/// quarantined in this object and cannot be reused for the next epoch.
private final class ControlListenerGeneration: @unchecked Sendable {
    let epoch: UInt64
    let descriptor: Int32

    private let lock = NSLock()
    private let acceptLoopFinished = DispatchSemaphore(value: 0)
    private let wakeReader: Int32
    private let wakeWriter: Int32
    private var accepting = true
    private var descriptorsAreOpen = true

    init(epoch: UInt64, descriptor: Int32) throws {
        var wakeDescriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &wakeDescriptors) == 0 else {
            throw ControlError.transport(
                "socketpair: \(String(cString: strerror(errno)))")
        }
        self.epoch = epoch
        self.descriptor = descriptor
        wakeReader = wakeDescriptors[0]
        wakeWriter = wakeDescriptors[1]
        var on: Int32 = 1
        setsockopt(
            wakeWriter, SOL_SOCKET, SO_NOSIGPIPE, &on,
            socklen_t(MemoryLayout<Int32>.size))
    }

    var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    func requestStop() {
        lock.lock()
        accepting = false
        if descriptorsAreOpen {
            var marker: UInt8 = 1
            while Darwin.write(wakeWriter, &marker, 1) < 0, errno == EINTR {}
        }
        lock.unlock()
    }

    /// Sleeps without periodic wakeups until either a client or `stop` arrives.
    func waitForConnection() -> Bool {
        while isAccepting {
            var states = [
                pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeReader, events: Int16(POLLIN), revents: 0),
            ]
            let result = Darwin.poll(&states, nfds_t(states.count), -1)
            if result < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard isAccepting else { return false }
            let terminal = Int16(POLLERR | POLLHUP | POLLNVAL)
            if states[1].revents & (Int16(POLLIN) | terminal) != 0 { return false }
            if states[0].revents & terminal != 0 { return false }
            if states[0].revents & Int16(POLLIN) != 0 { return true }
        }
        return false
    }

    /// Called exactly once, and only by the accept thread.
    func finishAccepting() {
        lock.lock()
        accepting = false
        if descriptorsAreOpen {
            close(descriptor)
            close(wakeReader)
            close(wakeWriter)
            descriptorsAreOpen = false
        }
        lock.unlock()
        acceptLoopFinished.signal()
    }

    func waitForAcceptLoop(timeout: TimeInterval) -> Bool {
        acceptLoopFinished.wait(timeout: .now() + timeout) == .success
    }
}

/// The application's end of the control socket.
///
/// Lives here rather than in the application target so that a test can stand up
/// the *real* server against a stub model. A hand-written stub socket in a test
/// proves the test's socket works.
public final class ControlListener: @unchecked Sendable {

    /// A listener thread must not keep the listener alive forever merely by
    /// waiting for a connection; otherwise `deinit` could never call `stop`.
    private final class WeakOwner: @unchecked Sendable {
        weak var value: ControlListener?

        init(_ value: ControlListener) {
            self.value = value
        }
    }

    /// Publishes the first answer while the original transaction is alive.
    public typealias Reply = @Sendable (ControlReply) -> Void

    /// Admits a request on MainActor without making that actor wait for its
    /// result. The callback may arrive from any executor; the listener itself
    /// creates no task and keeps no more than the fixed client admission cap.
    public typealias Handler =
        @MainActor @Sendable (ControlRequest, ControlRequestDeadline, @escaping Reply) -> Void

    public let path: String
    /// Serialises whole start/stop transactions. The state lock cannot be held
    /// while stop waits for an accept acknowledgement because that loop needs
    /// the state lock to publish its exit.
    private let lifecycleLock = NSLock()
    /// Guards the listener, admitted work and accepted descriptors. `stop`
    /// shuts the descriptors down; their workers remain their sole closers so a
    /// reused descriptor can never be closed by the wrong connection.
    private let lock = NSLock()
    private let scheduleOnMainActor:
        @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private var generation: ControlListenerGeneration?
    private var nextEpoch: UInt64 = 0
    private var clientDescriptors: [Int32: UInt64] = [:]
    private var pendingReplies: [Int32: PendingControlReply] = [:]
    private var activeAdmissions = 0
    private var peakAdmissions = 0
    private var acceptLoops = 0
    private var mostRecentStopAcknowledged = true
    private var acceptedReplies = 0
    private var rejectedReplies = 0
    private var stoppedReplies = 0

    /// An accept loop normally acknowledges immediately. The deadline is a
    /// responsiveness bound, not a licence to close its descriptor from the
    /// wrong thread: a late generation retains and eventually closes its own
    /// descriptor.
    static let stopAcknowledgementTimeout: TimeInterval = 0.25

    /// Observable bounds for executable tests; neither is an estimate derived
    /// from process-wide thread or file-descriptor counts.
    var activeClientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeAdmissions
    }

    public var openClientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clientDescriptors.count
    }

    var pendingReplyCount: Int { lock.withLock { pendingReplies.count } }

    var peakClientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakAdmissions
    }

    var activeAcceptLoopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return acceptLoops
    }

    var lastStopAcknowledged: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mostRecentStopAcknowledged
    }

    var listeningDescriptor: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return generation?.descriptor ?? -1
    }

    var listenerEpoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation?.epoch ?? nextEpoch
    }

    var acceptedReplyCount: Int { lock.withLock { acceptedReplies } }

    var rejectedReplyCount: Int { lock.withLock { rejectedReplies } }

    var stoppedReplyCount: Int { lock.withLock { stoppedReplies } }

    public convenience init(path: String = ControlSocket.defaultPath) {
        self.init(path: path) { operation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { operation() }
            }
        }
    }

    init(
        path: String,
        scheduleOnMainActor:
            @escaping @Sendable (
                @escaping @MainActor @Sendable () -> Void
            ) -> Void
    ) {
        self.path = path
        self.scheduleOnMainActor = scheduleOnMainActor
    }

    /// Binds and begins accepting. Throws rather than failing quietly: an
    /// application whose control socket did not come up looks exactly like one
    /// that is running normally, right up until an agent asks it something.
    public func start(handler: @escaping Handler) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        lock.lock()
        let isAlreadyRunning = generation != nil
        lock.unlock()
        guard !isAlreadyRunning else { throw ControlError.alreadyServing(path: path) }

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

        guard listen(listening, Int32(ControlSocket.maximumActiveClients)) == 0 else {
            let reason = String(cString: strerror(errno))
            close(listening)
            unlink(path)
            throw ControlError.transport("listen \(path): \(reason)")
        }

        // Readiness and stop are multiplexed below. Keeping accept itself
        // non-blocking closes the tiny race between poll reporting a peer and
        // that peer disappearing before `accept` begins.
        guard UnixSocket.makeNonBlocking(listening) else {
            let reason = String(cString: strerror(errno))
            close(listening)
            unlink(path)
            throw ControlError.transport("non-blocking listener \(path): \(reason)")
        }

        lock.lock()
        nextEpoch &+= 1
        let startedEpoch = nextEpoch
        lock.unlock()
        let startedGeneration: ControlListenerGeneration
        do {
            startedGeneration = try ControlListenerGeneration(
                epoch: startedEpoch, descriptor: listening)
        } catch {
            close(listening)
            unlink(path)
            throw error
        }
        lock.lock()
        generation = startedGeneration
        acceptLoops += 1
        lock.unlock()

        // A dedicated thread makes ownership literal: it polls both the
        // listener and the generation's wake socket, and it alone closes all
        // three descriptors before acknowledging. No stale integer can ever
        // name the next generation's socket.
        let owner = WeakOwner(self)
        let thread = Thread { [owner, startedGeneration] in
            Self.acceptLoop(owner: owner, generation: startedGeneration, handler: handler)
        }
        thread.name = "yunaudio.control"
        thread.start()
    }

    /// Closes the socket and takes the file away, so the next launch does not
    /// have to reason about debris it left itself.
    ///
    /// - Returns: Whether the accept loop closed its descriptor within 250 ms.
    ///   A false result is still fail-closed: the path and epoch are invalid,
    ///   accepted peers are shut down, and the old loop retains the descriptor
    ///   until it can close it itself rather than risking FD reuse.
    @discardableResult
    public func stop() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        lock.lock()
        guard let stoppedGeneration = generation else {
            lock.unlock()
            return true
        }
        generation = nil
        // Workers close accepted descriptors under this same lock. Shutting
        // them down before releasing it means none can be closed and reused by
        // an unrelated subsystem between taking the snapshot and this call.
        var cancelledReplies = 0
        for (client, epoch) in clientDescriptors where epoch == stoppedGeneration.epoch {
            shutdown(client, SHUT_RDWR)
            if pendingReplies[client]?.cancel(.stopped) == true { cancelledReplies += 1 }
        }
        stoppedReplies += cancelledReplies
        lock.unlock()

        // Remove the name before waking the old loop. No new connection can
        // enter that epoch, and a concurrent process may safely bind the path
        // without a later unlink here deleting its replacement.
        unlink(path)
        stoppedGeneration.requestStop()
        let acknowledged = stoppedGeneration.waitForAcceptLoop(
            timeout: Self.stopAcknowledgementTimeout)

        lock.lock()
        mostRecentStopAcknowledged = acknowledged
        lock.unlock()
        return acknowledged
    }

    deinit { _ = stop() }

    private func isServed(_ address: inout sockaddr_un) -> Bool {
        guard let probe = try? UnixSocket.make() else { return false }
        defer { close(probe) }
        let total = UnixSocket.Deadline(after: 0.2)
        return UnixSocket.connect(probe, to: &address, timeout: 0.2, total: total)
    }

    private static func acceptLoop(
        owner: WeakOwner, generation: ControlListenerGeneration,
        handler: @escaping Handler
    ) {
        defer {
            owner.value?.acceptLoopDidFinish()
            generation.finishAccepting()
        }
        while generation.waitForConnection() {
            let client = accept(generation.descriptor, nil, nil)
            guard client >= 0 else {
                if generation.isAccepting,
                    errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK
                {
                    continue
                }
                return
            }
            guard generation.isAccepting, let listener = owner.value else {
                close(client)
                return
            }
            var on: Int32 = 1
            setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            guard UnixSocket.makeNonBlocking(client),
                let admission = listener.admit(client, generation: generation)
            else {
                close(client)
                continue
            }
            // Each admitted connection gets one bounded worker. Excess clients
            // are closed above without creating either a worker or a main-actor
            // job, so silent peers cannot turn into an unbounded process.
            // A dedicated bounded thread per admission is intentional. These
            // workers spend almost all of their lifetime blocked in poll; the
            // process-wide dispatch pool can be saturated by unrelated model
            // analysis, which used to leave all 16 admitted sockets queued
            // without even starting their 1.5-second deadlines. Admission is
            // the bound, so this can create at most 16 short-lived threads.
            let worker = Thread { [weak listener, generation] in
                guard let listener else {
                    close(client)
                    admission.release()
                    return
                }
                listener.serve(
                    client, handler, generation: generation, admission: admission)
            }
            worker.name = "yunaudio.control.client"
            worker.start()
        }
    }

    private func acceptLoopDidFinish() {
        lock.lock()
        precondition(acceptLoops > 0)
        acceptLoops -= 1
        lock.unlock()
    }

    private func admit(
        _ client: Int32, generation admittedGeneration: ControlListenerGeneration
    ) -> ControlAdmission? {
        lock.lock()
        guard generation === admittedGeneration,
            activeAdmissions < ControlSocket.maximumActiveClients
        else {
            lock.unlock()
            return nil
        }
        activeAdmissions += 1
        peakAdmissions = max(peakAdmissions, activeAdmissions)
        clientDescriptors[client] = admittedGeneration.epoch
        lock.unlock()
        return ControlAdmission(
            deadline: UnixSocket.Deadline(after: ControlSocket.serverTotalTimeout)
        ) { [weak self] in self?.finishAdmission() }
    }

    private func finishAdmission() {
        lock.lock()
        precondition(activeAdmissions > 0)
        activeAdmissions -= 1
        lock.unlock()
    }

    private func clientSocketClosed(_ client: Int32, epoch: UInt64) {
        lock.lock()
        if clientDescriptors[client] == epoch { clientDescriptors.removeValue(forKey: client) }
        pendingReplies.removeValue(forKey: client)
        close(client)
        lock.unlock()
    }

    private func serve(
        _ client: Int32, _ handler: @escaping Handler,
        generation servedGeneration: ControlListenerGeneration,
        admission: ControlAdmission
    ) {
        defer {
            clientSocketClosed(client, epoch: servedGeneration.epoch)
            admission.release()
        }
        var total = admission.deadline
        guard
            let line = try? UnixSocket.readLine(
                client, timeout: ControlSocket.serverReadTimeout, total: total),
            !line.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }

        let reply: ControlReply
        if let json = JSONValue.parse(line), let request = ControlRequest(json: json) {
            switch ControlRequestEnvelope.deadline(in: json) {
            case .absent:
                break
            case .invalid:
                reply = .failure("not a request this application understands")
                _ = UnixSocket.writeAll(
                    client, reply.boundedWireText,
                    timeout: ControlSocket.serverWriteTimeout, total: total)
                return
            case .value(let clientDeadline):
                total = total.limited(toUptimeNanoseconds: clientDeadline)
            }
            let requestTotal = total
            let pending = PendingControlReply(deadline: requestTotal)
            guard register(pending, for: client, generation: servedGeneration) else {
                return
            }
            admission.retain()
            scheduleOnMainActor { [weak self, servedGeneration] in
                defer { admission.release() }
                guard self?.isCurrent(servedGeneration) == true else { return }
                guard pending.begin() else { return }
                let deadline = ControlRequestDeadline(
                    uptimeNanoseconds: requestTotal.uptimeNanoseconds)
                handler(request, deadline) { [weak self] reply in
                    self?.recordReply(accepted: pending.finish(reply))
                }
            }
            guard let answered = pending.wait() else { return }
            reply = answered
        } else {
            // Never echo an untrusted frame into its reply: that doubles the
            // memory cost and can turn a near-limit request into an oversized
            // response.
            reply = .failure("not a request this application understands")
        }
        _ = UnixSocket.writeAll(
            client, reply.boundedWireText, timeout: ControlSocket.serverWriteTimeout,
            total: total)
    }

    private func isCurrent(_ candidate: ControlListenerGeneration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation === candidate
    }

    private func register(
        _ pending: PendingControlReply, for client: Int32,
        generation servedGeneration: ControlListenerGeneration
    ) -> Bool {
        lock.withLock {
            guard generation === servedGeneration,
                clientDescriptors[client] == servedGeneration.epoch
            else { return false }
            pendingReplies[client] = pending
            return true
        }
    }

    private func recordReply(accepted: Bool) {
        lock.withLock {
            if accepted { acceptedReplies += 1 } else { rejectedReplies += 1 }
        }
    }
}
