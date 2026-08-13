import Testing

@testable import YunAudioEngine

@Suite("Sound classifier capacity")
struct SoundClassifierCapacityTests {
    @Test("one oversized batch is split into exact windows without losing its tail")
    func oversizedBatchIsPartitioned() throws {
        let buffer = try #require(SoundClassifierWindowBuffer(capacity: 8))
        let samples = (0..<27).map(Float.init)
        var windows: [[Float]] = []

        let completed = samples.withUnsafeBufferPointer {
            buffer.append($0.baseAddress!, count: $0.count) {
                windows.append(Array($0))
            }
        }
        var tail: [Float] = []
        buffer.withPendingSamples { tail = Array($0) }

        #expect(completed == 3)
        let expectedWindows: [[Float]] = [
            (0..<8).map { Float($0) },
            (8..<16).map { Float($0) },
            (16..<24).map { Float($0) },
        ]
        #expect(windows == expectedWindows)
        #expect(tail == [24, 25, 26])
        #expect(buffer.count == 3)
        #expect(buffer.highWaterMark == 8)
        #expect(buffer.storageBytes == 8 * MemoryLayout<Float>.stride)
    }

    @Test("a partial tail joins the next call in chronological order")
    func tailContinuesAcrossCalls() throws {
        let buffer = try #require(SoundClassifierWindowBuffer(capacity: 8))
        let first = (0..<5).map(Float.init)
        let second = (5..<19).map(Float.init)
        var windows: [[Float]] = []

        first.withUnsafeBufferPointer {
            #expect(
                buffer.append($0.baseAddress!, count: $0.count) {
                    windows.append(Array($0))
                } == 0)
        }
        second.withUnsafeBufferPointer {
            #expect(
                buffer.append($0.baseAddress!, count: $0.count) {
                    windows.append(Array($0))
                } == 2)
        }
        var tail: [Float] = []
        buffer.withPendingSamples { tail = Array($0) }

        let expectedWindows: [[Float]] = [
            (0..<8).map { Float($0) },
            (8..<16).map { Float($0) },
        ]
        #expect(windows == expectedWindows)
        #expect(tail == [16, 17, 18])
        #expect(windows.flatMap { $0 } + tail == (0..<19).map(Float.init))
        #expect(buffer.count < buffer.capacity)
    }

    @Test("the fixed window rejects capacities outside the processing contract")
    func capacityAdmission() {
        #expect(SoundClassifierWindowBuffer(capacity: 0) == nil)
        #expect(SoundClassifierWindowBuffer(capacity: -1) == nil)
        #expect(
            SoundClassifierWindowBuffer(
                capacity: SoundClassifierWindowBuffer.maximumCapacity + 1) == nil)
    }
}
