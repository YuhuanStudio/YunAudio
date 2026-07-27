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
    var note: String

    static let voiceChat = RoutePreset(
        name: loc("Voice chat"),
        sampleRate: 48000,
        bufferFrames: 128,
        voiceIsolationEnabled: false,
        voiceIsolationMix: 100,
        channelMode: SourceChannelMode.mono.rawValue,
        note:
            "48 kHz and a small buffer. Anything higher is resampled back down at the far end.")

    static let noisyRoom = RoutePreset(
        name: loc("Noisy room"),
        sampleRate: 48000,
        bufferFrames: 256,
        voiceIsolationEnabled: true,
        voiceIsolationMix: 100,
        channelMode: SourceChannelMode.mono.rawValue,
        note: "Adds Apple's voice isolation. Costs 56 ms and the path is no longer bit-exact.")

    static let recording = RoutePreset(
        name: loc("Recording"),
        sampleRate: 96000,
        bufferFrames: 256,
        voiceIsolationEnabled: false,
        voiceIsolationMix: 100,
        channelMode: SourceChannelMode.mono.rawValue,
        note: "96 kHz, untouched signal. Latency matters less than keeping the capture intact.")

    static let builtIn: [RoutePreset] = [.voiceChat, .noisyRoom, .recording]
}

extension RouterModel {
    /// Applies a preset. Device selection is deliberately left alone — a preset
    /// describes how to route, not what to route.
    func apply(_ preset: RoutePreset) {
        voiceIsolationEnabled = preset.voiceIsolationEnabled
        voiceIsolationMix = preset.voiceIsolationMix
        if let mode = SourceChannelMode(rawValue: preset.channelMode) {
            channelMode = mode
        }
        preferredSampleRate = preset.sampleRate
        activePresetName = preset.name
    }

    /// True when the current settings still match the named preset.
    func matches(_ preset: RoutePreset) -> Bool {
        voiceIsolationEnabled == preset.voiceIsolationEnabled
            && channelMode.rawValue == preset.channelMode
            && preferredSampleRate == preset.sampleRate
    }
}
