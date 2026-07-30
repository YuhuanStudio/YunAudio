import Testing

@testable import YunAudioHAL

@Suite("Bluetooth enumeration policy")
struct BluetoothEnumerationPolicyTests {
    @Test("an unrelated classic or LE Bluetooth endpoint skips timing")
    func unrelatedBluetoothSkipsTiming() {
        let selected = Set(["selected"])

        #expect(
            !AudioDevices.shouldLoadTimingCapabilities(
                transport: .bluetooth, uid: "other-classic", selectedUIDs: selected))
        #expect(
            !AudioDevices.shouldLoadTimingCapabilities(
                transport: .bluetoothLE, uid: "other-le", selectedUIDs: selected))
    }

    @Test("a selected Bluetooth endpoint loads timing")
    func selectedBluetoothLoadsTiming() {
        #expect(
            AudioDevices.shouldLoadTimingCapabilities(
                transport: .bluetooth, uid: "selected", selectedUIDs: ["selected"]))
        #expect(
            AudioDevices.shouldLoadTimingCapabilities(
                transport: .bluetoothLE, uid: "selected", selectedUIDs: ["selected"]))
    }

    @Test("a non-Bluetooth endpoint always loads timing")
    func nonBluetoothLoadsTiming() {
        #expect(
            AudioDevices.shouldLoadTimingCapabilities(
                transport: .usb, uid: "interface", selectedUIDs: []))
    }
}
