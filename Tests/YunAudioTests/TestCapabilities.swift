import Foundation
import Testing

/// Explicit opt-ins for tests whose evidence belongs to a particular host.
///
/// A raw `swift test` must be safe on a developer's everyday machine. Reading
/// the live Core Audio census can block behind a sick audio server; changing a
/// sample rate or creating a process tap is hardware work outright. Those tests
/// run only when the caller names that authority, while pure fault-injected HAL
/// tests remain in every run.
enum TestCapabilities {
    static var liveHAL: Bool {
        ProcessInfo.processInfo.environment["YUNAUDIO_LIVE_HAL_TESTS"] == "1"
    }

    /// One machine-readable marker for every test which may reach the live HAL.
    /// CI extracts the stable identifier from source and requires the complete
    /// set to match its reviewed exclusion manifest before a binary can run.
    static func liveHALTest(_ identifier: String) -> ConditionTrait {
        precondition(identifier.hasPrefix("YunAudioTests."))
        return .enabled(
            if: liveHAL,
            "set YUNAUDIO_LIVE_HAL_TESTS=1 to permit live Core Audio access")
    }

    static var hasTranscriptionRuntime: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }
}
