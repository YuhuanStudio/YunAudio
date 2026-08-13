import CoreAudio
import Foundation
import YunAudioHAL

/// Result of fencing every clock-publication turn before releasing its source.
public enum ClockAnchorPublisherTeardownResult: Sendable, Equatable {
    case complete
    case timedOut

    public var isComplete: Bool { self == .complete }
}

/// Feeds the YunAudio virtual driver the clock of the device we are capturing.
///
/// The driver's `GetZeroTimeStamp` defines its sample clock. Left alone it runs
/// on the host clock, drifts against the microphone's crystal, and the HAL has
/// to drift-correct — which means resampling. Publishing the master's real
/// (sampleTime, hostTime) pairs lets the driver measure the microphone's actual
/// rate and match it, so the two devices advance together and no correction is
/// needed anywhere on the path.
///
/// The property set is the only channel that crosses coreaudiod's sandbox;
/// shared memory does not. It is cheap enough at this rate: the driver only
/// needs a slope, not per-cycle updates.
public final class ClockAnchorPublisher: @unchecked Sendable {
    /// One DispatchSource lifetime marker shared by every retry of a cancellation.
    private final class DrainFence: @unchecked Sendable {
        private let group = DispatchGroup()

        init() {
            group.enter()
        }

        func finish() {
            group.leave()
        }

        func wait(until deadline: HALTeardownDeadline) -> Bool {
            // Take the uptime before asking for the remaining interval. Adding
            // that later, smaller interval to this earlier instant cannot extend
            // the caller's absolute budget through conversion overhead.
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = deadline.remainingTimeInterval
            let requested: UInt64
            if !remaining.isFinite || remaining >= Double(UInt64.max) / 1_000_000_000 {
                requested = UInt64.max
            } else {
                requested = UInt64(max(0, remaining) * 1_000_000_000)
            }
            let timeout = DispatchTime(
                uptimeNanoseconds:
                    requested > UInt64.max - now ? UInt64.max : now + requested)
            return group.wait(timeout: timeout) == .success
        }
    }

    /// One coherent read of the two values the driver publishes together.
    public struct Telemetry: Sendable, Equatable {
        public let isLocked: Bool
        public let rateRatio: Double

        public init(isLocked: Bool, rateRatio: Double) {
            self.isLocked = isLocked
            self.rateRatio = rateRatio
        }
    }

    /// Custom selector implemented by YunAudioDriver.
    static let clockAnchorSelector: AudioObjectPropertySelector = 0x79_63_6C_6B  // 'yclk'

    public static let driverDeviceUID = "YunAudioDevice_UID"

    private let deviceID: AudioObjectID
    /// Start and Stop are public, so their external caller cannot be assumed to
    /// be the engine's serial queue. The timer turn itself is drained before
    /// either field changes.
    private let lifecycleLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var timerDrain: DrainFence?
    private var pendingDrain: DrainFence?
    private let queue = DispatchQueue(label: "com.yuhuanstudio.yunaudio.clock-anchor")

    /// Ten updates a second is plenty to track a crystal that is tens of parts
    /// per million out, and keeps the IPC cost invisible.
    private let interval: TimeInterval
    /// Publishing is the clock lock. Reading its status is only telemetry, and
    /// the crystal cannot change meaningfully at the publication rate.
    private static let statusRefreshStride = 5
    private var publicationTick = 0
    /// The timer writes these while the interface and engine teardown read them.
    ///
    /// Protecting the publisher reference in `RoutingEngine` is not enough:
    /// once retained, its two fields still cross this queue boundary. One lock
    /// makes the lock bit and its measured ratio a single publishable fact.
    private let telemetryLock = NSLock()
    private var storedTelemetry = Telemetry(isLocked: false, rateRatio: 1)
    private var storedOnLockChanged: (@Sendable (Bool) -> Void)?

    public init?(driverDeviceUID: String = ClockAnchorPublisher.driverDeviceUID) {
        guard let device = try? AudioDevices.device(uid: driverDeviceUID) else { return nil }
        deviceID = device.id
        interval = 0.1
    }

