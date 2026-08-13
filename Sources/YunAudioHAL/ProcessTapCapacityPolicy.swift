import CoreAudio
import Foundation

/// Bounds caller-owned collections before they enter `CATapDescription` or HAL.
///
/// Process-tap creation is a synchronous `coreaudiod` operation. Read-side HAL
/// caps cannot protect this direction: without admission, one public call could
/// serialise an arbitrary process or bundle list into the system audio service.
enum ProcessTapCapacityPolicy {
    static let maximumProcesses = 64
    static let maximumBundleIDs = 64
    static let maximumBundleIDBytes = 1_024

    static func validate(
        processIDs: [AudioObjectID], bundleIDs: [String]
    ) throws {
        try requireCount(
            processIDs.count, resource: "process-tap processes",
            maximum: maximumProcesses)
        try requireCount(
            bundleIDs.count, resource: "process-tap bundle identifiers",
            maximum: maximumBundleIDs)

        guard processIDs.allSatisfy({ $0 != kAudioObjectUnknown }) else {
            throw ProcessTapError.invalidConfiguration(
                "process IDs must name live Core Audio objects")
        }
        guard Set(processIDs).count == processIDs.count else {
            throw ProcessTapError.invalidConfiguration(
                "process IDs must be unique")
        }

        var seenBundleIDs = Set<String>()
        for bundleID in bundleIDs {
            let byteCount = bundleID.utf8.count
            guard byteCount <= maximumBundleIDBytes else {
                throw ProcessTapError.configurationExceedsLimit(
                    resource: "bundle-identifier bytes", requested: byteCount,
                    maximum: maximumBundleIDBytes)
            }
            guard seenBundleIDs.insert(bundleID).inserted else {
                throw ProcessTapError.invalidConfiguration(
                    "bundle identifiers must be unique")
            }
        }
    }

    private static func requireCount(
        _ count: Int, resource: String, maximum: Int
    ) throws {
        guard count <= maximum else {
            throw ProcessTapError.configurationExceedsLimit(
                resource: resource, requested: count, maximum: maximum)
        }
    }
}
