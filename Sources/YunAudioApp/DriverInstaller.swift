import AppKit
import Foundation

/// Installs and removes the virtual audio device.
///
/// The plug-in has to land in `/Library/Audio/Plug-Ins/HAL`, which needs
/// privileges the app does not have and should not keep. Rather than shipping a
/// privileged helper that lives forever for the sake of a one-off copy, the work
/// is handed to `osascript` with administrator rights: the user sees the
/// standard authentication dialog, grants it once, and nothing persists
/// afterwards.
@MainActor
enum DriverInstaller {
    static let installPath = "/Library/Audio/Plug-Ins/HAL/YunAudioDriver.driver"

    enum Outcome: Equatable {
        case installed
        case removed
        case cancelled
        case failed(String)
    }

    /// The driver bundled alongside the app.
    ///
    /// Looked for inside the app bundle first, then next to it — the disk image
    /// ships them side by side so the driver can be copied out by an installer
    /// script without unpacking the app.
    static var bundledDriverURL: URL? {
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/YunAudioDriver.driver"),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("YunAudioDriver.driver"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installPath)
    }

    static func install() -> Outcome {
        guard let source = bundledDriverURL else {
            return .failed("The driver was not found next to the app.")
        }
        // Restarting coreaudiod is what makes the new device appear; without it
        // the copy sits on disk unnoticed until the next reboot.
        let script = """
            mkdir -p '/Library/Audio/Plug-Ins/HAL' && \
            rm -rf '\(installPath)' && \
            cp -R '\(source.path)' '/Library/Audio/Plug-Ins/HAL/' && \
            killall coreaudiod
            """
        return run(script, describing: "install", success: .installed)
    }

    static func uninstall() -> Outcome {
        let script = "rm -rf '\(installPath)' && killall coreaudiod"
        return run(script, describing: "remove", success: .removed)
    }

    private static func run(
        _ shellScript: String, describing action: String, success: Outcome
    ) -> Outcome {
        // Quoting matters here: the script is embedded in an AppleScript string
        // literal, so its own quotes and backslashes have to survive that layer.
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else {
            return .failed("Could not build the \(action) script.")
        }
        appleScript.executeAndReturnError(&error)

        guard let error else { return success }
        // -128 is the documented code for the user dismissing the dialog. That
        // is a decision, not a failure, and should not be reported as one.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        let message = error[NSAppleScript.errorMessage] as? String
            ?? "The \(action) did not complete."
        return .failed(message)
    }
}