    /// Builds only the synchronisation boundary, without asking HAL for a device.
    init(deviceIDForTesting: AudioObjectID, intervalForTesting: TimeInterval = 0.1) {
        deviceID = deviceIDForTesting
        interval = intervalForTesting
    }

    /// Publishes a synthetic pair without touching the driver.
    func installTelemetryForTesting(_ telemetry: Telemetry) {
        telemetryLock.withLock { storedTelemetry = telemetry }
    }

    /// Ownership evidence for deadline and retry tests.
    var hasRetainedTimerForTesting: Bool {
        lifecycleLock.withLock { timer != nil }
    }

    /// Whether a timed-out cancellation still has one reusable source fence.
    var hasPendingDrainForTesting: Bool {
        lifecycleLock.withLock { pendingDrain != nil }
    }

    /// True when the driver reports that it is following a published anchor.
    /// Read back from the driver rather than assumed, so the UI never claims a
    /// lock that did not take.
    public var isLocked: Bool { telemetry.isLocked }

    /// Ratio of the measured master rate to its nominal rate. 1.000020 means
    /// the microphone's crystal runs twenty parts per million fast.
    public var rateRatio: Double { telemetry.rateRatio }

    /// Lock state and rate from the same driver status response.
    public var telemetry: Telemetry {
        telemetryLock.withLock { storedTelemetry }
    }

    private var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: Self.clockAnchorSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// True when the installed driver understands the clock anchor property.
    public var driverSupportsClockLocking: Bool {
        var address = self.address
        return AudioObjectHasProperty(deviceID, &address)
    }

    /// Called on the publisher's queue whenever the driver's lock state flips.
    /// The handler must not call `stop()` directly — its own turn is ahead of the
    /// drain fence, so it would consume the whole deadline and fail. Hop to
    /// another queue first.
    public var onLockChanged: (@Sendable (Bool) -> Void)? {
        get { telemetryLock.withLock { storedOnLockChanged } }
        set { telemetryLock.withLock { storedOnLockChanged = newValue } }
    }

