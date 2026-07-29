import CoreAudio
import Foundation

/// Whether somebody is speaking, according to CoreAudio rather than to us.
///
/// The system has carried this since macOS 14 and nothing here used it. It is
/// two properties on an input device:
///
/// ```
/// kAudioDevicePropertyVoiceActivityDetectionEnable   'vAd+'
/// kAudioDevicePropertyVoiceActivityDetectionState    'vAdS'
/// ```
///
/// The header is worth quoting because it settles the two questions anybody
/// would ask about a detector: "Voice activity detection can be used with input
/// audio and has echo cancellation" and "Detection works when a process mute is
/// used, but not with hardware mute".
///
/// Both of those are things this application would otherwise have to build. The
/// echo cancellation matters because a detector without it says "somebody is
/// talking" when the speakers are playing somebody talking, which is exactly
/// when it is least useful. And surviving a process mute is the entire reason
/// the feature people actually want — *you are muted and you are speaking* —
/// can exist at all: a detector reading the routed signal sees silence, because
/// silence is what a mute produces.
///
/// It costs no model, no processor time on the audio path and no latency of our
/// own. The one honest caveat is in the header too: with input not running, or
/// detection disabled, the state reads 0 rather than "unknown". So a reading of
/// "not speaking" from a device nobody is recording from means nothing, and
/// this type reports that as `isObserving` rather than folding it into the
/// answer.
public final class VoiceActivityWatcher: @unchecked Sendable {

    public static let enableSelector: AudioObjectPropertySelector =
        kAudioDevicePropertyVoiceActivityDetectionEnable
    public static let stateSelector: AudioObjectPropertySelector =
        kAudioDevicePropertyVoiceActivityDetectionState

    private let device: AudioObjectID
    private let queue = DispatchQueue(label: "com.yuhuanstudio.yunaudio.voice-activity")
    private var block: AudioObjectPropertyListenerBlock?
    /// Whether this instance was the one that switched detection on, so that
    /// tearing it down leaves the device as it was found. Another application
    /// may be using the same detector on the same device, and turning it off
    /// underneath them would be taking away a feature they are relying on.
    private let didEnable: Bool

    /// Fresh each time rather than a shared mutable static: every CoreAudio
    /// call wants an `inout` address, and a `var` at file scope is shared
    /// mutable state that Swift 6 rightly refuses.
    ///
    /// **The scope is input.** Measured, after the global scope reported that
    /// not one device on this machine publishes the detector — not even the
    /// built-in microphone, which was the reading that made it worth checking
    /// rather than believing. On the input scope every one of ten devices
    /// publishes it and `vAd+` is settable on all of them. The header does not
    /// say which scope to ask on, and asking on the wrong one is indis-
    /// tinguishable from the feature being absent.
    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// True when this device publishes the detector at all.
    ///
    /// Asked rather than assumed by macOS version: an aggregate does not carry
    /// it, and neither does every piece of hardware. The interface has to be
    /// able to say "not on this device" rather than showing a light that never
    /// comes on.
    public static func isAvailable(on device: AudioObjectID) -> Bool {
        var address = address(enableSelector)
        return AudioObjectHasProperty(device, &address)
    }

    /// Whether detection is currently switched on for this device, by anybody.
    public static func isEnabled(on device: AudioObjectID) -> Bool {
        var address = address(enableSelector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard
            AudioObjectGetPropertyData(
                device, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    /// The current answer, without a watcher.
    ///
    /// - Returns: Nil when the device does not publish the property. Zero and
    ///   one are both real answers; nil means the question does not apply.
    public static func state(of device: AudioObjectID) -> Bool? {
        var address = address(stateSelector)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard
            AudioObjectGetPropertyData(
                device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value != 0
    }

    /// Which output the system would use as the echo-cancellation reference for
    /// this input, when it says.
    ///
    /// New in macOS 27, and the reason it is read here rather than guessed at:
    /// a detector with echo cancellation needs to know what the room is
    /// hearing, and until this property existed the only answer was "the system
    /// default output", which is wrong for anybody routing to something else —
    /// which is everybody using this application.
    ///
    /// - Returns: A device UID, or nil when the device does not publish one, in
    ///   which case the system uses the default output.
    public static func suggestedReferenceDeviceUID(for device: AudioObjectID) -> String? {
        guard #available(macOS 27, *) else { return nil }
        let property = AudioProperty<CFString>(
            kAudioDevicePropertySuggestedReferenceDevice,
            scope: kAudioObjectPropertyScopeInput)
        return device.optionalString(of: property)
    }

    /// Switches detection on and calls back whenever the answer changes.
    ///
    /// The callback arrives on a private queue, not the main thread, and it
    /// fires on *changes* — the header recommends listening rather than
    /// polling, and the reason is that the state moves at the rate of speech.
    ///
    /// - Returns: Nil when the device does not publish the detector.
    public init?(device: AudioObjectID, onChange: @escaping @Sendable (Bool) -> Void) {
        guard Self.isAvailable(on: device) else { return nil }
        self.device = device

        // Left alone if somebody else already has it on, so that tearing this
        // down does not take it away from them.
        let wasEnabled = Self.isEnabled(on: device)
        if wasEnabled {
            didEnable = false
        } else {
            var value: UInt32 = 1
            var address = Self.address(Self.enableSelector)
            didEnable =
                AudioObjectSetPropertyData(
                    device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
                == noErr
        }

        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            onChange(Self.state(of: device) ?? false)
        }
        block = listener
        var address = Self.address(Self.stateSelector)
        AudioObjectAddPropertyListenerBlock(device, &address, queue, listener)

        // The first answer, since a listener only reports changes and the
        // device may already be hearing somebody.
        onChange(Self.state(of: device) ?? false)
    }

    /// True while the detector is running on this device, which is what makes a
    /// reading of "not speaking" mean anything.
    public var isObserving: Bool { Self.isEnabled(on: device) }

    deinit {
        if let block {
            var address = Self.address(Self.stateSelector)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        // Only if we were the ones who switched it on.
        if didEnable {
            var value: UInt32 = 0
            var address = Self.address(Self.enableSelector)
            AudioObjectSetPropertyData(
                device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        }
    }
}
