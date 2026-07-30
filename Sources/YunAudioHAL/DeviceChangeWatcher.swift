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
    private let diagnostics: DeviceChangeDiagnostics?
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
        let diagnostics = DeviceChangeDiagnostics.fromEnvironment()
        self.diagnostics = diagnostics
        let inventory = DeviceInventoryProbe(
            // Construction happens before the application's first frame. A
            // baseline read here blocked MainActor on coreaudiod even though
            // there had not been a device-change notification to answer.
            // Starting unknown keeps construction read-free. RouterModel seeds
            // this probe from the launch snapshot before a notification is
            // allowed to ask HAL whether anything changed.
            initial: nil,
            read: Self.inventorySignature,
            diagnostics: diagnostics)
        self.inventory = inventory
        coalescer = DeviceChangeCoalescer(queue: queue, diagnostics: diagnostics) {
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
                self.diagnostics?.record(.notification)
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
                self.coalescer.signal(recordsNotification: false)
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
        diagnostics: DeviceChangeDiagnostics? = nil,
        clock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        handler: @escaping @Sendable () -> Bool
    ) {
        self.queue = queue
        var schedule = schedule
        schedule.diagnostics = diagnostics
        self.schedule = schedule
        self.clock = clock
        self.handler = handler
    }

    func signal(recordsNotification: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = clock()
            guard
                let probe = schedule.signal(
                    at: now, recordsNotification: recordsNotification)
            else { return }
            queue.asyncAfter(
                deadline: DispatchTime(uptimeNanoseconds: probe.deadline)
            ) { [weak self] in
                guard let self else { return }
                // A quiet, later notification can replace a long storm
                // deadline. The old closure is still in Dispatch's queue; the
                // token is what keeps it from reading HAL or completing the new
                // generation when it eventually arrives.
                guard schedule.beginProbe(probe) else { return }
                schedule.complete(inventoryChanged: handler(), at: clock())
            }
        }
    }
}

/// One scheduled inventory read.
///
/// Dispatch cannot cancel an `asyncAfter` closure already submitted to a queue.
/// Its generation therefore travels with the deadline so the closure can prove
/// it still owns the pending read before asking HAL anything.
struct DeviceChangeProbe: Sendable, Equatable {
    let deadline: UInt64
    fileprivate let generation: UInt64
}

/// Schedules device-list probes without allowing a noisy endpoint to poll HAL.
///
/// The first notification in a quiet period is delivered after 50 ms so one
/// physical plug event can publish all of its properties. Repeated unchanged
/// answers use a short 50/100/200/400 ms burst, then back off through
/// 1/2/4/8 seconds. A property read that causes its own notification can
/// otherwise keep coreaudiod and every device plug-in awake four times a second
/// for the lifetime of the application.
struct DeviceChangeSchedule: Sendable {
    private let initialDelay: UInt64
    private let burstMaximumDelay: UInt64
    private let stormInitialDelay: UInt64
    private let maximumDelay: UInt64
    private let quietReset: UInt64
    private var delay: UInt64
    private var lastCompletion: UInt64?
    private var lastSignal: UInt64?
    private var generation: UInt64 = 0
    private var pendingGeneration: UInt64?
    var diagnostics: DeviceChangeDiagnostics?

    init(
        initialDelay: UInt64 = 50_000_000,
        burstMaximumDelay: UInt64 = 400_000_000,
        stormInitialDelay: UInt64 = 1_000_000_000,
        maximumDelay: UInt64 = 8_000_000_000,
        quietReset: UInt64 = 500_000_000,
        diagnostics: DeviceChangeDiagnostics? = nil
    ) {
        precondition(initialDelay > 0)
        precondition(burstMaximumDelay >= initialDelay)
        precondition(stormInitialDelay > burstMaximumDelay)
        precondition(maximumDelay >= stormInitialDelay)
        precondition(quietReset >= initialDelay)
        self.initialDelay = initialDelay
        self.burstMaximumDelay = burstMaximumDelay
        self.stormInitialDelay = stormInitialDelay
        self.maximumDelay = maximumDelay
        self.quietReset = quietReset
        self.diagnostics = diagnostics
        delay = initialDelay
    }

