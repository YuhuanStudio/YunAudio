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

    @Test("sixty seconds of self-notifications perform thirteen inventory reads")
    func identicalNotificationStormBacksOff() {
        let inventory = Inventory([12, 34])
        let diagnostics = DeviceChangeDiagnostics { _, _, _ in }
        let probe = DeviceInventoryProbe(
            initial: [12, 34], read: inventory.read, diagnostics: diagnostics)
        var schedule = DeviceChangeSchedule(diagnostics: diagnostics)
        var deliveries = 0

        guard var scheduled = schedule.signal(at: 0) else {
            Issue.record("the first notification did not schedule a probe")
            return
        }
        while scheduled.deadline <= 60_000 * millisecond {
            let began = schedule.beginProbe(scheduled)
            #expect(began)
            let changed = probe.readChanged()
            if changed { deliveries += 1 }
            schedule.complete(inventoryChanged: changed, at: scheduled.deadline)
            guard let next = schedule.signal(at: scheduled.deadline) else {
                Issue.record("the self-notification did not schedule another probe")
                return
            }
            scheduled = next
        }

        #expect(inventory.reads == 13)
        #expect(scheduled.deadline == 63_750 * millisecond)
        #expect(deliveries == 0)
        #expect(
            diagnostics.snapshot
                == DeviceChangeDiagnostics.Snapshot(
                    notifications: 14, probes: 14, superseded: 0, halReads: 13))
    }

    @Test("diagnostics are disabled unless the trace environment opts in")
    func diagnosticsAreOffByDefault() {
        #expect(DeviceChangeDiagnostics.fromEnvironment([:]) == nil)
        #expect(
            DeviceChangeDiagnostics.fromEnvironment(
                ["YUNAUDIO_DEVICE_WATCH_TRACE": "0"]) == nil)
    }

    @Test("notification, probe, supersede, and HAL-read counts are event exact")
    func diagnosticCountsAreEventExact() {
        let diagnostics = DeviceChangeDiagnostics(clock: { 123 }) { _, _, _ in }
        let inventory = Inventory([1])
        let probe = DeviceInventoryProbe(
            initial: [1], read: inventory.read, diagnostics: diagnostics)
        var schedule = DeviceChangeSchedule(diagnostics: diagnostics)

        diagnostics.record(.notification)
        guard let first = schedule.signal(at: 0, recordsNotification: false) else {
            Issue.record("the first notification did not schedule a probe")
            return
        }
        #expect(schedule.signal(at: 10 * millisecond) == nil)
        let firstBegan = schedule.beginProbe(first)
        #expect(firstBegan)
        #expect(!probe.readChanged())
        schedule.complete(inventoryChanged: false, at: first.deadline)

        guard let stale = schedule.signal(at: first.deadline) else {
            Issue.record("the self-notification did not schedule a probe")
            return
        }
        let quietSignal = first.deadline + 550 * millisecond
        guard let replacement = schedule.signal(at: quietSignal) else {
            Issue.record("the quiet notification did not replace the pending probe")
            return
        }
        let replacementBegan = schedule.beginProbe(replacement)
        #expect(replacementBegan)
        #expect(!probe.readChanged())
        let staleBegan = schedule.beginProbe(stale)
        #expect(!staleBegan)

        #expect(inventory.reads == 2)
        #expect(
            diagnostics.snapshot
                == DeviceChangeDiagnostics.Snapshot(
                    notifications: 4, probes: 3, superseded: 1, halReads: 2))
    }

    @Test("unchanged self-notifications follow the bounded backoff ladder")
    func unchangedBackoffLadderIsBounded() {
        var schedule = DeviceChangeSchedule()
        var now: UInt64 = 0
        var delays: [UInt64] = []

        for _ in 0..<10 {
            guard let scheduled = schedule.signal(at: now) else {
                Issue.record("a completed probe left the schedule pending")
                return
            }
            delays.append(scheduled.deadline - now)
            now = scheduled.deadline
            let began = schedule.beginProbe(scheduled)
            #expect(began)
            schedule.complete(inventoryChanged: false, at: now)
        }

        #expect(
            delays
                == [50, 100, 200, 400, 1_000, 2_000, 4_000, 8_000, 8_000, 8_000]
                .map { UInt64($0) * millisecond })
    }

    @Test("a physical change after quiet is read in fifty milliseconds")
    func quietDeviceChangeKeepsLowLatency() {
        let inventory = Inventory([12, 34])
        let probe = DeviceInventoryProbe(initial: [12, 34], read: inventory.read)
        var schedule = DeviceChangeSchedule()

        guard var scheduled = schedule.signal(at: 0) else {
            Issue.record("the first notification did not schedule a probe")
            return
        }
        var began = schedule.beginProbe(scheduled)
        #expect(began)
        schedule.complete(inventoryChanged: probe.readChanged(), at: scheduled.deadline)
        guard let second = schedule.signal(at: scheduled.deadline) else {
            Issue.record("the second notification did not schedule a probe")
            return
        }
        scheduled = second
        began = schedule.beginProbe(scheduled)
        #expect(began)
        schedule.complete(inventoryChanged: probe.readChanged(), at: scheduled.deadline)
        guard let third = schedule.signal(at: scheduled.deadline) else {
            Issue.record("the third notification did not schedule a probe")
            return
        }
        scheduled = third
        began = schedule.beginProbe(scheduled)
        #expect(began)
        schedule.complete(inventoryChanged: probe.readChanged(), at: scheduled.deadline)

        inventory.set([12, 34, 56])
        let quietSignal = scheduled.deadline + 500 * millisecond
        guard let change = schedule.signal(at: quietSignal) else {
            Issue.record("the physical change did not schedule a probe")
            return
        }

        #expect(change.deadline - quietSignal == 50 * millisecond)
        began = schedule.beginProbe(change)
        #expect(began)
        #expect(probe.readChanged())
        schedule.complete(inventoryChanged: true, at: change.deadline)
        #expect(inventory.reads == 4)
    }

    @Test("a change inside a notification storm delivers the latest inventory")
    func stormReadsLatestInventory() {
        let inventory = Inventory([1])
        let probe = DeviceInventoryProbe(initial: [1], read: inventory.read)
        var schedule = DeviceChangeSchedule()

        guard let scheduled = schedule.signal(at: 0) else {
            Issue.record("the first notification did not schedule a probe")
            return
        }
        inventory.set([1, 2])
        #expect(schedule.signal(at: 10 * millisecond) == nil)
        inventory.set([2, 3])
        #expect(schedule.signal(at: 20 * millisecond) == nil)

        #expect(scheduled.deadline == 50 * millisecond)
        let began = schedule.beginProbe(scheduled)
        #expect(began)
        #expect(probe.readChanged())
        schedule.complete(inventoryChanged: true, at: scheduled.deadline)
        #expect(inventory.observations == [[2, 3]])
    }

    @Test("a quiet real change supersedes an eight-second storm probe")
    func quietChangeSupersedesStormProbe() {
        let inventory = Inventory([1])
        let probe = DeviceInventoryProbe(initial: [1], read: inventory.read)
        var schedule = DeviceChangeSchedule()
        var now: UInt64 = 0

        for _ in 0..<7 {
            guard let scheduled = schedule.signal(at: now) else {
                Issue.record("a completed probe left the schedule pending")
                return
            }
            now = scheduled.deadline
            let began = schedule.beginProbe(scheduled)
            #expect(began)
            #expect(!probe.readChanged())
            schedule.complete(inventoryChanged: false, at: now)
        }

        guard let stale = schedule.signal(at: now) else {
            Issue.record("the capped probe did not schedule")
            return
        }
        #expect(stale.deadline - now == 8_000 * millisecond)

        inventory.set([1, 2])
        let physicalSignal = now + 1_000 * millisecond
        guard let replacement = schedule.signal(at: physicalSignal) else {
            Issue.record("the quiet physical notification did not replace the storm probe")
            return
        }
        #expect(replacement != stale)
        #expect(replacement.deadline - physicalSignal == 50 * millisecond)

        let replacementBegan = schedule.beginProbe(replacement)
        #expect(replacementBegan)
        #expect(probe.readChanged())
        schedule.complete(inventoryChanged: true, at: replacement.deadline)
        let readsAfterReplacement = inventory.reads

        guard let reset = schedule.signal(at: replacement.deadline) else {
            Issue.record("a real inventory change did not reset the schedule")
            return
        }
        #expect(reset.deadline - replacement.deadline == 50 * millisecond)
        let staleBegan = schedule.beginProbe(stale)
        #expect(!staleBegan)
        #expect(inventory.reads == readsAfterReplacement)
        #expect(readsAfterReplacement == 8)
        #expect(inventory.observations.last == [1, 2])
    }
}
