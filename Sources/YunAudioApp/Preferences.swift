import Foundation
import ServiceManagement

/// Everything the app remembers between launches.
///
/// Devices are stored by UID, never by `AudioObjectID`: the numeric ID is
/// reassigned when a device is replugged or when the machine reboots, so a
/// persisted ID would silently start pointing at someone else's hardware.
struct Preferences: Codable, Equatable, Sendable {
    var sourceDeviceUID: String?
    var destinationDeviceUID: String?
    var channelMode: String
    var monoChannel: Int
    var bufferFrames: UInt32
    /// Start routing as soon as the app launches and the devices are present.
    var autoStart: Bool
    var voiceIsolationEnabled: Bool
    var voiceIsolationMix: Float
    var preferredSampleRate: Double

    static let `default` = Preferences(
        sourceDeviceUID: nil,
        destinationDeviceUID: nil,
        channelMode: SourceChannelMode.mono.rawValue,
        monoChannel: 0,
        bufferFrames: 128,
        autoStart: false,
        voiceIsolationEnabled: false,
        voiceIsolationMix: 100,
        preferredSampleRate: 48000)
}

@MainActor
enum PreferencesStore {
    private static let key = "com.yuhuanstudio.yunaudio.preferences"

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return .default }
        return decoded
    }

    static func save(_ preferences: Preferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Login item registration.
///
/// `SMAppService.mainApp` replaces the old login-item and helper-bundle dances;
/// the system owns the state, so it is read back rather than mirrored locally.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a message explaining why it did not take.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            // The most common cause is the app not being in /Applications, or
            // running unsigned from a build directory. Say so rather than
            // failing silently.
            return "Could not update the login item: \(error.localizedDescription)"
        }
    }
}
