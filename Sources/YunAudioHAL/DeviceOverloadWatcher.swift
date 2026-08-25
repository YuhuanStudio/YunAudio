import CoreAudio
import Foundation

/// Records the moments Core Audio says an IOProc missed its deadline.
///
/// `kAudioDeviceProcessorOverload` is the HAL's own name for a dropout. The
/// device posts it when the callback did not finish before the buffer it was
/// filling had to go out, which is precisely the click or gap somebody hears.
/// Nothing in this project was listening for it, so every report of "it still
/// drops sometimes" arrived without a single number attached and had to be
/// argued about from memory.
///
/// What the notification carries is *that* it happened and on which device —
/// no payload, no reason. That is still the difference between an anecdote and
/// an event with a time on it: whatever else is being recorded at that instant
/// (the negotiated rate, the buffer size, the call-quality flag) becomes
/// evidence once there is a timestamp to line it up against.
///
/// Members and the aggregate are watched separately and counted separately,
/// because "the Bluetooth output overran" and "the aggregate overran" are
/// different diagnoses with different fixes.
public final class DeviceOverloadWatcher: @unchecked Sendable {

    /// One overload, as it was seen.
    public struct Event: Sendable, Equatable {
        /// The device that posted it.
        public let device: AudioObjectID
        /// Monotonic seconds, from the clock this watcher was given.
        public let at: Double

        public init(device: AudioObjectID, at: Double) {
            self.device = device
            self.at = at
        }
    }

    /// One device's registration, kept so removal names the same block.
    ///
    /// Core Audio retains a listener block until it is removed with that same
    /// block, so the lifetime has to be represented rather than implied.
    private struct Registration {
        let device: AudioObjectID
        let block: AudioObjectPropertyListenerBlock
    }

    /// The most recent events kept. A route that is failing continuously can
    /// post these faster than anybody reads them, and an unbounded log would
    /// turn a dropout into a memory problem. The count is never discarded — it
    /// is the total that matters, and the ring only bounds the detail.
    public static let recentEventLimit = 256

    private static var overloadAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private let queue: DispatchQueue
    private let install:
        @Sendable (AudioObjectID, @escaping AudioObjectPropertyListenerBlock)
            -> Bool
    private let remove:
        @Sendable (AudioObjectID, @escaping AudioObjectPropertyListenerBlock)
            -> Void
    private let now: @Sendable () -> Double
    private let onOverload: @Sendable (Event) -> Void

    private let lock = NSLock()
    private var registrations: [Registration] = []
    private var counts: [AudioObjectID: Int] = [:]
    private var events: [Event] = []
    private var total = 0
    /// Revokes callbacks already in flight when the route goes down. Core Audio
    /// can deliver one after the removal call returns, and an overload counted
    /// against a route that no longer exists is a dropout nobody heard.
    private var generation: UInt64 = 0

    public convenience init(onOverload: @escaping @Sendable (Event) -> Void = { _ in }) {
        let queue = DispatchQueue(label: "com.yuhuanstudio.yunaudio.overload-watch")
        self.init(
            queue: queue,
            install: { device, block in
                var address = Self.overloadAddress
                return AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
                    == noErr
            },
            remove: { device, block in
                var address = Self.overloadAddress
                _ = AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            },
            now: {
                Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
            },
            onOverload: onOverload)
    }

    init(
        queue: DispatchQueue,
        install:
            @escaping @Sendable (
                AudioObjectID, @escaping AudioObjectPropertyListenerBlock
            ) -> Bool,
        remove:
            @escaping @Sendable (
                AudioObjectID, @escaping AudioObjectPropertyListenerBlock
            ) -> Void,
        now: @escaping @Sendable () -> Double,
        onOverload: @escaping @Sendable (Event) -> Void
    ) {
        self.queue = queue
        self.install = install
        self.remove = remove
        self.now = now
        self.onOverload = onOverload
    }

    /// Begins watching one route's devices for missed deadlines.
    ///
    /// Replaces any previous watch, so a restart cannot accumulate listeners
    /// against devices the new route does not use. The tally is *not* cleared:
    /// a route that has to restart to recover is itself a symptom, and zeroing
    /// the count at each restart would hide exactly the case worth seeing.
    public func watch(_ devices: [AudioObjectID]) {
        stop()
        let token = lock.withLock {
            generation &+= 1
            return generation
        }
        var installed: [Registration] = []
        for device in Set(devices) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.overloaded(device, token: token)
            }
            guard install(device, block) else { continue }
            installed.append(Registration(device: device, block: block))
        }
        lock.withLock { registrations = installed }
    }

    /// Ends the watch. Safe to call when nothing is being watched.
    public func stop() {
        let going: [Registration] = lock.withLock {
            let current = registrations
            registrations = []
            generation &+= 1
            return current
        }
        for registration in going {
            remove(registration.device, registration.block)
        }
    }

    /// Forgets every recorded overload. For a deliberate fresh measurement —
    /// teardown does not call it, on purpose.
    public func reset() {
        lock.withLock {
            counts = [:]
            events = []
            total = 0
        }
    }

    /// How many devices are being watched, for tests and diagnostics.
    public var watchedDeviceCount: Int { lock.withLock { registrations.count } }

    /// Every overload seen since the last `reset()`, across every watch.
    public var overloadCount: Int { lock.withLock { total } }

    /// The tally per device, so a member and the aggregate stay distinguishable.
    public var overloadsByDevice: [AudioObjectID: Int] { lock.withLock { counts } }

    /// The most recent events, oldest first, bounded by `recentEventLimit`.
    public var recentEvents: [Event] { lock.withLock { events } }

    /// When the last overload was seen, on the injected clock, or nil for none.
    public var lastOverloadAt: Double? { lock.withLock { events.last?.at } }

    deinit { stop() }

    private func overloaded(_ device: AudioObjectID, token: UInt64) {
        let at = now()
        let event: Event? = lock.withLock {
            guard generation == token else { return nil }
            let event = Event(device: device, at: at)
            total += 1
            counts[device, default: 0] += 1
            events.append(event)
            if events.count > Self.recentEventLimit {
                events.removeFirst(events.count - Self.recentEventLimit)
            }
            return event
        }
        guard let event else { return }
        onOverload(event)
    }
}
