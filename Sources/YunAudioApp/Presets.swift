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
            activePresetName = preset.name
        }
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
