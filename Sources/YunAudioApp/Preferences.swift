import Foundation
import ServiceManagement
import YunAudioEngine
import YunDesign

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
    /// Bundle identifiers of applications captured as routing sources.
    var capturedAppBundleIDs: [String]
    /// Raw values of the enabled processing stages.
    var enabledEffects: [String]
    /// Knob positions, keyed by "<stage>.<parameter>".
    var effectValues: [String: Float]
    /// Capture the microphone through the echo canceller. Optional so a
    /// preferences file written before this existed still decodes.
    var cancelsEcho: Bool?
    /// The speaker the canceller listens for. Nil means the current default.
    var echoSpeakerUID: String?
    /// Which look the application wears. Optional so a file written before the
    /// setting existed still decodes.
    var style: String?
    /// The input trim and the master, in decibels. Optional for the same
    /// reason.
    /// What the microphone's light ring shows.
    var lightingMode: String?
    var lightingHue: Double?
    var lightingBrightness: Double?
    var inputDecibels: Float?
    var isInputMuted: Bool?
    var outputDecibels: Float?
    var isOutputMuted: Bool?
    /// Which platform the loudness readout is compared against.
    var loudnessTarget: String?
    /// Where the microphone is also sent so the user can hear themselves.
    var monitorDeviceUID: String?
    var monitorDecibels: Float?
    /// Hold the microphone at the target loudness automatically.
    var isAutoLevelling: Bool?
    /// Application audio steps out of the way while somebody is talking.
    var isDucking: Bool?
    var duckDecibels: Float?
    /// What each source is for, keyed by device UID or bundle identifier.
    var sourceRoles: [String: String]?
    /// Hold a key to talk rather than clicking to mute.
    var isPushToTalkEnabled: Bool?
    /// Third-party Audio Units in the chain, and their knob positions.
    var plugins: [AudioUnitPlugin]?
    var pluginValues: [String: Float]?
    /// A whole voice, rather than the two stages it is made of.
    var voicePreset: String?
    /// Write a separate file per source alongside the mix.
    var recordsStems: Bool?

    static let `default` = Preferences(
        sourceDeviceUID: nil,
        destinationDeviceUID: nil,
        channelMode: SourceChannelMode.mono.rawValue,
        monoChannel: 0,
        bufferFrames: 128,
        autoStart: false,
        voiceIsolationEnabled: false,
        voiceIsolationMix: 100,
        preferredSampleRate: 48000,
        capturedAppBundleIDs: [],
        enabledEffects: [],
        effectValues: [:],
        cancelsEcho: false,
        echoSpeakerUID: nil,
        style: YunStyle.flat.rawValue,
        lightingMode: LightingMode.off.rawValue,
        lightingHue: 0.55,
        lightingBrightness: 1,
        inputDecibels: 0,
        isInputMuted: false,
        outputDecibels: 0,
        isOutputMuted: false,
        loudnessTarget: LoudnessTarget.discord.rawValue,
        monitorDeviceUID: nil,
        monitorDecibels: -6,
        isAutoLevelling: false,
        isDucking: false,
        duckDecibels: -14,
        sourceRoles: [:],
        isPushToTalkEnabled: false,
        plugins: [],
        pluginValues: [:],
        voicePreset: VoicePreset.none.rawValue,
        recordsStems: false)
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
