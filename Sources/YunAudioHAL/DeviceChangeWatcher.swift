import CoreAudio
import Foundation

/// Watches the HAL for devices appearing and disappearing.
///
/// Everything the app persists is keyed on a device UID rather than an
/// `AudioObjectID`, because the numeric ID is reassigned on replug. This is the
/// signal that tells the app to go and re-resolve those UIDs.
public final class DeviceChangeWatcher {
    private var block: AudioObjectPropertyListenerBlock?
    private let queue: DispatchQueue
    private let coalescer: DeviceChangeCoalescer

    private static let deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    public init(onChange: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "com.yuhuanstudio.yunaudio.device-watch")
        self.queue = queue
        let inventory = DeviceInventoryGate(initial: Self.inventorySignature())
        coalescer = DeviceChangeCoalescer(queue: queue) {
            // Some audio plug-ins announce the device-list property after a
            // harmless property read. Re-enumerating complete devices in
            // response asks the same plug-in again and can create a permanent
            // notification loop. Only an inventory change reaches the model.
            guard inventory.shouldDeliver(Self.inventorySignature()) else { return }
            onChange()
        }

        let listener: AudioObjectPropertyListenerBlock = { [coalescer] _, _ in
            coalescer.signal()
        }
        block = listener

        var deviceList = Self.deviceListAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID.system, &deviceList, queue, listener)

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
    private let delay: DispatchTimeInterval
    private let handler: @Sendable () -> Void
    /// Accessed only on `queue`.
    private var isPending = false

    init(
        queue: DispatchQueue, delay: DispatchTimeInterval = .milliseconds(50),
        handler: @escaping @Sendable () -> Void
    ) {
        self.queue = queue
        self.delay = delay
        self.handler = handler
    }

    func signal() {
        queue.async { [weak self] in
            guard let self, !isPending else { return }
            isPending = true
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                isPending = false
                handler()
            }
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

    func shouldDeliver(_ candidate: Set<AudioObjectID>?) -> Bool {
        guard let candidate, candidate != current else { return false }
        current = candidate
        return true
    }
}
