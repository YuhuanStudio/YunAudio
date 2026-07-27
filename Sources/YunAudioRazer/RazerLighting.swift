import Foundation
import IOKit.hid

/// Razer protocol 2.5, as the Seiren V3 Pro actually speaks it.
///
/// This is not the openrazer format. That one is 90 bytes on report id 0, and
/// this device declares no 90-byte report anywhere — sending one gets echoed
/// back untouched. The real channel is a 64-byte **feature report on id `0x07`**
/// under usage page `0xFF53`, and the frame differs from openrazer's in one
/// line that matters: the checksum covers the transaction id.
///
/// Everything below comes from a capture of Synapse driving the device, taken
/// by polling the same feature report every 3 ms while the lighting was
/// changed — 413 distinct frames over two minutes, with every field confirmed
/// against several independent samples.
///
/// The most useful thing that capture established is a negative: **the device
/// has no effects.** Switching Synapse to Spectrum produced 961 distinct RGB
/// values streamed one frame at a time, tracing a continuous hue circle. The
/// animation is computed on the host and pushed. So there is no effect protocol
/// to reverse — writing frames and setting brightness is the whole surface, and
/// every effect is ours to write.
public struct RazerLightingCommand {
    /// Total size including the report id byte.
    public static let size = 64

    public static let commandClass: UInt8 = 0x0F

    public enum Command: UInt8 {
        /// Tells the device the host is about to stream frames.
        case streamMode = 0x02
        /// Twelve LEDs of RGB.
        case frame = 0x03
        /// Brightness, where zero is off — there is no separate on/off command.
        case brightness = 0x04
    }

    /// Status the device reports when the frame is read back.
    public enum Status: UInt8 {
        case newCommand = 0x00
        case busy = 0x01
        case success = 0x02
        case failed = 0x03
        case timeout = 0x04
        case notSupported = 0x05
        case commandMismatch = 0xE1

        public var description: String {
            switch self {
            case .newCommand: "not yet acted on"
            case .busy: "busy"
            case .success: "success"
            case .failed: "failed"
            case .timeout: "timed out"
            case .notSupported: "not supported"
            case .commandMismatch: "custom command mismatch"
            }
        }
    }

    /// The ring has twelve addressable LEDs. The `0x0B` in the frame prefix is
    /// the highest index rather than a count, which is what fixes it at twelve.
    public static let ledCount = 12

    /// How high up the ring an LED sits, from 0 at the bottom to 1 at the top.
    ///
    /// Index 0 is at six o'clock and the indices run clockwise from there, one
    /// hour apart. That could not be read off the device — the capture settled
    /// every byte of the protocol and nothing about the geometry — so it came
    /// from lighting them one at a time and looking at the ring.
    ///
    /// Knowing it is what makes a level meter possible rather than a chase:
    /// indices 1 and 11 sit at the same height, as do 2 and 10, so filling by
    /// height rises up both sides at once the way a meter should, instead of
    /// sweeping round.
    public static func height(ofLED index: Int) -> Double {
        let angle = Double(index) / Double(ledCount) * 2 * .pi
        return (1 - cos(angle)) / 2
    }

    public var transactionID: UInt8
    public var command: Command
    public var arguments: [UInt8]

    public init(command: Command, arguments: [UInt8], transactionID: UInt8 = 0x1F) {
        self.command = command
        self.arguments = arguments
        self.transactionID = transactionID
    }

    /// Builds the 64-byte buffer, checksum included.
    public func encoded() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: Self.size)
        buffer[0] = 0x07  // HID report id
        buffer[1] = 0x00  // status: zero on the way out
        buffer[2] = transactionID
        buffer[3] = 0x00  // remaining packets, big endian
        buffer[4] = 0x00
        buffer[5] = 0x00  // protocol type
        buffer[6] = UInt8(min(arguments.count, 53))
        buffer[7] = Self.commandClass
        buffer[8] = command.rawValue
        for (index, byte) in arguments.prefix(53).enumerated() {
            buffer[9 + index] = byte
        }

        // XOR from the transaction id, not from after it. openrazer starts one
        // byte later, and a port that keeps that line produces a frame this
        // device rejects.
        var checksum: UInt8 = 0
        for index in 2...61 { checksum ^= buffer[index] }
        // Written to both trailing bytes. They are equal in every observed
        // `0x03` and `0x04` frame; in a read-back `0x02` frame byte 62 is zero,
        // which is the device's answer rather than what Synapse sent.
        buffer[62] = checksum
        buffer[63] = checksum
        return buffer
    }

    /// Twelve RGB triples, in LED order.
    ///
    /// - Parameters:
    ///   - colours: Up to twelve `(red, green, blue)` triples. Short lists are
    ///     padded with black rather than repeated.
    ///   - transactionID: Any value; it only has to be included in the checksum.
    /// - Returns: A frame command ready to send.
    public static func frame(
        _ colours: [(r: UInt8, g: UInt8, b: UInt8)], transactionID: UInt8 = 0x1F
    ) -> RazerLightingCommand {
        // The prefix was identical across all 400-odd captured frames, so it is
        // carried verbatim rather than guessed at.
        var arguments: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x0B]
        for index in 0..<ledCount {
            let colour = index < colours.count ? colours[index] : (r: 0, g: 0, b: 0)
            arguments.append(contentsOf: [colour.r, colour.g, colour.b])
        }
        return RazerLightingCommand(
            command: .frame, arguments: arguments, transactionID: transactionID)
    }

    /// - Parameters:
    ///   - level: 0 turns the ring off; there is no other off command.
    ///   - transactionID: Any value; it only has to be in the checksum.
    /// - Returns: A brightness command ready to send.
    public static func brightness(
        _ level: UInt8, transactionID: UInt8 = 0x1F
    ) -> RazerLightingCommand {
        RazerLightingCommand(
            command: .brightness, arguments: [0x01, 0x00, level],
            transactionID: transactionID)
    }

    /// Sent once before streaming frames.
    ///
    /// The third argument is `0x08` in every capture — including when switching
    /// to Spectrum, back to a solid colour, and off again. So it reads as "the
    /// host will push frames" rather than as an effect selector, and no other
    /// value has been observed to exist.
    ///
    /// - Parameter transactionID: Any value; it only has to be in the checksum.
    /// - Returns: A stream-mode command ready to send.
    public static func streamMode(transactionID: UInt8 = 0x1F) -> RazerLightingCommand {
        RazerLightingCommand(
            command: .streamMode, arguments: [0x00, 0x00, 0x08, 0x00, 0x00, 0x00],
            transactionID: transactionID)
    }
}
