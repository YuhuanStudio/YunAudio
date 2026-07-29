import Foundation

/// How a terminal talks to the running application, and how it answers.
///
/// A URL is a one-way message: `open yunaudio://mute` changes the state and
/// says nothing back, which is enough for a Stream Deck button and not enough
/// for a shell script. `yunaudio-cli mute` has to be able to print what
/// happened, and `yunaudio-cli status` has to be able to print what is true —
/// so there is a reply path, and it carries the outcome sentence the model
/// already produces for the URL handler.
///
/// Distributed notifications rather than a socket or XPC. XPC between a
/// SwiftPM binary and a shell-assembled bundle needs a launchd service
/// definition and a signed pair; a socket needs a path, an owner and cleanup
/// after a crash. This needs neither, and it is exactly as exposed as the URL
/// scheme already is: any process on the machine can post one, and any process
/// could already `open` a `yunaudio://` URL. Nothing here widens that.
public enum RemoteChannel {
    /// The bundle the tool is looking for, so it can say "not running" at once
    /// rather than waiting out a timeout for an answer that is not coming.
    public static let bundleIdentifier = "com.yuhuanstudio.yunaudio"

    public static let requestName = Notification.Name("com.yuhuanstudio.yunaudio.request")
    public static let replyName = Notification.Name("com.yuhuanstudio.yunaudio.reply")

    /// One key holding one JSON string. A distributed notification's userInfo
    /// crosses the process boundary as a property list, and a nested dictionary
    /// of mixed types survives that less predictably than a string does.
    public static let payloadKey = "payload"

    /// How long the tool waits for an answer.
    ///
    /// Longer than `ScriptHost.timeLimit`, which is two seconds: a script that
    /// runs to its limit must produce the error rather than a timeout blaming
    /// the wrong thing.
    public static let timeout: TimeInterval = 4
}

/// What a front end is asking for.
///
/// `url` rather than a second encoding of the vocabulary: the wire format and
/// the URL scheme are the same list of verbs, and keeping them the same string
/// means a command that parses in one parses in the other.
public struct RemoteRequest: RemotePayload, Equatable, Sendable {
    /// Matches a reply to the process waiting for it. Two terminals asking at
    /// once would otherwise each read whichever answer arrived first.
    public var token: String
    /// Nil for a question rather than a command — `status` asks and changes
    /// nothing, so it is deliberately not a `RemoteCommand`.
    public var url: String?

    public init(token: String = UUID().uuidString, url: String? = nil) {
        self.token = token
        self.url = url
    }

    /// The command, if this was one and it is still understood.
    public var command: RemoteCommand? {
        url.flatMap(URL.init(string:)).flatMap(RemoteCommand.parse)
    }
}

/// What the application says back.
///
/// Every reply carries the whole state, not just the sentence. A round trip
/// costs the same either way, and a caller that wants to check what its command
/// actually did should not have to ask twice and hope nothing moved in between.
public struct RemoteReply: RemotePayload, Equatable, Sendable {
    public var token: String
    /// The sentence the model produced, or nil when the command named a scene
    /// or a setup this application does not have.
    public var outcome: String?
    /// Whether the command did what it was asked. A sentence is what a menu bar
    /// wants; a shell wants an exit status, and the two are not the same
    /// question — a script that threw still produces a sentence.
    public var failed: Bool
    public var status: [String: RemoteValue]
    /// So a tool refusing a name can print the names that would have worked.
    /// "No such scene" is a dead end; a list is an answer.
    public var presets: [String]
    public var configs: [String]

    public init(
        token: String, outcome: String?, failed: Bool = false,
        status: [String: RemoteValue] = [:],
        presets: [String] = [], configs: [String] = []
    ) {
        self.token = token
        self.outcome = outcome
        self.failed = failed
        self.status = status
        self.presets = presets
        self.configs = configs
    }
}

/// One value out of the status dictionary, typed.
///
/// The model publishes `[String: Any]` for JavaScriptCore, which will take
/// anything; a wire format will not. Keeping the integer case apart from the
/// floating-point one is not pedantry — `bufferFrames` printed as `512.0` is a
/// buffer size nobody recognises.
public enum RemoteValue: Codable, Equatable, Sendable {
    case flag(Bool)
    case count(Int)
    case number(Double)
    case text(String)
    case list([String])

    /// Reads one value out of the model's untyped dictionary.
    public init?(_ value: Any) {
        // Every number in the dictionary arrives as a bridged `NSNumber`, and
        // Swift's `as?` will hand back whichever of `Bool`, `Int` and `Double`
        // is asked for regardless of what went in. So the question is put to
        // CoreFoundation, which knows: without this, `as? Bool` first turns
        // "one route" into "routes: yes", and `as? Int` first turns a level of
        // −70.0 dB into "−70" while −69.5 stays a decimal. The second was
        // observed in the first status this printed.
        if CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID() {
            self = .flag(value as? Bool ?? false)
        } else if let number = value as? NSNumber {
            self =
                CFNumberIsFloatType(number)
                ? .number(number.doubleValue) : .count(number.intValue)
        } else if let text = value as? String {
            self = .text(text)
        } else if let list = value as? [String] {
            self = .list(list)
        } else {
            return nil
        }
    }

    /// How the value reads on a terminal.
    public var described: String {
        switch self {
        case .flag(let flag): flag ? "yes" : "no"
        case .count(let count): String(count)
        // Two places is what every level in this application is quoted to, and
        // an unrounded double is fifteen digits of noise.
        case .number(let number): String(format: "%.2f", number)
        case .text(let text): text
        case .list(let list): list.isEmpty ? "—" : list.joined(separator: " ")
        }
    }

    /// Tagged, rather than written as a bare JSON value and guessed at on the
    /// way back.
    ///
    /// Guessing was tried and it does not work: a level of exactly 0 dB
    /// encodes as `0`, which decodes as an `Int` before anything asks whether
    /// it was a `Double`, so the terminal printed `0` beside `-69.50` in the
    /// very first status this produced. Five extra characters on the wire buys
    /// a format that cannot lose what it was told.
    private enum CodingKeys: String, CodingKey {
        case flag, count, number, text, list
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let flag = try container.decodeIfPresent(Bool.self, forKey: .flag) {
            self = .flag(flag)
        } else if let count = try container.decodeIfPresent(Int.self, forKey: .count) {
            self = .count(count)
        } else if let number = try container.decodeIfPresent(Double.self, forKey: .number) {
            self = .number(number)
        } else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else {
            self = .list(try container.decode([String].self, forKey: .list))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .flag(let flag): try container.encode(flag, forKey: .flag)
        case .count(let count): try container.encode(count, forKey: .count)
        case .number(let number): try container.encode(number, forKey: .number)
        case .text(let text): try container.encode(text, forKey: .text)
        case .list(let list): try container.encode(list, forKey: .list)
        }
    }
}

/// Something that crosses the process boundary as JSON.
///
/// A protocol of our own rather than an extension on `Codable`: the latter
/// would put `payload` on every encodable type in every module that imports
/// this, which is a lot of surface to add for two structs.
public protocol RemotePayload: Codable {}

extension RemotePayload {
    /// The JSON one of these travels as, or nil if it somehow will not encode.
    public var payload: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Reads one back out of a notification, or nothing if the notification was
    /// not one of ours. Anything on the machine can post to a distributed name,
    /// so what arrives is somebody else's string until it parses.
    public static func from(_ userInfo: [AnyHashable: Any]?) -> Self? {
        guard let text = userInfo?[RemoteChannel.payloadKey] as? String,
            let data = text.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
