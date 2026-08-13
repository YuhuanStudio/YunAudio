import CoreAudio
import Foundation

/// Watches the HAL for devices appearing and disappearing.
///
/// Everything the app persists is keyed on a device UID rather than an
/// `AudioObjectID`, because the numeric ID is reassigned on replug. This is the
/// signal that tells the app to go and re-resolve those UIDs.
public final class DeviceChangeWatcher: @unchecked Sendable {
    private let queue: DispatchQueue
    private let coalescer: DeviceChangeCoalescer
    private let inventory: DeviceInventoryProbe
    private let lifecycle: DeviceChangeWatcherLifecycle
    private let onChange: @Sendable () -> Void

    private static let deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    public convenience init(onChange: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "com.yuhuanstudio.yunaudio.device-watch")
        self.init(
            queue: queue,
            initialInventory: nil,
            inventoryRead: Self.inventorySignature,
            installListener: { registration in
                var deviceList = Self.deviceListAddress
                return AudioObjectAddPropertyListenerBlock(
                    AudioObjectID.system, &deviceList, queue, registration.block) == noErr
            },
            removeListener: { registration in
                var deviceList = Self.deviceListAddress
                _ = AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID.system, &deviceList, queue, registration.block)
            },
            diagnostics: DeviceChangeDiagnostics.fromEnvironment(),
            onChange: onChange)
    }

    init(
        queue: DispatchQueue,
        schedule: DeviceChangeSchedule = DeviceChangeSchedule(),
        initialInventory: Set<AudioObjectID>?,
        inventoryRead: @escaping @Sendable () -> Set<AudioObjectID>?,
        installListener: @escaping @Sendable (DeviceChangeListenerRegistration) -> Bool,
        removeListener: @escaping @Sendable (DeviceChangeListenerRegistration) -> Void,
        diagnostics: DeviceChangeDiagnostics? = nil,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.queue = queue
        self.onChange = onChange
        let lifecycle = DeviceChangeWatcherLifecycle(
            queue: queue, removeListener: removeListener)
        self.lifecycle = lifecycle
        let inventory = DeviceInventoryProbe(
            // Construction happens before the application's first frame. A
            // baseline read here blocked MainActor on coreaudiod even though
            // there had not been a device-change notification to answer.
            // Starting unknown keeps construction read-free: the probe reads
            // only when a notification has already said something changed, and
            // it does that on this watcher's own queue.
            initial: initialInventory,
            read: inventoryRead,
            diagnostics: diagnostics)
        self.inventory = inventory
        let coalescer = DeviceChangeCoalescer(
            queue: queue, schedule: schedule, diagnostics: diagnostics
        ) {
            // Some audio plug-ins announce the device-list property after a
            // harmless property read. Re-enumerating complete devices in
            // response asks the same plug-in again and can create a permanent
            // notification loop. An unchanged answer increases the probe
            // interval, while an actual inventory change restores the 50 ms
            // response for the next physical device event.
            inventory.readChanged()
        }
        self.coalescer = coalescer

        let listener: AudioObjectPropertyListenerBlock = {
            [weak lifecycle, weak coalescer] _, _ in
            guard let lifecycle, let token = lifecycle.admitNotification() else { return }
            // The generation is checked once before a queued probe enters HAL
            // and again before a changed inventory is published. Suspension is
            // therefore O(1): callbacks which were already queued do no HAL
            // work, while an entered system-object read may finish only on this
            // same serial owner and its late answer is discarded.
            coalescer?.signal(
                isCurrent: { [weak lifecycle] in
                    lifecycle?.accepts(token) == true
                },
                publish: onChange)
        }
        lifecycle.install(DeviceChangeListenerRegistration(listener), using: installListener)
    }

    /// Supplies the ID set already read by RouterModel's launch inventory.
    ///
    /// An optimisation rather than a requirement: it saves the probe the one
    /// HAL read it would otherwise perform to baseline itself, and it makes
    /// that baseline the same snapshot the interface is showing. Calling it is
    /// still worth doing on every path that constructs a watcher — a probe
    /// that baselines itself absorbs whichever change was being announced.
    public func establishBaseline(_ ids: Set<AudioObjectID>) {
        guard let token = lifecycle.admitOperation() else { return }
        queue.async { [weak self] in
            guard let self, lifecycle.accepts(token) else { return }
            inventory.establishBaseline(ids)
        }
    }

    /// Revokes queued probes and publications without removing the listener.
    ///
    /// AppKit can refuse Quit after an audio owner times out. Keeping this
    /// listener installed lets that same live process resume observation
    /// without constructing a peer beside a possibly blocked Core Audio call.
    @discardableResult
    public func suspend() -> Bool {
        guard lifecycle.suspend() else { return false }
        coalescer.invalidate()
        return true
    }

    /// Reopens the same listener owner after AppKit refuses termination.
    ///
    /// Any read which entered before suspension remains ahead of the resumed
    /// generation on the sole serial queue. This method never installs another
    /// listener and never joins that queue.
    @discardableResult
    public func resume() -> Bool {
        guard let token = lifecycle.beginResume() else { return false }
        queue.async { [weak self] in
            guard let self, self.lifecycle.activateResume(token) else { return }
            // Notifications received while suspended were deliberately ignored.
            // Reconcile once after the old generation has left this sole queue.
            // This direct probe must not pass back through `coalescer.signal`:
            // invalidation's queued schedule reset could otherwise erase the
            // new generation's pending deadline before it enters HAL.
            _ = inventory.readChanged()
            if lifecycle.accepts(token) { onChange() }
        }
        return true
    }

    /// Permanently closes admission and removes the listener on its owner queue.
    ///
    /// Removal is scheduled exactly once and this call never waits for a HAL
    /// read which already entered. Use only after process termination has been
    /// accepted; a refused attempt must call `resume()` instead.
    @discardableResult
    public func shutdown() -> Bool {
        guard lifecycle.shutdown() else { return false }
        coalescer.invalidate()
        return true
    }

    deinit {
        shutdown()
    }

    private static func inventorySignature() -> Set<AudioObjectID>? {
        try? Set(
            AudioObjectID.system.array(
                of: .devices, maximumCount: HALSemanticArrayPolicy.maximumDevices))
    }
}

