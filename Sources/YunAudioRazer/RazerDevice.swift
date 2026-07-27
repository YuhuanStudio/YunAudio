import Foundation
import IOKit.hid

/// Talks to a Razer device over its vendor HID interface.
///
/// Everything here is read-only by design. Razer's write commands are not
/// publicly documented for the Seiren V3 Pro, and the command space includes
/// operations that write to persistent configuration — probing it blind against
/// somebody's microphone is not a reasonable way to find out. The transport is
/// complete, so once a USB capture of Synapse supplies the command ids, writing
/// is a small addition rather than a new subsystem.
public final class RazerDevice {
    public static let vendorID = 0x1532

    /// Any usage page from 0xFF00 up is vendor-defined.
    ///
    /// Measured on a Seiren V3 Pro: it publishes 0xFF90, 0xFF82 and 0xFF53
    /// alongside Consumer Control and Telephony. An earlier note in this project
    /// claimed 0xFF0C; that came from reading an ioreg dump that had several
    /// Razer devices interleaved, and was wrong. Matching the whole vendor range
    /// and trying each collection is both correct and portable across models.
    public static func isVendorUsagePage(_ page: Int) -> Bool { page >= 0xFF00 }

    public let productID: Int
    public let productName: String
    /// Vendor-defined usage pages this device publishes.
    public let vendorUsagePages: [Int]
    private let device: IOHIDDevice

    private init(
        device: IOHIDDevice, productID: Int, productName: String, vendorUsagePages: [Int]
    ) {
        self.device = device
        self.productID = productID
        self.productName = productName
        self.vendorUsagePages = vendorUsagePages
    }

    /// Every Razer device exposing the vendor HID interface.
    public static func discover() -> [RazerDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Matching on the vendor alone, then filtering by usage page below:
        // asking IOKit for both at once misses devices whose usage page lives on
        // a collection rather than the top level.
        IOHIDManagerSetDeviceMatching(
            manager, [kIOHIDVendorIDKey: vendorID] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }

        return set.compactMap { device -> RazerDevice? in
            // The vendor collection is usually not the primary one — on the
            // Seiren V3 Pro the primary is Consumer Control — so the usage pairs
            // are what decide.
            let pairs = (property(device, kIOHIDDeviceUsagePairsKey) as? [[String: Int]]) ?? []
            let vendorPages = pairs
                .compactMap { $0[kIOHIDDeviceUsagePageKey] }
                .filter(isVendorUsagePage)
            let primary = property(device, kIOHIDPrimaryUsagePageKey) as? Int ?? 0
            guard !vendorPages.isEmpty || isVendorUsagePage(primary) else { return nil }

            let productID = property(device, kIOHIDProductIDKey) as? Int ?? 0
            let name = property(device, kIOHIDProductKey) as? String ?? "Razer device"
            return RazerDevice(
                device: device, productID: productID, productName: name,
                vendorUsagePages: vendorPages.sorted())
        }
        .sorted { $0.productName < $1.productName }
    }

