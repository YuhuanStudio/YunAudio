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

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    public init(onChange: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "com.yuhuanstudio.yunaudio.device-watch")
        self.queue = queue
        coalescer = DeviceChangeCoalescer(queue: queue, handler: onChange)

        let listener: AudioObjectPropertyListenerBlock = { [coalescer] _, _ in
            coalescer.signal()
        }
        block = listener

        var deviceList = Self.deviceListAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID.system, &deviceList, queue, listener)

        var defaultInput = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID.system, &defaultInput, queue, listener)
    }

    deinit {
        guard let block else { return }
        var deviceList = Self.deviceListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID.system, &deviceList, queue, block)
        var defaultInput = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID.system, &defaultInput, queue, block)
    }
}

/// Turns one HAL change into one application refresh, however many properties
/// announce it.
///
/// Plugging in one device can change the device list and the default input in
/// the same HAL turn. Both listeners used to run a complete device enumeration
/// and route-recovery pass. This is a fixed window from the first event rather
/// than a debounce: a device that keeps producing notifications cannot postpone
/// recovery indefinitely.
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
