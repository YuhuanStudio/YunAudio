import CoreAudio
import Foundation

/// Watches the HAL for devices appearing and disappearing.
///
/// Everything the app persists is keyed on a device UID rather than an
/// `AudioObjectID`, because the numeric ID is reassigned on replug. This is the
/// signal that tells the app to go and re-resolve those UIDs.
public final class DeviceChangeWatcher: @unchecked Sendable {
    private var block: AudioObjectPropertyListenerBlock?
    private let queue: DispatchQueue
    private let coalescer: DeviceChangeCoalescer
    private let inventory: DeviceInventoryProbe
    /// Accessed only on `queue`.
    private var hasBaseline = false
    /// Accessed only on `queue`.
    private var notificationBeforeBaseline = false

    private static let deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    public init(onChange: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "com.yuhuanstudio.yunaudio.device-watch")
        self.queue = queue
        let inventory = DeviceInventoryProbe(
            // Construction happens before the application's first frame. A
            // baseline read here blocked MainActor on coreaudiod even though
            // there had not been a device-change notification to answer.
            // Starting unknown keeps construction read-free. RouterModel seeds
            // this probe from the launch snapshot before a notification is
            // allowed to ask HAL whether anything changed.
            initial: nil,
            read: Self.inventorySignature)
        self.inventory = inventory
        coalescer = DeviceChangeCoalescer(queue: queue) {
            // Some audio plug-ins announce the device-list property after a
            // harmless property read. Re-enumerating complete devices in
            // response asks the same plug-in again and can create a permanent
            // notification loop. An unchanged answer increases the probe
            // interval, while an actual inventory change restores the 50 ms
            // response for the next physical device event.
            let changed = inventory.readChanged()
            if changed { onChange() }
            return changed
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // The listener itself is delivered on `queue`. Until RouterModel
            // publishes its launch snapshot there is no baseline against which
            // a notification can mean "changed", so remember the event without
            // starting a second inventory beside the first.
            if self.hasBaseline {
                self.coalescer.signal()
            } else {
                self.notificationBeforeBaseline = true
            }
        }
        block = listener

        var deviceList = Self.deviceListAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID.system, &deviceList, queue, listener)

    }

    /// Supplies the ID set already read by RouterModel's launch inventory.
    ///
    /// A notification received during that read is replayed once. If the set
    /// is unchanged, the probe suppresses it; if hardware really changed in
    /// the read's window, the ordinary refresh is delivered.
    public func establishBaseline(_ ids: Set<AudioObjectID>) {
        queue.async { [weak self] in
            guard let self else { return }
            self.inventory.establishBaseline(ids)
            self.hasBaseline = true
            if self.notificationBeforeBaseline {
                self.notificationBeforeBaseline = false
                self.coalescer.signal()
            }
        }
    }

    deinit {
        guard let block else { return }
        var deviceList = Self.deviceListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID.system, &deviceList, queue, block)
    }

    private static func inventorySignature() -> Set<AudioObjectID>? {
        try? Set(AudioObjectID.system.array(of: .devices))
    }
}

/// Turns one HAL change into one application refresh, however many properties
/// announce it.
///
/// Plugging in one device can publish the device list several times in the same
/// HAL turn. Those callbacks must not each run a complete device enumeration
/// and route-recovery pass. This is a fixed window from the first
/// event rather than a debounce: a device that keeps producing notifications
/// cannot postpone recovery indefinitely.
final class DeviceChangeCoalescer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let clock: @Sendable () -> UInt64
    private let handler: @Sendable () -> Bool
    /// Accessed only on `queue`.
    private var schedule: DeviceChangeSchedule

    init(
        queue: DispatchQueue,
        schedule: DeviceChangeSchedule = DeviceChangeSchedule(),
        clock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        handler: @escaping @Sendable () -> Bool
    ) {
        self.queue = queue
        self.schedule = schedule
        self.clock = clock
        self.handler = handler
    }

    func signal() {
        queue.async { [weak self] in
            guard let self else { return }
            let now = clock()
            guard let deadline = schedule.signal(at: now) else { return }
            queue.asyncAfter(
                deadline: DispatchTime(uptimeNanoseconds: deadline)
            ) { [weak self] in
                guard let self else { return }
                schedule.complete(inventoryChanged: handler())
            }
        }
    }
}

/// Schedules device-list probes without allowing a noisy endpoint to poll HAL.
///
/// The first notification in a quiet period is delivered after 50 ms so one
/// physical plug event can publish all of its properties. Repeated unchanged
/// answers back off to 250 ms. That cap keeps a real device change responsive
/// even when an unrelated plug-in is continuously publishing false changes.
struct DeviceChangeSchedule: Sendable {
    private let initialDelay: UInt64
    private let maximumDelay: UInt64
    private let quietReset: UInt64
    private var delay: UInt64
    private var lastSignal: UInt64?
    private var isPending = false

    init(
        initialDelay: UInt64 = 50_000_000,
        maximumDelay: UInt64 = 250_000_000,
        quietReset: UInt64 = 500_000_000
    ) {
        precondition(initialDelay > 0)
        precondition(maximumDelay >= initialDelay)
        precondition(quietReset >= initialDelay)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.quietReset = quietReset
        delay = initialDelay
    }

    mutating func signal(at now: UInt64) -> UInt64? {
        if let lastSignal, now &- lastSignal >= quietReset {
            delay = initialDelay
        }
        lastSignal = now
        guard !isPending else { return nil }
        isPending = true
        return now.addingReportingOverflow(delay).partialValue
    }

    mutating func complete(inventoryChanged: Bool) {
        isPending = false
        if inventoryChanged {
            delay = initialDelay
        } else {
            delay = min(delay.multipliedReportingOverflow(by: 2).partialValue, maximumDelay)
        }
    }
}

/// Delivers only a real change to the system's device identifiers.
///
/// Accessed on the watcher's serial queue. A failed read is not interpreted as
/// an empty machine: doing that would report every endpoint missing because one
/// transient query failed.
final class DeviceInventoryGate: @unchecked Sendable {
    private var current: Set<AudioObjectID>?

    init(initial: Set<AudioObjectID>?) {
        current = initial
    }

    func establishBaseline(_ baseline: Set<AudioObjectID>) {
        current = baseline
    }

    func shouldDeliver(_ candidate: Set<AudioObjectID>?) -> Bool {
        guard let candidate, candidate != current else { return false }
        current = candidate
        return true
    }
}

/// Reads the device ID set only when the coalescer's probe deadline arrives.
///
/// Keeping the read behind a closure makes the expensive system-object IPC
/// count measurable without asking CoreAudio during a unit test.
final class DeviceInventoryProbe: @unchecked Sendable {
    private let gate: DeviceInventoryGate
    private let read: @Sendable () -> Set<AudioObjectID>?

    init(
        initial: Set<AudioObjectID>?,
        read: @escaping @Sendable () -> Set<AudioObjectID>?
    ) {
        gate = DeviceInventoryGate(initial: initial)
        self.read = read
    }

    func readChanged() -> Bool {
        gate.shouldDeliver(read())
    }

    func establishBaseline(_ baseline: Set<AudioObjectID>) {
        gate.establishBaseline(baseline)
    }
}
