import Foundation

/// Bounds the dictionary handed to `AudioHardwareCreateAggregateDevice`.
///
/// Aggregate creation is synchronous inside Core Audio. A caller-controlled
/// member list is therefore not merely an allocation concern: it can occupy the
/// system audio service long enough to stall every application's device menu.
/// Validate the complete request before the first HAL call rather than relying
/// on an undocumented system limit or waiting for the service to refuse it.
enum AggregateCapacityPolicy {
    static let maximumEndpoints = 16
    static let maximumSubDevices = 16
    static let maximumTaps = 16
    static let maximumNameBytes = 256
    static let maximumUIDBytes = 1_024
    static let maximumChannelsPerMember = 64
    static let maximumExtraOutputLatencyFrames = 48_000

    static func validate(
        name: String,
        subDevices: [AggregateDevice.SubDevice],
        clockMasterUID: String?,
        tapUIDs: [String]
    ) throws {
        try requireBytes(name, resource: "aggregate name", maximum: maximumNameBytes)
        try requireCount(
            subDevices.count, resource: "aggregate sub-devices",
            maximum: maximumSubDevices)
        try requireCount(
            tapUIDs.count, resource: "aggregate process taps", maximum: maximumTaps)

        let (endpointCount, overflowed) = subDevices.count.addingReportingOverflow(
            tapUIDs.count)
        guard !overflowed else {
            throw AggregateError.configurationExceedsLimit(
                resource: "aggregate endpoints", requested: Int.max,
                maximum: maximumEndpoints)
        }
        try requireCount(
            endpointCount, resource: "aggregate endpoints", maximum: maximumEndpoints)

        var memberUIDs = Set<String>()
        for member in subDevices {
            try requireUID(member.uid, resource: "sub-device UID")
            guard memberUIDs.insert(member.uid).inserted else {
                throw AggregateError.invalidConfiguration(
                    "aggregate sub-device UIDs must be unique")
            }
            try requireOptionalChannelCount(member.inputChannels, side: "input")
            try requireOptionalChannelCount(member.outputChannels, side: "output")
            if let frames = member.extraOutputLatencyFrames {
                guard frames >= 0, frames <= maximumExtraOutputLatencyFrames else {
                    throw AggregateError.configurationExceedsLimit(
                        resource: "extra output-latency frames", requested: frames,
                        maximum: maximumExtraOutputLatencyFrames)
                }
            }
        }

        var seenTapUIDs = Set<String>()
        for uid in tapUIDs {
            try requireUID(uid, resource: "process-tap UID")
            guard seenTapUIDs.insert(uid).inserted else {
                throw AggregateError.invalidConfiguration(
                    "aggregate process-tap UIDs must be unique")
            }
        }

        if subDevices.isEmpty {
            guard !tapUIDs.isEmpty, clockMasterUID == nil else {
                throw AggregateError.noSubDevices
            }
        } else {
            guard let clockMasterUID, memberUIDs.contains(clockMasterUID) else {
                throw AggregateError.clockMasterNotAMember(clockMasterUID ?? "")
            }
            try requireUID(clockMasterUID, resource: "clock-master UID")
        }
    }

    private static func requireCount(_ count: Int, resource: String, maximum: Int) throws {
        guard count <= maximum else {
            throw AggregateError.configurationExceedsLimit(
                resource: resource, requested: count, maximum: maximum)
        }
    }

    private static func requireUID(_ uid: String, resource: String) throws {
        guard !uid.isEmpty else {
            throw AggregateError.invalidConfiguration("\(resource) must not be empty")
        }
        try requireBytes(uid, resource: resource, maximum: maximumUIDBytes)
    }

    private static func requireBytes(_ value: String, resource: String, maximum: Int) throws {
        let count = value.utf8.count
        guard count <= maximum else {
            throw AggregateError.configurationExceedsLimit(
                resource: "\(resource) bytes", requested: count, maximum: maximum)
        }
    }

    private static func requireOptionalChannelCount(_ count: Int?, side: String) throws {
        guard let count else { return }
        guard count >= 0, count <= maximumChannelsPerMember else {
            throw AggregateError.configurationExceedsLimit(
                resource: "aggregate \(side) channels", requested: count,
                maximum: maximumChannelsPerMember)
        }
    }
}
