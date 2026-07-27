import Foundation

/// Razer's vendor HID report.
///
/// The wire format is documented by the openrazer project, which reverse
/// engineered it for Linux. It is stable across the whole product line: 90
/// bytes, report id 0, with a checksum over the middle of the frame.
///
/// The Seiren V3 Pro exposes this on interface 3 with vendor usage page
/// `0xFF0C`, which is how Synapse configures it on Windows. macOS never claims
/// that interface, so a user-space process can reach it with no driver, no
/// kernel extension and no special entitlement.
public struct RazerReport {
    public static let size = 90

    public var status: UInt8 = 0x00
    public var transactionID: UInt8 = 0x1F
    public var remainingPackets: UInt16 = 0
    public var protocolType: UInt8 = 0
    public var dataSize: UInt8 = 0
    public var commandClass: UInt8 = 0
    public var commandID: UInt8 = 0
    public var arguments = [UInt8](repeating: 0, count: 80)

    public init() {}

    public init(commandClass: UInt8, commandID: UInt8, arguments: [UInt8] = []) {
        self.commandClass = commandClass
        self.commandID = commandID
        dataSize = UInt8(min(arguments.count, 80))
        for (index, byte) in arguments.prefix(80).enumerated() {
            self.arguments[index] = byte
        }
    }

    /// Serialises to the 90-byte frame, checksum included.
    public func encoded() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.size)
        bytes[0] = status
        bytes[1] = transactionID
        bytes[2] = UInt8(remainingPackets >> 8)
        bytes[3] = UInt8(remainingPackets & 0xFF)
        bytes[4] = protocolType
        bytes[5] = dataSize
        bytes[6] = commandClass
        bytes[7] = commandID
        for index in 0..<80 { bytes[8 + index] = arguments[index] }
        bytes[88] = Self.checksum(bytes)
        bytes[89] = 0
        return bytes
    }

    public init?(decoding bytes: [UInt8]) {
        guard bytes.count >= Self.size else { return nil }
        status = bytes[0]
        transactionID = bytes[1]
        remainingPackets = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        protocolType = bytes[4]
        dataSize = bytes[5]
        commandClass = bytes[6]
        commandID = bytes[7]
        arguments = Array(bytes[8..<88])
    }

    /// XOR of bytes 2 through 87 inclusive.
    public static func checksum(_ bytes: [UInt8]) -> UInt8 {
        var result: UInt8 = 0
        for index in 2..<88 where index < bytes.count {
            result ^= bytes[index]
        }
        return result
    }

    public var isChecksumValid: Bool {
        let bytes = encoded()
        return bytes[88] == Self.checksum(bytes)
    }

    /// What the device said about the command.
    public enum Status: UInt8, Sendable, CustomStringConvertible {
        case new = 0x00
        case busy = 0x01
        case successful = 0x02
        case failure = 0x03
        case timeout = 0x04
        case notSupported = 0x05

        public var description: String {
            switch self {
            case .new: "new"
            case .busy: "busy"
            case .successful: "successful"
            case .failure: "failure"
            case .timeout: "timeout"
            case .notSupported: "not supported"
            }
        }
    }

    public var decodedStatus: Status? { Status(rawValue: status) }
}

/// Commands used here.
///
/// Only the read-only ones are wired up. The write side of Razer's command space
/// is not publicly documented for this device, and a wrong command class can
/// write to persistent configuration — so discovering it belongs behind a USB
/// capture of Synapse on Windows, not behind guesswork against someone's
/// microphone.
public enum RazerCommand {
    /// Class 0x00 — device information.
    public static let firmwareVersion = (commandClass: UInt8(0x00), commandID: UInt8(0x81))
    public static let serialNumber = (commandClass: UInt8(0x00), commandID: UInt8(0x82))
    /// Class 0x03 — lighting. Reading the current brightness is safe; the
    /// matching write is left out until the protocol is confirmed.
    public static let ledBrightness = (commandClass: UInt8(0x03), commandID: UInt8(0x83))
}
