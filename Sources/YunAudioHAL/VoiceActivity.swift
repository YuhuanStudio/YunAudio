import CoreAudio
import Foundation

/// Whether a watcher may change CoreAudio's detector-enable property.
///
/// Observing is the safe default. `enableIfNeeded` is deliberately spelt out at
/// every call site because `vAd+` is device-global state: constructing an
/// object must not silently change it on behalf of an unrelated route.
public enum VoiceActivityActivationPolicy: Equatable, Sendable {
    case observeOnly
    case enableIfNeeded
}

/// The ownership state behind one detector activation.
///
/// CoreAudio itself is injected as two closures. Tests use a spy instead, so
/// the zero-write default and the exact restore count are proved without
/// touching the live HAL. Keeping the decision here also makes it impossible
/// for listener teardown and property ownership to drift into separate rules.
struct VoiceActivityEnableController {
    private enum Phase: Equatable {
        case idle
        case borrowed
        case owned
        case stopped
    }

    private var phase: Phase = .idle

    var isObserving: Bool {
        phase == .borrowed || phase == .owned
    }

    mutating func start(
        policy: VoiceActivityActivationPolicy,
        readEnabled: () -> Bool?,
        setEnabled: (Bool) -> Bool
    ) -> Bool {
        precondition(phase == .idle)
        guard let wasEnabled = readEnabled() else {
            phase = .stopped
            return false
        }
        if wasEnabled {
            // Somebody else owns the global switch. Observe it, but do not
            // claim it and therefore never turn it off later.
            phase = .borrowed
            return true
        }
        guard policy == .enableIfNeeded, setEnabled(true) else {
            phase = .stopped
            return false
        }
        phase = .owned
        return true
    }

    /// Claims the one restore write, if this activation owns it.
    ///
    /// The phase changes before the caller performs HAL work. A second stop —
    /// including `deinit` after an explicit stop — therefore cannot write the
    /// global property twice.
    mutating func takeRestore() -> Bool {
        guard phase != .stopped else { return false }
        let restores = phase == .owned
        phase = .stopped
        return restores
    }
}

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
    private let lifecycleLock = NSLock()
    private var block: AudioObjectPropertyListenerBlock?
    private var enableController = VoiceActivityEnableController()
    private var stopped = false

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
        enabledState(on: device) ?? false
    }

    /// The optional form used for ownership decisions.
    ///
    /// A failed read is not the same as off. Treating it as off and then
    /// writing one would lose the baseline required to restore the property.
    private static func enabledState(on device: AudioObjectID) -> Bool? {
        var address = address(enableSelector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard
            AudioObjectGetPropertyData(
                device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value != 0
    }

    private static func setEnabled(_ enabled: Bool, on device: AudioObjectID) -> Bool {
        var value: UInt32 = enabled ? 1 : 0
        var address = address(enableSelector)
        return
            AudioObjectSetPropertyData(
                device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            == noErr
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
            Self.suggestedReferenceDeviceSelector,
            scope: kAudioObjectPropertyScopeInput)
        return device.optionalString(of: property)
    }

    /// `kAudioDevicePropertySuggestedReferenceDevice`, written out.
    ///
    /// The header only declares it in the macOS 27 SDK, so naming it directly
    /// made the whole project refuse to build under the previous Xcode — which
    /// meant the one comparison that could settle where a crash was coming from
    /// could not be run at all. A four-character code is a number; the
    /// `#available` guard above is what actually decides whether the property
    /// is asked for, and that is a property of the running system rather than
    /// of whichever SDK happened to compile it.
    private static let suggestedReferenceDeviceSelector: AudioObjectPropertySelector =
        0x656f_7264  // 'eord'

    /// Observes detection and, only when explicitly allowed, switches it on.
    ///
    /// The callback arrives on a private queue, not the main thread, and it
    /// fires on *changes* — the header recommends listening rather than
    /// polling, and the reason is that the state moves at the rate of speech.
    ///
    /// - Returns: Nil when the device does not publish the detector.
    public init?(
        device: AudioObjectID,
        activation: VoiceActivityActivationPolicy,
        onCleanupFailure: @escaping @Sendable () -> Void = {},
        onChange: @escaping @Sendable (Bool) -> Void
    ) {
        guard Self.isAvailable(on: device) else { return nil }
        self.device = device

        guard
            enableController.start(
                policy: activation,
                readEnabled: { Self.enabledState(on: device) },
                setEnabled: { Self.setEnabled($0, on: device) })
        else { return nil }

        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            onChange(Self.state(of: device) ?? false)
        }
        var address = Self.address(Self.stateSelector)
        guard AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr
        else {
            if enableController.takeRestore() {
                if !Self.setEnabled(false, on: device) { onCleanupFailure() }
            }
            return nil
        }
        block = listener

        // The first answer, since a listener only reports changes and the
        // device may already be hearing somebody.
        onChange(Self.state(of: device) ?? false)
    }

    /// True after activation and before explicit cleanup.
    ///
    /// Cached rather than read from HAL: this property is presented by SwiftUI,
    /// and evaluating a view body must never synchronously query `coreaudiod`.
    public var isObserving: Bool {
        lifecycleLock.withLock { !stopped && enableController.isObserving }
    }

    /// Removes the listener and restores only the property this instance owns.
    ///
    /// Idempotent so normal route stop and application shutdown can both call
    /// it. `deinit` remains a last defence, not the normal lifecycle mechanism.
    ///
    /// - Returns: True when every requested HAL cleanup operation succeeded.
    @discardableResult
    public func stop() -> Bool {
        let cleanup: (AudioObjectPropertyListenerBlock?, Bool)? = lifecycleLock.withLock {
            guard !stopped else { return nil }
            stopped = true
            let listener = block
            block = nil
            return (listener, enableController.takeRestore())
        }
        guard let cleanup else { return true }

        var succeeded = true
        if let listener = cleanup.0 {
            var address = Self.address(Self.stateSelector)
            succeeded =
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
                == noErr
        }
        if cleanup.1 {
            succeeded = Self.setEnabled(false, on: device) && succeeded
        }
        return succeeded
    }

    deinit {
        stop()
    }
}
