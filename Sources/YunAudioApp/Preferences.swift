import AppKit
import Foundation
import ServiceManagement
import YunAudioEngine
import YunAudioHAL
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
    /// Applications this router will never tap, whatever is selected.
    var excludedAppBundleIDs: [String]?
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
    /// Which of `YunIconBadge.styles` the application icon wears. Optional for
    /// the same reason.
    var iconStyle: String?
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
    /// The container recordings are written in.
    ///
    /// Stored by raw value rather than as `Recorder.Format` for the reason
    /// `tapMuteBehavior` is: the type belongs to the engine, and a preferences
    /// file is a promise to a version that has not been built yet.
    var recordingFormat: String?
    /// How much of each source goes to the monitor, by source UID.
    var monitorSends: [String: Float]?
    /// Extra delay per output device UID, in milliseconds, for lining up two
    /// outputs that do not arrive together.
    var outputDelays: [String: Double]?
    /// The headphone correction in use, by file name.
    ///
    /// Superseded by `busHeadphoneProfiles`, and kept so that a file written
    /// before buses had their own still opens. Read once on the way in and
    /// folded into the bus it used to mean; never written again.
    var headphoneProfileName: String?
    /// Ten slider positions for the output tone control, in decibels.
    ///
    /// Superseded by `busGraphicEQ`, on the same terms.
    var graphicEQ: [Float]?
    /// Ten slider positions per bus, by output device UID.
    ///
    /// Keyed by device rather than by the bus's letter: the letters are
    /// positional — turning the monitor off promotes B to A — and a tone
    /// somebody dialled in for their headphones must not migrate to the stream
    /// mix because a picker changed.
    var busGraphicEQ: [String: [Float]]?
    /// The headphone correction per bus, by output device UID, by file name.
    var busHeadphoneProfiles: [String: String]?
    /// Devices chosen before, most recent first.
    ///
    /// Not a preference somebody sets — a record of what they have actually
    /// used, which is the only ranking that needs no interface and is right
    /// more often than one that does. It decides what to fall back to when the
    /// device in the route is unplugged.
    var recentSourceUIDs: [String]?
    var recentDestinationUIDs: [String]?
    /// Which physical control drives what, as flat strings — the target's own
    /// key against the message's. Flat rather than nested so that a file
    /// somebody has to read by hand stays readable, and so that a target this
    /// version has never heard of can be dropped on the way in without taking
    /// the rest of the decode down with it.
    var midiBindings: [String: String]?
    /// Whether a captured application is still heard while it is being tapped.
    ///
    /// Stored as a string rather than by giving `TapMuteBehavior` a raw value:
    /// that type lives in the HAL layer, where the shape of this application's
    /// preferences file has no business being.
    var tapMuteBehavior: String?

    /// The script that stays loaded and reacts to things.
    ///
    /// Optional so a file written by a version that predates scripting still
    /// decodes — every field added here has been, and the one time one was
    /// not, every setting after it in the file was silently lost.
    var residentScript: String?

    /// Where OBS is, and which of its inputs reads this application.
    ///
    /// The password is deliberately absent. `UserDefaults` is a plain file in
    /// the user's home directory, and this application's own control socket is
    /// `chmod 600` because of what it can do; a websocket password in clear
    /// beside that would be inconsistent. See `OBSLink.password`.
    var obsHost: String?
    var obsPort: Int?
    var obsInputName: String?
    var obsMirrorsMute: Bool?

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
        excludedAppBundleIDs: [],
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
        recordsStems: false,
        recordingFormat: Recorder.Format.wav.rawValue,
        monitorSends: [:],
        outputDelays: [:],
        headphoneProfileName: nil,
        graphicEQ: [Float](repeating: 0, count: 10),
        busGraphicEQ: [:],
        busHeadphoneProfiles: [:],
        recentSourceUIDs: [],
        recentDestinationUIDs: [],
        midiBindings: [:],
        tapMuteBehavior: TapMuteBehavior.unmuted.storageKey,
        residentScript: nil,
        obsHost: "127.0.0.1",
        obsPort: 4455,
        obsInputName: "",
        obsMirrorsMute: false)
}

extension TapMuteBehavior {
    /// A name that is safe to write down.
    ///
    /// Not `String(describing:)`: that is a debugging convenience the compiler
    /// is free to change, and a preferences file is a promise to a copy of the
    /// application that has not been built yet.
    var storageKey: String {
        switch self {
        case .unmuted: "unmuted"
        case .muted: "muted"
        case .mutedWhenTapped: "mutedWhenTapped"
        }
    }

    init?(storageKey: String) {
        guard let match = TapMuteBehavior.allCases.first(where: { $0.storageKey == storageKey })
        else { return nil }
        self = match
    }
}

@MainActor
enum PreferencesStore {
    private static let key = "com.yuhuanstudio.yunaudio.preferences"

    /// Whether anything has ever been saved.
    ///
    /// `load()` answers with defaults either way, which is right for reading a
    /// setting and wrong for deciding whether somebody has made a choice at
    /// all: a first launch and a launch where every value happens to equal its
    /// default are indistinguishable from the outside.
    static var hasStoredPreferences: Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }

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

/// Where the application puts itself.
///
/// Not in `Preferences`: that blob is decoded when the model is built, and the
/// activation policy has to be right before the first window is ordered in or
/// the Dock icon appears a beat late and then vanishes. `UserDefaults` answers
/// with nothing else having run.
@MainActor
enum InterfaceOptions {
    private static let dockKey = "com.yuhuanstudio.yunaudio.showsDockIcon"

    /// `LSUIElement` makes this an accessory by default: menu bar only, no Dock
    /// icon and no application menu. That is right for a router that is mostly
    /// left alone, and wrong for somebody who works in the window and wants to
    /// reach it with ⌘-tab like anything else.
    static var showsDockIcon: Bool {
        get { UserDefaults.standard.bool(forKey: dockKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: dockKey)
            apply()
        }
    }

    /// Puts the policy on the running application.
    ///
    /// Returns whether it took: `setActivationPolicy` reports failure, and a
    /// toggle that silently did nothing is the kind of defect this project
    /// keeps finding.
    @discardableResult
    static func apply() -> Bool {
        NSApp?.setActivationPolicy(showsDockIcon ? .regular : .accessory) ?? false
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
