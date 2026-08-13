import CoreAudio
import Foundation

/// What a device's channels actually carry, where that is known.
///
/// CoreAudio will tell you a device has three input channels and nothing about
/// what is on them. For most hardware that is all there is to say. For the
/// Seiren V3 Pro it is actively misleading: the three channels are three
/// different versions of the same microphone, and picking the wrong one gets
/// you a signal that sounds nearly right and is not what you meant.
///
/// The names below come from the device's own module dumping its internal
/// topology on startup — `Device_Mic`, `Device_MicDry`, `Device_MicPostExp` on
/// pin 1, channels 0 to 2, which is exactly the three-channel float stream
/// CoreAudio exposes. Nothing else on macOS says which is which.
public enum DeviceChannelNames {

    /// A channel's purpose, when the device is one we know the topology of.
    public struct Channel: Sendable, Hashable {
        public let name: String
        /// One line on why you would pick this one.
        public let detail: String
        /// True for the channel a person almost always wants.
        public let isDefault: Bool
    }

    /// - Parameters:
    ///   - modelUID: The device's model identifier, which is stable across
    ///     units in a way the device UID is not.
    ///   - name: The device's name, used when no model identifier is published.
    ///   - scope: Input or output.
    /// - Returns: One entry per channel, or nil when the device is not known.
    public static func channels(
        modelUID: String?, name: String, scope: AudioObjectPropertyScope
    ) -> [Channel]? {
        channels(
            in: shared.library, modelUID: modelUID, name: name, scope: scope)
    }

    /// Resolves names from a caller-owned immutable profile snapshot.
    ///
    /// Application views use this form so the first label they draw cannot be
    /// the event which lazily walks both profile directories on MainActor.
    public static func channels(
        in library: DeviceProfileLibrary,
        modelUID: String?, name: String, scope: AudioObjectPropertyScope
    ) -> [Channel]? {
        guard scope == kAudioObjectPropertyScopeInput else { return nil }
        guard let profile = library.profile(modelUID: modelUID, name: name) else {
            return nil
        }
        return profile.inputChannels.map {
            Channel(name: $0.name, detail: $0.detail, isDefault: $0.isDefault)
        }
    }

    /// Anything worth saying about the device as a whole.
    public static func note(modelUID: String?, name: String) -> String? {
        note(in: shared.library, modelUID: modelUID, name: name)
    }

    /// Resolves a note from a caller-owned immutable profile snapshot.
    public static func note(
        in library: DeviceProfileLibrary, modelUID: String?, name: String
    ) -> String? {
        library.profile(modelUID: modelUID, name: name)?.note
    }

    /// The loaded profiles, and anything that would not load.
    ///
    /// Built once. Reading a folder on every channel lookup would be a
    /// filesystem hit inside a device enumeration that runs on every hot-plug.
    public static let shared = Loaded()

    public struct Loaded: Sendable {
        public let library: DeviceProfileLibrary
        /// Files that would not parse, named so somebody can fix theirs.
        public let problems: [String]

        init() {
            let bundled = Bundle.moduleIfPresent?.url(
                forResource: "Devices", withExtension: nil)
            let (library, problems) = DeviceProfileLibrary.standard(
                bundled: bundled, userDirectory: DeviceProfileLibrary.userDirectory)
            self.library = library
            self.problems = problems
        }
    }

    /// The Seiren V3 Pro's three input channels, as the profile file states
    /// them. Kept as a symbol because the tests assert the shipped file still
    /// says what it is supposed to.
    ///
    /// The order is the device's own: channel 0 is the processed capsule,
    /// channel 1 is untouched, channel 2 has been through the microphone's own
    /// expander. That last one is the interesting discovery — the hardware has
    /// a gate of its own, ahead of the converter, which is a thing no amount of
    /// software can do after the fact.
    public static var seirenV3ProInputs: [Channel] {
        channels(
            modelUID: nil, name: "Razer Seiren V3 Pro",
            scope: kAudioObjectPropertyScopeInput) ?? fallbackSeirenInputs
    }

    /// What the shipped profile says, in case the resource is missing.
    static let fallbackSeirenInputs: [Channel] = [
        Channel(
            name: "Microphone",
            detail: "The capsule as the device presents it.",
            isDefault: true),
        Channel(
            name: "Dry",
            detail: "The same capsule with none of the device's own processing.",
            isDefault: false),
        Channel(
            name: "After the expander",
            detail:
                "Past the microphone's own expander, which sits before the converter — "
                + "so it removes room noise without anything having to clip first.",
            isDefault: false),
    ]
}
