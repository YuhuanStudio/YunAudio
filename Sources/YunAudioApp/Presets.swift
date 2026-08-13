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
    /// The processing a preset asks for, and the rest of what it captures.
    ///
    /// Optional, all of it, and that is not tidiness: a preset somebody saved
    /// before these fields existed is still sitting in `UserDefaults` as JSON,
    /// and a non-optional field would make the whole array fail to decode and
    /// take every one of their presets with it. `effects` keeps its original
    /// name for the same reason — renaming it to match the model's
    /// `enabledEffects` would change the coding key and silently drop the
    /// chain out of everything already saved.
    ///
    /// The built-in four used to leave all of this alone, on the theory that a
    /// preset described how to *route* rather than how to *process*. That was
    /// wrong in the way that is hardest to see: switching from a voice call to
    /// a noisy room moved a buffer size and one isolation flag, so the thing
    /// somebody pressed to sound better sounded identical.
    var effects: [String]?
    var effectValues: [String: Float]?
    var voicePreset: String?
    var inputDecibels: Float?
    var outputDecibels: Float?
    var monitorDeviceUID: String?
    var sourceDeviceUID: String?
    var destinationDeviceUID: String?
    var capturedAppBundleIDs: [String]?
    /// Whether application audio steps out of the way of a voice.
    var isDucking: Bool?
    var duckDecibels: Float?
    /// Whether the input trim chases the loudness target on its own.
    var isAutoLevelling: Bool?
    /// What the loudness readout is measured against. A call and a recording
    /// want different numbers, and the target is the thing auto-levelling aims
    /// at — so it belongs to the scene rather than to the application.
    var loudnessTarget: String?

    /// Clean and intelligible, and nothing else.
    ///
    /// Isolation at a partial mix rather than the full amount: on a call the
    /// model has to leave the voice alone more than it has to remove the room,
    /// and at 100% quiet consonants go with the noise.
    static let voiceChat = RoutePreset(
        name: loc("Voice chat"),
        sampleRate: 48000,
        bufferFrames: 128,
        voiceIsolationEnabled: true,
        voiceIsolationMix: 70,
        channelMode: SourceChannelMode.mono.rawValue,
        cancelsEcho: false,
        recordingFormat: Recorder.Format.wav.rawValue,
        note:
            "Isolation, a light gate and gentle compression, at 48 kHz. Nothing here is meant to be audible.",
        effects: [.voiceIsolation, .equaliser, .gate, .compressor, .limiter],
        effectValues: [
            "voiceIsolation.mix": 70,
            "equaliser.frequency": 80,
            // Low and shallow. A gate on a call is insurance against a fan, not
            // a way of removing a room — one set high enough to do that clips
            // the start of every quiet word.
            "gate.threshold": -50,
            "gate.ratio": 6,
            "gate.release": 300,
            "compressor.threshold": -20,
            "compressor.headroom": 6,
            "limiter.gain": 0,
        ],
        // Said rather than left out, here and on every other scene. A field a
        // preset declines to set is a field that keeps whatever the last scene
        // put there, and a scene whose behaviour depends on which scene
        // preceded it is not a starting point.
        isDucking: false,
        isAutoLevelling: true,
        loudnessTarget: LoudnessTarget.discord.rawValue)

    /// The case the echo canceller exists for.
    ///
    /// On speakers the far end comes back into the microphone and everyone
    /// hears themselves a beat late. On headphones none of this applies and the
    /// cost — no clock lock, no bit-exactness, a buffer each way — buys
    /// nothing, which is why it is a preset rather than a default.
    ///
    /// Isolation is left off deliberately: the canceller already owns the
    /// microphone and is already processing it, and stacking a second model on
    /// top of that costs another 56 ms to remove noise the first one took.
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
            "Removes the speakers from the microphone, then gates and compresses harder because the room is in it.",
        effects: [.equaliser, .gate, .compressor, .limiter],
        effectValues: [
            // Up from 80 Hz: a laptop sitting on the same desk as its own
            // speakers puts the whole bottom octave into the microphone as
            // structure rather than as air, and the canceller cannot see it.
            "equaliser.frequency": 110,
            "gate.threshold": -38,
            "gate.ratio": 20,
            "gate.release": 180,
            // Harder than a headset call, because somebody on speakerphone is
            // further from the microphone and moves about while talking.
            "compressor.threshold": -26,
            "compressor.headroom": 3,
            "limiter.gain": 0,
        ],
        isDucking: true,
        duckDecibels: -18,
        isAutoLevelling: true,
        loudnessTarget: LoudnessTarget.discord.rawValue)

    /// Everything turned up, plus the tone control the other three do not use.
    ///
    /// The equaliser earns its place here rather than being decoration: what a
    /// noisy room and a hard isolation setting both leave behind is a voice
    /// that has lost its top and kept its boxiness, and those are exactly the
    /// two bands being moved.
    static let noisyRoom = RoutePreset(
        name: loc("Noisy room"),
        sampleRate: 48000,
        bufferFrames: 256,
        voiceIsolationEnabled: true,
        voiceIsolationMix: 100,
        channelMode: SourceChannelMode.mono.rawValue,
        cancelsEcho: false,
        recordingFormat: Recorder.Format.wav.rawValue,
        note:
            "Isolation at full, a high gate and the high-pass moved up. Costs 56 ms and the path is no longer bit-exact.",
        effects: [.voiceIsolation, .equaliser, .tone, .gate, .compressor, .limiter],
        effectValues: [
            "voiceIsolation.mix": 100,
            "equaliser.frequency": 150,
            "gate.threshold": -28,
            "gate.ratio": 30,
            "gate.release": 120,
            "tone.b1": -4,
            "tone.b4": 3,
            "compressor.threshold": -22,
            "compressor.headroom": 5,
            "limiter.gain": 0,
        ],
        isDucking: false,
        isAutoLevelling: true,
        loudnessTarget: LoudnessTarget.discord.rawValue)

    /// Nothing that colours the signal.
    ///
    /// The limiter alone, and it is there as insurance rather than as
    /// processing: it only acts on a sample that would otherwise clip, and a
    /// clipped capture cannot be repaired afterwards. Auto-levelling is off for
    /// the same reason the rest is — a recording that had its gain moved while
    /// it was being made is a record of the gain rider rather than of the
    /// performance.
    static let recording = RoutePreset(
        name: loc("Recording"),
        sampleRate: 96000,
        bufferFrames: 256,
        voiceIsolationEnabled: false,
        voiceIsolationMix: 100,
        channelMode: SourceChannelMode.mono.rawValue,
        cancelsEcho: false,
        recordingFormat: Recorder.Format.wav.rawValue,
        note:
            "96 kHz and a limiter as insurance. Nothing else touches the signal, and the target is −23 LUFS.",
        effects: [.limiter],
        effectValues: ["limiter.gain": 0],
        isDucking: false,
        isAutoLevelling: false,
        loudnessTarget: LoudnessTarget.broadcast.rawValue)

    static let builtIn: [RoutePreset] = [
        .voiceChat, .speakerphone, .noisyRoom, .recording,
    ]
}