/// Gives injected installation operations an owned block rather than a
/// nonescaping closure parameter. Core Audio retains the block until removal;
/// representing that lifetime explicitly avoids lying to Swift's closure model.
final class DeviceChangeListenerRegistration: @unchecked Sendable {
    let block: AudioObjectPropertyListenerBlock

    init(_ block: @escaping AudioObjectPropertyListenerBlock) {
        self.block = block
    }
}

/// Generation admission and exact-once ownership of the HAL listener block.
///
/// The lock protects only scalar state and a block reference. No Core Audio
/// operation runs under it: listener removal belongs to the watcher's serial
/// queue, so releasing a watcher on MainActor cannot inherit a coreaudiod stall.
private final class DeviceChangeWatcherLifecycle: @unchecked Sendable {
    fileprivate struct Token: Sendable {
        let generation: UInt64
    }

    private enum Phase: Equatable {
        case active
        case suspended
        case resuming
        case shutDown
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let removeListener: @Sendable (DeviceChangeListenerRegistration) -> Void
    private var phase = Phase.active
    private var generation: UInt64 = 1
    private var listener: DeviceChangeListenerRegistration?
    private var removalWasScheduled = false

    init(
        queue: DispatchQueue,
        removeListener: @escaping @Sendable (DeviceChangeListenerRegistration) -> Void
    ) {
        self.queue = queue
        self.removeListener = removeListener
    }

    func install(
        _ listener: DeviceChangeListenerRegistration,
        using installListener: @Sendable (DeviceChangeListenerRegistration) -> Bool
    ) {
        guard installListener(listener) else { return }
        lock.withLock { self.listener = listener }
    }

    func admitNotification() -> Token? {
        admitOperation()
    }

