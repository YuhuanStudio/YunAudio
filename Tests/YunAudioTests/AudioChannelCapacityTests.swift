import Testing

@testable import YunAudioHAL

@Suite("Audio channel capacity")
struct AudioChannelCapacityTests {
    @Test("sixty-four reported channels are admitted exactly")
    func exactMaximum() {
        #expect(AudioDevice.admittedChannelTotal([32, 16, 16]) == 64)
        #expect(AudioDevice.admittedChannelTotal([64]) == 64)
    }

    @Test("one channel beyond the routing topology fails closed")
    func aboveMaximum() {
        #expect(AudioDevice.admittedChannelTotal([64, 1]) == nil)
        #expect(AudioDevice.admittedChannelTotal([65]) == nil)
        #expect(AudioDevice.admittedChannelTotal([UInt32.max]) == nil)
    }
}
