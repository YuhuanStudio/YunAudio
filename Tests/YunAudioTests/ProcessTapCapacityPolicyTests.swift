import CoreAudio
import Testing

@testable import YunAudioHAL

@Suite("Process-tap capacity policy")
struct ProcessTapCapacityPolicyTests {
    @Test("sixty-four process objects are admitted and sixty-five are refused")
    func processCount() throws {
        try ProcessTapCapacityPolicy.validate(
            processIDs: (1...64).map { AudioObjectID($0) },
            bundleIDs: [])

        do {
            try ProcessTapCapacityPolicy.validate(
                processIDs: (1...65).map { AudioObjectID($0) },
                bundleIDs: [])
            Issue.record("sixty-five process IDs were admitted")
        } catch let ProcessTapError.configurationExceedsLimit(
            resource, requested, maximum
        ) {
            #expect(resource == "process-tap processes")
            #expect(requested == 65)
            #expect(maximum == 64)
        }
    }

    @Test("an empty restore tap is valid but named process identities must be unique")
    func processIdentity() throws {
        try ProcessTapCapacityPolicy.validate(processIDs: [], bundleIDs: [])
        #expect(throws: ProcessTapError.self) {
            try ProcessTapCapacityPolicy.validate(processIDs: [0], bundleIDs: [])
        }
        #expect(throws: ProcessTapError.self) {
            try ProcessTapCapacityPolicy.validate(processIDs: [1, 1], bundleIDs: [])
        }
    }

    @Test("bundle identifiers have independent count and byte ceilings")
    func bundleIdentifiers() throws {
        try ProcessTapCapacityPolicy.validate(
            processIDs: [1],
            bundleIDs: [String(repeating: "b", count: 1_024)])

        #expect(throws: ProcessTapError.self) {
            try ProcessTapCapacityPolicy.validate(
                processIDs: [1],
                bundleIDs: [String(repeating: "b", count: 1_025)])
        }
        #expect(throws: ProcessTapError.self) {
            try ProcessTapCapacityPolicy.validate(
                processIDs: [1],
                bundleIDs: Array(repeating: "bundle", count: 65))
        }
        #expect(throws: ProcessTapError.self) {
            try ProcessTapCapacityPolicy.validate(
                processIDs: [1], bundleIDs: ["bundle", "bundle"])
        }
    }
}
