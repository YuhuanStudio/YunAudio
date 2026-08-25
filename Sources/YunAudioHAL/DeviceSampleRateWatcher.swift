import CoreAudio
import Foundation

/// Watches the devices in a live route for a sample rate that moves under it.
///
/// `DeviceChangeWatcher` listens to `kAudioHardwarePropertyDevices` — the
/// device *list*. It sees an endpoint appear or disappear and nothing else, so
/// a member whose format is changed by somebody else is invisible to it.
///
/// Bluetooth makes that gap audible. A headset is two Core Audio devices, and
/// opening the input one negotiates hands-free mode, which takes the output
/// down with it — this project's own notes for the Razer Barracuda record the
/// output moving between 44.1 kHz, 48 kHz and 16 kHz depending only on what the
/// link negotiated. Another application opening that microphone therefore
/// changes the format of a device already inside our aggregate, the device list
/// does not change, and nothing tells the route its destination is no longer
/// the device it was built for.
///
/// A route is built at one common rate across its members, so this is not a
/// detail: it is the route's central assumption being revoked from outside.
public final class DeviceSampleRateWatcher: @unchecked Sendable {

    /// One device's registration, kept so removal names the same block.
    ///
    /// Core Audio retains a listener block until it is removed with that same
    /// block, so the lifetime has to be represented rather than implied.
    private struct Registration {
        let device: AudioObjectID
        let block: AudioObjectPropertyListenerBlock
    }

    private static var rateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private let queue: DispatchQueue
    private let install: @Sendable (AudioObjectID, @escaping AudioObjectPropertyListenerBlock)
        -> Bool
    private let remove: @Sendable (AudioObjectID, @escaping AudioObjectPropertyListenerBlock)
        -> Void
    private let readRate: @Sendable (AudioObjectID) -> Double?
    private let onDrift: @Sendable (AudioObjectID, Double) -> Void

    private let lock = NSLock()
    private var registrations: [Registration] = []
    private var expectedRate: Double?
    /// Revokes callbacks already in flight when the route goes down. Core Audio
    /// can deliver one after the removal call returns, and a rebuild triggered
    /// by a route that no longer exists is a route nobody asked for.
    private var generation: UInt64 = 0

    public convenience init(onDrift: @escaping @Sendable (AudioObjectID, Double) -> Void) {
        let queue = DispatchQueue(label: "com.yuhuanstudio.yunaudio.member-rate-watch")
        self.init(
            queue: queue,
            install: { device, block in
                var address = Self.rateAddress
                return AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
                    == noErr
            },
            remove: { device, block in
                var address = Self.rateAddress
                _ = AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            },
            readRate: { device in
                device.optionalValue(of: .nominalSampleRate)
            },
            onDrift: onDrift)
    }

    init(
        queue: DispatchQueue,
        install: @escaping @Sendable (
            AudioObjectID, @escaping AudioObjectPropertyListenerBlock
        ) -> Bool,
        remove: @escaping @Sendable (
            AudioObjectID, @escaping AudioObjectPropertyListenerBlock
        ) -> Void,
        readRate: @escaping @Sendable (AudioObjectID) -> Double?,
        onDrift: @escaping @Sendable (AudioObjectID, Double) -> Void
    ) {
        self.queue = queue
        self.install = install
        self.remove = remove
        self.readRate = readRate
        self.onDrift = onDrift
    }

    /// Begins watching one route's members for departure from its common rate.
    ///
    /// Replaces any previous watch, so a restart cannot accumulate listeners
    /// against devices the new route does not use.
    public func watch(_ devices: [AudioObjectID], expecting rate: Double) {
        stop()
        guard rate > 0 else { return }
        let token = lock.withLock {
            expectedRate = rate
            generation &+= 1
            return generation
        }
        var installed: [Registration] = []
        for device in Set(devices) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.rateChanged(device, token: token)
            }
            guard install(device, block) else { continue }
            installed.append(Registration(device: device, block: block))
        }
        lock.withLock { registrations = installed }
    }

    /// Ends the watch. Safe to call when nothing is being watched.
    public func stop() {
        let (going, _): ([Registration], UInt64) = lock.withLock {
            let current = registrations
            registrations = []
            expectedRate = nil
            generation &+= 1
            return (current, generation)
        }
        for registration in going {
            remove(registration.device, registration.block)
        }
    }

    /// How many devices are being watched, for tests and diagnostics.
    public var watchedDeviceCount: Int { lock.withLock { registrations.count } }

    deinit { stop() }

    private func rateChanged(_ device: AudioObjectID, token: UInt64) {
        // Read before the generation check so a late callback costs one
        // property read rather than a route rebuild.
        guard let rate = readRate(device) else { return }
        let expected: Double? = lock.withLock {
            guard generation == token else { return nil }
            return expectedRate
        }
        guard let expected else { return }
        // Exact comparison is right here. These are the discrete rates a device
        // publishes, set by `AggregateDevice.alignSampleRate` to the very value
        // being compared against — not a measurement with error in it.
        guard rate != expected else { return }
        onDrift(device, rate)
    }
}
