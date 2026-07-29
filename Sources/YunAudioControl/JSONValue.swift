import Foundation

/// A JSON document as a value.
///
/// `JSONSerialization` deals in `Any`, which is neither `Sendable` nor
/// `Equatable` — and both of those are needed here, because status crosses a
/// socket between two processes and because a test has to be able to say what
/// the answer was rather than that it had the right shape. `Codable` is not the
/// answer either: JSON-RPC parameters and the model's status dictionary are both
/// genuinely open-ended, so there is no struct to decode into.
///
/// `int` and `double` are separate cases on purpose. Everything here goes out to
/// an agent reading JSON, and a route count printed as `2.0` reads as though
/// something is being interpolated when it is not.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Reading

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Whether this is `null` or absent, which callers almost always want to
    /// treat the same way: JSON-RPC lets a client send `"params": null` and mean
    /// "no parameters", and so does an agent that filled in a field it had no
    /// value for.
    public var isNull: Bool { self == .null }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    // MARK: Crossing to and from `Any`

    /// Wraps whatever `JSONSerialization` or the model handed over.
    ///
    /// Returns nil for anything JSON has no representation of, rather than
    /// substituting something. A status dictionary that has grown a value this
    /// cannot carry should be a visible failure at the boundary, not a field
    /// that quietly reads `null` on the far side.
    public init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // `Bool` bridges to `NSNumber`, so the type has to be asked rather
            // than pattern-matched: without this, `"running": false` crosses the
            // socket as `0` and an agent reads it as a number that is not a
            // boolean.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = Self.number(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as Double:
            self = Self.number(value)
        case let value as Float:
            self = Self.number(Double(value))
        case let value as String:
            self = .string(value)
        case let values as [Any]:
            var array: [JSONValue] = []
            array.reserveCapacity(values.count)
            for value in values {
                guard let wrapped = JSONValue(any: value) else { return nil }
                array.append(wrapped)
            }
            self = .array(array)
        case let values as [String: Any]:
            var object: [String: JSONValue] = [:]
            for (key, value) in values {
                guard let wrapped = JSONValue(any: value) else { return nil }
                object[key] = wrapped
            }
            self = .object(object)
        default:
            return nil
        }
    }

    /// A double, unless JSON cannot carry it.
    ///
    /// A silent level is −∞ dBFS, and that is not a hypothetical: it is what a
    /// meter reads with nothing plugged in. JSON has no representation of
    /// infinity and `JSONSerialization` *throws* on one, so a single −∞ in the
    /// status dictionary would not produce one odd field — it would fail the
    /// whole document, and the reply would be the word `null` where the
    /// application's entire state should have been. Null in one field is a
    /// reading an agent can act on; null for everything is a mystery.
    static func number(_ value: Double) -> JSONValue {
        value.isFinite ? .double(value) : .null
    }

    /// What `JSONSerialization` wants back.
    public var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.any)
        case .object(let values): values.mapValues(\.any)
        }
    }

    // MARK: Text

    /// Parses one JSON document, or nothing if it is not one.
    ///
    /// `.fragmentsAllowed` because JSON-RPC ids are bare scalars and a strict
    /// top-level-container reading would refuse half the protocol.
    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> JSONValue? {
        guard
            let any = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else { return nil }
        return JSONValue(any: any)
    }

    /// One line of JSON, with no newline in it.
    ///
    /// Written here rather than handed to `JSONSerialization`, for one measured
    /// reason: `JSONSerialization` renders `-6.02` as `-6.0199999999999996`.
    /// That is a correct double and it round-trips, but it is seventeen
    /// significant figures of a level somebody read off a meter, and every
    /// reading in every status reply would carry them. `Double.description` is
    /// the shortest text that round-trips, which is the number that was meant.
    ///
    /// Keys are sorted so that two readings of the same state are the same
    /// string — a diff between two status replies should show what changed
    /// rather than what the hash table felt like today.
    ///
    /// Both wire protocols here are newline-delimited, so an embedded newline
    /// would not be a formatting difference; it would be a framing bug that
    /// splits one message into two. Nothing below emits one: a newline inside a
    /// string is escaped, and nothing else can produce one.
    public var text: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        // Not reachable through `init(any:)`, which turns a non-finite number
        // into null — but reachable by construction, and JSON has no word for
        // infinity, so it cannot simply be printed.
        case .double(let value): value.isFinite ? value.description : "null"
        case .string(let value): Self.quote(value)
        case .array(let values): "[" + values.map(\.text).joined(separator: ",") + "]"
        case .object(let values):
            "{"
                + values.keys.sorted().map { "\(Self.quote($0)):\(values[$0]!.text)" }
                .joined(separator: ",") + "}"
        }
    }

    /// How one value reads on a terminal.
    ///
    /// Here rather than in `yunaudio-cli` because an executable target cannot be
    /// imported by the tests, and this is precisely the kind of formatting that
    /// goes wrong where nobody looks. The channel this replaced had its own
    /// tagged value type carrying exactly this method, and the reason it was
    /// tagged is the reason `int` and `double` are separate cases here: a level
    /// of −70.0 dB printed as "-70" beside "-69.50" is what an untyped reply
    /// produced, and neither line looked wrong on its own.
    public var described: String {
        switch self {
        // A reading JSON cannot carry — a level of −∞ dBFS, which is what a
        // meter shows with nothing plugged in. A dash reads as "no reading";
        // the word `null` reads as a defect.
        case .null: "—"
        case .bool(let value): value ? "yes" : "no"
        case .int(let value): String(value)
        // Two places is what every level in this application is quoted to, and
        // an unrounded double is fifteen digits of noise.
        case .double(let value): String(format: "%.2f", value)
        case .string(let value): value
        case .array(let values):
            values.isEmpty ? "—" : values.map(\.described).joined(separator: " ")
        // Nothing in the status dictionary nests today. Printing the JSON is a
        // line somebody can read rather than a line that is missing, which is
        // what a `fatalError` or an empty string would leave behind.
        case .object: text
        }
    }

    /// A JSON string literal.
    ///
    /// Everything below 0x20 has to be escaped or the document is invalid, and
    /// a scene name is whatever the user typed. Above that, UTF-8 goes through
    /// as itself: JSON is defined over Unicode, and `\u` escaping every
    /// non-ASCII character would triple the size of a Chinese preset name for
    /// nothing.
    private static func quote(_ value: String) -> String {
        var out = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }
}
