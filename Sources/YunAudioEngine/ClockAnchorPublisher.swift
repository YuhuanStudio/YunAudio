import CoreAudio
import Foundation
import YunAudioHAL

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
public final class ClockAnchorPublisher {
    /// Custom selector implemented by YunAudioDriver.
    static let clockAnchorSelector: AudioObjectPropertySelector = 0x79_63_6C_6B  // 'yclk'

    public static let driverDeviceUID = "YunAudioDevice_UID"

    private let deviceID: AudioObjectID
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.yuhuanstudio.yunaudio.clock-anchor")

    /// Ten updates a second is plenty to track a crystal that is tens of parts
    /// per million out, and keeps the IPC cost invisible.
    private let interval: TimeInterval = 0.1

    public init?(driverDeviceUID: String = ClockAnchorPublisher.driverDeviceUID) {
        guard let device = try? AudioDevices.device(uid: driverDeviceUID) else { return nil }
        deviceID = device.id
    }

    /// True when the driver reports that it is following a published anchor.
    /// Read back from the driver rather than assumed, so the UI never claims a
    /// lock that did not take.
    public private(set) var isLocked = false

    /// Ratio of the measured master rate to its nominal rate. 1.000020 means
    /// the microphone's crystal runs twenty parts per million fast.
    public private(set) var rateRatio: Double = 1.0

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
    /// The handler must not call `stop()` directly — that drains this very
    /// queue and would deadlock. Hop to another queue first.
    public var onLockChanged: (@Sendable (Bool) -> Void)?

    public func start(anchorSource: @escaping @Sendable () -> ClockAnchor?) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let anchor = anchorSource() else { return }
            self.publish(anchor)
            self.refreshStatus()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        // cancel() does not wait for a handler that is already running, and the
        // caller is about to free the graph the handler reads. Draining the
        // serial queue guarantees no handler is in flight.
        queue.sync {}
        // The driver expires a stale anchor on its own after a couple of
        // seconds, so there is nothing to tear down on its side.
        isLocked = false
    }

    private func publish(_ anchor: ClockAnchor) {
        let payload: [String: Any] = [
            "sampleTime": anchor.sampleTime,
            // Host times stay exact in a double until roughly 285 years of
            // uptime, so the dictionary round trip is lossless.
            "hostTime": Double(anchor.hostTime),
            "sampleRate": anchor.sampleRate,
        ]
        var address = self.address
        var value = payload as CFPropertyList
        _ = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                deviceID, &address, 0, nil,
                UInt32(MemoryLayout<CFPropertyList>.size), UnsafeRawPointer(pointer))
        }
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
        let wasLocked = isLocked
        isLocked = (dictionary["following"] as? Double ?? 0) != 0
        rateRatio = dictionary["rateRatio"] as? Double ?? 1.0
        if wasLocked != isLocked { onLockChanged?(isLocked) }
    }
}

/// A (sample time, host time) pair from the clock master, plus the rate it
/// claims to be running at.
public struct ClockAnchor: Sendable {
    public let sampleTime: Double
    public let hostTime: UInt64
    public let sampleRate: Double

    public init(sampleTime: Double, hostTime: UInt64, sampleRate: Double) {
        self.sampleTime = sampleTime
        self.hostTime = hostTime
        self.sampleRate = sampleRate
    }
}
