import AppKit
import Carbon.HIToolbox
import YunDesign

/// Global keyboard shortcuts.
///
/// Uses Carbon's `RegisterEventHotKey` rather than
/// `NSEvent.addGlobalMonitorForEvents`. The monitor approach needs Input
/// Monitoring permission — it can see every keystroke in every application,
/// which is a privacy grant far beyond what a mute button warrants. Registered
/// hot keys are handed to the app by the window server only when the exact
/// combination fires, so they need no permission at all.
@MainActor
final class HotkeyManager {
    enum Action: String, CaseIterable, Codable, Sendable {
        case toggleRouting
        case toggleMute

        var title: String {
            switch self {
            case .toggleRouting: loc("Start / stop routing")
            case .toggleMute: loc("Mute / unmute")
            }
        }

        /// Defaults chosen to avoid anything the system or common apps claim.
        /// Control-Option is largely unused territory.
        var defaultShortcut: Shortcut { candidateShortcuts[0] }

        /// Combinations to try, in order.
        ///
        /// One default was not enough: on this machine both of the originals
        /// were already owned by something else, so the preferences page showed
        /// two failures and offered no way to change them — a feature that
        /// cannot be used and cannot be fixed. Falling through to the next
        /// combination turns that into a shortcut that works, and the page says
        /// which one it got.
        var candidateShortcuts: [Shortcut] {
            switch self {
            case .toggleRouting:
                [
                    Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: [.control, .option]),
                    Shortcut(
                        keyCode: UInt32(kVK_ANSI_R),
                        modifiers: [.control, .option, .shift]),
                    Shortcut(
                        keyCode: UInt32(kVK_ANSI_Y), modifiers: [.control, .option]),
                    Shortcut(
                        keyCode: UInt32(kVK_F13), modifiers: [.control, .option]),
                ]
            case .toggleMute:
                [
                    Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: [.control, .option]),
                    Shortcut(
                        keyCode: UInt32(kVK_ANSI_M),
                        modifiers: [.control, .option, .shift]),
                    Shortcut(
                        keyCode: UInt32(kVK_ANSI_U), modifiers: [.control, .option]),
                    Shortcut(
                        keyCode: UInt32(kVK_F14), modifiers: [.control, .option]),
                ]
            }
        }
    }

    struct Shortcut: Codable, Equatable, Sendable {
        var keyCode: UInt32
        var modifiers: Modifiers

        struct Modifiers: OptionSet, Codable, Sendable {
            let rawValue: UInt32
            static let command = Modifiers(rawValue: 1 << 0)
            static let option = Modifiers(rawValue: 1 << 1)
            static let control = Modifiers(rawValue: 1 << 2)
            static let shift = Modifiers(rawValue: 1 << 3)

            /// Carbon uses its own modifier bits, not the Cocoa ones.
            var carbonValue: UInt32 {
                var value: UInt32 = 0
                if contains(.command) { value |= UInt32(cmdKey) }
                if contains(.option) { value |= UInt32(optionKey) }
                if contains(.control) { value |= UInt32(controlKey) }
                if contains(.shift) { value |= UInt32(shiftKey) }
                return value
            }

            var symbols: String {
                var result = ""
                if contains(.control) { result += "⌃" }
                if contains(.option) { result += "⌥" }
                if contains(.shift) { result += "⇧" }
                if contains(.command) { result += "⌘" }
                return result
            }
        }

        var displayName: String {
            modifiers.symbols + (Shortcut.keyName(for: keyCode) ?? "?")
        }

        /// Names for keys that produce no printable character.
        ///
        /// Deliberately not a range over `kVK_ANSI_A...kVK_ANSI_Z`: virtual key
        /// codes are positions on a QWERTY keyboard, not an ordered alphabet.
        /// `kVK_ANSI_0` is 29 and `kVK_ANSI_9` is 25, so that range is inverted
        /// and traps at runtime.
        private static let namedKeys: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Escape: "Esc",
            kVK_Tab: "Tab", kVK_Delete: "Delete",
            kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]

        static func keyName(for keyCode: UInt32) -> String? {
            if let named = namedKeys[Int(keyCode)] { return named }
            // Everything else resolves through the active layout, so a Dvorak
            // user sees the key they actually press.
            return layoutName(for: keyCode)
        }

        private static func layoutName(for keyCode: UInt32) -> String? {
            // ASCII-capable, not the current layout. With a Zhuyin or Pinyin
            // input source active the current layout resolves R to ㄐ, which is
            // not what is printed on the key. This is the same source macOS
            // itself uses to draw shortcuts in menus.
            guard
                let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                    .takeRetainedValue(),
                let pointer = TISGetInputSourceProperty(
                    source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

            return data.withUnsafeBytes { buffer -> String? in
                guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress
                else { return nil }
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, characters.count, &length, &characters)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length).uppercased()
            }
        }
    }

    private var registrations: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: @Sendable () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x7975_6E61  // 'yuna'

    /// The single dispatch table the Carbon callback reads. Carbon hands back a
    /// numeric id rather than context, so the mapping has to live somewhere the
    /// C callback can reach.
    /// Handlers are `@Sendable` because a Carbon callback delivers them from
    /// the event thread and they are then hopped to the main actor. Without the
    /// annotation the hop is a data race the compiler cannot see through.
    nonisolated(unsafe) private static var dispatch: [UInt32: @Sendable () -> Void] = [:]

    init() { installHandler() }

    /// Releases every registration. Called explicitly rather than from `deinit`:
    /// the Carbon references are not Sendable, so a nonisolated deinit cannot
    /// touch them. The manager lives for the process lifetime anyway.
    func tearDown() {
        for (_, reference) in registrations { UnregisterEventHotKey(reference) }
        registrations.removeAll()
        handlers.removeAll()
        Self.dispatch.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func installHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr else { return status }
                if let action = HotkeyManager.dispatch[identifier.id] {
                    DispatchQueue.main.async { action() }
                }
                return noErr
            },
            1, &spec, nil, &eventHandler)
    }

    /// Registers a shortcut. Returns false when another application already
    /// owns the combination, which is reported rather than swallowed — a
    /// shortcut that silently does nothing is worse than no shortcut.
    @discardableResult
    func register(
        _ action: Action, shortcut: Shortcut, handler: @escaping @Sendable () -> Void
    ) -> Bool {
        unregister(action)

        let identifier = UInt32(Action.allCases.firstIndex(of: action) ?? 0) + 1
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers.carbonValue, hotKeyID,
            GetApplicationEventTarget(), 0, &reference)

        guard status == noErr, let reference else { return false }
        registrations[action] = reference
        handlers[action] = handler
        Self.dispatch[identifier] = handler
        return true
    }

    func unregister(_ action: Action) {
        if let reference = registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(reference)
        }
        handlers[action] = nil
        let identifier = UInt32(Action.allCases.firstIndex(of: action) ?? 0) + 1
        Self.dispatch[identifier] = nil
    }

    var registeredActions: Set<Action> { Set(registrations.keys) }
}
