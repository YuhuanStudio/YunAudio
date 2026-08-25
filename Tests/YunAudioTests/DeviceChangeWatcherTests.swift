import CoreAudio
import Foundation
import Testing

@testable import YunAudioHAL

@Suite("Device change watcher")
struct DeviceChangeWatcherTests {
    private let millisecond: UInt64 = 1_000_000

    private final class ListenerHarness: @unchecked Sendable {
        private let lock = NSLock()
        private var listener: DeviceChangeListenerRegistration?
        private var installationCount = 0
        private var removalCount = 0
        private var removalThreads: [Bool] = []
        let removed = DispatchSemaphore(value: 0)

        func install(_ listener: DeviceChangeListenerRegistration) -> Bool {
            lock.withLock {
                installationCount += 1
                self.listener = listener
            }
            return true
        }

        func remove(_: DeviceChangeListenerRegistration) {
            lock.withLock {
                removalCount += 1
                removalThreads.append(Thread.isMainThread)
                self.listener = nil
            }
            removed.signal()
        }

        func notify() {
            let listener = lock.withLock { listener }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            withUnsafePointer(to: &address) { pointer in
                listener?.block(1, pointer)
            }
        }

        var removals: Int {
            lock.withLock { removalCount }
        }

        var installations: Int {
            lock.withLock { installationCount }
        }

        var removedOnMainThread: [Bool] {
            lock.withLock { removalThreads }
        }
    }

    private final class BlockingInventory: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseFirst = DispatchSemaphore(value: 0)
        let firstEntered = DispatchSemaphore(value: 0)
        private(set) var readCount = 0
        private(set) var maximumConcurrentReads = 0
        private var concurrentReads = 0

        func read() -> Set<AudioObjectID>? {
            let ordinal = lock.withLock {
                readCount += 1
                concurrentReads += 1
                maximumConcurrentReads = max(maximumConcurrentReads, concurrentReads)
                return readCount
            }
            if ordinal == 1 {
                firstEntered.signal()
                _ = releaseFirst.wait(timeout: .now() + TestGate.deadlock)
            }
            lock.withLock { concurrentReads -= 1 }
            return ordinal == 1 ? [1, 2] : [1, 3]
        }

        func releaseEnteredRead() {
            releaseFirst.signal()
        }