    @discardableResult
    public func start(anchorSource: @escaping @Sendable () -> ClockAnchor?) -> Bool {
        guard stop(until: HALTeardownDeadline(timeout: 2)).isComplete else { return false }
        lifecycleLock.lock()
        guard timer == nil, timerDrain == nil, pendingDrain == nil else {
            lifecycleLock.unlock()
            return false
        }
        publicationTick = 0
        let drain = DrainFence()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let anchor = anchorSource() else { return }
            guard self.publish(anchor) else { return }
            self.publicationTick &+= 1
            // The first read stays at 100 ms so lock acquisition is reported
            // promptly. Thereafter two reads a second are enough for UI
            // telemetry, reducing CoreAudio property IPC from 20 calls/s
            // (10 writes + 10 reads) to 12 without slowing the clock feed.
            if Self.shouldRefreshStatus(afterPublication: self.publicationTick) {
                self.refreshStatus()
            }
        }
        // A DispatchSource submits its cancellation handler only after every
        // submitted event handler has returned. Installing this before resume
        // makes it the source's formal lifetime fence, including an event turn
        // which was already running when Stop cancelled the timer.
        timer.setCancelHandler { drain.finish() }
        self.timer = timer
        timerDrain = drain
        timer.resume()
        lifecycleLock.unlock()
        return true
    }

    @discardableResult
    public func stop() -> ClockAnchorPublisherTeardownResult {
        stop(until: HALTeardownDeadline(timeout: 2))
    }

    /// Cancels publication and waits only within the route's shared deadline.
    ///
    /// A timeout keeps both the cancelled timer and the fence. The timer owns the
    /// closure which reads `sharedClock`; clearing it before the fence would turn
    /// a bounded Stop into a use-after-free. A retry waits on the same marker and
    /// clears ownership only after every earlier queue turn has returned.
    @discardableResult
    public func stop(
        until deadline: HALTeardownDeadline
    ) -> ClockAnchorPublisherTeardownResult {
        let fence: DrainFence? = lifecycleLock.withLock {
            if let pendingDrain { return pendingDrain }
            guard let timer, let timerDrain else { return nil }
            // Publish the fence before Cancel: an idle source is allowed to run
            // its cancellation handler immediately on the target queue.
            pendingDrain = timerDrain
            timer.cancel()
            return timerDrain
        }

        guard let fence else {
            telemetryLock.withLock {
                storedTelemetry = Telemetry(
                    isLocked: false, rateRatio: storedTelemetry.rateRatio)
            }
            return .complete
        }

        guard fence.wait(until: deadline) else { return .timedOut }

        lifecycleLock.withLock {
            // Another waiter may already have completed this cancellation and a
            // concurrent Start may own a new timer. Only the waiter which still
            // owns this exact fence may clear lifecycle state.
            guard pendingDrain === fence else { return }
            timer = nil
            timerDrain = nil
            pendingDrain = nil
            // The driver expires a stale anchor on its own after a couple of
            // seconds, so there is nothing to tear down on its side.
            telemetryLock.withLock {
                storedTelemetry = Telemetry(
                    isLocked: false, rateRatio: storedTelemetry.rateRatio)
            }
        }
        return .complete
    }

    @discardableResult
    private func publish(_ anchor: ClockAnchor) -> Bool {
        guard anchor.isValid, let hostTime = Self.hostTimePropertyNumber(anchor.hostTime)
        else { return false }
        let payload: [String: Any] = [
            "sampleTime": anchor.sampleTime,
            // Keep the host tick integer all the way across Core Audio. On an
            // Apple Silicon nanosecond timebase, Double stops being exact after
            // about 104 days; SInt64 remains exact for roughly 292 years.
            "hostTime": hostTime,
            "sampleRate": anchor.sampleRate,
        ]
        var address = self.address
        var value = payload as CFPropertyList
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                deviceID, &address, 0, nil,
                UInt32(MemoryLayout<CFPropertyList>.size), UnsafeRawPointer(pointer))
        }
        return status == noErr
    }

    /// The clock-anchor property-list schema stores host ticks as signed 64-bit.
    /// Core Foundation has no unsigned number type, so values beyond this bound
    /// have no exact representation in the channel the driver receives.
    static func hostTimePropertyNumber(_ hostTime: UInt64) -> CFNumber? {
        guard hostTime <= UInt64(Int64.max) else { return nil }
        var signed = Int64(hostTime)
        return CFNumberCreate(nil, .sInt64Type, &signed)
    }

    private func refreshStatus() {
        var address = self.address
        var size = UInt32(MemoryLayout<CFPropertyList?>.size)
        var unmanaged: Unmanaged<CFDictionary>?
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let dictionary = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return }
        let telemetry = Telemetry(
            isLocked: (dictionary["following"] as? Double ?? 0) != 0,
            rateRatio: dictionary["rateRatio"] as? Double ?? 1)
        let handler: (@Sendable (Bool) -> Void)? = telemetryLock.withLock {
            let changed = storedTelemetry.isLocked != telemetry.isLocked
            storedTelemetry = telemetry
            return changed ? storedOnLockChanged : nil
        }
        // Never call an arbitrary handler while holding the publisher lock.
        // Teardown clears it and drains this queue; invoking outside prevents a
        // handler which inspects telemetry from deadlocking that drain.
        handler?(telemetry.isLocked)
    }

    /// The telemetry cadence, separate from the timer so the resource contract
    /// can be asserted without a real driver.
    static func shouldRefreshStatus(afterPublication tick: Int) -> Bool {
        tick > 0 && (tick - 1) % statusRefreshStride == 0
    }
}

/// A (sample time, host time) pair from the clock master, plus the rate it
/// claims to be running at.
public struct ClockAnchor: Sendable {
    static let maximumExactlyRepresentableHostTime = UInt64(Int64.max)

    public let sampleTime: Double
    public let hostTime: UInt64
    public let sampleRate: Double

    public init(sampleTime: Double, hostTime: UInt64, sampleRate: Double) {
        self.sampleTime = sampleTime
        self.hostTime = hostTime
        self.sampleRate = sampleRate
    }

    /// True when the complete property-list payload is finite and lossless.
    /// Host time crosses Core Audio as an exact signed 64-bit CFNumber.
    public var isValid: Bool {
        sampleTime.isFinite
            && hostTime <= Self.maximumExactlyRepresentableHostTime
            && AudioProcessingContract.supports(sampleRate: sampleRate)
    }
}
