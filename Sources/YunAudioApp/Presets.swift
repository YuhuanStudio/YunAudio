import Foundation
import YunAudioEngine
import YunDesign

/// A named snapshot of a routing configuration.
///
/// The reason presets exist rather than one set of settings: sample rate is a
/// per-use-case decision, not a global one. Sending 96 kHz to a voice chat only
/// buys a resample back down to 48 kHz at the far end and twice the CPU, while a
/// recording session wants the opposite. One switch has to move both the rate
/// and the processing chain together.
struct RoutePreset: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var sampleRate: Double
    var bufferFrames: UInt32
    var voiceIsolationEnabled: Bool
    var voiceIsolationMix: Float
    var channelMode: String
    /// Whether the microphone goes through the echo canceller. Only the
    /// speakerphone preset wants this: it costs the clock lock and a buffer of
    /// latency each way, which is a bad trade on headphones.
    var cancelsEcho: Bool
    /// Container to record in. WAV keeps a lossless path lossless on disk.
    var recordingFormat: String
    var note: String
    /// True for one somebody saved themselves.
    ///
    /// The built-in four cannot be edited or deleted; a saved one can be both.
    /// Keeping the distinction in the data rather than in a separate list means
    /// there is one thing to iterate and one thing to persist.
    var isUserDefined: Bool = false
    /// Everything a saved preset captures that the built-in ones do not.
    ///
    /// The built-in four describe how to route — sample rate, buffer, a stage
    /// or two — because that is the part of the decision that is general. A
    /// preset somebody saves is a snapshot of *their* setup, so it carries what
    /// they had set: the processing chain, the voice, the levels and the
    /// devices themselves.
    var effects: [String]?
    var effectValues: [String: Float]?
    var voicePreset: String?
    var inputDecibels: Float?
    var outputDecibels: Float?
    var monitorDeviceUID: String?
    var sourceDeviceUID: String?
    var destinationDeviceUID: String?
    var capturedAppBundleIDs: [String]?

    static let voiceChat = RoutePreset(
        name: loc("Voice chat"),
        sampleRate: 48000,
        bufferFrames: 128,
        voiceIsolationEnabled: false,
        voiceIsolationMix: 100,
        channelMode: SourceChannelMode.mono.rawValue,
        cancelsEcho: false,
        recordingFormat: Recorder.Format.wav.rawValue,
        note:
            "48 kHz and a small buffer. Anything higher is resampled back down at the far end.")

    /// The case the echo canceller exists for.
    ///
    /// On speakers the far end comes back into the microphone and everyone
    /// hears themselves a beat late. On headphones none of this applies and the
    /// cost — no clock lock, no bit-exactness, a buffer each way — buys
    /// nothing, which is why it is a preset rather than a default.
    static let speakerphone = RoutePreset(
        name: loc("Speakers"),
        sampleRate: 48000,
        bufferFrames: 256,
        voiceIsolationEnabled: false,
        voiceIsolationMix: 100,
        channelMode: SourceChannelMode.mono.rawValue,
        cancelsEcho: true,
        recordingFormat: Recorder.Format.wav.rawValue,
        note:
            "Removes the speakers from the microphone. Costs the clock lock and a buffer of latency each way."
    )

    static let noisyRoom = RoutePreset(
        name: loc("Noisy room"),
        sampleRate: 48000,
        bufferFrames: 256,
        voiceIsolationEnabled: true,
        voiceIsolationMix: 100,
        channelMode: SourceChannelMode.mono.rawValue,
        cancelsEcho: false,
        recordingFormat: Recorder.Format.wav.rawValue,
        note: "Adds Apple's voice isolation. Costs 56 ms and the path is no longer bit-exact.")

    static let recording = RoutePreset(
        name: loc("Recording"),
        sampleRate: 96000,
        bufferFrames: 256,
        voiceIsolationEnabled: false,
        voiceIsolationMix: 100,
        channelMode: SourceChannelMode.mono.rawValue,
        cancelsEcho: false,
        recordingFormat: Recorder.Format.wav.rawValue,
        note: "96 kHz, untouched signal. Latency matters less than keeping the capture intact.")

    static let builtIn: [RoutePreset] = [
        .voiceChat, .speakerphone, .noisyRoom, .recording,
    ]
}

/// Presets somebody saved, on disk.
@MainActor
enum UserPresets {
    private static let key = "com.yuhuanstudio.yunaudio.presets"

    static func load() -> [RoutePreset] {
        guard let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([RoutePreset].self, from: data)
        else { return [] }
        // Whatever was stored, they are user-defined by definition of where
        // they came from — a file edited by hand cannot claim to be built in.
        return decoded.map {
            var preset = $0
            preset.isUserDefined = true
            return preset
        }
    }