        var snapshot: (reads: Int, maximumConcurrentReads: Int) {
            lock.withLock { (readCount, maximumConcurrentReads) }
        }
    }

    private func fastSchedule() -> DeviceChangeSchedule {
        DeviceChangeSchedule(
            initialDelay: millisecond,
            burstMaximumDelay: 2 * millisecond,
            stormInitialDelay: 3 * millisecond,
            maximumDelay: 4 * millisecond,
            quietReset: 5 * millisecond)
    }

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

    @Test("suspension revokes a queued probe and ten thousand later notifications")
    func suspensionRevokesQueuedAndLaterNotifications() {
        let queue = DispatchQueue(label: "device-watch-tests.suspension")
        let queueEntered = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        queue.async {
            queueEntered.signal()
            _ = releaseQueue.wait(timeout: .now() + TestGate.deadlock)
        }
        #expect(queueEntered.wait(timeout: .now() + 1) == .success)

        let listener = ListenerHarness()
        let inventory = Inventory([1, 2])
        let delivered = DispatchSemaphore(value: 0)
        let watcher = DeviceChangeWatcher(
            queue: queue,
            schedule: fastSchedule(),
            initialInventory: [1],
            inventoryRead: inventory.read,
            installListener: listener.install,
            removeListener: listener.remove
        ) {
            delivered.signal()
        }

        // This callback is admitted but remains queued behind the artificial
        // owner stall. Suspension must make its token stale before it enters HAL.
        listener.notify()
        let began = DispatchTime.now().uptimeNanoseconds
        #expect(watcher.suspend())
        let suspensionNanoseconds = DispatchTime.now().uptimeNanoseconds - began
        // Core Audio delivers the block on this same queue. Submit the storm
        // before resume so the test proves delayed callbacks do not become a
        // new-generation notification merely because they execute later.
        for _ in 0..<10_000 {
            queue.async { listener.notify() }
        }
        #expect(inventory.reads == 0)
        #expect(watcher.resume())
        #expect(inventory.reads == 0)
        releaseQueue.signal()

        #expect(suspensionNanoseconds < 8_000_000)

        #expect(delivered.wait(timeout: .now() + 1) == .success)
        #expect(delivered.wait(timeout: .now() + .milliseconds(20)) == .timedOut)
        #expect(inventory.reads == 1)
        #expect(inventory.observations == [[1, 2]])
        #expect(listener.installations == 1)

        #expect(watcher.shutdown())
        #expect(listener.removed.wait(timeout: .now() + 1) == .success)
        #expect(listener.removals == 1)
    }

    @MainActor
    @Test("accepted shutdown removes one listener off MainActor exactly once")
    func acceptedShutdownRemovesListenerExactlyOnce() {
        let queue = DispatchQueue(label: "device-watch-tests.shutdown")
        let listener = ListenerHarness()
        let watcher = DeviceChangeWatcher(
            queue: queue,
            schedule: fastSchedule(),
            initialInventory: [1],
            inventoryRead: { [1] },
            installListener: listener.install,
            removeListener: listener.remove,
            onChange: {})

        let began = DispatchTime.now().uptimeNanoseconds
        #expect(watcher.shutdown())
        let admissionNanoseconds = DispatchTime.now().uptimeNanoseconds - began
        for _ in 0..<10_000 { #expect(!watcher.shutdown()) }

        #expect(admissionNanoseconds < 8_000_000)
        #expect(listener.removed.wait(timeout: .now() + 1) == .success)
        #expect(listener.removals == 1)
        #expect(listener.installations == 1)
        #expect(listener.removedOnMainThread == [false])
    }

    @Test("an entered read publishes zero late results and resume stays single owner")
    func enteredReadIsQuarantinedAcrossResume() {
        let queue = DispatchQueue(label: "device-watch-tests.entered-read")
        let listener = ListenerHarness()
        let inventory = BlockingInventory()
        let delivered = DispatchSemaphore(value: 0)
        let watcher = DeviceChangeWatcher(
            queue: queue,
            schedule: fastSchedule(),
            initialInventory: [1],
            inventoryRead: inventory.read,
            installListener: listener.install,
            removeListener: listener.remove
        ) {
            delivered.signal()
        }

        listener.notify()
        #expect(inventory.firstEntered.wait(timeout: .now() + 1) == .success)
        let began = DispatchTime.now().uptimeNanoseconds
        #expect(watcher.suspend())
        let suspensionNanoseconds = DispatchTime.now().uptimeNanoseconds - began
        #expect(watcher.resume())
        inventory.releaseEnteredRead()

        #expect(delivered.wait(timeout: .now() + 1) == .success)
        #expect(delivered.wait(timeout: .now() + .milliseconds(20)) == .timedOut)
        #expect(inventory.snapshot.reads == 2)
        #expect(inventory.snapshot.maximumConcurrentReads == 1)
        #expect(listener.installations == 1)
        #expect(suspensionNanoseconds < 8_000_000)

        #expect(watcher.shutdown())
        #expect(listener.removed.wait(timeout: .now() + 1) == .success)
        #expect(listener.removals == 1)
    }

    /// A watcher whose baseline never arrives has to start working anyway.
    ///
    /// It did not. `establishBaseline` is reached from one code path in
    /// RouterModel, the verification process reads its inventory synchronously
    /// and takes the other one, and the watcher then swallowed every
    /// notification for the lifetime of the process — a decoy device created
    /// beside a running route was never seen, and neither was a destination
    /// being destroyed underneath one. The first read is the baseline now:
    /// silent, because it has nothing to be a change from, and after it every
    /// notification is a real comparison.
    @Test("a probe with no baseline supplied baselines itself on its first read")
    func probeBaselinesItselfWithoutBeingTold() {
        let inventory = Inventory([12, 34])
        let probe = DeviceInventoryProbe(initial: nil, read: inventory.read)

        // Adopted, not announced: announcing it would mean a second
        // whole-machine enumeration beside the launch inventory, every launch.
        #expect(!probe.readChanged())
        #expect(inventory.reads == 1)

        inventory.set([12, 34, 56])
        #expect(probe.readChanged())
        inventory.set([12, 34, 56])
        #expect(!probe.readChanged())
        #expect(inventory.reads == 3)
    }

    /// A read that failed is not a machine with no devices, and it must not
    /// become the baseline either — that would make the next successful read
    /// look like every device on the machine appearing at once.
    @Test("a failed first read leaves the probe still waiting for a baseline")
    func failedFirstReadDoesNotBaseline() {
        let inventory = Inventory(nil)
        let probe = DeviceInventoryProbe(initial: nil, read: inventory.read)

        #expect(!probe.readChanged())
        inventory.set([12, 34])
        #expect(!probe.readChanged())
        inventory.set([12, 34, 56])
        #expect(probe.readChanged())
        #expect(inventory.reads == 3)
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
