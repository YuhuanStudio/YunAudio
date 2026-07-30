import AppKit
import Foundation

/// Exercises the Settings scene without starting or reserving any audio device.
///
/// A responder accepting `showSettingsWindow:` proved nothing: it could return
/// true while presenting no window. This drives the header button's keyboard
/// equivalent and then measures the retained window that actually appeared.
@MainActor
enum SettingsEntryCheck {
    static func run() async -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == "YunAudio" }) else {
            report(handled: false, appeared: false, milliseconds: 0)
            return false
        }
        window.makeKeyAndOrderFront(nil)
        await settle()

        guard
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: ",",
                charactersIgnoringModifiers: ",",
                isARepeat: false,
                keyCode: 43)
        else {
            report(handled: false, appeared: false, milliseconds: 0)
            return false
        }

        let began = ContinuousClock.now
        let handled = window.performKeyEquivalent(with: event)
        var settings: NSWindow?
        for _ in 0..<20 {
            settings = PreferencesWindow.openWindow()
            if settings != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = began.duration(to: .now)
        let milliseconds =
            elapsed.components.seconds * 1_000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
        report(handled: handled, appeared: settings != nil, milliseconds: milliseconds)
        settings?.close()
        window.makeKeyAndOrderFront(nil)
        return handled && settings != nil
    }

    private static func settle() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }

    private static func report(handled: Bool, appeared: Bool, milliseconds: Int64) {
        let line =
            "settings entry: handled=\(handled ? 1 : 0) "
            + "window=\(appeared ? 1 : 0) elapsed=\(milliseconds)ms\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
