import CoreAudio
import Foundation

/// Watches the HAL for devices appearing and disappearing.
///
/// Everything the app persists is keyed on a device UID rather than an
/// `AudioObjectID`, because the numeric ID is reassigned on replug. This is the
/// signal that tells the app to go and re-resolve those UIDs.
public final class DeviceChangeWatcher {
    private let handler: @Sendable () -> Void
    private var block: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "com.yuhuanstudio.yunaudio.device-watch")

    private static let deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    public init(onChange: @escaping @Sendable () -> Void) {
        handler = onChange

        let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
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
