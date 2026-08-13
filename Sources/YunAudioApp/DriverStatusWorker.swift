import CryptoKit
import Foundation

/// A value-only answer about the driver files currently on disk.
struct DriverStatusSnapshot: Sendable, Equatable {
    let isInstalled: Bool
    let bundledDriverURL: URL?
    /// Nil means the comparison did not finish within its resource budget.
    let isOutOfDate: Bool?
    let timedOut: Bool
    let rejectedOversizedInput: Bool
}

/// Reads the driver manifest and fallback binary hash away from MainActor.
///
/// Source identifiers normally settle the comparison after two small plists.
/// The binary fallback exists for old bundles, but it too has a byte ceiling;
/// an unexpectedly large or remote file is an unknown answer rather than an
/// unbounded allocation during launch.
enum DriverStatusProbe {
    static let defaultTimeout: Duration = .milliseconds(500)
    static let maximumManifestBytes = 64 * 1_024
    static let maximumDriverBinaryBytes = 16 * 1_024 * 1_024
    static let maximumBundledCandidates = 2

    struct Request: Sendable {
        let installedDriverURL: URL
        let bundledCandidates: [URL]
        let timeout: Duration

        init(
            installedDriverURL: URL,
            bundledCandidates: [URL],
            timeout: Duration = DriverStatusProbe.defaultTimeout
        ) {
            self.installedDriverURL = installedDriverURL
            self.bundledCandidates = Array(
                bundledCandidates.prefix(DriverStatusProbe.maximumBundledCandidates))
            self.timeout = timeout
        }
    }

    static func inspect(
        _ request: Request,
        fileSystem: BoundedFileSystem = .system
    ) -> DriverStatusSnapshot {
        let deadline = ExternalIODeadline(timeout: request.timeout)
        let installed: Bool
        switch fileSystem.itemExists(request.installedDriverURL, deadline) {
        case .exists(let value): installed = value
        case .timedOut:
            return DriverStatusSnapshot(
                isInstalled: false, bundledDriverURL: nil, isOutOfDate: nil,
                timedOut: true, rejectedOversizedInput: false)
        }

        var bundled: URL?
        for candidate in request.bundledCandidates {
            switch fileSystem.itemExists(candidate, deadline) {
            case .exists(true):
                bundled = candidate
                break
            case .exists(false):
                continue
            case .timedOut:
                return DriverStatusSnapshot(
                    isInstalled: installed, bundledDriverURL: nil, isOutOfDate: nil,
                    timedOut: true, rejectedOversizedInput: false)
            }
            if bundled != nil { break }
        }

        guard installed, let bundled else {
            return DriverStatusSnapshot(
                isInstalled: installed, bundledDriverURL: bundled,
                isOutOfDate: false, timedOut: false, rejectedOversizedInput: false)
        }

        let installedManifest = sourceIdentifier(
            of: request.installedDriverURL, fileSystem: fileSystem, deadline: deadline)
        let bundledManifest = sourceIdentifier(
            of: bundled, fileSystem: fileSystem, deadline: deadline)
        if installedManifest.timedOut || bundledManifest.timedOut {
            return DriverStatusSnapshot(
                isInstalled: true, bundledDriverURL: bundled, isOutOfDate: nil,
                timedOut: true, rejectedOversizedInput: false)
        }
        if installedManifest.tooLarge || bundledManifest.tooLarge {
            return DriverStatusSnapshot(
                isInstalled: true, bundledDriverURL: bundled, isOutOfDate: nil,
                timedOut: false, rejectedOversizedInput: true)
        }
        if installedManifest.value != nil || bundledManifest.value != nil {
            return DriverStatusSnapshot(
                isInstalled: true, bundledDriverURL: bundled,
                isOutOfDate: installedManifest.value != bundledManifest.value,
                timedOut: false, rejectedOversizedInput: false)
        }

        let installedHash = binaryHash(
            of: request.installedDriverURL, fileSystem: fileSystem, deadline: deadline)
        let bundledHash = binaryHash(
            of: bundled, fileSystem: fileSystem, deadline: deadline)
        if installedHash.timedOut || bundledHash.timedOut {
            return DriverStatusSnapshot(
                isInstalled: true, bundledDriverURL: bundled, isOutOfDate: nil,
                timedOut: true, rejectedOversizedInput: false)
        }
        if installedHash.tooLarge || bundledHash.tooLarge {
            return DriverStatusSnapshot(
                isInstalled: true, bundledDriverURL: bundled, isOutOfDate: nil,
                timedOut: false, rejectedOversizedInput: true)
        }
        guard let installedHash = installedHash.value, let bundledHash = bundledHash.value
        else {
            // Preserve the old-bundle behaviour: an unavailable comparison is not
            // evidence that the installed copy differs.
            return DriverStatusSnapshot(
                isInstalled: true, bundledDriverURL: bundled, isOutOfDate: false,
                timedOut: false, rejectedOversizedInput: false)
        }
        return DriverStatusSnapshot(
            isInstalled: true, bundledDriverURL: bundled,
            isOutOfDate: installedHash != bundledHash,
            timedOut: false, rejectedOversizedInput: false)
    }

    private struct ReadValue {
        var value: String?
        var timedOut = false
        var tooLarge = false
    }

    private static func sourceIdentifier(
        of driver: URL,
        fileSystem: BoundedFileSystem,
        deadline: ExternalIODeadline
    ) -> ReadValue {
        let url = driver.appendingPathComponent("Contents/Info.plist")
        switch fileSystem.readFile(url, maximumManifestBytes, deadline) {
        case .data(let data):
            guard
                let value = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil),
                let dictionary = value as? [String: Any]
            else { return ReadValue() }
            return ReadValue(value: dictionary["YunAudioSourceIdentifier"] as? String)
        case .timedOut:
            return ReadValue(timedOut: true)
        case .tooLarge:
            return ReadValue(tooLarge: true)
        case .unavailable:
            return ReadValue()
        }
    }

    private static func binaryHash(
        of driver: URL,
        fileSystem: BoundedFileSystem,
        deadline: ExternalIODeadline
    ) -> ReadValue {
        let url = driver.appendingPathComponent("Contents/MacOS/YunAudioDriver")
        switch fileSystem.readFile(url, maximumDriverBinaryBytes, deadline) {
        case .data(let data):
            let digest = SHA256.hash(data: data)
            return ReadValue(value: digest.map { String(format: "%02x", $0) }.joined())
        case .timedOut:
            return ReadValue(timedOut: true)
        case .tooLarge:
            return ReadValue(tooLarge: true)
        case .unavailable:
            return ReadValue()
        }
    }
}

/// Owns the one driver-status read which can be in flight.
final class DriverStatusWorker: @unchecked Sendable {
    private let lane: LatestExternalWorkLane<DriverStatusProbe.Request, DriverStatusSnapshot>

    init(
        fileSystem: BoundedFileSystem = .system,
        publish: @escaping @MainActor @Sendable (DriverStatusSnapshot) -> Void
    ) {
        lane = LatestExternalWorkLane(
            queue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.driver-status", qos: .utility),
            apply: { DriverStatusProbe.inspect($0, fileSystem: fileSystem) },
            publish: publish)
    }

    var statistics:
        LatestExternalWorkLane<DriverStatusProbe.Request, DriverStatusSnapshot>.Statistics
    { lane.statistics }

    @discardableResult
    func submit(_ request: DriverStatusProbe.Request) -> Bool { lane.submit(request) }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }
}