extension RoutePreset {
    /// The stages this preset asks for, or nil for one saved before presets
    /// carried a chain at all.
    var effectKinds: Set<EffectKind>? {
        effects.map { Set($0.compactMap(EffectKind.init(rawValue:))) }
    }

    /// Spelling the chain with the enum rather than with strings.
    ///
    /// The stored form has to be `[String]`, because a preset written by a
    /// version that knew about a stage this one does not must still decode. But
    /// a mistyped raw string in the four definitions above would compile, store
    /// and then silently produce a preset with one stage fewer than intended —
    /// which is precisely the failure this whole change exists to end.
    fileprivate init(
        name: String, sampleRate: Double, bufferFrames: UInt32,
        voiceIsolationEnabled: Bool, voiceIsolationMix: Float, channelMode: String,
        cancelsEcho: Bool, recordingFormat: String, note: String,
        effects: [EffectKind], effectValues: [String: Float],
        isDucking: Bool? = nil, duckDecibels: Float? = nil,
        isAutoLevelling: Bool? = nil, loudnessTarget: String? = nil
    ) {
        self.init(
            name: name, sampleRate: sampleRate, bufferFrames: bufferFrames,
            voiceIsolationEnabled: voiceIsolationEnabled,
            voiceIsolationMix: voiceIsolationMix, channelMode: channelMode,
            cancelsEcho: cancelsEcho, recordingFormat: recordingFormat, note: note)
        self.effects = effects.map(\.rawValue)
        self.effectValues = effectValues
        // Stated rather than left nil. A scene now owns the whole chain, and
        // leaving the voice alone would put the model in a state it can only
        // reach through a preset: a voice selected, and neither of the two
        // stages that produce it in the chain the scene just installed.
        self.voicePreset = VoicePreset.none.rawValue
        self.isDucking = isDucking
        self.duckDecibels = duckDecibels
        self.isAutoLevelling = isAutoLevelling
        self.loudnessTarget = loudnessTarget
    }
}

