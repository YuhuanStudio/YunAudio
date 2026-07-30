import CoreAudio
import Foundation
import Testing

@testable import YunAudioHAL

@Suite("Device change watcher")
struct DeviceChangeWatcherTests {
    private let millisecond: UInt64 = 1_000_000

    private final class Inventory: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Set<AudioObjectID>?
        private var readCount = 0
        private var observed: [Set<AudioObjectID>?] = []

        init(_ value: Set<AudioObjectID>?) {
            self.value = value
        }

        func set(_ value: Set<AudioObjectID>?) {
            lock.withLock { self.value = value }
        }

        func read() -> Set<AudioObjectID>? {
            lock.withLock {
                readCount += 1
                observed.append(value)
                return value
            }
        }

        var reads: Int {
            lock.withLock { readCount }
        }

        var observations: [Set<AudioObjectID>?] {
            lock.withLock { observed }
        }
    }

    @Test("constructing a notification probe performs zero inventory reads")
    func constructionDoesNotReadInventory() {
        let inventory = Inventory([12, 34])
        let probe = DeviceInventoryProbe(initial: nil, read: inventory.read)

        #expect(inventory.reads == 0)
        probe.establishBaseline([12, 34])
        #expect(!probe.readChanged())
        #expect(inventory.reads == 1)
        inventory.set([12, 34, 56])
        #expect(probe.readChanged())
        #expect(inventory.reads == 2)
    }

    @Test("one thousand identical notifications perform six inventory reads")
    func identicalNotificationStormBacksOff() {
        let inventory = Inventory([12, 34])
        let probe = DeviceInventoryProbe(initial: [12, 34], read: inventory.read)
        var schedule = DeviceChangeSchedule()
        var deadline: UInt64?
        var deliveries = 0

        for elapsedMilliseconds in 0..<1_000 {
            let now = UInt64(elapsedMilliseconds) * millisecond
            if let due = deadline, due <= now {
                let changed = probe.readChanged()
                if changed { deliveries += 1 }
                schedule.complete(inventoryChanged: changed)
                deadline = nil
            }
            deadline = schedule.signal(at: now) ?? deadline
        }

        if deadline != nil {
            let changed = probe.readChanged()
            if changed { deliveries += 1 }
            schedule.complete(inventoryChanged: changed)
        }

        #expect(inventory.reads == 6)
        #expect(deliveries == 0)
    }

    @Test("a physical change after quiet is read in fifty milliseconds")
    func quietDeviceChangeKeepsLowLatency() {
        let inventory = Inventory([12, 34])
        let probe = DeviceInventoryProbe(initial: [12, 34], read: inventory.read)
        var schedule = DeviceChangeSchedule()

        guard var deadline = schedule.signal(at: 0) else {
            Issue.record("the first notification did not schedule a probe")
            return
        }
        schedule.complete(inventoryChanged: probe.readChanged())
        guard let secondDeadline = schedule.signal(at: deadline) else {
            Issue.record("the second notification did not schedule a probe")
            return
        }
        deadline = secondDeadline
        schedule.complete(inventoryChanged: probe.readChanged())
        guard let thirdDeadline = schedule.signal(at: deadline) else {
            Issue.record("the third notification did not schedule a probe")
            return
        }
        deadline = thirdDeadline
        schedule.complete(inventoryChanged: probe.readChanged())

        inventory.set([12, 34, 56])
        let quietSignal = deadline + 500 * millisecond
        guard let changeDeadline = schedule.signal(at: quietSignal) else {
            Issue.record("the physical change did not schedule a probe")
            return
        }

        #expect(changeDeadline - quietSignal == 50 * millisecond)
        #expect(probe.readChanged())
        schedule.complete(inventoryChanged: true)
        #expect(inventory.reads == 4)
    }

    @Test("a change inside a notification storm delivers the latest inventory")
    func stormReadsLatestInventory() {
        let inventory = Inventory([1])
        let probe = DeviceInventoryProbe(initial: [1], read: inventory.read)
        var schedule = DeviceChangeSchedule()

        guard let deadline = schedule.signal(at: 0) else {
            Issue.record("the first notification did not schedule a probe")
            return
        }
        inventory.set([1, 2])
        #expect(schedule.signal(at: 10 * millisecond) == nil)
        inventory.set([2, 3])
        #expect(schedule.signal(at: 20 * millisecond) == nil)

        #expect(deadline == 50 * millisecond)
        #expect(probe.readChanged())
        schedule.complete(inventoryChanged: true)
        #expect(inventory.observations == [[2, 3]])
    }

    @Test("a storm bounds physical-change latency to two hundred fifty milliseconds")
    func stormChangeLatencyIsBounded() {
        var schedule = DeviceChangeSchedule()
        var now: UInt64 = 0

        for _ in 0..<4 {
            guard let deadline = schedule.signal(at: now) else {
                Issue.record("a completed probe left the schedule pending")
                return
            }
            now = deadline
            schedule.complete(inventoryChanged: false)
        }

        guard let deadline = schedule.signal(at: now) else {
            Issue.record("the capped probe did not schedule")
            return
        }
        #expect(deadline - now == 250 * millisecond)
    }
}
