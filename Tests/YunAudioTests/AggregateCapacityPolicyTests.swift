import Testing

@testable import YunAudioHAL

@Suite("Aggregate capacity policy")
struct AggregateCapacityPolicyTests {
    private func member(
        _ uid: String, input: Int? = nil, output: Int? = nil,
        latency: Int? = nil
    ) -> AggregateDevice.SubDevice {
        .init(
            uid: uid, driftCompensation: true, inputChannels: input,
            outputChannels: output, extraOutputLatencyFrames: latency)
    }

    private func validate(
        _ members: [AggregateDevice.SubDevice], tapUIDs: [String] = []
    ) throws {
        try AggregateCapacityPolicy.validate(
            name: "test", subDevices: members,
            clockMasterUID: members.first?.uid, tapUIDs: tapUIDs)
    }

    @Test("sixteen total endpoints are admitted and seventeen are refused")
    func endpointBoundary() throws {
        let sixteen = (0..<15).map { member("device-\($0)") }
        try validate(sixteen, tapUIDs: ["tap"])

        do {
            try validate(sixteen, tapUIDs: ["tap-a", "tap-b"])
            Issue.record("seventeen aggregate endpoints were admitted")
        } catch let AggregateError.configurationExceedsLimit(resource, requested, maximum) {
            #expect(resource == "aggregate endpoints")
            #expect(requested == 17)
            #expect(maximum == 16)
        }
    }

    @Test("member dimensions have exact inclusive ceilings")
    func memberDimensions() throws {
        try validate([member("device", input: 64, output: 64, latency: 48_000)])

        for invalid in [
            member("device", input: -1),
            member("device", input: 65),
            member("device", output: -1),
            member("device", output: 65),
            member("device", latency: -1),
            member("device", latency: 48_001),
        ] {
            #expect(throws: AggregateError.self) {
                try validate([invalid])
            }
        }
    }

    @Test("identifiers are unique, non-empty and byte bounded")
    func identifiers() throws {
        try validate([member(String(repeating: "u", count: 1_024))])

        #expect(throws: AggregateError.self) {
            try validate([member(String(repeating: "u", count: 1_025))])
        }
        #expect(throws: AggregateError.self) {
            try validate([member("")])
        }
        #expect(throws: AggregateError.self) {
            try validate([member("same"), member("same")])
        }
        #expect(throws: AggregateError.self) {
            try validate([member("device")], tapUIDs: ["same", "same"])
        }
    }

    @Test("a tap-only aggregate is admitted without inventing a clock master")
    func tapsOnly() throws {
        try AggregateCapacityPolicy.validate(
            name: "tap", subDevices: [], clockMasterUID: nil,
            tapUIDs: ["tap"])
        #expect(throws: AggregateError.self) {
            try AggregateCapacityPolicy.validate(
                name: "empty", subDevices: [], clockMasterUID: nil,
                tapUIDs: [])
        }
    }
}