private let userPresetsStoreKey = "com.yuhuanstudio.yunaudio.presets"

/// Presets somebody saved, on disk.
@MainActor
enum UserPresets {
    enum SaveResult: Equatable, Sendable {
        case saved(RoutePreset)
        case invalidName
        case refused(CollectionPersistenceRefusal)
    }

    private static let persistence = BoundedCollectionPersistence<[RoutePreset]>(
        encode: { try? JSONEncoder().encode($0) },
        sink: { data in
            UserDefaults.standard.set(data, forKey: userPresetsStoreKey)
            return UserDefaults.standard.data(forKey: userPresetsStoreKey) == data
        },
        synchronise: { UserDefaults.standard.synchronize() })

    static var statistics: CollectionPersistenceStatistics {
        persistence.statistics
    }

    static func refusal(for presets: [RoutePreset]) -> CollectionPersistenceRefusal? {
        persistence.preflightRefusal(
            recordCount: presets.count,
            estimatedEncodedBytes: encodedSizeUpperBoundForDiagnostics(presets))
    }

    static func load() -> [RoutePreset] {
        let decoded: [RoutePreset]
        switch persistence.load(
            UserDefaults.standard.data(forKey: userPresetsStoreKey),
            decode: { try? JSONDecoder().decode([RoutePreset].self, from: $0) },
            recordCount: \.count)
        {
        case .loaded(let saved):
            decoded = saved
        case .absent, .refused:
            return []
        }
        // Whatever was stored, they are user-defined by definition of where
        // they came from — a file edited by hand cannot claim to be built in.
        return decoded.map {
            var preset = $0
            preset.isUserDefined = true
            return preset
        }
    }

    @discardableResult
    static func save(_ presets: [RoutePreset]) -> CollectionPersistenceSubmission {
        persistence.submit(
            presets,
            recordCount: presets.count,
            estimatedEncodedBytes: encodedSizeUpperBoundForDiagnostics(presets))
    }

    static func flush(
        timeout: Duration = .seconds(1),
        completion: @escaping @MainActor @Sendable (PreferenceFlushResult) -> Void
    ) {
        persistence.flush(timeout: timeout, completion: completion)
    }

