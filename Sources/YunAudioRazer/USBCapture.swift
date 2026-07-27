import Foundation

/// Reads a USBPcap capture and pulls out the vendor HID traffic.
///
/// The Seiren V3 Pro's lighting protocol cannot be worked out from macOS: the
/// transport is verified and the command format is not, and the only place the
/// format exists is in what Synapse sends on Windows. So the remaining step is
/// a capture — and this is the thing that turns a capture into an answer rather
/// than into an afternoon of reading hex by hand.
///
/// It parses pcapng directly rather than shelling out to `tshark`, because the
/// part that matters is small: block framing, then USBPcap's own header, then
/// the payload. Depending on a Wireshark install to read a file the user
/// already has would be the larger cost.
public enum USBCapture {

    /// One control transfer carrying a payload.
    public struct Transfer: Sendable, Equatable {
        /// Sequence within the capture, so a diff can be reported in order.
        public let index: Int
        public let device: UInt16
        public let endpoint: UInt8
        /// True when the host sent this, false when the device answered.
        public let isOutbound: Bool
        public let payload: [UInt8]
    }

    public enum CaptureError: Error, CustomStringConvertible {
        case notPcapng
        case truncated(at: Int)
        case unsupportedLinkType(UInt16)

        public var description: String {
            switch self {
            case .notPcapng:
                "not a pcapng file — Wireshark writes this by default, but check "
                    + "the save format if it was exported"
            case let .truncated(offset):
                "the file ends part way through a block at byte \(offset)"
            case let .unsupportedLinkType(type):
                "link type \(type) is not USBPcap (249) — capture on the USBPcap "
                    + "interface rather than a network one"
            }
        }
    }

    private static let blockSectionHeader: UInt32 = 0x0A0D_0D0A
    private static let blockInterfaceDescription: UInt32 = 1
    private static let blockEnhancedPacket: UInt32 = 6
    private static let linkTypeUSBPcap: UInt16 = 249

    /// - Parameters:
    ///   - data: The whole `.pcapng` file.
    ///   - payloadSize: Only transfers whose payload is exactly this long are
    ///     returned. The Seiren's vendor feature report is 63 bytes; without
    ///     the filter the answer is buried in audio class traffic.
    /// - Returns: The matching transfers, in capture order.
    /// - Throws: `CaptureError` when the file is not a USBPcap pcapng.
    public static func transfers(
        in data: Data, payloadSize: Int? = nil
    ) throws -> [Transfer] {
        var transfers: [Transfer] = []
        var offset = 0
        var isLittleEndian = true
        var sawInterface = false
        var index = 0

        while offset + 12 <= data.count {
            let type = read32(data, offset, isLittleEndian)
            // The section header carries the byte order for everything after
            // it, so it has to be recognised before the length is trusted.
            if type == blockSectionHeader {
                guard offset + 12 <= data.count else {
                    throw CaptureError.truncated(at: offset)
                }
                let magic = read32(data, offset + 8, true)
                isLittleEndian = (magic == 0x1A2B_3C4D)
            } else if offset == 0 {
                throw CaptureError.notPcapng
            }

            let length = Int(read32(data, offset + 4, isLittleEndian))
            guard length >= 12, offset + length <= data.count else {
                throw CaptureError.truncated(at: offset)
            }

            if type == blockInterfaceDescription {
                let linkType = UInt16(read16(data, offset + 8, isLittleEndian))
                guard linkType == linkTypeUSBPcap else {
                    throw CaptureError.unsupportedLinkType(linkType)
                }
                sawInterface = true
            } else if type == blockEnhancedPacket, sawInterface {
                // Enhanced packet block: interface, timestamp high/low,
                // captured length, original length, then the packet.
                let captured = Int(read32(data, offset + 20, isLittleEndian))
                let start = offset + 28
                guard start + captured <= data.count else {
                    throw CaptureError.truncated(at: offset)
                }
                if let transfer = decode(
                    data, start: start, count: captured, index: index,
                    isLittleEndian: isLittleEndian, payloadSize: payloadSize)
                {
                    transfers.append(transfer)
                }
                index += 1
            }

            offset += length
        }
        return transfers
    }

    /// Decodes one USBPcap packet.
    ///
    /// The header is variable-length — it says how long it is in its first two
    /// bytes — because a control transfer carries an extra stage byte that the
    /// other transfer types do not.
    private static func decode(
        _ data: Data, start: Int, count: Int, index: Int,
        isLittleEndian: Bool, payloadSize: Int?
    ) -> Transfer? {
        guard count >= 27 else { return nil }
        let headerLength = Int(read16(data, start, isLittleEndian))
        guard headerLength >= 27, headerLength <= count else { return nil }

        let device = read16(data, start + 19, isLittleEndian)
        let endpoint = data[data.startIndex + start + 21]
        let dataLength = Int(read32(data, start + 23, isLittleEndian))

        // Bit 0 of the endpoint address is direction on this header: the top
        // bit is IN, which for a feature report is the device answering.
        let isOutbound = (endpoint & 0x80) == 0

        let payloadStart = start + headerLength
        let available = min(dataLength, count - headerLength)
        guard available > 0, payloadStart + available <= data.count else { return nil }
        let lower = data.startIndex + payloadStart
        let payload = [UInt8](data[lower..<(lower + available)])
        if let payloadSize, payload.count != payloadSize { return nil }

        return Transfer(
            index: index, device: device, endpoint: endpoint,
            isOutbound: isOutbound, payload: payload)
    }

    private static func read16(_ data: Data, _ offset: Int, _ little: Bool) -> UInt16 {
        let base = data.startIndex + offset
        guard base + 1 < data.endIndex else { return 0 }
        let a = UInt16(data[base])
        let b = UInt16(data[base + 1])
        return little ? (b << 8) | a : (a << 8) | b
    }

    private static func read32(_ data: Data, _ offset: Int, _ little: Bool) -> UInt32 {
        let base = data.startIndex + offset
        guard base + 3 < data.endIndex else { return 0 }
        let bytes = (0..<4).map { UInt32(data[base + $0]) }
        return little
            ? bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)
            : bytes[3] | (bytes[2] << 8) | (bytes[1] << 16) | (bytes[0] << 24)
    }
}

extension USBCapture {
    /// Byte positions where a set of frames disagree.
    ///
    /// This is the whole analysis. Setting the ring to pure red, then pure
    /// green, then pure blue produces three frames that are identical except
    /// where the colour lives, so the positions that differ are the colour and
    /// everything else is the command envelope.
    public static func differingPositions(_ frames: [[UInt8]]) -> [Int] {
        guard let first = frames.first, frames.count > 1 else { return [] }
        return (0..<first.count).filter { position in
            frames.contains { frame in
                position < frame.count && frame[position] != first[position]
            }
        }
    }

    /// Groups identical payloads, keeping the order they first appeared in.
    ///
    /// Synapse repeats itself — a colour change is sent several times, and
    /// there is a keep-alive underneath. Collapsing the repeats is what makes
    /// the sequence readable.
    public static func distinctPayloads(
        _ transfers: [Transfer]
    ) -> [(payload: [UInt8], count: Int)] {
        var order: [[UInt8]] = []
        var counts: [[UInt8]: Int] = [:]
        for transfer in transfers {
            if counts[transfer.payload] == nil { order.append(transfer.payload) }
            counts[transfer.payload, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }
}