    func admitOperation() -> Token? {
        lock.withLock {
            guard phase == .active else { return nil }
            return Token(generation: generation)
        }
    }

    func accepts(_ token: Token) -> Bool {
        lock.withLock {
            phase == .active && generation == token.generation
        }
    }

    func suspend() -> Bool {
        lock.withLock {
            guard phase == .active || phase == .resuming else { return false }
            phase = .suspended
            advanceGeneration()
            return true
        }
    }

    func beginResume() -> Token? {
        lock.withLock {
            guard phase == .suspended else { return nil }
            // Stay closed until the serial queue reaches the activation edge.
            // Core Audio callbacks submitted while suspended can themselves be
            // waiting on this queue; opening here would misclassify them as new.
            phase = .resuming
            advanceGeneration()
            return Token(generation: generation)
        }
    }

    func activateResume(_ token: Token) -> Bool {
        lock.withLock {
            guard phase == .resuming, generation == token.generation else { return false }
            phase = .active
            return true
        }
    }

    func shutdown() -> Bool {
        let result: (changed: Bool, schedulesRemoval: Bool) = lock.withLock {
            guard phase != .shutDown else { return (false, false) }
            phase = .shutDown
            advanceGeneration()
            guard listener != nil, !removalWasScheduled else { return (true, false) }
            removalWasScheduled = true
            return (true, true)
        }
        if result.schedulesRemoval {
            queue.async { [self] in removeInstalledListener() }
        }
        return result.changed
    }

    private func removeInstalledListener() {
        let installed = lock.withLock {
            let installed = listener
            listener = nil
            return installed
        }
        if let installed { removeListener(installed) }
    }

    private func advanceGeneration() {
        generation &+= 1
        if generation == 0 { generation = 1 }
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
        signal(recordsNotification: recordsNotification, isCurrent: { true }, publish: {})
    }

    func signal(
        recordsNotification: Bool = true,
        isCurrent: @escaping @Sendable () -> Bool,
        publish: @escaping @Sendable () -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard isCurrent() else { return }
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
                guard isCurrent() else { return }
                let changed = handler()
                let mayPublish = isCurrent()
                schedule.complete(inventoryChanged: changed && mayPublish, at: clock())
                if changed, mayPublish { publish() }
            }
        }
    }

    /// Invalidates an already-submitted deadline without joining the queue.
    func invalidate() {
        queue.async { [weak self] in
            self?.schedule.invalidate()
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

    /// Makes every submitted `asyncAfter` token stale and resets its backoff.
    mutating func invalidate() {
        generation &+= 1
        if generation == 0 { generation = 1 }
        pendingGeneration = nil
        delay = initialDelay
        lastCompletion = nil
        lastSignal = nil
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
    /// Accessed only on the watcher's serial queue.
    private var hasBaseline: Bool

    init(
        initial: Set<AudioObjectID>?,
        read: @escaping @Sendable () -> Set<AudioObjectID>?,
        diagnostics: DeviceChangeDiagnostics? = nil
    ) {
        gate = DeviceInventoryGate(initial: initial)
        hasBaseline = initial != nil
        self.read = read
        self.diagnostics = diagnostics
    }

    func readChanged() -> Bool {
        diagnostics?.record(.halRead)
        let candidate = read()
        let changed = gate.shouldDeliver(candidate)
        guard hasBaseline else {
            // The first answer has nothing to be a change *from*, so it is
            // adopted rather than announced: reporting it would mean a second
            // whole-machine enumeration beside the launch inventory, every
            // launch. Only a read that actually returned something counts —
            // a transient failure must not leave this permanently baselined
            // on nothing.
            //
            // This is why the watcher no longer needs a baseline to be given
            // to it before it will listen. It used to, and a caller that never
            // supplied one got a watcher that noticed nothing for the lifetime
            // of the process and said nothing about it.
            hasBaseline = candidate != nil
            return false
        }
        return changed
    }

    func establishBaseline(_ baseline: Set<AudioObjectID>) {
        gate.establishBaseline(baseline)
        hasBaseline = true
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
