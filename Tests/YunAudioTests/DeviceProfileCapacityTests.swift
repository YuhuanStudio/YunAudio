import Foundation
import Testing

@testable import YunAudioHAL

@Suite("Device profile capacity")
struct DeviceProfileCapacityTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-profile-capacity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a profile larger than sixty-four KiB is never decoded")
    func oversizedFile() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.json")
        try Data(repeating: 0x20, count: DeviceProfileLibrary.maximumProfileBytes + 1)
            .write(to: file)

        let result = DeviceProfileLibrary.load(from: directory)
        #expect(result.0.isEmpty)
        #expect(result.1 == ["large.json: profile is too large"])
    }

    @Test("a profile cannot manufacture a sixty-fifth channel")
    func tooManyChannels() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let channels = (0...DeviceProfileLibrary.maximumChannelsPerProfile).map {
            ["name": "Channel \($0)", "detail": ""]
        }
        let object: [String: Any] = ["match": "example", "inputChannels": channels]
        let file = directory.appendingPathComponent("channels.json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        let result = DeviceProfileLibrary.load(from: directory)
        #expect(result.0.isEmpty)
        #expect(result.1 == ["channels.json: profile exceeds safe limits"])
    }
}