    mutating func signal(
        at now: UInt64, recordsNotification: Bool = true
    ) -> DeviceChangeProbe? {
        if recordsNotification { diagnostics?.record(.notification) }
        let followsQuiet =
            lastSignal.map { now &- $0 >= quietReset }
            ?? false
        lastSignal = now

        if pendingGeneration != nil {
            // Continuous notifications merely coalesce into the existing read.
            // A notification after a quiet period is different: it may be a
            // real plug event that arrived while an unchanged storm probe was
            // waiting eight seconds. Replace that deadline with a 50 ms probe.
            guard followsQuiet else { return nil }
            delay = initialDelay
            return makeProbe(at: now)
        }

        // A self-notification follows the read that produced it, however long
        // that read was delayed. Measuring quiet from the previous signal made
        // every delay above 500 ms look like a new physical event and collapsed
        // the storm back to 50 ms. Completion is the causal boundary: an event
        // arriving long after the probe is new; one arriving immediately after
        // it is allowed to continue the backoff.
        if let lastCompletion, now &- lastCompletion >= quietReset {
            delay = initialDelay
        }
        return makeProbe(at: now)
    }

    /// Claims a deadline before its closure performs the HAL read.
    ///
    /// False means a quiet-period notification superseded this generation.
    /// The caller must return without invoking its handler or `complete`.
    mutating func beginProbe(_ probe: DeviceChangeProbe) -> Bool {
        guard pendingGeneration == probe.generation else {
            diagnostics?.record(.probeSuperseded)
            return false
        }
        pendingGeneration = nil
        return true
    }

    mutating func complete(inventoryChanged: Bool, at now: UInt64) {
        lastCompletion = now
        if inventoryChanged {
            delay = initialDelay
        } else if delay < burstMaximumDelay {
            delay = min(
                delay.multipliedReportingOverflow(by: 2).partialValue,
                burstMaximumDelay)
        } else if delay < stormInitialDelay {
            delay = stormInitialDelay
        } else {
            delay = min(delay.multipliedReportingOverflow(by: 2).partialValue, maximumDelay)
        }
    }

    private mutating func makeProbe(at now: UInt64) -> DeviceChangeProbe {
        generation &+= 1
        pendingGeneration = generation
        diagnostics?.record(.probe)
        return DeviceChangeProbe(
            deadline: now.addingReportingOverflow(delay).partialValue,
            generation: generation)
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
    private let diagnostics: DeviceChangeDiagnostics?

    init(
        initial: Set<AudioObjectID>?,
        read: @escaping @Sendable () -> Set<AudioObjectID>?,
        diagnostics: DeviceChangeDiagnostics? = nil
    ) {
        gate = DeviceInventoryGate(initial: initial)
        self.read = read
        self.diagnostics = diagnostics
    }

    func readChanged() -> Bool {
        diagnostics?.record(.halRead)
        return gate.shouldDeliver(read())
    }

    func establishBaseline(_ baseline: Set<AudioObjectID>) {
        gate.establishBaseline(baseline)
    }
}

/// Event counts for diagnosing a noisy HAL device-list publisher.
///
/// Nil in ordinary runs, so an idle watcher pays for neither locking nor
/// output. `YUNAUDIO_DEVICE_WATCH_TRACE=1` enables one stderr line per event;
/// there is no sampling timer, and silence in CoreAudio produces no work.
final class DeviceChangeDiagnostics: @unchecked Sendable {
    enum Event: String, Sendable {
        case notification
        case probe
        case probeSuperseded = "probe-superseded"
        case halRead = "hal-read"
    }

    struct Snapshot: Sendable, Equatable {
        var notifications = 0
        var probes = 0
        var superseded = 0
        var halReads = 0
    }

    private let lock = NSLock()
    private var counters = Snapshot()
    private let clock: @Sendable () -> UInt64
    private let sink: @Sendable (Event, UInt64, Snapshot) -> Void

    init(
        clock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        sink: @escaping @Sendable (Event, UInt64, Snapshot) -> Void
    ) {
        self.clock = clock
        self.sink = sink
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DeviceChangeDiagnostics? {
        guard environment["YUNAUDIO_DEVICE_WATCH_TRACE"] == "1" else { return nil }
        return DeviceChangeDiagnostics { event, now, snapshot in
            let line =
                "device-watch event=\(event.rawValue) uptime-ns=\(now)"
                + " notifications=\(snapshot.notifications)"
                + " probes=\(snapshot.probes)"
                + " superseded=\(snapshot.superseded)"
                + " hal-reads=\(snapshot.halReads)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    func record(_ event: Event) {
        let snapshot = lock.withLock {
            switch event {
            case .notification:
                counters.notifications += 1
            case .probe:
                counters.probes += 1
            case .probeSuperseded:
                counters.superseded += 1
            case .halRead:
                counters.halReads += 1
            }
            return counters
        }
        sink(event, clock(), snapshot)
    }

    var snapshot: Snapshot {
        lock.withLock { counters }
    }
}