    private static func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }

    /// Prints what every Razer HID device publishes, for working out which
    /// interface carries the vendor protocol on a given model.
    public static func dumpCandidates() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(
            manager, [kIOHIDVendorIDKey: vendorID] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            print("no HID devices from vendor 0x1532")
            return
        }
        for device in set {
            let name = property(device, kIOHIDProductKey) as? String ?? "?"
            let productID = property(device, kIOHIDProductIDKey) as? Int ?? 0
            let usagePage = property(device, kIOHIDPrimaryUsagePageKey) as? Int ?? 0
            let usage = property(device, kIOHIDPrimaryUsageKey) as? Int ?? 0
            print(String(
                format: "%@  pid 0x%04X  primary usage page 0x%04X usage 0x%02X",
                name, productID, usagePage, usage))
            if let pairs = property(device, kIOHIDDeviceUsagePairsKey) as? [[String: Int]] {
                for pair in pairs {
                    let page = pair[kIOHIDDeviceUsagePageKey] ?? 0
                    let value = pair[kIOHIDDeviceUsageKey] ?? 0
                    print(String(format: "    pair: page 0x%04X usage 0x%02X", page, value))
                }
            }
        }
    }

    // MARK: Transport

    /// Sends a report and reads the reply.
    ///
    /// Razer's protocol is request/response over the same feature report: the
    /// command goes out with `SetReport`, then the device's answer is read back
    /// from the same report id. The delay between them is not optional — the
    /// firmware needs a moment, and reading immediately returns the request.
    public func send(_ report: RazerReport) throws -> RazerReport {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { throw RazerError.couldNotOpen }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        var outgoing = report.encoded()
        let setResult = IOHIDDeviceSetReport(
            device, kIOHIDReportTypeFeature, 0, &outgoing, outgoing.count)
        guard setResult == kIOReturnSuccess else {
            throw RazerError.transferFailed(setResult)
        }

        usleep(15000)

        var incoming = [UInt8](repeating: 0, count: RazerReport.size)
        var length = incoming.count
        let getResult = IOHIDDeviceGetReport(
            device, kIOHIDReportTypeFeature, 0, &incoming, &length)
        guard getResult == kIOReturnSuccess else {
            throw RazerError.transferFailed(getResult)
        }
        guard let reply = RazerReport(decoding: incoming) else {
            throw RazerError.malformedReply
        }
        return reply
    }

    /// Report ids and sizes the device declares, per usage page.
    ///
    /// This is the ground truth for whether a given protocol can even apply: if
    /// the device declares no feature report of the right size, no amount of
    /// guessing at command bytes will help.
    public func reportDescriptorSummary() -> [String] {
        guard let data = Self.property(device, kIOHIDReportDescriptorKey) as? Data else {
            return ["no report descriptor published"]
        }

        var lines: [String] = ["descriptor is \(data.count) bytes"]
        var index = 0
        var usagePage = 0
        var reportID = 0
        var reportSize = 0
        var reportCount = 0
        let bytes = [UInt8](data)

        // A minimal HID item walker. Only the items that decide whether a
        // report exists and how big it is are interpreted.
        while index < bytes.count {
            let prefix = bytes[index]
            let sizeCode = Int(prefix & 0x03)
            let length = sizeCode == 3 ? 4 : sizeCode
            let tag = prefix & 0xFC
            var value = 0
            for offset in 0..<length where index + 1 + offset < bytes.count {
                value |= Int(bytes[index + 1 + offset]) << (8 * offset)
            }

            switch tag {
            case 0x04: usagePage = value                       // Usage Page
            case 0x84: reportID = value                        // Report ID
            case 0x74: reportSize = value                      // Report Size
            case 0x94: reportCount = value                     // Report Count
            case 0xB0:                                          // Feature
                let bytesPerReport = (reportSize * reportCount + 7) / 8
                lines.append(String(
                    format: "  feature report id 0x%02X · %d bytes · usage page 0x%04X",
                    reportID, bytesPerReport, usagePage))
            case 0x80, 0x90:                                    // Input / Output
                let bytesPerReport = (reportSize * reportCount + 7) / 8
                let kind = tag == 0x80 ? "input" : "output"
                lines.append(String(
                    format: "  %@ report id 0x%02X · %d bytes · usage page 0x%04X",
                    kind, reportID, bytesPerReport, usagePage))
            default: break
            }
            index += 1 + length
        }
        return lines
    }

    /// Reads a feature report as raw bytes.
    ///
    /// Purely a read: `GET_REPORT` asks the device for its current state and
    /// changes nothing. This is as far as protocol discovery can responsibly go
    /// without a capture of the vendor's own tool — the write side would be
    /// guessing at command bytes on hardware that stores configuration.
    public func readFeatureReport(id: UInt8, size: Int) throws -> [UInt8] {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { throw RazerError.couldNotOpen }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        var buffer = [UInt8](repeating: 0, count: size)
        var length = buffer.count
        let result = IOHIDDeviceGetReport(
            device, kIOHIDReportTypeFeature, CFIndex(id), &buffer, &length)
        guard result == kIOReturnSuccess else { throw RazerError.transferFailed(result) }
        return Array(buffer.prefix(length))
    }

    // MARK: Protocol discovery

    /// Transaction ids seen across Razer's range.
    ///
    /// The field is not a sequence number — it selects which internal endpoint
    /// handles the command, and the right value differs per model. A device
    /// given the wrong one echoes the request back untouched with status `new`,
    /// which is exactly what a Seiren V3 Pro does at the common 0x1F.
    public static let knownTransactionIDs: [UInt8] = [
        0x00, 0x08, 0x1F, 0x3F, 0x80, 0x88, 0x9F,
    ]

    /// Finds the transaction id this device answers on, using the firmware
    /// version query. Read-only, so it is safe to sweep.
    public func discoverTransactionID() -> (id: UInt8, firmware: String)? {
        for candidate in Self.knownTransactionIDs {
            var request = RazerReport(
                commandClass: RazerCommand.firmwareVersion.commandClass,
                commandID: RazerCommand.firmwareVersion.commandID,
                arguments: [0x00, 0x00])
            request.transactionID = candidate
            request.dataSize = 0x02
            guard let reply = try? send(request) else { continue }
            if reply.decodedStatus == .successful {
                return (candidate, "\(reply.arguments[0]).\(reply.arguments[1])")
            }
        }
        return nil
    }

    /// Transaction id to use for subsequent commands, once discovered.
    public var transactionID: UInt8 = 0x1F

    // MARK: Read-only queries

    public func firmwareVersion() throws -> String {
        var request = RazerReport(
            commandClass: RazerCommand.firmwareVersion.commandClass,
            commandID: RazerCommand.firmwareVersion.commandID,
            arguments: [0x00, 0x00])
        request.transactionID = transactionID
        request.dataSize = 0x02
        let reply = try send(request)
        guard reply.decodedStatus == .successful else {
            throw RazerError.deviceRefused(reply.decodedStatus)
        }
        return "\(reply.arguments[0]).\(reply.arguments[1])"
    }

    public func serialNumber() throws -> String {
        var request = RazerReport(
            commandClass: RazerCommand.serialNumber.commandClass,
            commandID: RazerCommand.serialNumber.commandID)
        request.transactionID = transactionID
        request.dataSize = 0x16
        let reply = try send(request)
        guard reply.decodedStatus == .successful else {
            throw RazerError.deviceRefused(reply.decodedStatus)
        }
        let bytes = reply.arguments.prefix(22).prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func ledBrightness() throws -> UInt8 {
        var request = RazerReport(
            commandClass: RazerCommand.ledBrightness.commandClass,
            commandID: RazerCommand.ledBrightness.commandID,
            arguments: [0x01, 0x05, 0x00])
        request.transactionID = transactionID
        request.dataSize = 0x03
        let reply = try send(request)
        guard reply.decodedStatus == .successful else {
            throw RazerError.deviceRefused(reply.decodedStatus)
        }
        return reply.arguments[2]
    }
}

public enum RazerError: Error, CustomStringConvertible {
    case couldNotOpen
    case transferFailed(IOReturn)
    case malformedReply
    case deviceRefused(RazerReport.Status?)

    public var description: String {
        switch self {
        case .couldNotOpen:
            "could not open the HID device — another process may hold it exclusively"
        case let .transferFailed(result):
            "HID transfer failed (0x\(String(result, radix: 16)))"
        case .malformedReply:
            "the device returned a reply shorter than a Razer report"
        case let .deviceRefused(status):
            "the device refused the command: \(status?.description ?? "unknown status")"
        }
    }
}