    static func encodedSizeUpperBoundForDiagnostics(_ presets: [RoutePreset]) -> Int? {
        var budget = JSONEncodedSizeBudget(
            limit: CollectionPersistenceLimits.userCollection.maximumEncodedBytes)
        budget.addSyntax()
        for preset in presets {
            budget.addSyntax()
            budget.addField("name", string: preset.name)
            budget.addField("sampleRate", number: preset.sampleRate)
            budget.addIntegerField("bufferFrames")
            budget.addBooleanField("voiceIsolationEnabled")
            budget.addField("voiceIsolationMix", number: preset.voiceIsolationMix)
            budget.addField("channelMode", string: preset.channelMode)
            budget.addBooleanField("cancelsEcho")
            budget.addField("recordingFormat", string: preset.recordingFormat)
            budget.addField("note", string: preset.note)
            budget.addBooleanField("isUserDefined")
            budget.addStringArrayField("effects", values: preset.effects)
            budget.addFloatDictionaryField("effectValues", values: preset.effectValues)
            budget.addField("voicePreset", string: preset.voicePreset)
            budget.addField("inputDecibels", number: preset.inputDecibels)
            budget.addField("outputDecibels", number: preset.outputDecibels)
            budget.addField("monitorDeviceUID", string: preset.monitorDeviceUID)
            budget.addField("sourceDeviceUID", string: preset.sourceDeviceUID)
            budget.addField(
                "destinationDeviceUID", string: preset.destinationDeviceUID)
            budget.addStringArrayField(
                "capturedAppBundleIDs", values: preset.capturedAppBundleIDs)
            budget.addField("isDucking", boolean: preset.isDucking)
            budget.addField("duckDecibels", number: preset.duckDecibels)
            budget.addField("isAutoLevelling", boolean: preset.isAutoLevelling)
            budget.addField("loudnessTarget", string: preset.loudnessTarget)
            budget.addSyntax(2)
            if budget.hasExceededLimit || !budget.isValid { break }
        }
        budget.addSyntax()
        return budget.upperBound
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

            // The processing. Every preset carries this now, including the
            // built-in four — a scene that moves a buffer size and leaves the
            // chain alone is a scene that does nothing anybody can hear.
            if let effects = preset.effectKinds {
                enabledEffects = effects
            }
            // Merged rather than assigned. A preset names the knobs it has an
            // opinion about; the ones it does not name belong to whoever set
            // them, and wholesale replacement would throw away a stage's tuning
            // every time somebody pressed a scene that does not use that stage.
            if let values = preset.effectValues {
                effectValues.merge(values) { _, fromPreset in fromPreset }
            }
            if let voice = preset.voicePreset.flatMap(VoicePreset.init(rawValue:)) {
                voicePreset = voice
            }
            if let level = preset.inputDecibels { inputDecibels = level }
            if let level = preset.outputDecibels { outputDecibels = level }
            if let ducking = preset.isDucking { isDucking = ducking }
            if let depth = preset.duckDecibels { duckDecibels = depth }
            if let levelling = preset.isAutoLevelling { isAutoLevelling = levelling }
            if let target = preset.loudnessTarget.flatMap(LoudnessTarget.init(rawValue:)) {
                loudnessTarget = target
            }
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
    @discardableResult
    func saveCurrentAsPreset(named name: String) -> UserPresets.SaveResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidName }
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
        preset.isDucking = isDucking
        preset.duckDecibels = duckDecibels
        preset.isAutoLevelling = isAutoLevelling
        preset.loudnessTarget = loudnessTarget.rawValue

        // Saving over a name that exists replaces it rather than making a
        // second one: the alternative is a list of "Podcast", "Podcast 2",
        // "Podcast 3" and no way to tell which is current.
        var presets = userPresets.filter { $0.name != trimmed }
        presets.append(preset)
        if let refusal = UserPresets.refusal(for: presets) {
            return .refused(refusal)
        }
        userPresets = presets
        activePresetName = trimmed
        return .saved(preset)
    }

    func deletePreset(_ preset: RoutePreset) {
        guard preset.isUserDefined else { return }
        userPresets.removeAll { $0.name == preset.name }
        if activePresetName == preset.name { activePresetName = nil }
    }

    /// True when the current settings still match the named preset.
    ///
    /// Every field the preset sets has to be compared, or two presets that
    /// differ only in a field nobody checks both light up at once. The
    /// processing chain is now the field they differ in most, so it is compared
    /// too — which also means that switching one stage off stops the scene
    /// button claiming to describe what is running, and it no longer does.
    func matches(_ preset: RoutePreset) -> Bool {
        guard voiceIsolationEnabled == preset.voiceIsolationEnabled,
            channelMode.rawValue == preset.channelMode,
            preferredSampleRate == preset.sampleRate,
            bufferFrames == preset.bufferFrames,
            cancelsEcho == preset.cancelsEcho,
            recordingFormat.rawValue == preset.recordingFormat
        else { return false }
        // Absent on a preset saved before presets carried a chain. Comparing
        // against an empty set there would report every one of them as never
        // matching, which is worse than not comparing.
        if let effects = preset.effectKinds, effects != enabledEffects { return false }
        // Only the knobs the preset has an opinion about, because only those
        // are the ones it set.
        if let values = preset.effectValues,
            values.contains(where: { effectValues[$0.key] != $0.value })
        {
            return false
        }
        if let target = preset.loudnessTarget, target != loudnessTarget.rawValue {
            return false
        }
        if let ducking = preset.isDucking, ducking != isDucking { return false }
        if let levelling = preset.isAutoLevelling, levelling != isAutoLevelling {
            return false
        }
        return true
    }
}
