import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioHAL

@Suite("Background resource use")
struct BackgroundResourceTests {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.withLock { value += 1 }
        }

        var current: Int {
            lock.withLock { value }
        }
    }

    @Test("a hundred HAL notifications become one device refresh")
    func deviceChangeBurstIsCoalesced() throws {
        let queue = DispatchQueue(label: "yunaudio.test.device-change")
        let delivered = DispatchSemaphore(value: 0)
        let count = Count()
        let coalescer = DeviceChangeCoalescer(
            queue: queue, delay: .milliseconds(50)
        ) {
            count.increment()
            delivered.signal()
        }

        for _ in 0..<100 { coalescer.signal() }
        // Put every signal into the fixed window before its deadline. Without
        // the coalescer this barrier would leave 100 expensive refreshes queued.
        queue.sync {}
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        queue.sync {}
        #expect(count.current == 1)

        // Coalescing is per burst, not a once-only gate.
        coalescer.signal()
        queue.sync {}
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        queue.sync {}
        #expect(count.current == 2)
    }

    @MainActor
    @Test("a hundred control changes become one preferences write")
    func preferenceWritesAreCoalesced() async throws {
        var written: [Int] = []
        let writer = CoalescedPreferenceWriter<Int>(delay: .milliseconds(50)) {
            written.append($0)
        }

        for value in 0..<100 { writer.submit(value) }
        #expect(writer.pendingValue == 99)
        #expect(written.isEmpty)

        try await Task.sleep(for: .milliseconds(100))
        #expect(written == [99])
        #expect(writer.pendingValue == nil)

        // Quit does not wait for the window, so its flush has to write exactly
        // once and cancel the scheduled duplicate.
        writer.submit(100)
        writer.flush()
        try await Task.sleep(for: .milliseconds(100))
        #expect(written == [99, 100])
    }
}
