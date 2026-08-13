import CoreAudio
import Testing

@testable import YunAudioHAL

@Suite("Bounded HAL array reads")
struct HALArrayReadPolicyTests {
    private let selector: AudioObjectPropertySelector = 0x7465_7374  // 'test'

    @Test("a valid response has an exact element count")
    func validCount() throws {
        #expect(
            try HALArrayReadPolicy.elementCount(
                byteCount: 24, for: UInt64.self, selector: selector) == 3)
        #expect(
            try HALArrayReadPolicy.elementCount(
                byteCount: 16, for: UInt32.self, selector: selector,
                capacity: 32) == 4)
    }

    @Test("a partial element is rejected instead of rounded down")
    func partialElement() {
        #expect(throws: AudioHALError.self) {
            try HALArrayReadPolicy.elementCount(
                byteCount: 10, for: UInt64.self, selector: selector)
        }
    }

    @Test("a response cannot outgrow its allocated buffer")
    func responseGrowth() {
        #expect(throws: AudioHALError.self) {
            try HALArrayReadPolicy.elementCount(
                byteCount: 24, for: UInt64.self, selector: selector,
                capacity: 16)
        }
    }

    @Test("a corrupt census cannot request an unbounded allocation")
    func allocationBound() {
        #expect(throws: AudioHALError.self) {
            try HALArrayReadPolicy.elementCount(
                byteCount: HALArrayReadPolicy.maximumBytes + 1,
                for: AudioObjectID.self, selector: selector)
        }
    }

    @Test("a byte-valid object list still has a semantic operation ceiling")
    func semanticCount() throws {
        try HALSemanticArrayPolicy.validate(count: 4_096, maximum: 4_096, selector: selector)
        #expect(throws: AudioHALError.self) {
            try HALSemanticArrayPolicy.validate(
                count: 4_097, maximum: 4_096, selector: selector)
        }
        #expect(throws: AudioHALError.self) {
            try HALSemanticArrayPolicy.validate(count: -1, maximum: 4_096, selector: selector)
        }
    }

    @Test("an audio buffer list must contain every buffer it declares")
    func audioBufferListLayout() throws {
        let header = HALAudioBufferListPolicy.headerBytes
        let stride = MemoryLayout<AudioBuffer>.stride

        #expect(
            try HALAudioBufferListPolicy.bufferCount(
                byteCount: header + 3 * stride, declaredCount: 3,
                selector: selector) == 3)
        #expect(throws: AudioHALError.self) {
            try HALAudioBufferListPolicy.bufferCount(
                byteCount: header - 1, declaredCount: 0, selector: selector)
        }
        #expect(throws: AudioHALError.self) {
            try HALAudioBufferListPolicy.bufferCount(
                byteCount: header + stride, declaredCount: 2,
                selector: selector)
        }
    }
}