    static func save(_ presets: [RoutePreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension RouterModel {
    /// Applies a preset. Device selection is deliberately left alone — a preset
    /// describes how to route, not what to route.
    func apply(_ preset: RoutePreset) {
        // One edit, not five. Every one of these properties restarts the route
        // on its own, so applying a preset used to tear the audio down and
        // build it back three times for a single click.
        batched {
            voiceIsolationEnabled = preset.voiceIsolationEnabled
            voiceIsolationMix = preset.voiceIsolationMix
            if let mode = SourceChannelMode(rawValue: preset.channelMode) {
                channelMode = mode
            }
            preferredSampleRate = preset.sampleRate
            bufferFrames = preset.bufferFrames
            cancelsEcho = preset.cancelsEcho
            if let format = Recorder.Format(rawValue: preset.recordingFormat) {
                recordingFormat = format
            }

            // The extra fields a saved preset carries. Absent on the built-in
            // four, which describe how to route rather than what somebody's
            // setup was.
            if let effects = preset.effects {
                enabledEffects = Set(effects.compactMap(EffectKind.init(rawValue:)))
            }
            if let values = preset.effectValues { effectValues = values }
            if let voice = preset.voicePreset.flatMap(VoicePreset.init(rawValue:)) {
                voicePreset = voice
            }
            if let level = preset.inputDecibels { inputDecibels = level }
            if let level = preset.outputDecibels { outputDecibels = level }
            // Devices are restored only when they are actually present.
            // Pointing at a microphone somebody unplugged would fail the start
            // and blame the preset.
            if let uid = preset.sourceDeviceUID,
                inputDevices.contains(where: { $0.uid == uid })
            {
                selectedSourceUID = uid
            }
            if let uid = preset.destinationDeviceUID,
                outputDevices.contains(where: { $0.uid == uid })
            {
                selectedDestinationUID = uid
            }
            monitorDeviceUID =
                preset.monitorDeviceUID.flatMap { uid in
                    monitorOptions.contains(where: { $0.uid == uid }) ? uid : nil
                } ?? monitorDeviceUID
            if let apps = preset.capturedAppBundleIDs {
                capturedAppBundleIDs = Set(apps)
            }

            activePresetName = preset.name
        }
    }

    /// Everything the interface offers, saved ones after the built-in four.
    var allPresets: [RoutePreset] { RoutePreset.builtIn + userPresets }

    /// A snapshot of everything as it is now.
    ///
    /// Deliberately everything rather than a chosen subset: somebody who saves
    /// a preset has just spent time getting a setup right, and a snapshot that
    /// quietly left out the thing they were adjusting is worse than no snapshot
    /// at all.
    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var preset = RoutePreset(
            name: trimmed,
            sampleRate: preferredSampleRate,
            bufferFrames: bufferFrames,
            voiceIsolationEnabled: voiceIsolationEnabled,
            voiceIsolationMix: voiceIsolationMix,
            channelMode: channelMode.rawValue,
            cancelsEcho: cancelsEcho,
            recordingFormat: recordingFormat.rawValue,
            note: loc("Saved from the current setup."),
            isUserDefined: true)
        preset.effects = enabledEffects.map(\.rawValue)
        preset.effectValues = effectValues
        preset.voicePreset = voicePreset.rawValue
        preset.inputDecibels = inputDecibels
        preset.outputDecibels = outputDecibels
        preset.monitorDeviceUID = monitorDeviceUID
        preset.sourceDeviceUID = selectedSourceUID
        preset.destinationDeviceUID = selectedDestinationUID
        preset.capturedAppBundleIDs = Array(capturedAppBundleIDs)

        // Saving over a name that exists replaces it rather than making a
        // second one: the alternative is a list of "Podcast", "Podcast 2",
        // "Podcast 3" and no way to tell which is current.
        var presets = userPresets.filter { $0.name != trimmed }
        presets.append(preset)
        userPresets = presets
        activePresetName = trimmed
    }

    func deletePreset(_ preset: RoutePreset) {
        guard preset.isUserDefined else { return }
        userPresets.removeAll { $0.name == preset.name }
        if activePresetName == preset.name { activePresetName = nil }
    }

    /// True when the current settings still match the named preset.
    ///
    /// Every field the preset sets has to be compared, or two presets that
    /// differ only in a field nobody checks both light up at once.
    func matches(_ preset: RoutePreset) -> Bool {
        voiceIsolationEnabled == preset.voiceIsolationEnabled
            && channelMode.rawValue == preset.channelMode
            && preferredSampleRate == preset.sampleRate
            && bufferFrames == preset.bufferFrames
            && cancelsEcho == preset.cancelsEcho
            && recordingFormat.rawValue == preset.recordingFormat
    }
}
